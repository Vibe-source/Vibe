# VPS deployment — Podman/Docker compose stack

Operational companion to [`agent-platform-v1.md`](agent-platform-v1.md) (architecture,
frozen contracts) and [`deploy/README.md`](../deploy/README.md) (file layout, first-deploy
command list). This doc covers sizing, DNS, the Railway/Supabase → VPS migration, day-2
operations, and security posture.

## 1. Architecture recap

One VPS, `podman compose` (rootless, preferred) or `docker compose`, no Kubernetes. Caddy
terminates TLS and is the only publicly-reachable service; everything else sits on an
internal Docker network. See `agent-platform-v1.md` §1 for the trust-boundary table — this
stack enforces the same boundaries, one compose network per boundary:

- `edge` — caddy, core, agent-runtime (Caddy → core:4000 / agent-runtime:4100)
- `internal` — everything except caddy and the sandboxes
- `sandbox-net` (`internal: true`, no default route out) — sandbox-gateway, egress-proxy,
  and the sandbox containers the gateway spins up on demand

Postgres holds two databases (`vibe_core`, `vibe_agents`) behind PgBouncer (transaction
pooling); Valkey is cache/rate-limit only, no persistence; the doc renderer and the
sandbox-gateway's container socket are each their own service so a crash or a compromise
in one doesn't take the chat core down with it.

## 2. Sizing

Baseline target: a 4-8 GB / 2-4 vCPU VPS (e.g. Hetzner CX32/CX42, DigitalOcean equivalent).

| Service | Memory limit | Notes |
|---|---|---|
| postgres | 2 GB | `shared_buffers 1GB` — see `deploy/postgres/postgresql.conf` |
| core | 1 GB | Elixir release + yt-dlp/ffmpeg subprocess spikes |
| agent-runtime | 1 GB | one BEAM process per concurrent run |
| valkey | 384 MB | `maxmemory 256mb` cap, no persistence |
| doc-renderer | 512 MB | weasyprint spikes on large PDFs |
| pgbouncer / caddy / sandbox-gateway / egress-proxy / backup | 128-256 MB each | |

At 4 GB total limits above plus OS + container overhead, an 8 GB box has comfortable
headroom; a 4 GB box works but leaves little for sandbox containers (each sandbox gets its
own memory budget via `SANDBOX_DEFAULT_MEMORY_MB` on top of this table). Scale up before
scaling out — phase 4 (`agent-platform-v1.md` §5) adds a second VPS via libcluster only
once one box is genuinely full.

## 3. DNS

Three names, all pointed at the VPS's IP:

- `<domain>` — SPA (served by core)
- `api.<domain>` — core's API/websocket
- `agents.<domain>` — agent-runtime's provider ingress + voice sockets

Caddy provisions Let's Encrypt certs for all three automatically on first boot (needs 80
and 443 reachable from the internet for the ACME HTTP-01 challenge). Set a low TTL (300s)
on these records a day before any planned migration/cutover — see §5.

## 4. First deploy

Command-by-command list: [`deploy/README.md`](../deploy/README.md#first-deploy-in-10-commands).
In short: `vps-bootstrap.sh` hardens the box and installs the engine, `gen-secrets.sh` +
hand-editing `deploy/env/*.env` fills in real values, `deploy.sh` builds, migrates, and
brings the stack up, `status.sh` confirms it's healthy.

## 5. Migration: Railway/Supabase → VPS

A cutover, not a live migration — plan for a short write freeze.

1. **Provision the VPS** and run through §4 up to (not including) DNS cutover, so the new
   stack is fully up and reachable at its IP before any traffic moves.
2. **Freeze writes** on the Railway deployment (maintenance mode / scale to 0, whichever
   the app supports) — a single point-in-time dump is only consistent if nothing writes
   during it.
3. **Dump from Supabase's pooler**, not a direct connection (Supabase's session pooler
   handles the large `pg_dump` connection fine; the transaction pooler does not):
   ```bash
   pg_dump --no-owner --no-privileges -Fc \
     "postgresql://postgres.<project-ref>:<password>@aws-0-<region>.pooler.supabase.com:5432/postgres" \
     -f vibe_core.dump
   ```
   `--no-owner --no-privileges` because Supabase's role names don't exist here; `--role`
   makes `vibe_core_app` own every restored table (the app connects as that role and, as
   owner, bypasses the non-forced RLS policies exactly as it does on Supabase today).
4. **Restore** into the VPS's `vibe_core` database:
   ```bash
   podman compose -f deploy/compose.yml exec -T postgres \
     pg_restore -U "$POSTGRES_USER" --role=vibe_core_app -d vibe_core --no-owner --no-privileges <vibe_core.dump
   ```
5. **Sequence check** — `pg_restore` restores sequence values as of the dump, but any row
   inserted between the dump and the freeze (there should be none if step 2 held) would
   desync them. Verify: for each table with a serial/identity PK, confirm
   `select setval('<seq>', (select max(id) from <table>))` is a no-op (already at max).
6. **Storage stays put.** Media lives in Supabase Storage / R2 buckets, addressed by URL —
   nothing in the app writes to local disk for uploads, so there is no file migration step.
   Keep `SUPABASE_*`/`R2_*` credentials pointed at the same buckets in `core.env`.
7. **DNS cutover.** With the low TTL from §3 already in place, repoint `<domain>`,
   `api.<domain>`, `agents.<domain>` to the VPS. Caddy issues certs on first request to
   each name — expect a few seconds of ACME latency on the very first hit per host.
8. **Rollback = DNS back.** Nothing on Railway is torn down until the VPS has been
   observed healthy for a real traffic window (hours, not minutes) — repointing DNS back
   to Railway is the entire rollback procedure as long as Railway's deployment is still
   running and its Supabase database wasn't touched (it wasn't; the VPS reads its own copy).

