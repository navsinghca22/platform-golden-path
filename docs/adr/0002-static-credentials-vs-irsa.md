# ADR-0002: Static AWS credentials in the lab, IRSA in production

**Status:** Accepted
**Date:** 2026-08-06

## Context

The Crossplane AWS provider must authenticate to AWS. Options:

1. **Static access keys** in a Kubernetes Secret.
2. **IRSA / EKS Pod Identity** — the provider's service account gets a projected OIDC token, exchanges it via STS for temporary credentials, and no long-lived secret exists.
3. **Instance profile** — credentials from EC2 node metadata.

IRSA is unambiguously the right answer in production. Long-lived keys have no expiry, are copied into laptops and CI systems, appear in shell history and screenshots, and are the single most common root cause of cloud breaches. Temporary credentials scoped to a service account remove the class of problem rather than managing it.

**IRSA is not available here.** It requires an OIDC issuer that AWS IAM trusts, published at a URL AWS can reach and registered as an identity provider in the account. A kind cluster on a laptop has neither. Options 2 and 3 both assume a cluster running in AWS — and [ADR-0001](0001-local-control-plane.md) deliberately put the control plane on the laptop.

## Decision

**Use a static access key for a dedicated, S3-scoped IAM user (`crossplane-lab`), stored in a Kubernetes Secret created outside Git. Document IRSA as the production answer and make the migration path explicit.**

Controls applied to reduce the blast radius:

- **Dedicated user, not root or admin.** `scripts/aws-credentials.sh` verifies the identity via STS and **refuses to run if the ARN ends in `:root`**. The failure mode this prevents — handing account-root credentials to a controller acting unattended — is severe enough to be worth a hard stop rather than a warning.
- **Scoped to S3 only.** `AmazonS3FullAccess` is broader than ideal but cannot touch IAM, EC2, or billing.
- **Never in Git.** The Secret is generated locally from `~/.aws`. The committed `ClusterProviderConfig` references it by name. The script's temp file is mode-600 in a mode-700 directory, removed via a trap on exit, interrupt and error.
- **Rotatable.** Re-running `make aws-creds` replaces the Secret, so rotation is one command.

## Consequences

**Accepted:**

- A long-lived credential exists on the laptop and in the cluster. If either is compromised, an attacker gets S3 access to the lab account until the key is revoked.
- No hands-on experience with the IRSA trust chain — OIDC provider registration, the role trust policy conditioning on `sub`, the annotation on the provider's ServiceAccount. This is the most significant gap in the whole project.
- The pattern here is one a reviewer could mistake for a production recommendation, which is why this ADR exists and why `docs/lab-02-crossplane.md` says so out loud.

**Mitigations:**

- The blast radius is one scoped user in a sandbox account with a zero-spend budget alarm.
- Migration is genuinely small: create the IAM role with a trust policy for the cluster's OIDC issuer, annotate the provider's ServiceAccount, and delete the Secret. The `ClusterProviderConfig` changes `credentials.source` from `Secret` to `IRSA`. Nothing else in this repo moves — which is itself evidence the abstraction is drawn in the right place.
- Understanding *why* IRSA is better, and what specifically it replaces, is most of the interview value. Having wired it up is better; being unable to explain it would be worse than both.

## Revisit if

- The project moves to EKS for any reason — IRSA becomes available and there is no excuse.
- A local OIDC issuer reachable by AWS becomes practical to run.
- An employer specifically wants hands-on IRSA, in which case a short-lived EKS cluster purely to configure the trust relationship is worth the ~$0.10/hour for a day.
