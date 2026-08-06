#!/usr/bin/env bash
#
# The point of the whole lab, in about forty seconds.
#
# We change the live cluster by hand -- the thing every runbook tells you to do
# during an incident -- and watch Argo CD put it back, because Git said 2 and
# the cluster said 5. Pull-based reconciliation is not "CI that runs kubectl";
# it is a controller continuously asserting that reality matches the declared
# state, forever, whether or not a pipeline ever runs again.

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require kubectl

NS=podinfo
DEPLOY=podinfo

desired="$(kubectl -n "$NS" get deploy "$DEPLOY" -o jsonpath='{.spec.replicas}')"
log "current replicas (as declared in Git): ${desired}"

log "introducing drift: scaling to 5 by hand"
kubectl -n "$NS" scale deploy "$DEPLOY" --replicas=5

log "watching Argo CD self-heal (selfHeal: true) ..."
for i in $(seq 1 36); do
  sleep 5
  now="$(kubectl -n "$NS" get deploy "$DEPLOY" -o jsonpath='{.spec.replicas}')"
  printf '   t+%-3ss  replicas=%s\n' "$((i * 5))" "$now"
  if [ "$now" = "$desired" ]; then
    cat <<MSG

Reverted after ~$((i * 5))s.

Nobody ran a pipeline. No webhook fired. The application controller compared
live state to the Git revision on its polling interval and corrected the
difference. That is the property you are actually buying with GitOps: drift has
a bounded lifetime, and the repo is a truthful description of the cluster.

Try the other half of the loop next -- edit replicas in
apps/podinfo/overlays/local/kustomization.yaml, push, and watch the same
controller converge in the opposite direction.
MSG
    exit 0
  fi
done

warn "still not reverted after 3 minutes."
warn "check:  kubectl -n argocd get application podinfo -o yaml | grep -A5 'syncPolicy\|status:'"
exit 1
