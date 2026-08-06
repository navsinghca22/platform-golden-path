# Concepts — how this works, and why it's built this way

Written to be re-readable. If you come back to this repo after three months away, start here.

---

## 1. Reconciliation: the idea underneath everything

Almost every modern infrastructure tool is a **reconciliation loop**. Once you see it, Kubernetes stops being a pile of YAML and starts being one idea repeated.

A thermostat is the cleanest analogy:

1. You declare a **desired state** — 70°.
2. A controller observes **actual state** — it's 64°.
3. It acts to close the gap — turns on the heat.
4. It never stops. Open a window and it responds. Nobody has to "run" the thermostat.

That's it. Kubernetes is a stack of these:

| Controller | Desired state | Actual state | Action |
|---|---|---|---|
| Deployment controller | 2 replicas | 1 pod running | create a pod |
| ReplicaSet controller | this pod spec | pod with old spec | replace it |
| **Argo CD** | **what Git says** | **what's in the cluster** | **make the cluster match** |

Argo CD isn't a new kind of thing. It's the same pattern applied one level up, with Git as the desired state.

**Why this matters:** in an imperative world you describe *steps* ("create this, then update that"), and steps only run when triggered. In a declarative world you describe the *destination*, and something is permanently responsible for getting there. The second survives things going wrong at 3am; the first doesn't.

---

## 2. Pull vs push, and why pull won

The older model: a CI pipeline holds credentials for your clusters and runs `kubectl apply` when triggered.

The GitOps model: a controller *inside* each cluster pulls from Git and reconciles continuously.

| | Push (CI applies) | Pull (GitOps) |
|---|---|---|
| What applies changes | A pipeline, when triggered | A controller, continuously |
| Manual change to the cluster | Persists until noticed | Reverted within one sync interval |
| Where cluster credentials live | In CI, outside the cluster | Never leave the cluster |
| "Does the repo describe prod?" | Hopefully | Yes, by construction |
| Adding a cluster | Another CI target + another credential | Another controller pulling the same repo |
| Blast radius of CI compromise | Every cluster CI can reach | No cluster access to steal |

The last two rows are the real reason for the industry shift. Push-based delivery makes CI a hub that must hold credentials for every environment it touches — which means CI becomes the highest-value target in your infrastructure. Pull-based inverts it: each cluster reaches out, and CI never needs cluster access at all.

The drift property is what you can *demonstrate*, though, which is why `make drift-demo` exists.

---

## 3. The asymmetry: fast healing, slow deploys

Run `make drift-demo` and the correction lands in about **5 seconds**. Push a change to Git and it can take up to **3 minutes**. Same controller. Why?

Because Argo CD observes the two sides differently:

- **Cluster state** — watched via Kubernetes *informers*, a streaming watch API. Changes arrive as events, nearly instantly.
- **Git state** — *polled* on an interval (3 minutes by default). Argo CD has to ask GitHub "anything new?"

So drift correction is event-driven and fast; deployment is poll-driven and eventual.

This is why webhooks exist: configure GitHub to notify Argo CD on push and the Git side becomes event-driven too. In this lab there's no webhook, because localhost isn't reachable from GitHub — which is itself a useful thing to understand about why local development environments feel slower than they need to.

Being able to explain this asymmetry is a good signal that you understand the system rather than the tutorial.

---

## 4. App-of-apps: why onboarding is a pull request

`bootstrap.sh` applies exactly **one** manifest — the root Application. Everything else appears because a controller found it.

```
root Application
  watches:  clusters/local/applications/
              └── podinfo.yaml  ──►  podinfo Application
                                       watches: apps/podinfo/overlays/local/
                                                  └── the actual Deployment, Service
```

Two levels, two different jobs:

- **root** manages *Application definitions* — the list of what exists.
- **children** manage *workloads* — the actual running things.

The consequence is organisational, not technical. Adding a service to the platform means **adding one file to a directory and opening a PR**. No cluster credentials. No knowledge of Argo CD. No ticket, and — importantly — no conversation with the platform team.

That last point is the whole argument. A platform whose adoption requires a meeting doesn't scale past the platform team's calendar. Self-service isn't a nice-to-have feature; it's the only thing that makes a small platform team able to serve many product teams.

---

## 5. `prune` and `selfHeal`: two different promises

Both are in `syncPolicy.automated`, both default to `false`, and they do genuinely different things.