### Secret rotation on cutover

| Secret | Action |
|---|---|
| `SECRET_KEY_BASE` | **Keep the Railway value.** It signs/encrypts existing sessions and cookies; rotating it logs every user out. |
| DB credentials | **New.** `vibe_core_app`/`vibe_agents_app` passwords are generated fresh by `gen-secrets.sh` for the VPS's own Postgres — never reuse the Supabase password. |
| Agent provider keys (`ANTHROPIC_API_KEY` etc.) | **Unchanged** — same keys, just also present in `agent-runtime.env` now (see the `# remove after cutover` markers in `core.env.example` for phase 3). |
| `VIBE_INTERNAL_HMAC_KEY` | New — this is a VPS-only concept, Railway never had it. |
| Push/Lemon Squeezy/R2/Supabase-storage credentials | Unchanged — same external services, just read from a new box. |

## 6. Operations

**Upgrade:** `deploy/scripts/deploy.sh` — pulls, builds, tags the build with the current
git short SHA, migrates (core then agent-runtime), brings the stack up, waits for
`/api/ready` and `/readyz`.

**Rollback:** `deploy/scripts/deploy.sh --rollback <tag>` retags a previous build (the SHA
printed by the deploy that shipped it) back onto `vibe-core:latest` /
`vibe-agent-runtime:latest` and restarts — no rebuild. Does not reverse migrations; a
migration that must be undone needs `Vibe.Release.rollback/2` run by hand.

**Backups:** automatic every 6h (`deploy/backup/crontab` inside the `backup` container) —
`pg_dump -Fc` both databases, `age`-encrypted to `BACKUP_AGE_PUBLIC_KEY`, uploaded to R2
under `daily/<db>/` (14-day retention) and, on the weekly Sunday run, also under
`weekly/<db>/` (56-day retention). Trigger one on demand with `deploy/scripts/backup.sh`.

**Restore drill:** `deploy/scripts/restore.sh <vibe_core|vibe_agents>` downloads the newest
backup, decrypts it (needs `BACKUP_AGE_PRIVATE_KEY`, which is never stored on the VPS —
export it from wherever it's kept offline before running), restores into a scratch
database, and prints a row-count diff against the live one. It does **not** touch the live
database unless re-run with `--swap`, which stops core/agent-runtime, terminates
connections, and renames the scratch DB into place. Run this drill on a schedule (monthly,
at minimum) — an untested backup is a hope, not a plan.

**Logs:** `podman compose -f deploy/compose.yml logs -f <service>`. Caddy's JSON access
log is additionally written to `deploy/caddy-logs/access.log` on the host (fail2ban's
caddy jail and host logrotate both read it from there — see `vps-bootstrap.sh`).

**Health/metrics:** `deploy/scripts/status.sh` for a one-shot snapshot. `core:9568` and
`agent-runtime:9568` expose Prometheus metrics on the `internal` network only; bring up
`prometheus`/`grafana`/`node-exporter` with `podman compose --profile monitoring up -d` —
both are bound to `127.0.0.1` on the host, reachable only over an SSH tunnel
(`ssh -L 3000:localhost:3000 vibe@<vps>`), never published publicly.

## 7. Security notes

**Public surface:** only Caddy, on 80/443. Everything else — postgres, pgbouncer, valkey,
sandbox-gateway, egress-proxy, doc-renderer, backup — has no `ports:` mapping and is
reachable only from other containers on the same compose network. `/internal/*` is blocked
at the edge on all three Caddy site blocks (belt-and-suspenders: the routes underneath
still require a valid `vibe-internal-auth/v1` HMAC signature even if this block were
bypassed).

**Internal-only:** the `internal` network carries plaintext HTTP/Postgres-wire/Redis-wire
traffic between containers — this is standard practice for a single-box compose stack (the
alternative, mTLS between every container, is real complexity for a threat model — another
container escaping onto the same bridge network — that `cap_drop: [ALL]` and
`no-new-privileges` on every application container already narrow considerably). Valkey has
no separate network ACL beyond this; its `requirepass` (set from `VALKEY_PASSWORD` at
container start, never written to the static `valkey.conf`) is defense-in-depth on top of
the network boundary, not a substitute for it.

**The sandbox-gateway's socket mount is the highest-value target in this stack** — anything
that can write to the mounted container socket can create arbitrary containers, which on a
naive setup means root-equivalent access to the host. Rootless Podman is why this deploy
uses it by default rather than Docker: the mounted socket
(`${XDG_RUNTIME_DIR}/podman/podman.sock`) belongs to the unprivileged `vibe` user's own
Podman instance, not a root daemon, so a container escape through that socket lands as
`vibe`, not root — it can create/destroy other containers owned by `vibe` (still a real
blast radius: it could tear down the whole stack, or spin up sandboxes of its own) but
cannot read arbitrary host files, install a kernel module, or touch other users' processes.
The Docker variant (`CONTAINER_SOCKET_HOST_PATH=/var/run/docker.sock`, the default when
`--docker` is used) does **not** have this property — Docker's daemon runs as root, so
anything that reaches that socket has effectively root on the host. Prefer rootless podman
for this reason; if Docker is a hard requirement, treat sandbox-gateway's compromise as
equivalent to a host compromise in your incident-response plan.

**What never leaves the box:** `BACKUP_AGE_PRIVATE_KEY` (backup decryption — only the
public key lives in `backup.env`), the Postgres data directory (only its encrypted,
off-site `pg_dump` output does), and MLS key material (never touches the server at all —
out of scope for this doc, see `crypto-audit-and-mls-direction` in agent memory).
