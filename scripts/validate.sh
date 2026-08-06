#!/usr/bin/env bash
#
# Render every kustomize overlay and validate the output against the real
# Kubernetes OpenAPI schema. Runs locally and in CI from the same entrypoint,
# so "works on my machine" and "passes the PR check" cannot diverge.

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require kustomize kubeconform

# Overlays that Argo CD is pointed at. Bases are validated transitively.
OVERLAYS=(
  "apps/podinfo/overlays/local"
)

# Loose manifests that are applied directly rather than rendered.
RAW_DIRS=(
  "clusters/local/bootstrap"
  "clusters/local/applications"
)

fail=0

for overlay in "${OVERLAYS[@]}"; do
  log "kustomize build ${overlay}"
  if ! kustomize build "${REPO_ROOT}/${overlay}" \
      | kubeconform -strict -summary -ignore-missing-schemas \
          -schema-location default; then
    warn "validation failed for ${overlay}"
    fail=1
  fi
done

for dir in "${RAW_DIRS[@]}"; do
  log "kubeconform ${dir}"
  # Argo CD's Application CRD is not in the default schema set. -ignore-missing-schemas
  # downgrades that to a skip rather than a hard failure; YAML syntax and
  # structure are still checked.
  if ! kubeconform -strict -summary -ignore-missing-schemas \
        -schema-location default \
        "${REPO_ROOT}/${dir}"; then
    warn "validation failed for ${dir}"
    fail=1
  fi
done

# Placeholders must never reach main -- a merged __REPO_URL__ silently breaks
# bootstrap for every future clone.
if grep -rq '__REPO_URL__' "${REPO_ROOT}/clusters" 2>/dev/null; then
  warn "unresolved __REPO_URL__ placeholder found (expected before 'make init', a bug after)"
fi

[ "$fail" -eq 0 ] || die "validation failed"
log "all manifests valid"
