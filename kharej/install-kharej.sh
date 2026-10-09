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
#   --mimics LIST         camouflage endpoints, comma list (default: smtp — the only one that carried
#                         data reliably in testing; TLS-based mimics often stall behind DPI)
#   --persona NAME        use a Hedioum persona INSTEAD of --mimics (auto|cpanel|directadmin|devops)
#   --domain DOMAIN       real domain for a Let's Encrypt cert (default: self-signed)
#   --move-ssh            let Hedioum relocate OpenSSH to its decoy port (default: off)
#   --jitter-restart      install a randomized-restart timer (anti-fingerprinting)
#   --bundle-dir DIR      where to write the Iran bundle (default: /root/iran-bundle)
#   --listen-port N       SSH-mimic public port       (Hedioum default: 22)
#   --decoy-port N        local decoy sshd port       (Hedioum default: 2022)
#   --tls-port N          TLS mimic port
#   --smtp-port N         SMTP mimic port             (Hedioum default: 587)
#   --imap-port N         IMAP mimic port             (Hedioum default: 143)
#   --smtps-port N        SMTPS mimic port            (Hedioum default: 465)
#   --extra "FLAGS"       any other `setup-foreign` flags, passed through verbatim
#   -y, --yes             never prompt; use flags/defaults only
#
# Run in a terminal without --yes and the script asks for every value
# (press Enter to accept the default).
#   -h, --help
set -euo pipefail

PERSONA=""; MIMICS="smtp"; DOMAIN=""; MOVE_SSH=0; JITTER=0; BUNDLE="/root/iran-bundle"
LISTEN_PORT=""; DECOY_PORT=""; TLS_PORT=""; SMTP_PORT=""; IMAP_PORT=""; SMTPS_PORT=""
EXTRA=""; YES=0; JITTER_SET=0

HEDIOUM_REPO="hedioum/Hedioum-Pool-Tunnel"
XRAY_REPO="XTLS/Xray-core"

log()  { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --persona)        PERSONA="${2:?}"; MIMICS=""; shift 2;;
    --mimics)         MIMICS="${2:?}"; PERSONA=""; shift 2;;
    --domain)         DOMAIN="${2:?}"; shift 2;;
    --move-ssh)       MOVE_SSH=1; shift;;
    --jitter-restart) JITTER=1; JITTER_SET=1; shift;;
    --bundle-dir)     BUNDLE="${2:?}"; shift 2;;
    --listen-port)    LISTEN_PORT="${2:?}"; shift 2;;
    --decoy-port)     DECOY_PORT="${2:?}"; shift 2;;
    --tls-port)       TLS_PORT="${2:?}"; shift 2;;
    --smtp-port)      SMTP_PORT="${2:?}"; shift 2;;
    --imap-port)      IMAP_PORT="${2:?}"; shift 2;;
    --smtps-port)     SMTPS_PORT="${2:?}"; shift 2;;
    --extra)          EXTRA="${2:?}"; shift 2;;
    -y|--yes)         YES=1; shift;;
    -h|--help)        sed -n "2,27p" "$0"; exit 0;;
    *) die "unknown option: $1";;
  esac
done

[ "$(id -u)" -eq 0 ] || die "run as root"
command -v systemctl >/dev/null || die "systemd is required"

valid_port() { [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }
port_free()  { ! ss -tln "( sport = :$1 )" 2>/dev/null | tail -n +2 | grep -q .; }
ask()   { local var="$1" label="$2" cur="${!1}" ans; read -r -p "$label [${cur:-default}]: " ans || true; if [ -n "$ans" ]; then printf -v "$var" '%s' "$ans"; fi; return 0; }
yesno() { local ans; read -r -p "$1 [y/N]: " ans || true; [[ "$ans" =~ ^[Yy] ]]; }

if [ "$YES" -eq 0 ] && [ -t 0 ]; then
  echo "Interactive setup — press Enter to keep the value in [brackets]."
  ask MIMICS  "Camouflage endpoints (comma list; smtp is the proven one)"
  ask DOMAIN  "Domain for Let's Encrypt (blank = self-signed)"
  if yesno "Customize the public mimic ports?"; then
    echo "(blank = Hedioum default)"
    ask LISTEN_PORT "SSH-mimic port"
    ask DECOY_PORT  "Local decoy sshd port"
    ask TLS_PORT    "TLS mimic port"
    ask SMTP_PORT   "SMTP mimic port"
    ask IMAP_PORT   "IMAP mimic port"
    ask SMTPS_PORT  "SMTPS mimic port"
  fi
  if [ "$JITTER_SET" -eq 0 ] && yesno "Install the randomized-restart timer?"; then JITTER=1; fi
fi

for pv in LISTEN_PORT DECOY_PORT TLS_PORT SMTP_PORT IMAP_PORT SMTPS_PORT; do
  v="${!pv}"; [ -z "$v" ] && continue
  valid_port "$v" || die "$pv: '$v' is not a valid port (1-65535)"
  # the SSH-mimic port may legitimately be 22 only when --move-ssh frees it
  port_free "$v" || { [ "$pv" = LISTEN_PORT ] && [ "$MOVE_SSH" -eq 1 ]; } \
    || die "$pv: TCP port $v is already in use (ss -tlnp | grep :$v)"
done

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

SETUP_ARGS=(--public-ip "$PUBLIC_IP")
if [ -n "$MIMICS" ]; then SETUP_ARGS+=(--mimics "$MIMICS"); else SETUP_ARGS+=(--persona "${PERSONA:-auto}"); fi
[ -n "$DOMAIN" ]  && SETUP_ARGS+=(--domain "$DOMAIN")
[ "$MOVE_SSH" -eq 1 ] && SETUP_ARGS+=(--move-ssh)
[ -n "$LISTEN_PORT" ] && SETUP_ARGS+=(--listen-port "$LISTEN_PORT")
[ -n "$DECOY_PORT" ]  && SETUP_ARGS+=(--decoy-port "$DECOY_PORT")
[ -n "$TLS_PORT" ]    && SETUP_ARGS+=(--tls-port "$TLS_PORT")
[ -n "$SMTP_PORT" ]   && SETUP_ARGS+=(--smtp-port "$SMTP_PORT")
[ -n "$IMAP_PORT" ]   && SETUP_ARGS+=(--imap-port "$IMAP_PORT")
[ -n "$SMTPS_PORT" ]  && SETUP_ARGS+=(--smtps-port "$SMTPS_PORT")
if [ -n "$EXTRA" ]; then read -r -a EXTRA_ARR <<<"$EXTRA"; SETUP_ARGS+=("${EXTRA_ARR[@]}"); fi

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