**`selfHeal: true`** — "if the live cluster differs from Git, fix the cluster."
Someone scales a deployment by hand → reverted.

**`prune: true`** — "if a resource exists in the cluster but not in Git, delete it."
Someone removes a file from the repo → resource deleted.

Without `prune`, deleting a manifest from Git leaves the resource running forever, silently. Your repo says one thing, the cluster does another, and nobody notices until an audit.

Without `selfHeal`, manual changes stick around. Some teams **deliberately** turn `selfHeal` off in production so that emergency intervention during an incident isn't silently undone at the worst possible moment — accepting permanent drift as the price. That's a real trade-off with defensible answers on both sides, and knowing it's a trade-off rather than a best practice is the point.

Try it: set `selfHeal: false`, push, re-run the drift demo. Argo reports OutOfSync and does nothing.

---

## 6. Kustomize: base and overlay

```
apps/podinfo/
  base/                  what's true everywhere
  overlays/local/        only what differs here
```

The overlay doesn't copy the base — it *references* it and patches. So `replicas: 2` in the local overlay overrides `replicas: 1` in the base, and everything else is inherited.

**The rule worth internalising:** if an overlay starts to look like a fork of the base, the abstraction is wrong. The fix is to change the base or split it — not to add more patches. Overlay sprawl is how platforms die: after two years nobody can predict what a given environment actually renders to, and teams stop trusting the platform.

Why `service-nodeport.yaml` lives in the overlay and not the base: NodePort is a local convenience for reaching the app at `localhost:8080`. Nothing about it should follow a service into an environment that has a real ingress controller. Environment-shaped things belong in overlays.

---

## 7. What makes this "platform engineering" and not just "DevOps"

The CNCF Platforms White Paper lists attributes of a good platform. Four of them are visible in this repo, and they're worth knowing by name because interviewers use this vocabulary:

**Platform as a product.** The platform exists to serve its users' requirements, and is designed and evolved based on those requirements — like any product. Product teams are *customers*, not ticket submitters.

**Self-service.** Users must be able to request and receive capabilities autonomously, with minimal manual intervention. Here: a PR adding one file.

**Reduced cognitive load.** The platform hides complexity so product teams don't carry it. A service scaffolded from `base/` gets probes, limits, security hardening and observability without anyone thinking about them.

**Optional and composable.** A platform must not be an impediment; teams must be able to use parts of it, and to provide their own capabilities when the platform doesn't fit. Every abstraction needs an escape hatch — without one, your best engineers route around the platform and you end up with two systems instead of one.

There's a fifth that this repo learned the hard way: **secure by default**, but only if the defaults actually work. See `docs/troubleshooting.md` — a hardened default that CrashLoops on first deploy is worse than no default at all, because the team that hits it stops trusting you.

---

## 8. Vocabulary

Terms that show up constantly in this space:

**Golden path / paved road** — the well-lit, supported way to do a common thing. Optional, but so much easier than the alternatives that people choose it.

**Thinnest viable platform** — build the smallest layer that delivers the value. A wiki page of standard procedures can be a legitimate platform. Platform teams that build everything become the bottleneck they were created to remove.

**Cognitive load** — the total amount a team must hold in their head to do their job. The core design constraint of platform engineering; reducing it is most of the value.

**Drift** — divergence between declared state and actual state.

**Reconciliation** — the continuous process of eliminating drift.

**Declarative vs imperative** — describing the destination vs describing the steps.

**Idempotent** — running it twice produces the same result as running it once. `bootstrap.sh` is idempotent on purpose: re-running it on a half-built cluster converges rather than breaking.

**DORA metrics** — deployment frequency, lead time for changes, change failure rate, time to restore. The standard way platform teams demonstrate impact on delivery.

---

## Further reading

- [CNCF Platforms White Paper](https://tag-app-delivery.cncf.io/whitepapers/platforms/) — short, free, and the source of most of the vocabulary above
- [CNCF Platform Engineering Maturity Model](https://tag-app-delivery.cncf.io/whitepapers/platform-eng-maturity-model/)
- [Team Topologies](https://teamtopologies.com/key-concepts) — where "cognitive load" and "thinnest viable platform" come from
- [Argo CD docs](https://argo-cd.readthedocs.io/en/stable/) — particularly the sync options and application specification pages
