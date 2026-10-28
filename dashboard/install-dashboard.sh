#!/usr/bin/env bash
# install-dashboard.sh - install the hub's MONITOR and the web DASHBOARD (monitoring + users).
#
# Run it on the hub, from a copy of this project (files are taken from ../tools and ../panel):
#   sudo bash dashboard/install-dashboard.sh                      # local only: reach it through "ssh -L 8088:127.0.0.1:8088"
#   sudo bash dashboard/install-dashboard.sh --public --cert /etc/xray-tls/fullchain.pem --key /etc/xray-tls/privkey.pem
#   sudo bash dashboard/install-dashboard.sh --public --self-signed hub.example.com     # or an IP; browser will warn
#
# Options:
#   --port N            dashboard port                                    (default 8088)
#   --public            listen on 0.0.0.0 (reachable from the internet).  Default: 127.0.0.1 only.
#                       Public without TLS would send the password in clear text, so it needs --cert/--key or --self-signed.
#   --cert F --key F    serve HTTPS with this certificate (e.g. the one made by tools/enable-tls.sh)
#   --self-signed NAME  make a self-signed certificate for this DNS name or IP
#   --user NAME         login name (default: admin); the password is generated and shown ONCE
#   --reset-password    create a new password even if one already exists
#   --no-monitor        do not install/start the monitor (dashboard needs its log for the charts)
#   --with-vnstat       apt-get install vnstat (long-term traffic volume; needs the package mirror)
#   --no-start          install everything but do not start/enable services
#
# What it installs:  /opt/tunnel-dashboard/{dashboard.py,index.html,panel_tool.py,auth.json}
#                    /usr/local/bin/{hedioum-monitor.sh,reality-target-check.py}
#                    tunnel-dashboard.service, hedioum-monitor.service
# The "users" tabs need the 3x-ui panel wired to Hedioum (panel/install-panel.sh creates /etc/tunnel-panel.json).
# For testing only: ROOT=/some/dir installs under that prefix and never touches systemd.
set -u
die()  { echo "ERROR: $*" >&2; exit 1; }
warn() { echo "WARN:  $*" >&2; }

PORT=8088; PUBLIC=0; CERT=""; KEY=""; SELF=""; USERNAME=admin; RESET=0; NO_MON=0; VNSTAT=0; NO_START=0
while [ $# -gt 0 ]; do
  case "$1" in
    --port) PORT="${2:?}"; shift 2;;
    --public) PUBLIC=1; shift;;
    --cert) CERT="${2:?}"; shift 2;;
    --key) KEY="${2:?}"; shift 2;;
    --self-signed) SELF="${2:?}"; shift 2;;
    --user) USERNAME="${2:?}"; shift 2;;
    --reset-password) RESET=1; shift;;
    --no-monitor) NO_MON=1; shift;;
    --with-vnstat) VNSTAT=1; shift;;
    --no-start) NO_START=1; shift;;
    -h|--help) sed -n '2,26p' "$0"; exit 0;;
    *) die "unknown option: $1";;
  esac
done
[[ "$PORT" =~ ^[0-9]+$ ]] && [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] || die "bad --port"
[ -n "$CERT$KEY" ] && { [ -n "$CERT" ] && [ -n "$KEY" ] || die "--cert and --key go together"; }
[ -n "$CERT" ] && [ -n "$SELF" ] && die "use either --cert/--key or --self-signed"

R="${ROOT:-}"                                   # test prefix; empty in real use
[ -n "$R" ] || [ "$(id -u)" -eq 0 ] || die "run as root (sudo)"
[ -n "$R" ] && NO_START=1
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_PANEL="$HERE/../panel/panel_tool.py"; SRC_MON="$HERE/../tools/hedioum-monitor.sh"; SRC_RT="$HERE/../tools/reality-target-check.py"
for f in "$HERE/dashboard.py" "$HERE/index.html" "$SRC_PANEL" "$SRC_MON" "$SRC_RT"; do [ -f "$f" ] || die "missing $f (run this from a full copy of the project)"; done
command -v python3 >/dev/null || die "python3 is required"
BASE="$R/opt/tunnel-dashboard"; BIN="$R/usr/local/bin"; UNITS="$R/etc/systemd/system"

# ---- TLS / exposure decision (before writing anything)
TLS_CERT=""; TLS_KEY=""
if [ -n "$CERT" ]; then TLS_CERT="$CERT"; TLS_KEY="$KEY"; [ -f "$CERT" ] && [ -f "$KEY" ] || die "certificate or key file not found"
elif [ -n "$SELF" ]; then TLS_CERT="/opt/tunnel-dashboard/tls/cert.pem"; TLS_KEY="/opt/tunnel-dashboard/tls/key.pem"; fi
if [ "$PUBLIC" -eq 1 ] && [ -z "$TLS_CERT" ]; then
  die "--public needs HTTPS: add --cert/--key or --self-signed NAME (otherwise the login password travels in clear text)"
fi
BIND=127.0.0.1; [ "$PUBLIC" -eq 1 ] && BIND=0.0.0.0

