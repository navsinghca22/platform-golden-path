#!/usr/bin/env bash
# Shared helpers. Sourced, not executed.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export REPO_ROOT

# shellcheck source=/dev/null
set -a; source "${REPO_ROOT}/versions.env"; set +a

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m warn\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror\033[0m %s\n' "$*" >&2; exit 1; }

require() {
  local missing=0 bin
  for bin in "$@"; do
    command -v "$bin" >/dev/null 2>&1 || { warn "missing required binary: ${bin}"; missing=1; }
  done
  [ "$missing" -eq 0 ] || die "install the missing tools above, then re-run. See README 'Prerequisites'."
}

# Fail loudly if the repo has not been pointed at a real Git remote yet.
# Argo CD pulls from a URL; a placeholder produces a confusing ComparisonError
# deep in the UI rather than an actionable message here.
assert_repo_initialised() {
  if grep -rq '__REPO_URL__\|__REPO_REVISION__' "${REPO_ROOT}/clusters" 2>/dev/null; then
    die "repo not initialised: run 'make init' first (it points the Argo CD Applications at your fork)."
  fi
}
