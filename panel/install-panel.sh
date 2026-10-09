#!/usr/bin/env bash
# install-panel.sh — install the 3x-ui (Sanaei) panel on the IRAN HUB and wire it to Hedioum.
#
# After it finishes you have:
#   - the web panel (random port, random secret path, random login — printed at the end)
#   - one ready Reality inbound whose users leave through your Hedioum tunnel
#   - the helper commands:  add-user.sh / list-users.sh / remove-user.sh  (in this folder)
#
# Usage (as root on the hub):
#   bash install-panel.sh                     # download 3x-ui from GitHub (needs access to GitHub)
#   bash install-panel.sh --tarball FILE      # OFFLINE: use a file you copied to the hub (see the guide)
#   bash install-panel.sh --configure-only    # the panel is already installed — only wire it to Hedioum
#
# Options:
#   --socks-port N     Hedioum's local SOCKS port on this hub (default 40001; see /etc/hedioum/hedioum.json)
#   --direct           TEST MODE: users leave directly instead of through Hedioum
#   --panel-port N     port of the web panel (default: random)
#   --panel-user NAME / --panel-pass PASS   login (default: random)
#   --reality-port N   port users connect to (default: random 20000-50000)
#   --sni NAME         camouflage site for Reality (default digikala.com — a site reachable from Iran)
#   --host IP          address that goes into the user links (default: this server's IP)
#   -h, --help
set -euo pipefail

TARBALL=""; CONF_ONLY=0; SOCKS=40001; DIRECT=0; PPORT=""; PUSER=""; PPASS=""; RPORT=""; SNI="digikala.com"; HOST=""
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
log()  { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --tarball)        TARBALL="${2:?}"; shift 2;;
    --configure-only) CONF_ONLY=1; shift;;
    --socks-port)     SOCKS="${2:?}"; shift 2;;
    --direct)         DIRECT=1; shift;;
    --panel-port)     PPORT="${2:?}"; shift 2;;
    --panel-user)     PUSER="${2:?}"; shift 2;;
    --panel-pass)     PPASS="${2:?}"; shift 2;;
    --reality-port)   RPORT="${2:?}"; shift 2;;
    --sni)            SNI="${2:?}"; shift 2;;
    --host)           HOST="${2:?}"; shift 2;;
    -h|--help)        sed -n '2,24p' "$0"; exit 0;;
    *) die "unknown option: $1";;
  esac
done

[ "$(id -u)" -eq 0 ] || die "run as root (type: sudo -i   and try again)"
command -v systemctl >/dev/null || die "this script needs systemd"
command -v python3 >/dev/null || { apt-get update -qq && apt-get install -y -qq python3 >/dev/null; }
[ -f "$HERE/panel_tool.py" ] || die "panel_tool.py must be in the same folder as this script"
chmod +x "$HERE"/*.sh "$HERE"/panel_tool.py 2>/dev/null || true
rnd() { python3 -c "import secrets,string;print(''.join(secrets.choice(string.ascii_lowercase+string.digits) for _ in range(int('$1'))))"; }

if [ "$CONF_ONLY" -eq 0 ]; then
  if [ -x /usr/local/x-ui/x-ui ]; then
    warn "3x-ui is already installed — skipping the download. (Use --configure-only to just wire it.)"
  else
    case "$(uname -m)" in x86_64|amd64) ARCH=amd64;; aarch64|arm64) ARCH=arm64;; *) die "unsupported CPU: $(uname -m)";; esac
    if [ -z "$TARBALL" ]; then
      log "Downloading 3x-ui from GitHub (20 s limit)"
      TARBALL=/tmp/x-ui-linux-$ARCH.tar.gz
      if ! curl -fL --connect-timeout 10 --max-time 120 -o "$TARBALL" "https://github.com/MHSanaei/3x-ui/releases/latest/download/x-ui-linux-$ARCH.tar.gz" 2>/dev/null; then
        rm -f "$TARBALL"
        cat >&2 <<EOF

[x] This server cannot reach GitHub (normal for Iran). Do the OFFLINE install instead:
    1) On a computer/server WITH internet, download this file:
       https://github.com/MHSanaei/3x-ui/releases/latest/download/x-ui-linux-$ARCH.tar.gz
    2) Copy it to this hub, e.g.:  scp x-ui-linux-$ARCH.tar.gz root@THIS_SERVER:/root/
    3) Run again:  bash install-panel.sh --tarball /root/x-ui-linux-$ARCH.tar.gz
EOF
        exit 1
      fi
    fi
    [ -r "$TARBALL" ] || die "cannot read $TARBALL"
    log "Installing 3x-ui from $TARBALL"
    rm -rf /usr/local/x-ui.new && mkdir -p /usr/local/x-ui.new
    tar xzf "$TARBALL" -C /usr/local/x-ui.new || die "the file is not a valid .tar.gz"
    SRC="$(find /usr/local/x-ui.new -maxdepth 2 -name x-ui -type f | head -1)"; [ -n "$SRC" ] || die "no 'x-ui' program inside the archive"
    mv "$(dirname "$SRC")" /usr/local/x-ui && rm -rf /usr/local/x-ui.new
    chmod +x /usr/local/x-ui/x-ui /usr/local/x-ui/bin/xray-linux-* 2>/dev/null || true
    [ -f /usr/local/x-ui/x-ui.sh ] && install -m 755 /usr/local/x-ui/x-ui.sh /usr/bin/x-ui
    SVC=/usr/local/x-ui/x-ui.service.debian; [ -f "$SVC" ] || SVC="$(ls /usr/local/x-ui/x-ui.service* | head -1)"
    install -m 644 "$SVC" /etc/systemd/system/x-ui.service
    mkdir -p /etc/x-ui
  fi

  PUSER="${PUSER:-admin-$(rnd 5)}"; PPASS="${PPASS:-$(rnd 14)}"; PPORT="${PPORT:-$((20000 + RANDOM % 30000))}"; BASEPATH="/$(rnd 16)/"
  log "Creating the panel database and login"
  /usr/local/x-ui/x-ui setting -username "$PUSER" -password "$PPASS" -port "$PPORT" -webBasePath "$BASEPATH" >/dev/null 2>&1 || die "x-ui setting failed"
  systemctl daemon-reload; systemctl enable --now x-ui >/dev/null 2>&1
  for i in $(seq 1 30); do [ -f /usr/local/x-ui/bin/config.json ] && systemctl is-active --quiet x-ui && break; sleep 1; done
  systemctl is-active --quiet x-ui || die "the panel did not start (journalctl -u x-ui -n 30)"
fi

log "Wiring the panel to Hedioum and creating the Reality inbound"
ARGS=(configure --sni "$SNI"); [ -n "$RPORT" ] && ARGS+=(--port "$RPORT"); [ -n "$HOST" ] && ARGS+=(--host "$HOST")
if [ "$DIRECT" -eq 1 ]; then ARGS+=(--direct); else ARGS+=(--socks-port "$SOCKS"); fi
python3 "$HERE/panel_tool.py" "${ARGS[@]}"

if [ "$CONF_ONLY" -eq 0 ]; then
  IP="${HOST:-$(ip -4 route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}')}"
  umask 077
  cat > /root/panel-credentials.txt <<EOF
Panel address : http://$IP:$PPORT$BASEPATH
Username      : $PUSER
Password      : $PPASS
EOF
  cat <<EOF

=================== DONE ===================
$(cat /root/panel-credentials.txt)
(also saved in /root/panel-credentials.txt — keep it private)

Create your first user:
  bash $HERE/add-user.sh myname --monthly 30
============================================
EOF
fi