# ---- files
echo "== 1) files"
install -d -m 700 "$BASE"            # only the dashboard's own folder is private; never chmod shared dirs
mkdir -p "$BIN" "$UNITS"
install -m 755 "$HERE/dashboard.py" "$BASE/dashboard.py"
install -m 644 "$HERE/index.html"   "$BASE/index.html"
install -m 755 "$SRC_PANEL"         "$BASE/panel_tool.py"
if [ "$NO_MON" -eq 0 ]; then
  [ -f "$BIN/hedioum-monitor.sh" ] && ! cmp -s "$SRC_MON" "$BIN/hedioum-monitor.sh" && cp -p "$BIN/hedioum-monitor.sh" "$BIN/hedioum-monitor.sh.bak-$(date +%s)"
  install -m 755 "$SRC_MON" "$BIN/hedioum-monitor.sh"
  install -m 755 "$SRC_RT"  "$BIN/reality-target-check.py"
fi
echo "installed into $BASE and $BIN"

if [ -n "$SELF" ]; then
  echo "== 2) self-signed certificate for $SELF"
  install -d -m 700 "$BASE/tls"
  if [[ "$SELF" =~ ^[0-9.]+$ ]]; then SAN="IP:$SELF"; else SAN="DNS:$SELF"; fi
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 825 -subj "/CN=$SELF" -addext "subjectAltName=$SAN" \
    -keyout "$BASE/tls/key.pem" -out "$BASE/tls/cert.pem" 2>/dev/null || die "could not create the certificate (is openssl installed?)"
  chmod 600 "$BASE/tls/key.pem"
fi

# ---- units
echo "== 3) systemd units"
{
  echo "[Unit]"; echo "Description=Tunnel dashboard (monitoring + users)"; echo "After=network.target"
  echo; echo "[Service]"; echo "ExecStart=/usr/bin/python3 /opt/tunnel-dashboard/dashboard.py"
  echo "Environment=DASH_BIND=$BIND"; echo "Environment=DASH_PORT=$PORT"
  [ -n "$TLS_CERT" ] && { echo "Environment=DASH_TLS_CERT=$TLS_CERT"; echo "Environment=DASH_TLS_KEY=$TLS_KEY"; }
  echo "Restart=always"; echo "RestartSec=3"; echo "User=root"
  echo; echo "[Install]"; echo "WantedBy=multi-user.target"
} > "$UNITS/tunnel-dashboard.service"
if [ "$NO_MON" -eq 0 ] && [ ! -f "$UNITS/hedioum-monitor.service" ]; then
  cat > "$UNITS/hedioum-monitor.service" <<'EOF'
[Unit]
Description=Hedioum tunnel monitor (one summary line per minute)
After=network-online.target hedioum.service

[Service]
ExecStart=/usr/local/bin/hedioum-monitor.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
fi
echo "units written to $UNITS"

# ---- login
echo "== 4) login"
PW=""
if [ ! -f "$BASE/auth.json" ] || [ "$RESET" -eq 1 ]; then
  PW="$(DASH_BASE="$BASE" python3 "$BASE/dashboard.py" --init-auth "$USERNAME" | sed -n 's/^password: //p')"
  [ -n "$PW" ] || die "could not create the login"
else
  echo "a login already exists (use --reset-password for a new one)"
fi

# ---- vnstat + start
if [ "$VNSTAT" -eq 1 ] && [ -z "$R" ]; then apt-get install -y vnstat >/dev/null 2>&1 && echo "vnstat installed" || warn "could not install vnstat"; fi
[ -f "$R/etc/tunnel-panel.json" ] || warn "no /etc/tunnel-panel.json: the users tabs need the panel wired first (panel/install-panel.sh)"
SCHEME=http; [ -n "$TLS_CERT" ] && SCHEME=https
if [ "$NO_START" -eq 1 ]; then
  echo "(not started: --no-start / test mode)"
else
  echo "== 5) start"
  systemctl daemon-reload
  [ "$NO_MON" -eq 0 ] && systemctl enable --now hedioum-monitor.service
  systemctl enable tunnel-dashboard.service; systemctl restart tunnel-dashboard.service; sleep 2
  systemctl is-active --quiet tunnel-dashboard || die "the dashboard did not start: journalctl -u tunnel-dashboard -n 30"
  code=$(curl -sk -o /dev/null -w '%{http_code}' "$SCHEME://127.0.0.1:$PORT/login"); echo "login page answers: HTTP $code"
fi

echo
echo "DONE."
[ -n "$PW" ] && { echo "  user:     $USERNAME"; echo "  password: $PW      <- shown once, store it now (change it later from the Settings tab)"; }
if [ "$PUBLIC" -eq 1 ]; then
  echo "  open:     $SCHEME://<name-or-ip>:$PORT/"
  [ -n "$SELF" ] && echo "            (self-signed certificate: the browser will warn once)"
  echo "  also allow TCP $PORT in the provider firewall, and keep the password long."
else
  echo "  open:     ssh -N -L $PORT:127.0.0.1:$PORT root@<hub>   then   $SCHEME://127.0.0.1:$PORT/"
fi
