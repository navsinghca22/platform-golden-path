# platform-golden-path

[![validate](https://github.com/navsinghca22/platform-golden-path/actions/workflows/validate.yaml/badge.svg)](https://github.com/navsinghca22/platform-golden-path/actions/workflows/validate.yaml)

An internal developer platform. A developer fills in a five-field form and gets a hardened, observable service with the cloud infrastructure it needs — without touching a cluster or a cloud console.

GitOps delivery, self-service infrastructure, and a scaffolder that ties them together. Control plane runs locally; the AWS resources it provisions are real.

> **Status:** All three labs complete — GitOps delivery, self-service cloud infrastructure,
> and a golden path a developer can walk without reading any of it.

### Where to start

| If you want to… | Read |
|---|---|
| Run it | [Quick start](#quick-start) below — about 5 minutes |
| Understand *why* it's built this way | **[docs/concepts.md](docs/concepts.md)** — reconciliation, pull vs push, app-of-apps, cognitive load |
| Follow the labs step by step | [1 — GitOps](docs/lab-01-gitops.md) · [2 — Crossplane](docs/lab-02-crossplane.md) · [3 — Scaffolder](docs/lab-03-scaffolder.md) |
| See what broke and why | [docs/troubleshooting.md](docs/troubleshooting.md) — real failures, root causes |
| Understand the decisions | [0001 — local control plane](docs/adr/0001-local-control-plane.md) · [0002 — credentials](docs/adr/0002-static-credentials-vs-irsa.md) · [0003 — no Backstage](docs/adr/0003-scaffolder-not-backstage.md) |

`concepts.md` is the one to read if you only read one. It explains the ideas rather than the commands, and it's written to be re-read.

---

## The problem this solves

A fictional-but-familiar org: **15 product teams, no platform team.**

Standing up a new service means finding a neighbouring team's repo and copying it. That repo was itself copied from somewhere else, eighteen months ago, and nobody remembers what the `resources` block was tuned for. The result:

- **Time to first deploy for a new service: ~3 days**, nearly all of it spent reverse-engineering someone else's YAML.
- **No two services are observable the same way.** Some export Prometheus metrics on 9090, some on 8080, some not at all. Building a dashboard that spans services is a research project.
- **Drift is permanent.** Someone scales a deployment by hand during an incident. It stays scaled. Six months later nobody can say whether the repo describes production.
- **Security defaults are whatever the original author happened to write in 2023.** Half the fleet runs as root because one seed repo did.

None of these are Kubernetes problems. They're the absence of a paved road.

## What this repo builds

A golden path: one well-lit way to get a service running, with the right defaults already applied, that a product team can adopt without learning the platform's internals.

```
                       ┌──────────────────────────────────────────┐
   git push ─────────► │  Git — the only source of truth          │
                       │    apps/<service>/…      workloads       │
                       │    clusters/local/…      what runs where │
                       └───────────────────┬──────────────────────┘
                                           │ pull (poll + reconcile)
                                           ▼
                       ┌──────────────────────────────────────────┐
                       │  Argo CD          root "app of apps"     │
                       │    └── services (scaffolded)             │
                       │    └── crossplane (provider + config)    │
                       │    └── platform APIs (XRD + Composition) │
                       └───────────────────┬──────────────────────┘
                                           │ reconcile
                                           ▼
                       ┌──────────────────────────────────────────┐
                       │  kind cluster (local, free, disposable)  │
                       └───────────────────┬──────────────────────┘
                                           │ Crossplane (namespaced XRs)
                                           ▼
                       ┌──────────────────────────────────────────┐
                       │  AWS — real S3, real IAM, real API       │
                       └──────────────────────────────────────────┘
```

---

## Quick start

**Prerequisites:** Docker (or OrbStack), `kind`, `kubectl`. See [Prerequisites](#prerequisites) for install commands.

```bash
git clone https://github.com/<you>/platform-golden-path.git
cd platform-golden-path

make init      # point the Argo CD Applications at your fork
git add -A && git commit -m "chore: point at my fork" && git push

make up        # kind cluster + Argo CD + root app   (~4 min cold)
make drift-demo  # the part that actually teaches something
```

Then:

| | |
|---|---|
| Sample app | <http://localhost:8080> |
| Argo CD UI | `make argocd-ui` → <https://localhost:8081> |
| Admin password | `make argocd-password` |
| Application state | `make status` |
| Tear down | `make down` |

Run `make help` for everything.

---

## The design decisions, and why

### Local control plane, real cloud infrastructure

The obvious way to build this is on EKS. I deliberately didn't.

EKS is **$0.10/hr per cluster for the control plane alone** — about $73/month before a single worker node, NAT gateway, or load balancer. A realistic always-on lab cluster runs $150–450/month. And it buys nothing here: the manifests Argo CD reconciles are byte-identical whether the API server is EKS or kind. Nobody reading this repo can tell the difference.

So the money goes where the learning is. The **cluster is local and free**; the **infrastructure it provisions is real AWS** (Lab 2, via Crossplane) — real IAM, real credentials plumbing, real cloud API reconciliation, on free-tier resources costing pennies.

This is the same trade a platform team makes constantly: spend on the layer that's genuinely hard, use the cheap substitute everywhere the substitute is indistinguishable. See [ADR-0001](docs/adr/0001-local-control-plane.md).

### Exactly one imperative act

`bootstrap.sh` creates a cluster, installs Argo CD, and applies **one** manifest: the root Application. After that, the cluster's contents are a pure function of this repo.

That boundary is the whole point. "We use GitOps" usually means "we have a pipeline that runs `kubectl apply`". This means: there is one documented escape hatch, it is used once, and everything past it is reconciled continuously by a controller that doesn't care whether a pipeline ever runs again.

### App-of-apps, so onboarding is a pull request

The root Application watches `clusters/local/applications/`. Adding a workload to the platform is a PR that adds one file to that directory — no cluster credentials, no Argo CD knowledge, no ticket.

That's the mechanism, but the reason is organisational: **a platform whose adoption requires a conversation with the platform team doesn't scale past the platform team's calendar.**

### What's in the default template — and what isn't

Every service the scaffolder generates inherits, without asking:

- **Liveness and readiness probes** wired to real endpoints
- **Resource requests and limits**, so the scheduler can do its job and one service can't starve a node
- **A hardened `securityContext`** — non-root, no privilege escalation, read-only root filesystem, all capabilities dropped
- **A numeric `runAsUser` and a writable `/tmp`.** Both learned the hard way: `runAsNonRoot` fails closed without a numeric UID, and `readOnlyRootFilesystem` without writable paths CrashLoops on first deploy. A hardened default that doesn't start is worse than no default at all.
- **Prometheus scrape annotations**, so the service is observable on day one whether or not anyone remembered to ask

Deliberately **excluded** from the base:

| Excluded | Why |
|---|---|
| `NodePort` services | Local convenience only. It lives in the local overlay. Nothing about NodePort should follow a service into an environment that has a real ingress controller. |
| Ingress / TLS | Environment-shaped, not service-shaped. Belongs in overlays and the platform layer. |
| HPA | Needs per-service load characteristics. A default here would be a guess wearing a suit. |
| ServiceMonitor CRD | Requires Prometheus Operator to be installed. Plain annotations work with or without it — fewer preconditions, wider adoption. |
| Ingress hostnames | Environment-shaped. The platform supplies the mechanism; the team supplies the name, in an overlay. |

Every option in a template is cognitive load pushed onto the customer. The interesting engineering is in what you leave out.

### An escape hatch, on purpose

`resources` in the overlay can override anything in the base, and a team that genuinely needs something different can stop using the base entirely without leaving the platform. Any abstraction without an exit gets routed around by your best engineers — and then you have two problems: the thing you built, and the shadow platform they built to avoid it.

---

## Lab 1: what you'll actually see

Full walkthrough in **[docs/lab-01-gitops.md](docs/lab-01-gitops.md)**. The core of it:

```bash
make drift-demo
```

The script scales the deployment to 5 replicas by hand — the thing every incident runbook tells you to do — and then watches Argo CD put it back to 2, because Git says 2.

No pipeline ran. No webhook fired. The application controller compared live state against the Git revision on its polling interval and corrected the difference. **That's the property you're actually buying: drift has a bounded lifetime, and the repo is a truthful description of the cluster.**

Then run the loop the other way — change `replicas` in `apps/podinfo/overlays/local/kustomization.yaml`, push, and watch the same controller converge toward the new declared state. One mechanism, both directions.

Notice the timing difference: self-heal lands in ~5 seconds, a Git change takes up to 3 minutes. Argo CD *watches* cluster state via informers but *polls* Git. Drift correction is event-driven; deployment is eventual. [Why that matters →](docs/concepts.md#3-the-asymmetry-fast-healing-slow-deploys)

---

## The golden path, end to end

```bash
make scaffold NAME=checkout-api OWNER=team-checkout \
  IMAGE=ghcr.io/stefanprodan/podinfo:6.11.2 PORT=9898
```

Or, for someone who has never seen this repo: **Actions → scaffold new service → Run workflow**. Five fields and a checkbox produce a pull request containing a complete service plus its Argo CD `Application` — and an `ObjectStorage` request if they ticked the box. Merging the PR is the deploy.

What the developer supplied: a name, an owner, an image, a port, a checkbox.

What they never had to learn: probes, resource limits, security context, scrape annotations, namespace conventions, the Argo `Application` shape, AWS regions, bucket naming, or the tagging policy.

The scaffolder also **refuses** bad input with an explanation rather than a schema error four steps later — uppercase names, `:latest` tags, privileged ports, name collisions. A well-designed input schema catches most of what people reach for admission controllers to catch, at the moment the mistake is made, in language the person who made it understands.

It's a GitHub Actions form rather than Backstage, on purpose: [ADR-0003](docs/adr/0003-scaffolder-not-backstage.md).

---

## What broke while building this

Eleven failures are written up with symptoms and root causes. The two most transferable:

**The `applicationsets` CRD failed at exactly 262144 bytes.** Client-side `kubectl apply` stores the entire manifest in the `last-applied-configuration` annotation, and annotations cap at 256 KB. Server-side apply tracks ownership in `managedFields` instead — no annotation to overflow. This bites on nearly every large CRD.

**Pods failed with `CreateContainerConfigError` under `runAsNonRoot`.** The kubelet must *verify* the user isn't root before starting a container, and it can't resolve a named user (`USER app`) without reading the image's `/etc/passwd`. So it fails closed. `runAsNonRoot` is only usable alongside a numeric `runAsUser`.

The second one carries the more useful lesson, and it changed how the base template is written: **a hardened default that CrashLoops on first deploy is worse than no default at all.** A product team that hits it doesn't debug your securityContext — they conclude the platform is broken and copy someone else's working YAML. That's also why every generated service ships a writable `/tmp` (and podinfo additionally `/data`, because that image wants it) — `readOnlyRootFilesystem: true` without writable paths is the same failure wearing a different hat.

Full write-ups with symptoms and root causes: **[docs/troubleshooting.md](docs/troubleshooting.md)**.

---

## Prerequisites

```bash
# macOS
brew install --cask orbstack     # or Docker Desktop
brew install kubectl kind

# validation tooling (optional, CI runs it anyway)
brew install kustomize kubeconform shellcheck
```

OrbStack over Docker Desktop on a laptop: noticeably lighter on RAM and faster to start, which matters when the cluster, Argo CD and your workloads are all competing for it.

Versions are pinned in [`versions.env`](versions.env) — including the kind node image **by digest**, because kind rebuilds the same tag across releases and an unpinned tag makes "works on my machine" a coin flip.

## Repository layout

```
versions.env                      pinned versions, single source of truth
Makefile                          every operation, self-documenting (make help)
clusters/local/
  kind.yaml                       cluster shape + host port mappings
  bootstrap/root-app.yaml         the one imperative act
  applications/                   ← add a file here to onboard a service
apps/<service>/
  base/                           the golden path defaults
  overlays/local/                 only what differs for this environment
templates/service/                what the scaffolder renders
apis/storage/                     the platform's own API (XRD + Composition)
platform/crossplane*/             control-plane components, installed via Argo
examples/                         a hand-written request, for reference
scripts/
  scaffold.py                     the renderer behind the form
  bootstrap.sh teardown*.sh       cluster lifecycle
  aws-credentials.sh              local creds -> in-cluster Secret, never via Git
  drift-demo.sh validate.sh       the demo, and the CI entrypoint
docs/
  concepts.md                     how it works and why — start here
  lab-0{1,2,3}-*.md               step-by-step walkthroughs
  troubleshooting.md              eleven real failures, root causes
  aws-setup.md                    AWS account prep
  adr/                            decisions worth defending later
.github/workflows/
  validate.yaml                   render + schema-validate every PR
  scaffold.yaml                   the developer-facing form
```

## Validation

CI **discovers** every overlay under `apps/*/overlays/*` — including ones the scaffolder created — renders them with `kustomize build`, validates the output against the real Kubernetes OpenAPI schema with `kubeconform`, and shellchecks the scripts with `-x` so sourced files are checked too. A hardcoded list of things to validate is a list that silently stops covering things. Same entrypoint locally:

```bash
make validate
make lint
```

Manifests that don't render are caught in review, not at 2am.

---

## Roadmap

- [x] **Lab 1 — GitOps.** kind + Argo CD + app-of-apps + drift reconciliation. [Walkthrough](docs/lab-01-gitops.md).
- [x] **Lab 2 — Self-service infrastructure.** Crossplane v2 provisioning real AWS S3 from a namespaced composite resource, behind a two-field developer API. [Walkthrough](docs/lab-02-crossplane.md).
- [x] **Lab 3 — The golden path.** A five-field form that generates a hardened, observable service plus its infrastructure request and opens a pull request. Merging is the deploy. [Walkthrough](docs/lab-03-scaffolder.md) · [why not Backstage](docs/adr/0003-scaffolder-not-backstage.md).

## What I'd do next with more time

- **Progressive delivery.** Argo Rollouts with automated analysis, so a bad deploy fails a canary instead of a customer.
- **Template versioning.** The unglamorous, genuinely hard problem: once 200 services have been scaffolded from template v1, how does v2 reach them? Probably automated PRs against every downstream repo, plus a scorecard tracking who's behind.
- **Policy as code.** Kyverno enforcing the defaults above as admission rules, so the paved road is also the only road for the things that actually matter (non-root, resource limits) — and advisory everywhere else.
- **Secrets.** External Secrets Operator; nothing in this repo currently needs a secret, which is the only reason it isn't here yet.

## License

MIT — see [LICENSE](LICENSE).
