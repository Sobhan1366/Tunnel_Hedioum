#!/usr/bin/env bash
# install-iran.sh — run on the IRAN (hub) server, as root.
#
# Pairs this server with the foreign node prepared by install-kharej.sh and
# exposes a VLESS+WebSocket entry point whose traffic leaves through Hedioum.
#
# Usage:
#   sudo bash install-iran.sh --bundle /root/iran-bundle [options]
#
# Options:
#   --bundle DIR        bundle copied from the foreign server (default: /root/iran-bundle)
#   --token TOKEN       pairing token (default: read from <bundle>/pairing.token)
#   --alias NAME        Hedioum node alias (default: KHAREJ)
#   --socks-port PORT   local Hedioum SOCKS5 port, loopback only (default: 40001)
#   --vless-port PORT   public VLESS+WS port (default: 2100)
#   --ws-path PATH      WebSocket path (default: /hed-ssh)
#   --uuid UUID         VLESS user id (default: generated)
#   --random-port       pick a random free port (20000-60000) for the VLESS entry
#   --jitter-restart    install a randomized-restart timer (anti-fingerprinting)
#   -y, --yes           never prompt; use flags/defaults only
#
# Run in a terminal without --yes and the script asks for every value
# (press Enter to accept the default).
#   -h, --help
set -euo pipefail

BUNDLE="/root/iran-bundle"; TOKEN=""; ALIAS="KHAREJ"
SOCKS_PORT=40001; VLESS_PORT=2100; WS_PATH="/hed-ssh"; UUID=""
JITTER=0; JITTER_SET=0; YES=0; RANDOM_PORT=0

log()  { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --bundle)         BUNDLE="${2:?}"; shift 2;;
    --token)          TOKEN="${2:?}"; shift 2;;
    --alias)          ALIAS="${2:?}"; shift 2;;
    --socks-port)     SOCKS_PORT="${2:?}"; shift 2;;
    --vless-port)     VLESS_PORT="${2:?}"; shift 2;;
    --ws-path)        WS_PATH="${2:?}"; shift 2;;
    --uuid)           UUID="${2:?}"; shift 2;;
    --random-port)    RANDOM_PORT=1; shift;;
    -y|--yes)         YES=1; shift;;
    --jitter-restart) JITTER=1; JITTER_SET=1; shift;;
    -h|--help)        sed -n "2,24p" "$0"; exit 0;;
    *) die "unknown option: $1";;
  esac
done

[ "$(id -u)" -eq 0 ] || die "run as root"
command -v systemctl >/dev/null || die "systemd is required"
[ -x "$BUNDLE/hedioum-tunnel" ] || die "missing $BUNDLE/hedioum-tunnel (copy the bundle from the foreign server)"
[ -x "$BUNDLE/xray" ]           || die "missing $BUNDLE/xray"
[ -n "$TOKEN" ] || { [ -r "$BUNDLE/pairing.token" ] && TOKEN="$(tr -d '[:space:]' < "$BUNDLE/pairing.token")"; }
[ -n "$TOKEN" ] || die "no pairing token: pass --token or provide $BUNDLE/pairing.token"

