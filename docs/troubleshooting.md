# What broke, and why

Real failures hit while building this, with root causes. Both of the first two are general Kubernetes traps, not anything specific to this repo — you'll meet them again.

---

## 1. `applicationsets` CRD fails at exactly 262144 bytes

**Symptom**

```
The CustomResourceDefinition "applicationsets.argoproj.io" is invalid:
metadata.annotations: Too long: may not be more than 262144 bytes
```

Everything else in the Argo CD install applied cleanly. Only this one CRD failed.

**Root cause**

`kubectl apply` defaults to **client-side apply**. To compute a three-way merge on the next apply, it stores the *entire manifest you just applied* in an annotation on the object:

```
kubectl.kubernetes.io/last-applied-configuration
```

Kubernetes caps total annotation size at 256 KB (262144 bytes). The ApplicationSet CRD's OpenAPI schema is larger than that on its own, so the annotation can never be written and the apply fails.

**Fix**

```bash
kubectl apply --server-side --force-conflicts -f <manifest>
```

**Server-side apply** moves merge logic into the API server, which tracks per-field ownership in `metadata.managedFields` instead of stuffing a copy of the manifest into an annotation. There is no annotation to overflow.

`--force-conflicts` is needed here because the object already had client-side-apply metadata from the failed attempt; without it, SSA refuses to take ownership of fields another manager claims.

**Generalise it**

This bites on nearly every large CRD — Argo, Istio, Prometheus Operator, Crossplane. If a manifest fails at exactly 262144 bytes, you already know the answer. Server-side apply has been the recommended default for CRD installation for a while; client-side is legacy behaviour that happens to still be the default.

---

## 2. `runAsNonRoot` needs a *numeric* UID

**Symptom**

```
NAME                       READY   STATUS                       RESTARTS   AGE
podinfo-7bd74ffdcc-8ml5s   0/1     CreateContainerConfigError   0          4m58s
```

Note the status: `CreateContainerConfigError`, not `CrashLoopBackOff`. The container never started — the kubelet refused to create it. `describe pod` shows:

```
container has runAsNonRoot and image has non-numeric user (app),
cannot verify user is non-root
```

**Root cause**

The pod spec had:

```yaml
securityContext:
  runAsNonRoot: true      # and no runAsUser
```

`runAsNonRoot: true` is a promise the kubelet must *verify* before starting the container. podinfo's image declares its user by name (`USER app`), not by number. Resolving `app` to a UID would mean reading `/etc/passwd` inside the image, which the kubelet doesn't do. Unable to verify, it fails closed.

Failing closed is correct behaviour — but it means `runAsNonRoot` is only usable with a numeric UID, either in the image (`USER 100`) or in the pod spec.

**Fix**

```yaml
securityContext:
  runAsNonRoot: true
  runAsUser: 100        # the UID podinfo's upstream Helm chart uses
```

**The mistake behind the mistake**

I originally removed `runAsUser` deliberately, reasoning that pinning a UID was fragile — it would break if the upstream image changed its user. That reasoning wasn't wrong, but it traded a *hypothetical future* break for a *guaranteed immediate* one. Bad trade.

**The lesson that actually matters**

A hardened default that CrashLoops on first deploy is worse than no default at all.

Every service scaffolded from `apps/podinfo/base/` inherits this security context. If it fails on first deploy, the product team's conclusion isn't "I should debug the securityContext" — it's "the platform is broken, I'll copy someone else's working YAML instead." Teams remember the first thing that broke, and adoption is the thing platform teams are actually measured on.

Which is also why the base ships `emptyDir` volumes at `/data` and `/tmp`: `readOnlyRootFilesystem: true` without writable paths for a process that needs them is the same failure wearing a different hat.

---

## 3. Argo CD shows `ComparisonError` / "repository not accessible"

**Cause, almost always:** `make init` was run but the result was never pushed.

Argo CD clones from the **remote**, not your working copy. A committed-but-unpushed change is invisible to it, as is an uncommitted one.

```bash
git status              # must be clean
git log origin/main -1  # must show your commit
```

Also check the `repoURL` in `clusters/local/applications/*.yaml` is an HTTPS URL. Argo CD runs in-cluster with no SSH key, so `git@github.com:...` won't authenticate — `init-repo.sh` normalises this, but a hand-edited URL can reintroduce it.

