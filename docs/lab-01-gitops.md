# Lab 1 — GitOps delivery with Argo CD

**Time:** about an evening, most of it waiting for images to pull.
**You'll end with:** a local cluster whose entire contents are a function of this Git repo, and a demonstrable understanding of why that's different from running `kubectl apply` in CI.

---

## Before you start

```bash
docker version      # must be running
kind version        # v0.32.0 or newer
kubectl version --client
```

Missing any of them, see [Prerequisites](../README.md#prerequisites).

---

## Step 1 — Point the repo at your fork

Argo CD pulls from a Git URL, so the Application manifests have to name the repo they live in. They ship with a `__REPO_URL__` placeholder.

```bash
make init
```

This reads your `origin` remote, rewrites the placeholders, and normalises an SSH remote to HTTPS (Argo CD runs in-cluster and has no SSH key).

**Then commit and push before continuing.** Argo CD reads the *remote*, not your working copy — this is the single most common way this lab fails:

```bash
git add -A && git commit -m "chore: point Argo CD applications at this fork" && git push
```

## Step 2 — Bootstrap

```bash
make up
```

Which does, in order:

1. Creates a kind cluster, pinned to a digest so you get the same Kubernetes every time.
2. Installs Argo CD (v3.4.5, pinned) and waits for the repo-server, API server, and application controller to be genuinely ready — not just scheduled.
3. Applies **one** manifest: `clusters/local/bootstrap/root-app.yaml`.

Step 3 is the interesting one. It's the only imperative act in the whole system. Everything else arrives because a controller noticed it was missing.

Cold start is 3–5 minutes, nearly all of it pulling Argo CD images.

## Step 3 — Watch it converge

```bash
make status
```

```
NAME      SYNC STATUS   HEALTH STATUS
podinfo   Synced        Healthy
root      Synced        Healthy
```

You applied `root`. You did not apply `podinfo` — the root Application found it in `clusters/local/applications/`, created it, and that child then deployed the workload. That's the app-of-apps pattern: one root, N children discovered from a directory.

Open the UI to see the ownership tree:

```bash
make argocd-ui          # https://localhost:8081
make argocd-password    # username is: admin
```

(The cert is self-signed. Your browser will complain; proceed anyway.)

And the app itself: <http://localhost:8080>

## Step 4 — Break it

This is the lab.

```bash
make drift-demo
```

The script scales the deployment to 5 replicas by hand, then polls until Argo CD puts it back to 2.

```
==> current replicas (as declared in Git): 2
==> introducing drift: scaling to 5 by hand
==> watching Argo CD self-heal (selfHeal: true) ...
   t+5s    replicas=5
   t+10s   replicas=5
   ...
   t+40s   replicas=2
```

**Sit with what just happened.** No pipeline ran. No webhook fired. Nothing pushed anything into the cluster. The application controller woke up on its polling interval, compared live state against the Git revision, saw a difference, and corrected it. It will do that forever.

That is the actual distinction between GitOps and "CI that runs kubectl":

| | Push-based CI | Pull-based GitOps |
|---|---|---|
| What applies changes | A pipeline, when triggered | A controller, continuously |
| Manual change to the cluster | Persists until someone notices | Reverted within one sync interval |
| Cluster credentials | Held by CI, outside the cluster | Never leave the cluster |
| "Does the repo describe prod?" | Hopefully | Yes, by construction |
| Adding a cluster | Another CI target + another credential | Another controller pulling the same repo |

The last row is why this pattern won for multi-cluster. Push-based delivery makes CI a hub that must hold credentials for every cluster it deploys to. Pull-based inverts it: each cluster pulls, and CI never needs cluster access at all.

## Step 5 — Drive it the other way

Drift correction is one direction of the loop. Now the intended one:

```bash
# edit apps/podinfo/overlays/local/kustomization.yaml, set count: 3
git commit -am "feat: scale podinfo to 3" && git push
```

Watch `make status`, or hit **Refresh** in the UI to skip the poll interval. Same controller, same mechanism, opposite direction — converging toward a new declared state rather than back to the old one.

There is no separate "deploy" concept in this system. There is only: *what does Git say, and does the cluster match?*

## Step 6 — Tear down

```bash
make down
```

Free to run, free to forget. Lab 2's teardown is the one that matters — that one deletes real AWS resources.

---

## Things worth breaking on purpose

The lab is more useful if you make it fail. Some suggestions:

**Delete the podinfo namespace.** `kubectl delete ns podinfo`. Watch it come back. Ask yourself which controller did that, and what `CreateNamespace=true` in the sync options has to do with it.

**Delete the child Application.** `kubectl -n argocd delete app podinfo`. The root app recreates it — the child is itself declared in Git.

**Delete the file instead.** Remove `clusters/local/applications/podinfo.yaml`, commit, push. Now the workload really goes away, because `prune: true` means "resources absent from Git should be absent from the cluster". Compare the two failure modes and you'll understand `prune` properly.

**Turn off `selfHeal`.** Set it to `false` in the child Application, push, then re-run the drift demo. It reports OutOfSync and does nothing. Now you understand what the flag actually buys, and why some teams deliberately leave it off in production (manual intervention during an incident stops being silently undone — at the cost of drift becoming permanent again).

**Push a broken manifest.** Bad indentation, or a `replicas: "two"`. Watch Argo CD report `ComparisonError` and — importantly — *not* take down the running app. Then note that `make validate` would have caught it before the push. That's the argument for the CI job in one experiment.

---

## Troubleshooting

**`ComparisonError` / `repository not accessible`**
You didn't push after `make init`, or the remote is private. Argo CD reads the remote. Check: `git status` is clean, `git log origin/main -1` shows your commit.

**`Unknown` / stuck `Progressing`**
Usually image pull. `kubectl -n podinfo describe pod` will say so plainly.

**Pod `CrashLoopBackOff` right after a securityContext change**
Almost always `readOnlyRootFilesystem: true` without a writable volume where the process wants to write. The base has `emptyDir` mounts at `/data` and `/tmp` for exactly this reason — this is the failure mode that makes teams abandon hardened defaults.

**`make up` says the repo isn't initialised**
`make init` hasn't run, or ran on a clone with no `origin`. Run `make init REPO_URL=https://github.com/<you>/platform-golden-path.git`.

**Port 8080 already in use**
Change `hostPort` in `clusters/local/kind.yaml` and recreate the cluster (`make down && make up`). Port mappings are fixed at cluster creation.

---

## What to say about this in an interview

Not "I set up Argo CD." Everyone has set up Argo CD.

The interesting claims are the ones about judgment:

- **Why pull over push** — credentials never leave the cluster, drift has a bounded lifetime, and adding a cluster doesn't mean adding a CI credential.
- **Why exactly one imperative step**, and why you'd defend that boundary rather than automating it away.
- **What you put in the base and what you deliberately left out** — and that "every option in a template is cognitive load pushed onto the customer."
- **The `readOnlyRootFilesystem` trap** — you shipped hardened defaults *and* made them actually work on first deploy, because a platform default that CrashLoops is worse than no default at all. Teams remember the first thing that broke.
- **Why the cluster is local and the money went to the AWS layer instead.** Cost-awareness is graded explicitly in design rounds now, and "I chose not to spend $73/month on something indistinguishable from free" is a better answer than having run EKS.

---

**Next:** [Lab 2 — self-service infrastructure with Crossplane](aws-setup.md) →
