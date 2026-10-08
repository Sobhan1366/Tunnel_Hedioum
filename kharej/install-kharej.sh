#!/usr/bin/env bash
# install-kharej.sh — run on the FOREIGN (egress) server, as root.
#
# Installs Hedioum Pool Tunnel in "foreign" mode, prepares a self-contained
# bundle for the Iran server (binaries + pairing token).
#
# Usage:
#   sudo bash install-kharej.sh [options]
#
# Options:
#   --persona NAME        auto|cpanel|directadmin|devops   (default: auto)
#   --domain DOMAIN       real domain for a Let's Encrypt cert (default: self-signed)
#   --move-ssh            let Hedioum relocate OpenSSH to its decoy port (default: off)
#   --jitter-restart      install a randomized-restart timer (anti-fingerprinting)
#   --bundle-dir DIR      where to write the Iran bundle (default: /root/iran-bundle)
#   -h, --help
set -euo pipefail

PERSONA="auto"; DOMAIN=""; MOVE_SSH=0; JITTER=0; BUNDLE="/root/iran-bundle"

HEDIOUM_REPO="hedioum/Hedioum-Pool-Tunnel"
XRAY_REPO="XTLS/Xray-core"

log()  { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --persona)        PERSONA="${2:?}"; shift 2;;
    --domain)         DOMAIN="${2:?}"; shift 2;;
    --move-ssh)       MOVE_SSH=1; shift;;
    --jitter-restart) JITTER=1; shift;;
    --bundle-dir)     BUNDLE="${2:?}"; shift 2;;
    -h|--help)        sed -n "2,16p" "$0"; exit 0;;
    *) die "unknown option: $1";;
  esac
done

[ "$(id -u)" -eq 0 ] || die "run as root"
command -v systemctl >/dev/null || die "systemd is required"

case "$(uname -m)" in
  x86_64|amd64)  HED_ASSET="hedioum-tunnel";       XRAY_ASSET="Xray-linux-64.zip";;
  aarch64|arm64) HED_ASSET="hedioum-tunnel-arm64"; XRAY_ASSET="Xray-linux-arm64-v8a.zip";;
  armv7l)        HED_ASSET="hedioum-tunnel-armv7"; XRAY_ASSET="Xray-linux-arm32-v7a.zip";;
  *) die "unsupported architecture: $(uname -m)";;
esac

export DEBIAN_FRONTEND=noninteractive
log "Installing prerequisites"
apt-get update -qq
apt-get install -y -qq curl ca-certificates unzip iproute2 >/dev/null

PUBLIC_IP="$(curl -fsS --max-time 8 https://api.ipify.org || true)"
[ -n "$PUBLIC_IP" ] || PUBLIC_IP="$(ip -4 route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}')"
log "Public IP: $PUBLIC_IP"

mkdir -p "$BUNDLE"; chmod 700 "$BUNDLE"

# ---------------------------------------------------------------- Hedioum
if [ ! -x /usr/local/bin/hedioum-tunnel ]; then
  log "Downloading Hedioum ($HED_ASSET)"
  curl -fL --retry 3 -o /tmp/hedioum-tunnel \
    "https://github.com/$HEDIOUM_REPO/releases/latest/download/$HED_ASSET"
  chmod +x /tmp/hedioum-tunnel
  /tmp/hedioum-tunnel install   # self-copies to /usr/local/bin and enables the unit
else
  log "Hedioum already installed: $(/usr/local/bin/hedioum-tunnel version | head -1)"
fi
cp -f /usr/local/bin/hedioum-tunnel "$BUNDLE/hedioum-tunnel"

SETUP_ARGS=(--persona "$PERSONA" --public-ip "$PUBLIC_IP")
[ -n "$DOMAIN" ]  && SETUP_ARGS+=(--domain "$DOMAIN")
[ "$MOVE_SSH" -eq 1 ] && SETUP_ARGS+=(--move-ssh)

log "Configuring foreign node: hedioum-tunnel setup-foreign ${SETUP_ARGS[*]}"
SETUP_OUT="$(/usr/local/bin/hedioum-tunnel setup-foreign "${SETUP_ARGS[@]}" 2>&1)" \
  || { printf '%s\n' "$SETUP_OUT" >&2; die "setup-foreign failed"; }
printf '%s\n' "$SETUP_OUT"

# The pairing token is the long base64url string printed by setup-foreign.
TOKEN="$(printf '%s\n' "$SETUP_OUT" | grep -oE '[A-Za-z0-9_-]{80,}' | tail -1 || true)"
if [ -n "$TOKEN" ]; then
  umask 077; printf '%s\n' "$TOKEN" > "$BUNDLE/pairing.token"
  log "Pairing token saved to $BUNDLE/pairing.token"
else
  warn "Could not auto-detect the pairing token in the output above."
  warn "Copy it by hand and pass it to the Iran script with --token."
fi
systemctl enable --now hedioum.service
systemctl restart hedioum.service

# ------------------------------------------------------------------- Xray
# Bundled here because Iran servers frequently cannot reach GitHub.
if [ ! -x "$BUNDLE/xray" ]; then
  log "Downloading Xray ($XRAY_ASSET) for the Iran bundle"
  curl -fL --retry 3 -o /tmp/xray.zip \
    "https://github.com/$XRAY_REPO/releases/latest/download/$XRAY_ASSET"
  rm -rf /tmp/xray-x && mkdir /tmp/xray-x && unzip -q -o /tmp/xray.zip -d /tmp/xray-x
  install -m 0755 /tmp/xray-x/xray "$BUNDLE/xray"
  for f in geoip.dat geosite.dat; do [ -f "/tmp/xray-x/$f" ] && cp "/tmp/xray-x/$f" "$BUNDLE/"; done
fi

# ----------------------------------------------------- randomized restarts
if [ "$JITTER" -eq 1 ]; then
  log "Installing randomized-restart timer"
  cat > /usr/local/sbin/tunnel-jitter-restart.sh <<'EOF'
#!/bin/bash
set -e
sleep $((RANDOM % 900))
systemctl restart hedioum.service
EOF
  chmod +x /usr/local/sbin/tunnel-jitter-restart.sh
  cat > /etc/systemd/system/tunnel-jitter-restart.service <<'EOF'
[Unit]
Description=Jittered restart of tunnel services
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/tunnel-jitter-restart.sh
EOF
  cat > /etc/systemd/system/tunnel-jitter-restart.timer <<'EOF'
[Unit]
Description=Irregular multi-hour restart of tunnel services
[Timer]
OnBootSec=45min
OnUnitActiveSec=3h
RandomizedDelaySec=5400
[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable tunnel-jitter-restart.timer
  systemctl restart tunnel-jitter-restart.timer   # forces NEXT to be computed
fi

log "Foreign server ready."
cat <<EOF

================ NEXT STEP — on the IRAN server ================
  scp -r root@$PUBLIC_IP:$BUNDLE /root/
  sudo bash install-iran.sh --bundle /root/iran-bundle
================================================================
The bundle contains the pairing token and keys — delete it from both servers
once the Iran side is installed:  rm -rf $BUNDLE
EOF
