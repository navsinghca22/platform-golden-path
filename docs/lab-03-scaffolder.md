# Lab 3 — The golden path, end to end

**Time:** an evening. **Cost:** free unless you tick the storage box, and pennies if you do.
**You'll end with:** a form a developer fills in, which produces a pull request containing a complete, hardened, observable service — and merging it deploys.

This is where Labs 1 and 2 stop being two separate demos and become one product.

---

## What "golden path" actually means now

Before this lab, adopting the platform meant reading this repo, copying `apps/podinfo/`, editing six files correctly, and knowing that an Argo `Application` had to be added in a different directory.

After it:

```
Developer fills a 5-field form
        │
        ▼
scripts/scaffold.py renders templates/service/
        │
        ▼
apps/<name>/{base,overlays/local}     ← the workload
clusters/local/applications/<name>.yaml ← the Argo CD Application
apps/<name>/overlays/local/objectstorage.yaml ← if they ticked "storage"
        │
        ▼
Pull request, validated by the same CI that guards every other change
        │
        ▼
Merge → Argo CD reconciles → running service, and a real S3 bucket
```

The developer supplied: a name, an owner, an image, a port, and a checkbox.

They did not supply — and never learn — probes, resource limits, security context, scrape annotations, namespace conventions, the Argo `Application` shape, AWS regions, bucket naming, or the tagging policy. **That gap is the platform's entire value, made concrete.**

---

## Step 1 — Scaffold locally first

Before using the form, run the renderer directly. It's the same code path, and failures are easier to read:

```bash
cd ~/code/platform-golden-path
make scaffold NAME=checkout-api OWNER=team-checkout IMAGE=ghcr.io/stefanprodan/podinfo:6.11.2 PORT=9898
```

Look at what it produced:

```bash
git status --short
cat apps/checkout-api/base/deployment.yaml
```

Every hardening decision from Lab 1 is in there, including the numeric `runAsUser` and the writable `/tmp` — the two things that cost us an evening. **A scaffolder is where lessons get institutionalised.** You fix the bug once, put the fix in the template, and no service created afterward can inherit it.

## Step 2 — Watch it refuse bad input

The validation is the interesting part, not the templating:

```bash
make scaffold NAME=Checkout_API OWNER=team-x IMAGE=nginx:1.27
make scaffold NAME=svc OWNER=team-x IMAGE=nginx:latest
make scaffold NAME=svc OWNER=team-x IMAGE=nginx:1.27 PORT=80
make scaffold NAME=podinfo OWNER=team-x IMAGE=nginx:1.27
```

Each is rejected with an explanation of *why*, not just *what*:

- Uppercase and underscores aren't valid Kubernetes names. Kubernetes would also reject this — but at apply time, with a message about DNS-1123 subdomains that means nothing to an app developer.
- `:latest` isn't a version. It makes deploys unreproducible and rollbacks meaningless.
- Port 80 is privileged, and the platform runs containers as non-root, so the process couldn't bind it. This one would have manifested as a CrashLoop twenty minutes later.
- The name already exists. The scaffolder refuses to overwrite: silently clobbering someone's service is worse than making you think about it.

**This is policy enforcement that costs nothing and needs no admission controller.** A well-designed input schema catches most of what people reach for OPA to catch, at the moment the mistake is made, in language the person who made it understands.

## Step 3 — Deploy it

```bash
git checkout -b scaffold/checkout-api
git add -A && git commit -m "feat: scaffold checkout-api"
git push -u origin scaffold/checkout-api
```

Open the PR, watch `validate` run against the generated manifests, merge it.

```bash
make status
kubectl -n checkout-api get pods
```

Nobody ran a deploy command. Merging was the deploy.

## Step 4 — Use the form

The form is the same thing with a UI. On GitHub: **Actions → scaffold new service → Run workflow**.

Fill in the fields, tick **storage**, run it. The workflow:

1. Runs the same `scaffold.py`
2. Validates the generated manifests with `kubeconform` — the same check CI runs on every PR
3. Opens a PR with a review checklist in the body

That second step matters more than it looks. **A scaffolder that can emit manifests its own pipeline would reject is a scaffolder nobody trusts twice.** The generator and the gate have to agree.

Merge the PR and you get a running service *and* a real S3 bucket, from a form, with no cluster or AWS access anywhere in the process.

---

## Things worth breaking

**Ask for storage in a region that isn't offered.** The form's dropdown won't let you, but `make scaffold --region ap-south-1` will refuse too — and so would the XRD's enum if you bypassed both. Three layers, and the outermost gives the best error message. That ordering is deliberate.

**Scaffold a service, then edit the template.** Note that existing services *don't* change. This is the day-2 problem: once 200 services exist, how does template v2 reach them? See below.

**Delete the generated `Application` file and push.** The service disappears — `prune: true` from Lab 1, one layer up.

**Point the image at something that doesn't serve `/healthz`.** The readiness probe fails, Argo reports `Progressing`, and you learn why the template can't guess health endpoints for arbitrary images. A real platform either standardises them or makes them an input.

---

## The problem this lab doesn't solve

**Template drift.** Scaffolding is a one-time copy. Change `templates/service/base/deployment.yaml` today and every service generated yesterday keeps its old copy forever. After two years you have services carrying defaults from four different template generations and no way to tell which.

This is the genuinely hard part of platform engineering, and it's worth being able to describe the shape of the answer:

- **Automated PRs** — a bot that re-renders each service against the current template and opens a PR with the diff, Renovate-style. Teams stay in control; being current becomes cheap.
- **Template versioning** — record the template version in each generated service, so you can query who's behind.
- **Scorecards** — make staleness *visible* rather than mandatory. Teams fix what's measured.
- **Move defaults out of the template entirely** — a mutating admission policy (Kyverno) or a shared base that overlays reference by ref rather than copy. Then updating the default updates every service at once, at the cost of less local control.

The last option is the real trade-off: **copied defaults are inspectable but drift; referenced defaults stay current but change under teams without warning.** Most platforms end up with both — copy what teams should own, reference what the platform must guarantee.

---

## What to say in an interview

**"Why not Backstage?"** — [ADR-0003](adr/0003-scaffolder-not-backstage.md). Short version: the golden path is the product, the portal is packaging. Backstage typically needs 6–12 months and 2–4 dedicated engineers; at 15 teams that's a platform team whose largest operational burden is its own portal. Everyone already has GitHub, so a form there costs no new access, no new RBAC, no new runtime. Revisit at ~50 services when the catalog starts earning its keep — and probably buy it then rather than build.

**"How does a developer get a database/bucket/queue?"** — They tick a box. It becomes an `ObjectStorage` resource in their namespace, Crossplane reconciles it into AWS. Adding a second resource type is a new XRD and Composition; the form grows one checkbox.

**"How do you enforce standards?"** — Three layers, cheapest first: the input schema rejects bad requests with a readable error; CI validates the rendered output; admission policy would be the third for things that genuinely must never happen. Most teams reach for the third layer first, which is expensive and produces worse errors.

**"What happens when the template changes?"** — Be honest that it's unsolved here, then describe automated PRs, version tracking, scorecards, and the copy-versus-reference trade-off. Knowing this is the hard part is most of the signal.

**"How would you measure whether this worked?"** — Time-to-first-deploy for a new service (three days → about ten minutes), percentage of services on the paved road, infra tickets filed. Then the honest caveat: adoption is the real metric, and you can't claim it from a lab.

---

**All three labs done.** What you have: a GitOps control plane that self-heals, a self-service infrastructure API over real AWS, and a golden path a developer can walk without reading any of it.
