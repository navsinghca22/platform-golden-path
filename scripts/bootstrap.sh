#!/usr/bin/env bash
#
# Stand up the local cluster and hand control to Argo CD.
#
# Everything here is deliberately idempotent: re-running it on a half-built
# cluster should converge, not explode. That property is worth more than
# elegance in a bootstrap script.

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require kind kubectl
assert_repo_initialised

CTX="kind-${CLUSTER_NAME}"

# ---------------------------------------------------------------- cluster ---
if kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
  log "cluster '${CLUSTER_NAME}' already exists, reusing it"
else
  log "creating kind cluster '${CLUSTER_NAME}' (node image pinned: ${KIND_NODE_IMAGE%%@*})"
  kind create cluster \
    --name "${CLUSTER_NAME}" \
    --image "${KIND_NODE_IMAGE}" \
    --config "${REPO_ROOT}/clusters/local/kind.yaml" \
    --wait 120s
fi

kubectl config use-context "${CTX}" >/dev/null
log "kube context: ${CTX}"

# ---------------------------------------------------------------- argo cd ---
log "installing Argo CD ${ARGOCD_VERSION}"
kubectl apply -f "${REPO_ROOT}/clusters/local/bootstrap/namespace.yaml"
# Server-side apply: the applicationsets CRD schema exceeds the 256KB
# annotation limit that client-side apply needs for
# kubectl.kubernetes.io/last-applied-configuration. SSA tracks ownership in
# managedFields instead, so there is no annotation to overflow.
kubectl apply --server-side --force-conflicts -n argocd \
  -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"

log "waiting for Argo CD to become available (this pulls a few images; 2-3 min on a cold cache)"
kubectl -n argocd rollout status deploy/argocd-repo-server --timeout=300s
kubectl -n argocd rollout status deploy/argocd-server      --timeout=300s
kubectl -n argocd rollout status statefulset/argocd-application-controller --timeout=300s

# --------------------------------------------------------------- root app ---
# The single imperative act. From here the cluster's contents are a function
# of the Git repo, and this script never needs to know what is deployed.
log "applying the app-of-apps root application"
kubectl apply -f "${REPO_ROOT}/clusters/local/bootstrap/root-app.yaml"

log "waiting for the root app to sync its children"
for _ in $(seq 1 60); do
  phase="$(kubectl -n argocd get application podinfo -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
  [ "$phase" = "Synced" ] && break
  sleep 5
done

cat <<MSG

------------------------------------------------------------------
Bootstrap complete.

  Argo CD UI     make argocd-ui      -> https://localhost:8081
  admin password make argocd-password
  Sample app     http://localhost:8080

  Prove it reconciles:   make drift-demo
  Tear it all down:      make down
------------------------------------------------------------------
MSG