valid_port() { [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }
port_free()  { ! ss -tln "( sport = :$1 )" 2>/dev/null | tail -n +2 | grep -q .; }
ask()   { local var="$1" label="$2" cur="${!1}" ans; read -r -p "$label [${cur:-generate}]: " ans || true; if [ -n "$ans" ]; then printf -v "$var" '%s' "$ans"; fi; return 0; }
yesno() { local ans; read -r -p "$1 [y/N]: " ans || true; [[ "$ans" =~ ^[Yy] ]]; }
random_free_port() { local p; for _ in $(seq 1 50); do p=$((20000 + RANDOM % 40001)); port_free "$p" && { echo "$p"; return; }; done; die "no free random port found"; }

if [ "$YES" -eq 0 ] && [ -t 0 ]; then
  echo "Interactive setup — press Enter to keep the value in [brackets]."
  if [ "$RANDOM_PORT" -eq 0 ]; then
    ask VLESS_PORT "Public VLESS+WS port (type 'random' for a random free port)"
    [ "$VLESS_PORT" = random ] && RANDOM_PORT=1
  fi
  ask WS_PATH    "WebSocket path"
  ask SOCKS_PORT "Hedioum local SOCKS5 port (loopback only)"
  ask ALIAS      "Hedioum node alias"
  ask UUID       "VLESS UUID (blank = generate)"
  if [ "$JITTER_SET" -eq 0 ] && yesno "Install the randomized-restart timer?"; then JITTER=1; fi
fi

[ "$RANDOM_PORT" -eq 1 ] && VLESS_PORT="$(random_free_port)"
[ -n "$UUID" ] || UUID="$(cat /proc/sys/kernel/random/uuid)"
case "$WS_PATH" in /*) ;; *) WS_PATH="/$WS_PATH";; esac
valid_port "$VLESS_PORT" || die "VLESS port '$VLESS_PORT' is not valid (1-65535)"
valid_port "$SOCKS_PORT" || die "SOCKS port '$SOCKS_PORT' is not valid (1-65535)"
[ "$VLESS_PORT" != "$SOCKS_PORT" ] || die "VLESS port and SOCKS port must differ"
[[ "$UUID" =~ ^[0-9a-fA-F-]{36}$ ]] || die "UUID '$UUID' is not a valid UUID"
port_free "$VLESS_PORT" || die "TCP port $VLESS_PORT is already in use (ss -tlnp | grep :$VLESS_PORT) — choose another or use --random-port"
log "Using: VLESS :$VLESS_PORT  path $WS_PATH  SOCKS 127.0.0.1:$SOCKS_PORT  alias $ALIAS"

export DEBIAN_FRONTEND=noninteractive
apt-get install -y -qq iproute2 python3 >/dev/null 2>&1 || warn "apt prerequisites skipped (offline?)"

# ---------------------------------------------------------------- Hedioum
if [ ! -x /usr/local/bin/hedioum-tunnel ]; then
  log "Installing Hedioum from bundle"
  "$BUNDLE/hedioum-tunnel" install
fi
log "Pairing with the foreign node (alias $ALIAS)"
/usr/local/bin/hedioum-tunnel setup-iran --alias "$ALIAS" --token "$TOKEN" --socks-port "$SOCKS_PORT"
systemctl enable --now hedioum.service
systemctl restart hedioum.service

log "Waiting for the local SOCKS5 on 127.0.0.1:$SOCKS_PORT"
for i in $(seq 1 30); do
  ss -tln "( sport = :$SOCKS_PORT )" | tail -n +2 | grep -q . && break
  sleep 1
  [ "$i" -eq 30 ] && die "Hedioum SOCKS5 did not come up — see: journalctl -u hedioum -n 50"
done

# ------------------------------------------------------------------- Xray
log "Installing Xray VLESS+WS on :$VLESS_PORT (outbound -> Hedioum SOCKS5)"
install -m 0755 "$BUNDLE/xray" /usr/local/bin/xray
mkdir -p /usr/local/etc/xray
for f in geoip.dat geosite.dat; do [ -f "$BUNDLE/$f" ] && cp -f "$BUNDLE/$f" /usr/local/bin/; done
[ -f /usr/local/etc/xray/config.json ] && cp -a /usr/local/etc/xray/config.json "/usr/local/etc/xray/config.json.bak-$(date +%s)"
cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [{
    "listen": "0.0.0.0",
    "port": $VLESS_PORT,
    "protocol": "vless",
    "settings": { "clients": [{ "id": "$UUID", "level": 0 }], "decryption": "none" },
    "streamSettings": { "network": "ws", "wsSettings": { "path": "$WS_PATH" } }
  }],
  "outbounds": [{
    "tag": "hedioum-out",
    "protocol": "socks",
    "settings": { "servers": [{ "address": "127.0.0.1", "port": $SOCKS_PORT }] }
  }]
}
EOF
chmod 600 /usr/local/etc/xray/config.json
cat > /etc/systemd/system/xray-iran.service <<'EOF'
[Unit]
Description=Xray VLESS entry server on Iran
After=network.target hedioum.service
Requires=hedioum.service

[Service]
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/config.json
Restart=always
RestartSec=3
User=root

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now xray-iran.service

# ----------------------------------------------------- randomized restarts
if [ "$JITTER" -eq 1 ]; then
  log "Installing randomized-restart timer"
  cat > /usr/local/sbin/tunnel-jitter-restart.sh <<'EOF'
#!/bin/bash
set -e
sleep $((RANDOM % 900))
systemctl restart hedioum.service
sleep 3
systemctl restart xray-iran.service
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
  systemctl restart tunnel-jitter-restart.timer
fi

# ------------------------------------------------------------------ report
IRAN_IP="$(ip -4 route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}')"
ENC_PATH="${WS_PATH//\//%2F}"
log "Done. Service state:"
systemctl is-active hedioum.service xray-iran.service
cat <<EOF

VLESS link (import into v2rayN / similar):
  vless://$UUID@$IRAN_IP:$VLESS_PORT?encryption=none&security=none&type=ws&path=$ENC_PATH#Hedioum-Tunnel

EOF
echo "Remember to delete the bundle once done: rm -rf $BUNDLE (it holds the pairing token and keys)"
