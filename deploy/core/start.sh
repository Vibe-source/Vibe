#!/bin/sh
set -euo pipefail

# Migrate against MIGRATION_DATABASE_URL (direct to postgres:5432) — Ecto's
# migration lock is a session-scoped Postgres advisory lock, which pgbouncer's
# transaction pooling (DATABASE_URL) cannot hold. Falls back to DATABASE_URL
# if unset, so this still works against a non-pooled DATABASE_URL.
echo "[start.sh] Running database migrations..."
DATABASE_URL="${MIGRATION_DATABASE_URL:-$DATABASE_URL}" /app/bin/vibe eval "Vibe.Release.migrate"

# Doc renderer now runs as its own container (deploy/doc-renderer); nothing to
# start here — core reaches it at DOC_RENDERER_URL over the compose network.

if command -v yt-dlp >/dev/null 2>&1; then
  echo "[start.sh] yt-dlp: $(command -v yt-dlp) ($(yt-dlp --version 2>/dev/null || echo unknown))"
  export YTDLP_PATH="${YTDLP_PATH:-$(command -v yt-dlp)}"
elif python3 -c "import yt_dlp" >/dev/null 2>&1; then
  echo "[start.sh] yt-dlp: python3 -m yt_dlp ($(python3 -m yt_dlp --version 2>/dev/null || echo module-ok))"
else
  echo "[start.sh] WARNING: yt-dlp missing — SoundCloud/YouTube music resolve will fail"
fi

export PHX_SERVER=true
exec /app/bin/vibe start
