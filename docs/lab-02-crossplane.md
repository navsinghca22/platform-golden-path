# Lab 2 — Self-service infrastructure with Crossplane

**Time:** an evening. **Cost:** effectively zero — an empty S3 bucket is free.
**You'll end with:** a developer-facing API where `kind: ObjectStorage` produces a real S3 bucket in a real AWS account, and the developer never sees AWS.

Prerequisites: Lab 1 working, and `docs/aws-setup.md` complete (`aws sts get-caller-identity --profile lab` returns `user/crossplane-lab`, **not** root).

---

## The idea: Kubernetes as a control plane for things that aren't Kubernetes

Lab 1's insight was reconciliation — a controller continuously making reality match Git. Everything it reconciled lived inside the cluster.

Crossplane applies the identical loop to things *outside* the cluster. A `Bucket` resource in Kubernetes has a controller that talks to the AWS API and makes S3 match the spec. Delete the resource, the bucket goes. Change a tag by hand in the console, it gets changed back.

**Kubernetes stops being a container scheduler and becomes a general-purpose control plane.** That reframing is what platform engineering interviews are probing when they ask about Crossplane. Containers are incidental; the API machinery — CRDs, controllers, reconciliation, RBAC — is the valuable part, and it works just as well for buckets, databases, and DNS records.

Then composition adds the layer that makes it a *platform* rather than a differently-shaped Terraform: you define your own API, and developers use that instead of the cloud's.

---

## Step 1 — Bring the cluster up

```bash
cd ~/code/platform-golden-path
make up
make status
```

Wait for `root` and `podinfo` to be `Synced`/`Healthy` before continuing.

## Step 2 — Give the platform its AWS identity

```bash
make aws-creds
```

This reads your `lab` profile, verifies the credentials work, **refuses if they belong to the root user**, and writes them into a Kubernetes Secret. The temp file it uses is mode-600 and removed on exit.

Note what did *not* happen: no credential touched this repository. The `ClusterProviderConfig` in Git *references* a secret by name; the secret's contents are created locally. That separation is the whole answer to "how do you do GitOps with secrets" at this scale. (The grown-up answer is External Secrets Operator or SOPS — see *What's missing* below.)

## Step 3 — Push the Lab 2 manifests

```bash
git add -A
git commit -m "feat: lab 2 - crossplane and self-service object storage"
git push
```

Argo CD does the rest. Four new Applications, ordered by sync wave:

| Wave | Application | What it installs |
|---|---|---|
| 0 | `crossplane` | Crossplane v2.3.1, from the upstream Helm chart |
| 1 | `crossplane-runtime` | AWS S3 provider + patch-and-transform function |
| 2 | `crossplane-config` | `ClusterProviderConfig` pointing at your Secret |
| 3 | `platform-apis` | **Your XRD and Composition** |

Waves matter because each layer's CRDs must exist before the next layer's resources can be created. You can't create a `ClusterProviderConfig` before the provider that defines it is installed. `SkipDryRunOnMissingResource=true` handles the window where Argo diffs against a kind the API server hasn't heard of yet, and the retry backoff handles the rest.

Watch it converge:

```bash
make status          # argo applications
make xp-status       # providers and functions
```

First run takes 3–5 minutes — provider packages are large. **Expect `crossplane-config` to fail and retry a couple of times.** That's not a bug; it's wave 2 arriving before the provider finished becoming healthy, and the backoff resolving it. Watching that self-correct is a good illustration of why declarative systems tolerate ordering problems that imperative scripts can't.

## Step 4 — Ask the platform for storage

```bash
make bucket
```

That creates this — the entire developer-facing surface:

```yaml
apiVersion: platform.golden-path.io/v1alpha1
kind: ObjectStorage
metadata:
  namespace: default
  generateName: team-checkout-
spec:
  region: us-east-1
  owner: team-checkout
```

Two fields. No account ID, no ARN, no bucket naming scheme, no tagging policy, no mention of S3.

```bash
make storage
```

```
--- ObjectStorage (what developers asked for) ---
NAME                  SYNCED   READY   AGE
team-checkout-x7k2p   True     True    45s

--- Bucket (what Crossplane created in AWS) ---
NAME                        SYNCED   READY   EXTERNAL-NAME
team-checkout-x7k2p-8fhq2   True     True    team-checkout-x7k2p-8fhq2
```

Two objects, because two layers. The `ObjectStorage` is your API. The `Bucket` is the AWS-shaped resource your Composition produced from it. Developers only ever see the first.

**Now confirm it's real:**

```bash
aws s3 ls --profile lab
aws s3api get-bucket-tagging --bucket <name-from-above> --profile lab
```

