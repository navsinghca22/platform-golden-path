#!/usr/bin/env bash
#
# One-time setup: rewrite the __REPO_URL__ / __REPO_REVISION__ placeholders in
# the Argo CD Application manifests to point at YOUR fork.
#
# Why a placeholder and not a value: Argo CD pulls from a Git URL, so the
# manifests must name the repo they live in. Hardcoding one author's URL makes
# the repo unusable by anyone else; templating it at bootstrap time and leaving
# Git dirty is worse. An explicit, committed init step is the honest option.

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REPO_URL="${REPO_URL:-}"
REPO_REVISION="${REPO_REVISION:-main}"

if [ -z "$REPO_URL" ]; then
  REPO_URL="$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null || true)"
  [ -n "$REPO_URL" ] || die "no git remote 'origin' found. Push this repo to GitHub first, or run: make init REPO_URL=https://github.com/<you>/platform-golden-path.git"
  # Normalise SSH remotes to HTTPS: Argo CD runs in-cluster and has no SSH key.
  case "$REPO_URL" in
    git@github.com:*) REPO_URL="https://github.com/${REPO_URL#git@github.com:}" ;;
  esac
fi

log "repo URL      : ${REPO_URL}"
log "target revision: ${REPO_REVISION}"

files="$(grep -rl '__REPO_URL__\|__REPO_REVISION__' "${REPO_ROOT}/clusters" || true)"
if [ -z "$files" ]; then
  log "no placeholders left; nothing to do."
  exit 0
fi

while IFS= read -r f; do
  # BSD sed (macOS) and GNU sed disagree on -i; write to a temp file instead.
  tmp="$(mktemp)"
  sed -e "s|__REPO_URL__|${REPO_URL}|g" -e "s|__REPO_REVISION__|${REPO_REVISION}|g" "$f" > "$tmp"
  mv "$tmp" "$f"
  log "updated ${f#"$REPO_ROOT"/}"
done <<< "$files"

cat <<MSG

Done. Commit and push before bootstrapping -- Argo CD reads from the remote,
not from your working copy:

  git add -A && git commit -m "chore: point Argo CD applications at this fork" && git push

MSG
