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

# Explicit build, not `compose build`: podman-compose cannot resolve a
# `dockerfile:` key against a parent `context:`, and this is engine-agnostic.
build_image() {
  local name="$1" ctx="$2" dockerfile="$3"
  log "building ${name}"
  "$ENGINE_BIN" build -t "${name}:latest" -f "${ctx}/${dockerfile}" "$ctx"
}

# Not `compose run`: podman-compose 1.0.6 crashes in its cleanup path
# (compose_down: no attribute 'remove_orphans') and tears the stack down with it.
migrate() {
  local service="$1" bin="$2" mod="$3"
  local project; project="$(basename "$(dirname "$COMPOSE_FILE")")"
  log "migrating ${service} (${mod})"
  "$ENGINE_BIN" run --rm --network "${project}_internal" \
    --env-file "${REPO_ROOT}/deploy/env/${service}.env" \
    "vibe-${service}:latest" \
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
  # Both tags are checked before either is moved: a half-rolled-back pair is worse
  # than a failed rollback. Migrations are forward-only — this restores code, not schema.
  for image in vibe-core vibe-agent-runtime; do
    "$ENGINE_BIN" image inspect "${image}:${tag}" >/dev/null 2>&1 ||
      { echo "[deploy] no ${image}:${tag} — run: ${ENGINE_BIN} images ${image}" >&2; exit 1; }
  done
  for image in vibe-core vibe-agent-runtime; do
    log "rolling back ${image} to ${tag}"
    "$ENGINE_BIN" tag "${image}:${tag}" "${image}:latest"
  done
  # podman-compose 1.0.6 ignores --no-deps and would recreate postgres/valkey too.
  # Dropping only these two and running --no-recreate leaves the data tier alone.
  local project; project="$(basename "$(dirname "$COMPOSE_FILE")")"
  "$ENGINE_BIN" rm -f "${project}_core_1" "${project}_agent-runtime_1" >/dev/null 2>&1 || true
  "${COMPOSE[@]}" up -d --no-build --no-recreate
  "${COMPOSE[@]}" ps || true
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

  # Snapshot what is live before anything replaces :latest, so a failed
  # readiness gate can put it straight back.
  for image in vibe-core vibe-agent-runtime; do
    "$ENGINE_BIN" tag "${image}:latest" "${image}:previous" 2>/dev/null || true
  done

  log "building images"
  build_image vibe-core            "$REPO_ROOT"                 deploy/core/Dockerfile
  build_image vibe-agent-runtime   "$REPO_ROOT"                 agent-runtime/Dockerfile
  build_image vibe-sandbox-gateway "$REPO_ROOT/sandbox-gateway" Dockerfile
  build_image vibe-doc-renderer    "$REPO_ROOT"                 deploy/doc-renderer/Dockerfile
  build_image vibe-backup          "$REPO_ROOT/deploy/backup"   Dockerfile

  # Tag this build with the git SHA before anything replaces :latest, so
  # --rollback <sha> has something to retag back to.
  sha="${VIBE_BUILD_SHA:-$(cat "${REPO_ROOT}/.vibe-sha" 2>/dev/null \
        || git rev-parse --short HEAD 2>/dev/null || date -u +%Y%m%dT%H%M%SZ)}"
  for image in vibe-core vibe-agent-runtime; do
    "$ENGINE_BIN" tag "${image}:latest" "${image}:${sha}" 2>/dev/null || true
  done
  log "tagged build as ${sha}"

  log "starting data tier"
  "${COMPOSE[@]}" up -d postgres pgbouncer valkey

  log "waiting for postgres"
  tries=30
  until "$ENGINE_BIN" exec "$(basename "$(dirname "$COMPOSE_FILE")")_postgres_1" \
          pg_isready -U "${POSTGRES_USER:-postgres}" >/dev/null 2>&1; do
    tries=$((tries - 1))
    [ "$tries" -le 0 ] && { echo "[deploy] postgres did not come up" >&2; exit 1; }
    sleep 2
  done

  migrate core vibe Vibe.Release
  migrate agent-runtime vibe_agents VibeAgents.Release

  log "starting remaining services"
  "${COMPOSE[@]}" up -d

  if ! wait_ready core "http://127.0.0.1:4000/api/ready" ||
     ! wait_ready agent-runtime "http://127.0.0.1:4100/readyz"; then
    if "$ENGINE_BIN" image inspect vibe-core:previous >/dev/null 2>&1; then
      log "readiness failed — rolling back to the previous images"
      rollback previous
    fi
    echo "[deploy] failed readiness; retry this build with --rollback ${sha}" >&2
    exit 1
  fi

  "${COMPOSE[@]}" ps || true
}

main "$@"