The tags are there — `ManagedBy`, `Project`, `Owner`, `ObjectStorage`, `Namespace` — and nobody typed them. Every bucket the platform creates carries them, forever, because they're in the Composition rather than in a runbook someone has to remember.

## Step 5 — Prove it reconciles

Same demo as Lab 1, one layer further out:

```bash
aws s3api delete-bucket-tagging --bucket <name> --profile lab   # vandalise it
sleep 60
aws s3api get-bucket-tagging --bucket <name> --profile lab      # they're back
```

A controller in your laptop's kind cluster just corrected the state of a resource in AWS. **That's the whole idea.** Cloud infrastructure with the same self-healing property your Kubernetes workloads have — not a pipeline that ran once and hoped.

Compare to Terraform: `terraform apply` is a point-in-time action. Drift accumulates silently until someone runs `plan` again. Crossplane's controller never stops checking. (Terraform isn't wrong — the trade-off is real, and *knowing* the trade-off is the interview answer. See below.)

## Step 6 — Tear down and verify

```bash
make teardown-aws
make down
```

`teardown-aws` deletes the resources **and then queries the AWS API** to confirm the buckets are actually gone. That second half is the point: deleting a Kubernetes object is not evidence the cloud resource followed it. A deletion policy of `Orphan`, an expired credential, or a force-deleted finalizer all leave the bucket behind, still billing.

Trusting your own automation without verifying it once is free to do wrong in a lab and expensive to do wrong in production.

---

## Things worth breaking

**Delete the Secret.** `kubectl -n crossplane-system delete secret aws-secret`, then create a bucket. The MR sits `Synced: False` with an auth error in its conditions. `kubectl describe bucket <name>` — learn to read those conditions, they're where every Crossplane problem is diagnosed.

**Delete the bucket in the AWS console.** Watch Crossplane recreate it. External deletion is just another kind of drift.

**Ask for an invalid region.** Set `region: ap-south-1` in the XR. Rejected by the API server, instantly, because the XRD has an `enum`. That's a schema doing policy work — no admission controller, no OPA, just a well-designed API. Cheapest guardrail in the business.

**Add a field.** Put `versioning: bool` in the XRD, then a `BucketVersioning` resource in the Composition. This is the actual day-to-day work of a platform engineer, and doing it once tells you more than reading about it five times.

---

## What's missing, and be honest about it

Say these before an interviewer asks:

**Static credentials.** Production uses IRSA (or EKS Pod Identity) so the provider assumes a role via a projected service account token and no long-lived key exists. Not possible on kind, which has no AWS-trusted OIDC issuer. See [ADR-0002](adr/0002-static-credentials-vs-irsa.md).

**Over-broad IAM.** `AmazonS3FullAccess` is a lab convenience. Production scopes to specific prefixes and actions.

**No secrets management.** External Secrets Operator or SOPS-encrypted manifests, so even the reference-to-a-secret is reproducible from Git.

**No policy enforcement.** The XRD enum stops bad regions, but nothing stops someone bypassing the platform and creating a raw `Bucket` MR. Kyverno restricting who can create MRs directly is the usual answer.

**One resource type.** A real platform's storage API would compose the bucket, its encryption config, public access block, versioning, a scoped IAM policy, and a Kubernetes Secret with credentials for the app — from the same two-field request.

---

## What to say in an interview

**"Why Crossplane over Terraform?"** — The honest answer names the trade-off rather than declaring a winner. Crossplane's controller reconciles continuously, so drift has a bounded lifetime and infrastructure gets the same self-healing property as workloads; it's also Kubernetes-native, so RBAC, admission control and GitOps tooling apply for free. Terraform has a vastly larger provider ecosystem, a plan step people trust, and doesn't require running a cluster to manage infrastructure. Terraform is usually right for foundational infrastructure — VPCs, accounts, the cluster itself. Crossplane is usually right for the self-service layer developers touch daily. Plenty of shops run both, and saying so signals you've thought about it rather than picked a side.

**"What's the point of the XRD?"** — It's the platform's product surface. Compare the raw S3 API to a two-field `ObjectStorage`: the difference is exactly the cognitive load you removed. And because it's an ordinary Kubernetes API, RBAC decides who can ask for storage — no separate permissions system.

**"How do you stop people bypassing it?"** — You mostly don't, and shouldn't try to win that fight with mandates. You make the paved road easier, and use policy only for the things that genuinely matter. An escape hatch that nobody needs is the goal; an escape hatch that doesn't exist means your best engineers build a shadow platform.

**"How do developers get credentials to the bucket?"** — Good question to be asked, and the honest answer is "not solved here." Crossplane writes connection details to a Secret; wiring that into a workload is the next lab.

---

**Next:** Lab 3 — the portal. A scaffolder that generates a service repo with CI, manifests, an `ObjectStorage` request, and observability wired in, from a form.