---

## 4. Pod `Progressing` forever

`Progressing` means Argo deployed the resources but they aren't passing readiness. Argo is fine; the workload isn't.

```bash
kubectl -n podinfo get pods
kubectl -n podinfo describe pod | grep -A10 "Events:"
```

The Events section names the actual problem. Common ones: image pull failure, a readiness probe pointed at a port nothing listens on, or a container that exits immediately.

Worth internalising the distinction: **Sync status** is "does the cluster match Git." **Health status** is "is the thing actually working." An app can be perfectly `Synced` and completely `Degraded` — you told it to run something broken, and it faithfully did.

---

## 5. `bind: address already in use` on port-forward

```
Unable to listen on port 8081: ... bind: address already in use
```

A previous `kubectl port-forward` is still running, usually in a terminal tab you forgot about.

```bash
lsof -i :8081          # confirm it's kubectl
lsof -ti:8081 | xargs kill
```

Or just use a different port — `kubectl -n argocd port-forward svc/argocd-server 8082:443`.

---

## 6. Browser warns "connection is not private"

Argo CD serves a self-signed certificate. Your browser can't distinguish "self-signed on your own laptop" from "someone impersonating a site," so it warns.

Chrome: **Advanced → Proceed to localhost (unsafe)**, or click the page and type `thisisunsafe`.
Safari: **Show Details → visit this website**.

In a real deployment you'd terminate TLS at an ingress with a certificate from a trusted CA (cert-manager + Let's Encrypt is the standard answer), or run Argo CD's server in insecure mode behind a mesh that handles mTLS.

---

## 7. Argo CD child Applications stuck `Unknown`, revision shows `__REPO_REVISION__`

**Symptom**

```
NAME                 SYNC STATUS   HEALTH STATUS   REVISION
crossplane-config    Unknown       Healthy         __REPO_REVISION__
crossplane-runtime   Unknown       Healthy         __REPO_REVISION__
platform-apis        Unknown       Healthy         __REPO_REVISION__
root                 Synced        Healthy         18a7ff67...
podinfo              Synced        Healthy         47229b2e...
```

The working copy is clean, `make init` reports nothing to do, and `git status`
says everything is pushed. But the cluster disagrees.

**Root cause**

Look at the two revisions: `root` is at an *older* commit than `podinfo`.

Each Argo CD Application polls Git independently on its own ~3 minute interval.
`root` had not re-polled since before the `make init` commit, so it was still
reconciling the *old* versions of the child Application manifests — the ones
that still contained placeholders. Root faithfully wrote those stale specs into
the cluster, and the children, pointed at a repo URL that doesn't resolve,
reported `Unknown`.

The lesson generalises: in an app-of-apps setup, **a stale root produces stale
children**, and the child's symptom points at the child, not at the root. When
children look wrong, check the root's revision first.

**Fix**

Force root to re-read Git:

```bash
kubectl -n argocd patch app root --type merge \
  -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'
```

If the children were already created with a bad spec, delete them so root
rebuilds from current Git:

```bash
kubectl -n argocd delete app crossplane-runtime crossplane-config platform-apis --wait=false
```

`--wait=false` avoids hanging on the cascade-delete finalizer. Safe when the
Applications own nothing yet; think twice when they own live infrastructure.

**Prevention**

A webhook from GitHub to Argo CD removes the poll delay entirely. Not possible
against a localhost cluster, which is why this lab feels slower than a real
environment — and why webhooks exist.

---

## 8. `no matches for kind "ObjectStorage"` — a guard that checked half a condition

**Symptom**

```
error: resource mapping not found for name: "" namespace: "default"
from "examples/objectstorage.yaml": no matches for kind "ObjectStorage"
in version "platform.golden-path.io/v1alpha1"
ensure CRDs are installed first
```

**Immediate cause**

The XRD wasn't established, because `platform-apis` (sync wave 3) never synced,
because of the stale-root problem above. `kubectl get xrd` returning nothing
confirms it in one command — always check whether the CRD exists before
debugging the resource that needs it.

**The more interesting cause**

`bootstrap.sh` calls `assert_repo_initialised`, which was supposed to stop
exactly this. It didn't, because it only grepped for one of the two
placeholders:

