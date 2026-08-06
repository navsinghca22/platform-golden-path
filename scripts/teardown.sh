#!/usr/bin/env bash
# Delete the local cluster. Local only -- costs nothing to run, costs nothing
# to forget. The AWS teardown in Lab 2 is the one that matters financially.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require kind

if kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
  log "deleting kind cluster '${CLUSTER_NAME}'"
  kind delete cluster --name "${CLUSTER_NAME}"
else
  log "cluster '${CLUSTER_NAME}' not found; nothing to do"
fi
