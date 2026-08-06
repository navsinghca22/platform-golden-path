#!/usr/bin/env bash
#
# Delete every ObjectStorage this platform created, then VERIFY against the AWS
# API that the buckets are actually gone.
#
# The verification is the point. Deleting the Kubernetes resource and assuming
# the cloud resource followed is how people end up with surprise bills --
# Crossplane will silently leave the bucket behind if the deletion policy is
# Orphan, or if the provider lost its credentials, or if the XR was force-
# deleted past its finalizer. Trusting your own automation without checking it
# once is a bad habit to build in a lab and an expensive one in production.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require kubectl aws

PROFILE="${AWS_PROFILE_LAB:-lab}"

log "deleting all ObjectStorage resources"
if kubectl get objectstorages.platform.golden-path.io -A >/dev/null 2>&1; then
  kubectl delete objectstorages.platform.golden-path.io --all -A --wait=true --timeout=180s || \
    warn "delete timed out; continuing to verification"
else
  log "no ObjectStorage CRD present (nothing was ever created, or Crossplane is gone)"
fi

log "waiting for the provider to finish deleting buckets in AWS"
sleep 10

log "verifying against the real AWS API"
remaining=0
buckets="$(aws s3api list-buckets --profile "$PROFILE" --query 'Buckets[].Name' --output text 2>/dev/null || true)"

if [ -z "$buckets" ]; then
  log "no S3 buckets in the account at all"
else
  for b in $buckets; do
    tags="$(aws s3api get-bucket-tagging --bucket "$b" --profile "$PROFILE" --output text 2>/dev/null || true)"
    case "$tags" in
      *platform-golden-path*)
        warn "STILL EXISTS: s3://${b}  (tagged Project=platform-golden-path)"
        remaining=$((remaining + 1))
        ;;
    esac
  done
fi

echo
if [ "$remaining" -eq 0 ]; then
  cat <<MSG
Verified: no buckets tagged Project=platform-golden-path remain.

This is the check most people skip. Deleting the Kubernetes object is not
evidence that the cloud resource is gone -- the AWS API is.
MSG
else
  cat <<MSG
${remaining} bucket(s) survived teardown. Investigate before walking away:

  kubectl get buckets.s3.aws.m.upbound.io -A
  kubectl describe bucket <name>            # look at Synced/Ready conditions
  aws s3 rb s3://<bucket> --force --profile ${PROFILE}   # last resort, manual

Common cause: the provider lost its credentials, so it cannot issue the delete
and the finalizer never clears.
MSG
  exit 1
fi
