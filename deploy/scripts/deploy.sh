#!/bin/bash
# First deploy and every redeploy after: build, migrate, bring the stack up,
# wait for readiness. Run from the repo root (or anywhere — it cd's there).
#
# Usage: deploy/scripts/deploy.sh
#        deploy/scripts/deploy.sh --rollback <tag>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
COMPOSE_FILE="${REPO_ROOT}/deploy/compose.yml"

if command -v podman >/dev/null 2>&1; then
  COMPOSE=(podman compose -f "$COMPOSE_FILE")
  ENGINE_BIN=podman
else
  COMPOSE=(docker compose -f "$COMPOSE_FILE")
  ENGINE_BIN=docker
fi

log() { echo "[deploy] $*"; }

migrate() {
  local service="$1" bin="$2" mod="$3"
  log "migrating ${service} (${mod})"
  "${COMPOSE[@]}" run --rm "$service" \
    sh -c "DATABASE_URL=\"\${MIGRATION_DATABASE_URL:-\$DATABASE_URL}\" /app/bin/${bin} eval \"${mod}.migrate\""
}

wait_ready() {
  local service="$1" url="$2" tries=30
  log "waiting for ${service} readiness (${url})"
  while [ "$tries" -gt 0 ]; do
    if "${COMPOSE[@]}" exec -T "$service" wget -qO- "$url" >/dev/null 2>&1; then
      log "${service} ready"
      return 0
    fi
    tries=$((tries - 1))
    sleep 2
  done
  echo "[deploy] ${service} did not become ready in time" >&2
  return 1
}

rollback() {
  local tag="$1"
  for image in vibe-core vibe-agent-runtime; do
    log "rolling back ${image} to ${tag}"
    "$ENGINE_BIN" tag "${image}:${tag}" "${image}:latest"
  done
  "${COMPOSE[@]}" up -d --no-build core agent-runtime
  "${COMPOSE[@]}" ps
}

main() {
  cd "$REPO_ROOT"

  if [ "${1:-}" = "--rollback" ]; then
    [ -n "${2:-}" ] || { echo "usage: deploy.sh --rollback <tag>" >&2; exit 1; }
    rollback "$2"
    exit 0
  fi

  if [ -d .git ]; then
    log "git pull"
    git pull --ff-only
  fi

  log "building images"
  "${COMPOSE[@]}" build

  # Tag this build with the git SHA before anything replaces :latest, so
  # --rollback <sha> has something to retag back to.
  sha="$(git rev-parse --short HEAD 2>/dev/null || date -u +%Y%m%dT%H%M%SZ)"
  for image in vibe-core vibe-agent-runtime; do
    "$ENGINE_BIN" tag "${image}:latest" "${image}:${sha}" 2>/dev/null || true
  done
  log "tagged build as ${sha}"

  log "starting data tier"
  "${COMPOSE[@]}" up -d postgres pgbouncer valkey

  log "waiting for postgres"
  tries=30
  until "${COMPOSE[@]}" exec -T postgres pg_isready -U "${POSTGRES_USER:-postgres}" >/dev/null 2>&1; do
    tries=$((tries - 1))
    [ "$tries" -le 0 ] && { echo "[deploy] postgres did not come up" >&2; exit 1; }
    sleep 2
  done

  migrate core vibe Vibe.Release
  # Assumes the agent-runtime release binary/module follow the core's naming
  # convention (bin/vibe_agents, VibeAgents.Release) — agent-runtime/ had no
  # Release module yet when this was written; confirm with the runtime worker.
  migrate agent-runtime vibe_agents VibeAgents.Release

  log "starting remaining services"
  "${COMPOSE[@]}" up -d

  wait_ready core "http://127.0.0.1:4000/api/ready"
  wait_ready agent-runtime "http://127.0.0.1:4100/readyz"

  "${COMPOSE[@]}" ps
}

main "$@"