```bash
# before -- checks __REPO_URL__ only
if grep -rq '__REPO_URL__' "${REPO_ROOT}/clusters"; then

# after
if grep -rq '__REPO_URL__\|__REPO_REVISION__' "${REPO_ROOT}/clusters"; then
```

Lab 1 never caught this because both placeholders were always resolved
together. Lab 2 added new manifests and the partial check sailed straight
through.

**The lesson**

**A guard that verifies half its condition is worse than no guard**, because it
buys false confidence. The failure surfaced four steps downstream as a confusing
error about a missing CRD, and the whole point of a precondition check is to
fail early with a message that names the actual problem.

If you write a check, enumerate every condition it claims to cover — and add a
case to it whenever you add something new it should be watching.

---

## 9. Crossplane didn't correct drift after 60 seconds (it wasn't broken)

**Symptom**

Deleted a bucket's tags with the AWS CLI, waited a minute, checked again:

```
An error occurred (NoSuchTagSet) when calling the GetBucketTagging operation:
The TagSet does not exist
```

Lab 1's drift demo self-healed in ~5 seconds. This looked like a failure. It
wasn't — the assumption was.

**Root cause**

Argo CD and Crossplane observe the world in fundamentally different ways:

| | Argo CD (in-cluster) | Crossplane (cloud) |
|---|---|---|
| How it observes | Kubernetes **informers** — a streaming watch | **Polls** the cloud provider's API |
| Notified of change | Immediately, by the API server | Not at all; must ask |
| Drift correction | Seconds | Bounded by the poll interval |

Kubernetes pushes events to watchers. **AWS has no equivalent** — nothing tells
your cluster that someone deleted a tag. So the provider has to wake up on a
timer and compare. Upjet-based providers, which the AWS family are, default to a
**10-minute** poll interval.

Nothing was wrong. The controller was going to fix it — just not on the
timescale Lab 1 conditioned me to expect.

**Force it**

Touching any annotation generates a watch event on the managed resource, which
wakes the controller immediately instead of waiting for its timer:

```bash
kubectl -n default annotate bucket <name> reconcile-now="$(date +%s)" --overwrite
```

The tags came back within 30 seconds. To change it permanently, set
`--poll-interval` on the provider via a `DeploymentRuntimeConfig`.

**The trade-off worth being able to discuss**

Shortening the poll interval closes drift faster, but the cost is multiplied
across *every* managed resource the provider owns. A platform with thousands of
resources polling every 30 seconds generates serious API traffic — AWS
rate-limits, throttled calls make reconciliation slower rather than faster, and
CloudTrail charges for the volume.

So "how fast should drift close?" is a real engineering decision with a bill
attached, not a value to crank to the minimum. Most teams leave the default and
rely on preventive controls — SCPs, IAM boundaries, Kyverno — to stop
out-of-band changes happening at all, rather than racing to correct them after.

---

## 10. The demo that failed because there were two buckets

**Symptom**

Tags stripped from a bucket, a reconcile forced on "the" managed resource,
tags still missing. The MR reported `Synced: True` and `ReconcileSuccess`, and
its own tags were visibly correct in `describe`.

**Root cause**

`make bucket` had been run twice. Two `ObjectStorage` XRs, two buckets. The
lookup command used to find the managed resource was:

```bash
MR=$(kubectl get buckets.s3.aws.m.upbound.io -A -o jsonpath='{.items[0].metadata.name}')
```

`items[0]`. Tags were deleted from bucket A; the reconcile was forced on
bucket B; bucket A was then checked and found wanting. Every individual piece
reported success, because every individual piece *was* succeeding.

**The lesson**

`items[0]` is fine in a demo with one resource and a bug the moment there are
two — and it fails *silently*, by operating confidently on the wrong object.
That is worse than an error, because the misleading evidence sends you
debugging the controller instead of the query.

Match on identity, never on position:

```bash
kubectl get buckets.s3.aws.m.upbound.io -A \
  -o jsonpath="{.items[?(@.metadata.annotations['crossplane\.io/external-name']=='$BUCKET')].metadata.name}"
```

More generally: when a system insists every component is healthy but the
outcome is wrong, stop debugging components and check whether you are looking
at the thing you think you are looking at.
