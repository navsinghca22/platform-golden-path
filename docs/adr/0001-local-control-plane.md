# ADR-0001: Local Kubernetes control plane, real cloud infrastructure

**Status:** Accepted
**Date:** 2026-08-05

## Context

This platform needs a Kubernetes cluster to run Argo CD, Crossplane, and workloads. The obvious choice for something calling itself a platform-engineering project is a managed cluster — EKS.

Costs, at time of writing:

- EKS control plane: **$0.10/hr per cluster** during standard support (~$73/month), rising to $0.60/hr on extended support for clusters left on an old Kubernetes version.
- Worker nodes: EC2 on-demand, from ~$30/month for something usable.
- NAT gateway: ~$32/month plus data processing, if nodes are in private subnets.
- Load balancer: ~$16/month plus LCU charges.

A realistic always-on lab cluster is $150–450/month. This is a learning environment used a few evenings a week.

## Decision

**Run the Kubernetes control plane locally on kind. Provision real infrastructure in real AWS.**

The cluster is free, disposable, and recreated from scratch by a single command. The infrastructure that Crossplane provisions from inside it — S3 to begin with — is genuinely in AWS, against real IAM and real cloud APIs, using free-tier-eligible resources.

## Rationale

**The manifests are identical either way.** Argo CD reconciles the same YAML against a kind API server as against EKS. Nothing in this repository's delivery layer would be written differently, and no reader of the repo could tell which one produced it. Paying $73/month for an indistinguishable artifact is not a trade-off, it's a leak.

**The cloud layer is not substitutable.** IAM behaviour, credential plumbing, real API errors, eventual consistency, and the gap between what a controller believes it created and what actually exists — none of that is faithfully reproduced by a mock. LocalStack would make this project cheaper and strictly less educational.

**Disposability is a feature.** `make down && make up` from clean in a few minutes encourages breaking things, which is the point of a lab. An EKS cluster that takes 15 minutes to replace quietly discourages exactly the experimentation the repo exists to enable.

**Cost reasoning is part of the job.** Platform engineering is substantially about spending an organisation's money well, and design interviews now grade cost and operability explicitly. Choosing not to spend on an indistinguishable layer, and being able to say why, is a stronger signal than having run EKS.

## Consequences

**Accepted:**

- No experience with EKS-specific concerns: control plane upgrades, IRSA / Pod Identity, VPC CNI, managed node groups, cluster autoscaling.
- No multi-node scheduling behaviour worth the name; kind's single node hides real topology, zone-spreading and eviction dynamics.
- Local resource limits cap what can run simultaneously — relevant once the observability stack lands in Lab 3.

**Mitigations:**

- IRSA is the notable gap, since it's how production Crossplane authenticates. Lab 2 uses static credentials in a Kubernetes Secret and documents explicitly what IRSA would replace and why it's better — understanding the problem is most of the value.
- The kind config is a single file. Adding worker nodes is a two-line change if multi-node behaviour becomes relevant.
- Nothing in the repo is coupled to kind. `clusters/local/` is a directory, not an assumption; `clusters/eks/` could sit beside it, reusing every application manifest unchanged. That the layout makes this cheap is itself the argument that the decision is reversible.

## Revisit if

- The project needs to demonstrate IRSA, managed node groups, or cluster autoscaling directly.
- An employer or interview loop specifically asks for hands-on EKS operations.
- AWS free credits make the control plane cost irrelevant.
