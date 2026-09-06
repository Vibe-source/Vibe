# deploy/ — Vibe VPS stack

Podman-or-Docker compose stack that replaces Railway. Full architecture,
sizing, migration and operations runbooks: [`docs/vps-deployment.md`](../docs/vps-deployment.md).

## Layout

- `compose.yml` — the stack. `caddy core agent-runtime sandbox-gateway
  egress-proxy postgres pgbouncer valkey doc-renderer backup`, plus an opt-in
  `monitoring` profile (prometheus/grafana/node-exporter).
- `core/` — Dockerfile + start.sh for the chat core (VPS variant of the root
  `Dockerfile`, minus the doc-renderer).
- `caddy/`, `postgres/`, `pgbouncer/`, `valkey/`, `doc-renderer/`, `backup/` —
  per-service config and, where needed, a Dockerfile.
- `env/*.env.example` — one template per service. Copy to `<name>.env`
  (gitignored) and fill in real values; never commit the real files.
- `scripts/` — `gen-secrets.sh`, `vps-bootstrap.sh`, `deploy.sh`, `backup.sh`,
  `restore.sh`, `status.sh`.
- `systemd/` — user units that bring the stack up on boot (podman and docker
  variants).
- `sandbox/`, `egress-proxy/` — owned by the sandbox-gateway work; referenced
  here, not duplicated.

## Where secrets live

Real secrets only ever live in `deploy/env/*.env` on the VPS itself
(gitignored) — never in this repo, never in `compose.yml`. Generate values
with `deploy/scripts/gen-secrets.sh`; it prints, it doesn't write, so it can't
clobber a live deployment. The one exception: the backup encryption private
key (`BACKUP_AGE_PRIVATE_KEY`) never touches the VPS at all — keep it offline
and pass it to `restore.sh` only when actually restoring.

## First deploy, in 10 commands

```bash
# 1. On the VPS, as root:
curl -fsSL https://raw.githubusercontent.com/<org>/vibe/main/deploy/scripts/vps-bootstrap.sh | bash -s -- --repo-url https://github.com/<org>/vibe.git
# 2.
su - vibe && cd /opt/vibe
# 3.
deploy/scripts/gen-secrets.sh > /tmp/secrets.txt
# 4. Copy each block from /tmp/secrets.txt into the matching file, then:
for f in deploy/env/*.env.example; do cp "$f" "${f%.example}"; done
# 5. Edit deploy/env/*.env: paste secrets, set VIBE_DOMAIN/ACME_EMAIL, provider
#    keys, R2/Supabase creds, push keys — see docs/vps-deployment.md.
$EDITOR deploy/env/core.env deploy/env/agent-runtime.env deploy/env/caddy.env …
# 6. Point DNS (api.<domain>, agents.<domain>, <domain>) at this VPS's IP.
# 7.
rm /tmp/secrets.txt
# 8.
deploy/scripts/deploy.sh
# 9.
deploy/scripts/status.sh
# 10. Start on boot:
systemctl --user start vibe-stack
```
