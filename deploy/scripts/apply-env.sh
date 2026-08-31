#!/bin/bash
# Merge KEY=VALUE lines from stdin into deploy/env/<file>. Values arrive over a
# pipe, never argv, so they stay out of `ps` and out of this output.
#
#   agix secret run --only R2_SECRET_ACCESS_KEY -- sh -c \
#     'printf "R2_SECRET_ACCESS_KEY=%s\n" "$R2_SECRET_ACCESS_KEY" |
#      ssh vibe@$VPS_HOST "/opt/vibe/deploy/scripts/apply-env.sh core.env"'
#
# Prints names only.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ENV_DIR="${REPO_ROOT}/deploy/env"
TARGET="${1:?usage: apply-env.sh <file.env>}"
FILE="${ENV_DIR}/${TARGET}"

case "$TARGET" in
  */*|..*) echo "apply-env: name only, not a path" >&2; exit 1 ;;
  *.env) ;;
  *) echo "apply-env: must end in .env" >&2; exit 1 ;;
esac
[ -f "$FILE" ] || { echo "apply-env: ${TARGET} does not exist — run init-env.sh first" >&2; exit 1; }

umask 077
tmp="$(mktemp "${FILE}.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
cp "$FILE" "$tmp"
applied=()

while IFS= read -r line; do
  [ -n "$line" ] || continue
  case "$line" in \#*) continue ;; esac
  name="${line%%=*}"
  [ "$name" != "$line" ] || { echo "apply-env: skipping malformed line" >&2; continue; }
  case "$name" in
    [A-Z_]*[A-Z0-9_]|[A-Z_]) ;;
    *) echo "apply-env: skipping non-env name" >&2; continue ;;
  esac
  # grep -v then append: rewriting in place would need the value on a sed line.
  grep -v "^${name}=" "$tmp" >"${tmp}.n" || true
  mv "${tmp}.n" "$tmp"
  printf '%s\n' "$line" >>"$tmp"
  applied+=("$name")
done

mv "$tmp" "$FILE"
trap - EXIT
chmod 600 "$FILE"
echo "${TARGET}: set ${#applied[@]} -> ${applied[*]:-none}"
