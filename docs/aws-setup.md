# AWS setup (prep for Lab 2)

Lab 2 puts Crossplane in the local cluster and has it provision a **real S3 bucket** in your AWS account from a Kubernetes resource. This page gets your account ready. Do it before starting Lab 2 — none of it is interesting, and all of it is annoying to debug halfway through.

**Expected cost: effectively zero.** An empty S3 bucket costs nothing to exist; you'll store a few kilobytes. The billing alarm below exists to protect against mistakes, not against this lab.

---

## 1. Set up a billing alarm first

Before anything else. This takes five minutes and is the difference between a mistake costing $3 and a mistake costing $300.

1. Sign in to the AWS console as the root user.
2. **Account → Billing preferences →** enable *Receive Billing Alerts*.
3. Go to **CloudWatch → Alarms → Create alarm → Billing → Total Estimated Charge**.
   - Region must be **us-east-1** — billing metrics only publish there, regardless of where your resources live.
   - Threshold: something you'd want to hear about. $5 is reasonable for a lab account.
   - Send to an email address you actually read, and confirm the SNS subscription.

Also worth enabling: **Billing → Budgets → Create budget → Zero spend budget**. It alerts the moment anything leaves the free tier.

## 2. Create a non-root user for the lab

Don't use root credentials for anything beyond step 1.

In **IAM → Users → Create user**:

- Name it something obvious, e.g. `crossplane-lab`.
- Attach `AmazonS3FullAccess` directly. It's broader than ideal — a production setup would scope this to a bucket prefix — but a lab that fails on permissions teaches you nothing about Crossplane.
- **Do not** give it console access. It only needs programmatic access.

Then **Security credentials → Create access key → Command Line Interface (CLI)**.

You'll see an access key ID and a secret. The secret is shown once.

> **A note on how this repo handles credentials:** they go in `~/.aws/credentials` on your machine and are read by the AWS CLI. Nothing in this repo contains, templates, or logs a credential, and `.gitignore` covers `.env` and `.env.local`. In Lab 2, Crossplane reads them from a Kubernetes Secret that you create locally — the manifest that references it is committed, the Secret itself never is.

## 3. Configure the CLI

```bash
brew install awscli          # if you don't have it
aws configure --profile lab
```

It prompts for four things:

```
AWS Access Key ID:      <from step 2>
AWS Secret Access Key:  <from step 2>
Default region name:    us-east-1
Default output format:  json
```

Verify:

```bash
aws sts get-caller-identity --profile lab
```

```json
{
  "UserId": "AIDA...",
  "Account": "123456789012",
  "Arn": "arn:aws:iam::123456789012:user/crossplane-lab"
}
```

If that returns your `crossplane-lab` user, you're done. If it returns the root user, you configured the wrong keys.

Make the profile the default for your shell session so you don't have to pass `--profile` every time:

```bash
export AWS_PROFILE=lab
```

Add it to your shell profile if you'd rather not think about it again.

### Using IAM Identity Center (SSO) instead

If your account is under AWS Organizations with Identity Center enabled, skip the access keys entirely — they're the thing you'd be criticised for in a real environment:

```bash
aws configure sso --profile lab
aws sso login --profile lab
```

Crossplane needs slightly different configuration for SSO credentials (they're short-lived); Lab 2 covers both paths.

---

## 4. Habits worth forming now

**Tag everything.** Lab 2 tags every provisioned resource with `Project=platform-golden-path`. Not decoration — it's how you find and delete things you've forgotten. Cost Explorer can group by tag.

**Know your teardown before you build.** Every AWS lab in this repo ships a teardown script, and Lab 2's is the one that matters. `kind delete cluster` is free to forget. An orphaned NAT gateway is $32/month, forever, invisible until the statement arrives.

**Check the console once, at the end.** After Lab 2's teardown, look at S3 in the console and confirm the bucket is actually gone. Trusting your own automation without verifying it once is how people end up with surprise bills. Crossplane deletion in particular can silently no-op if the deletion policy is set to `Orphan`.

---

## Why this is worth doing at all

The cluster in this repo is deliberately local and free ([ADR-0001](adr/0001-local-control-plane.md)). So why touch real AWS?

Because the part that's genuinely hard to learn from a simulator is exactly what's on the other side of that credential: IAM's actual behaviour, real API error messages, eventual consistency, the difference between what Crossplane thinks it created and what exists. LocalStack gives you a clean, fast, honest-looking mock, and mocks never teach you the thing that bites you in production.

Local where local is indistinguishable. Real where real is the point.

---

**Next:** Lab 2 — Crossplane and self-service infrastructure *(not yet written)*
