#!/bin/bash
# Put the VPS behind an outbound Cloudflare tunnel: no inbound port, no A record,
# nothing to port-scan. Run on the box as root. The token is argv, so run it yourself.
#
#   sudo /opt/vibe/deploy/scripts/tunnel-install.sh --token <cloudflare-tunnel-token>
#
# Options: --no-firewall (leave ufw alone), --origin <host:port> (default 127.0.0.1:8080)
set -euo pipefail

TOKEN=""
ORIGIN="127.0.0.1:8080"
NO_FIREWALL=""

while [ $# -gt 0 ]; do
  case "$1" in
    --token)       TOKEN="${2:?--token needs a value}"; shift 2 ;;
    --origin)      ORIGIN="${2:?--origin needs host:port}"; shift 2 ;;
    --no-firewall) NO_FIREWALL=1; shift ;;
    -h|--help)     sed -n '2,8p' "$0"; exit 0 ;;
    *)             echo "tunnel-install: unknown option: $1" >&2; exit 1 ;;
  esac
done

[ "$(id -u)" -eq 0 ] || { echo "tunnel-install: run with sudo" >&2; exit 1; }
[ -n "$TOKEN" ] || { echo "tunnel-install: --token is required" >&2; exit 1; }

echo "==> origin check"
curl -fsS -o /dev/null -H 'Host: localhost' "http://${ORIGIN}/" 2>/dev/null \
  || echo " !  ${ORIGIN} did not answer — start the stack first, or pass --origin"

echo "==> cloudflared"
if ! command -v cloudflared >/dev/null; then
  case "$(uname -m)" in
    x86_64|amd64)  CF_ARCH=amd64 ;;
    aarch64|arm64) CF_ARCH=arm64 ;;
    *) echo "tunnel-install: no cloudflared build for $(uname -m)" >&2; exit 1 ;;
  esac
  curl -fsSL -o /usr/local/bin/cloudflared \
    "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CF_ARCH}"
  chmod 0755 /usr/local/bin/cloudflared
fi

echo "==> service"
cloudflared service install "$TOKEN" >/dev/null 2>&1 \
  || echo " !  cloudflared service install reported a problem — check: systemctl status cloudflared"
systemctl enable --now cloudflared >/dev/null 2>&1 || true

if [ -z "$NO_FIREWALL" ] && command -v ufw >/dev/null; then
  echo "==> firewall"
  ufw --force default deny incoming >/dev/null
  # Outbound is denied too: a box that can dial anywhere can be made to dial anywhere.
  ufw --force default deny outgoing >/dev/null
  ufw allow out 53 >/dev/null
  ufw allow out 80/tcp >/dev/null
  ufw allow out 443/tcp >/dev/null
  ufw allow out 587/tcp >/dev/null
  ufw allow out 465/tcp >/dev/null
  ufw allow out on lo >/dev/null
  ufw allow in on lo >/dev/null
  ufw limit OpenSSH >/dev/null 2>&1 || ufw limit 22/tcp >/dev/null
  ufw delete allow 80/tcp >/dev/null 2>&1 || true
  ufw delete allow 443/tcp >/dev/null 2>&1 || true
  ufw --force enable >/dev/null
  echo "    inbound: SSH only (rate limited). outbound: DNS, 80, 443, 587, 465."
fi

systemctl is-active --quiet cloudflared && echo "cloudflared: active" || echo " !  cloudflared is not active"

cat <<DONE

Tunnel installed. Add these four public hostnames in the Zero Trust dashboard
(Networks > Tunnels > your tunnel > Public Hostname), each pointing at:

    Type: HTTP    URL: ${ORIGIN}

    vibegram.io
    api.vibegram.io
    agents.vibegram.io
    logs.vibegram.io

Cloudflare writes the DNS itself. Do not add A records: the origin address
should never appear in DNS.
DONE
