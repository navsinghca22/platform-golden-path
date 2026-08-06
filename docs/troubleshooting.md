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
