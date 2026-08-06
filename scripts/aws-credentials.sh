#!/usr/bin/env bash
#
# Create the Kubernetes Secret the AWS provider reads, from your local AWS
# profile. Run once after `make up`.
#
# This script exists so that credentials travel from your machine into the
# cluster WITHOUT ever passing through a file in this repository. The temp file
# it writes lives in a mode-600 directory and is removed on exit, including on
# error -- see the trap below.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require aws kubectl

PROFILE="${AWS_PROFILE_LAB:-lab}"

log "reading credentials from AWS profile '${PROFILE}'"
KEY_ID="$(aws configure get aws_access_key_id --profile "$PROFILE" 2>/dev/null || true)"
SECRET="$(aws configure get aws_secret_access_key --profile "$PROFILE" 2>/dev/null || true)"

if [ -z "$KEY_ID" ] || [ -z "$SECRET" ]; then
  die "profile '${PROFILE}' has no access keys. Run: aws configure --profile ${PROFILE}  (see docs/aws-setup.md)"
fi

# Confirm the credentials actually work, and that they are NOT root, before
# handing them to a controller that will act on them unattended.
ident="$(aws sts get-caller-identity --profile "$PROFILE" --output text --query Arn 2>/dev/null || true)"
[ -n "$ident" ] || die "credentials in profile '${PROFILE}' are not valid (sts get-caller-identity failed)"
case "$ident" in
  *:root) die "profile '${PROFILE}' is the account ROOT user. Refusing. Create a scoped IAM user -- see docs/aws-setup.md." ;;
esac
log "identity: ${ident}"

tmpdir="$(mktemp -d)"
chmod 700 "$tmpdir"
trap 'rm -rf "$tmpdir"' EXIT INT TERM

cat > "${tmpdir}/creds.ini" <<CREDS
[default]
aws_access_key_id = ${KEY_ID}
aws_secret_access_key = ${SECRET}
CREDS
chmod 600 "${tmpdir}/creds.ini"

kubectl create namespace crossplane-system --dry-run=client -o yaml | kubectl apply -f - >/dev/null

# --dry-run|apply so re-running rotates the secret rather than erroring.
kubectl create secret generic aws-secret \
  --namespace crossplane-system \
  --from-file=creds="${tmpdir}/creds.ini" \
  --dry-run=client -o yaml | kubectl apply -f -

log "secret 'aws-secret' created in crossplane-system"
log "temp credential file removed"
