#!/bin/bash
# First-boot hardening for a fresh Debian 12 / Ubuntu 24.04 VPS: a `vibe` user,
# SSH/firewall/fail2ban/unattended-upgrades, sysctl, the container engine, and
# the systemd user unit that brings the compose stack up on boot.
#
# Usage: sudo ./vps-bootstrap.sh [--docker] [--repo-url <git-url>]
# Default engine is rootless Podman; --docker installs Docker instead.
set -euo pipefail

ENGINE="podman"
REPO_URL=""
VIBE_HOME="/home/vibe"
APP_DIR="/opt/vibe"

while [ $# -gt 0 ]; do
  case "$1" in
    --docker) ENGINE="docker"; shift ;;
    --repo-url) REPO_URL="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

if [ "$(id -u)" -ne 0 ]; then
  echo "run as root (sudo ./vps-bootstrap.sh)" >&2
  exit 1
fi

log() { echo "[bootstrap] $*"; }

create_user() {
  if id vibe >/dev/null 2>&1; then
    log "user 'vibe' already exists"
  else
    log "creating user 'vibe' (runs the stack; not a sudoer — keep your admin user for that)"
    adduser --disabled-password --gecos "" vibe
  fi
}

harden_ssh() {
  log "hardening sshd (PasswordAuthentication no)"
  sed -i \
    -e 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' \
    -e 's/^#\?PermitRootLogin.*/PermitRootLogin no/' \
    -e 's/^#\?KbdInteractiveAuthentication.*/KbdInteractiveAuthentication no/' \
    /etc/ssh/sshd_config
  systemctl reload ssh || systemctl reload sshd || true
}

setup_firewall() {
  log "installing ufw"
  apt-get install -y -qq ufw
  ufw default deny incoming
  ufw default allow outgoing
  ufw limit 22/tcp
  ufw allow 80/tcp
  ufw allow 443/tcp
  ufw --force enable
}

setup_fail2ban() {
  log "installing fail2ban (sshd + caddy 401/429 jail)"
  apt-get install -y -qq fail2ban
  mkdir -p /etc/fail2ban/filter.d
  cat >/etc/fail2ban/filter.d/caddy-auth.conf <<-'EOF'
	# Matches Caddy's JSON access log (deploy/caddy/Caddyfile) for repeated
	# 401/429 responses from one IP — brute-force / abuse, not a real client.
	[Definition]
	failregex = "remote_ip":"<HOST>".*"status":(401|429)
	journalmatch =
	EOF
  cat >/etc/fail2ban/jail.d/vibe.local <<-'EOF'
	[sshd]
	enabled = true

	[caddy-auth]
	enabled = true
	filter = caddy-auth
	logpath = /opt/vibe/deploy/caddy-logs/access.log
	maxretry = 20
	findtime = 60
	bantime = 3600
	EOF
  systemctl enable --now fail2ban
}

setup_unattended_upgrades() {
  log "installing unattended-upgrades"
  apt-get install -y -qq unattended-upgrades apt-listchanges
  dpkg-reconfigure -f noninteractive unattended-upgrades
}

setup_sysctl() {
  log "applying sysctl tuning"
  cat >/etc/sysctl.d/99-vibe.conf <<-'EOF'
	net.ipv4.ip_unprivileged_port_start=80
	net.core.somaxconn=4096
	fs.file-max=200000
	EOF
  sysctl --system >/dev/null
}

setup_time_sync() {
  log "enabling systemd-timesyncd"
  timedatectl set-ntp true
}

setup_logrotate() {
  log "installing logrotate policy for the stack's own logs"
  cat >/etc/logrotate.d/vibe <<-'EOF'
	/opt/vibe/deploy/caddy-logs/*.log {
	  weekly
	  rotate 8
	  compress
	  missingok
	  notifempty
	}
	EOF
}

install_podman() {
  log "installing podman + podman-compose"
  apt-get install -y -qq podman uidmap slirp4netns fuse-overlayfs
  apt-get install -y -qq podman-compose || pip3 install --break-system-packages podman-compose
}

install_docker() {
  log "installing docker + compose plugin"
  apt-get install -y -qq ca-certificates curl gnupg
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  . /etc/os-release
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${ID} ${VERSION_CODENAME} stable" \
    >/etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin
  usermod -aG docker vibe
}

setup_linger_and_unit() {
  log "enabling linger + systemd user unit for vibe"
  loginctl enable-linger vibe
  if [ "$ENGINE" = "podman" ]; then
    su - vibe -c "XDG_RUNTIME_DIR=/run/user/$(id -u vibe) systemctl --user enable --now podman.socket"
  fi
  mkdir -p "${VIBE_HOME}/.config/systemd/user"
  unit_src="${APP_DIR}/deploy/systemd/vibe-stack.service"
  [ "$ENGINE" = "docker" ] && unit_src="${APP_DIR}/deploy/systemd/vibe-stack-docker.service"
  if [ -f "$unit_src" ]; then
    cp "$unit_src" "${VIBE_HOME}/.config/systemd/user/vibe-stack.service"
    chown -R vibe:vibe "${VIBE_HOME}/.config"
    su - vibe -c "XDG_RUNTIME_DIR=/run/user/$(id -u vibe) systemctl --user daemon-reload"
    su - vibe -c "XDG_RUNTIME_DIR=/run/user/$(id -u vibe) systemctl --user enable vibe-stack.service"
    log "unit installed (not started — run deploy.sh first, then: systemctl --user start vibe-stack)"
  else
    log "WARNING: ${unit_src} not found yet — clone the repo to ${APP_DIR} first, then re-run this step"
  fi
}

setup_app_dir() {
  # /opt is root:root by default — vibe needs it before it can git clone / run compose there.
  mkdir -p "$APP_DIR"
  chown vibe:vibe "$APP_DIR"
}

clone_repo() {
  if [ -n "$REPO_URL" ] && [ ! -d "$APP_DIR/.git" ]; then
    log "cloning ${REPO_URL} to ${APP_DIR}"
    su - vibe -c "git clone '${REPO_URL}' '${APP_DIR}'"
  fi
}

main() {
  apt-get update -qq
  create_user
  setup_app_dir
  harden_ssh
  setup_firewall
  setup_fail2ban
  setup_unattended_upgrades
  setup_sysctl
  setup_time_sync
  setup_logrotate
  if [ "$ENGINE" = "docker" ]; then install_docker; else install_podman; fi
  clone_repo
  setup_linger_and_unit
  log "done. Next: su - vibe, cd ${APP_DIR}, deploy/scripts/gen-secrets.sh, fill in deploy/env/*.env, then deploy/scripts/deploy.sh"
}

main
