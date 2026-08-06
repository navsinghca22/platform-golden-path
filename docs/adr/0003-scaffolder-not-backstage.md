# ADR-0003: A form-and-template scaffolder, not Backstage

**Status:** Accepted
**Date:** 2026-08-06

## Context

The platform needs a way for a product team to get a new service onto the golden path without reading this repository first. The usual answer is a developer portal.

Options considered:

1. **Backstage** — the CNCF-graduated open-source portal. Software catalog, scaffolder templates, plugin ecosystem, the name everyone recognizes.
2. **A managed portal** — Port, Roadie (managed Backstage), Cortex. Low-code, fast, free tiers.
3. **A form-and-template scaffolder** — a `workflow_dispatch` form in GitHub Actions that renders a template and opens a pull request.

Backstage is the highest-status choice and the most recognizable line on a résumé. It is also, by widely reported experience, expensive to own: typical estimates are 6–12 months to reach production and 2–4 dedicated engineers to maintain, and Gartner's 2025 market guide noted a clear shift toward turnkey commercial portals partly because of that burden.

## Decision

**Build option 3: a GitHub Actions form that runs a dependency-free renderer and opens a pull request.**

The developer fills in five fields. The workflow generates the service from `templates/service/`, validates the output with the same `kubeconform` checks CI runs on every PR, and opens a PR containing the manifests plus an Argo CD `Application`. Merging the PR is the deploy.

## Rationale

**The golden path is the product; the portal is packaging.** Everything that makes this a platform — the defaults a service inherits, the deliberate exclusions, the self-service infrastructure API, the fact that onboarding is a PR — lives in the template and the Composition. A portal changes how the request is *submitted*. Swapping GitHub Actions for Backstage later would not change a single generated manifest.

**Zero new surface to operate.** Backstage is a Node application with a database that the platform team runs, patches, upgrades and is paged for. A platform team whose own portal is its largest operational burden has inverted its purpose. This scaffolder has no runtime: it exists only while a job runs.

**Zero new access to grant.** Every engineer already has GitHub, already has permissions, already knows what a PR is. A separate portal means another login, another RBAC model, another onboarding step — friction paid by every user, forever, to save the platform team from writing a form.

**Pull requests are the right output.** The generated service is visible, diffable, reviewable and rejectable before anything reaches a cluster. A portal that provisions directly on submit skips code review for exactly the artifacts most worth reviewing.

**It's honest about scale.** At 15 teams, a form and a template is the [thinnest viable platform](https://teamtopologies.com/key-concepts). Backstage's catalog and plugin model start paying for themselves at a few hundred engineers with sprawling service ownership — which is a different company than the one this repo describes.

## Consequences

**Accepted:**

- **No software catalog.** Nothing answers "who owns this service, what depends on it, is it meeting standards." That is Backstage's genuinely strongest feature and it isn't replicated here. Ownership is captured as a label and an AWS tag, which supports grep and cost allocation but not a browsable graph.
- **No scorecards**, so standards compliance across the fleet isn't visible.
- **No plugin ecosystem** — no CI status, no incident history, no cost data on a per-service page.
- **A weaker résumé line.** "Backstage" is a keyword screeners match on; "GitHub Actions scaffolder" is not.
- **GitHub-coupled.** Moving to GitLab means rewriting the form, though `scripts/scaffold.py` itself is portable and runs locally via `make scaffold`.

**Mitigations:**

- The renderer is deliberately independent of the form. `make scaffold` runs the same code path with no CI involved, so the portal layer is genuinely replaceable rather than nominally so.
- The catalog gap is the real one, and it is the reason to revisit this — not the résumé keyword.
- Being able to explain *why* Backstage wasn't chosen, with the ownership cost and the size threshold, demonstrates more judgment than having installed it. "It depends on team size" is the answer a senior engineer gives; "yes, Backstage is the standard" is the answer someone gives who has only read about it.

## Revisit if

- Service count passes roughly 50, where "who owns this and what depends on it" stops being answerable from memory and a catalog starts earning its keep.
- The platform team gets enough headcount that 2–4 engineers on portal maintenance is affordable — or a managed option (Port, Roadie) removes that cost entirely, which is the more likely path.
- An employer specifically requires hands-on Backstage, in which case a timeboxed spike is worth doing.
