#!/bin/bash
# Add TLS (wss) NEXT TO the plain VLESS+WebSocket inbound(s) of the hub's xray.
#
# ADDITIVE on purpose: every plain WebSocket inbound is cloned (same users, same path, same routing) onto a
# new TLS port; the plain ports keep working, so no existing link breaks. A port is either plain or TLS -
# it cannot be both - which is why the TLS copy lives on another port (443 first: it looks like normal HTTPS).
#
# usage:  bash enable-tls.sh --domain hub.example.com [options]
#   --domain D         a DNS name whose A record points at THIS server and is "DNS only"
#                      (NOT proxied by a CDN - a proxy only forwards a few web ports, not ours)
#   --ports LIST       TLS ports for the clones, in inbound order            (default: 443,8443)
#   --config FILE      xray config                                           (default: /usr/local/etc/xray/config.json)
#   --service NAME     systemd unit to restart                               (default: xray-iran)
#   --cert F --key F   use an existing certificate instead of asking Let's Encrypt via acme.sh
#   --with-dashboard   also use the certificate for /opt/tunnel-dashboard (HTTPS without a browser warning)
#   --set-panel-host   write the domain into /etc/tunnel-panel.json ("host" of the links the panel creates)
#   --no-restart       patch the config but do not restart the service (testing)
#   --dry-run          show the plan and test the resulting config, change nothing
#
# Needs: root, python3, the xray binary (/usr/local/bin/xray), and for a new certificate acme.sh
#        (https://get.acme.sh) with port 80 free and reachable from the internet (HTTP-01 challenge).
# Re-running is safe: inbounds that already have a "-tls" clone are skipped.
set -u

DOMAIN=""; PORTS="443,8443"; CONFIG=/usr/local/etc/xray/config.json; SERVICE=xray-iran
CERT=""; KEY=""; WITH_DASH=0; SET_HOST=0; NO_RESTART=0; DRY=0
XRAY=${XRAY:-/usr/local/bin/xray}
TLSDIR=${TLSDIR:-/etc/xray-tls}
HOOK=${HOOK:-/usr/local/bin/xray-tls-reload.sh}
ACME=${ACME:-$HOME/.acme.sh/acme.sh}
die()  { echo "ERROR: $*" >&2; exit 1; }
warn() { echo "WARN:  $*" >&2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --domain) DOMAIN="${2:?}"; shift 2;;
    --ports) PORTS="${2:?}"; shift 2;;
    --config) CONFIG="${2:?}"; shift 2;;
    --service) SERVICE="${2:?}"; shift 2;;
    --cert) CERT="${2:?}"; shift 2;;
    --key) KEY="${2:?}"; shift 2;;
    --with-dashboard) WITH_DASH=1; shift;;
    --set-panel-host) SET_HOST=1; shift;;
    --no-restart) NO_RESTART=1; shift;;
    --dry-run) DRY=1; shift;;
    -h|--help) sed -n '2,24p' "$0"; exit 0;;
    *) die "unknown option: $1";;
  esac
done
[ -n "$DOMAIN" ] || die "--domain is required (see --help)"
[ -n "$CERT$KEY" ] && { [ -n "$CERT" ] && [ -n "$KEY" ] || die "--cert and --key go together"; }
[ -f "$CONFIG" ] || die "xray config not found: $CONFIG"
[ -x "$XRAY" ]   || die "xray binary not found: $XRAY"
command -v python3 >/dev/null || die "python3 is required"
[ "$DRY" -eq 1 ] || [ "$(id -u)" -eq 0 ] || die "run as root (or use --dry-run)"
TS=$(date +%Y%m%d-%H%M%S)

port_busy() { ss -ltn 2>/dev/null | awk '{print $4}' | grep -q ":$1\$"; }

# ------------------------------------------------------------------ 1) plan
echo "== 1) plan"
PLAN=$(python3 - "$CONFIG" "$PORTS" <<'PY'
import json, sys
cfg, ports = sys.argv[1], [int(p) for p in sys.argv[2].split(",") if p.strip()]
c = json.load(open(cfg))
tags = {i.get("tag") for i in c["inbounds"]}
todo = []
for i in c["inbounds"]:
    ss = i.get("streamSettings") or {}
    plain_ws = ss.get("network") == "ws" and ss.get("security", "none") in ("none", "")
    if not plain_ws or i.get("protocol") not in ("vless", "vmess", "trojan"):
        continue
    tag = i.get("tag") or "ws-%s" % i["port"]
    if tag + "-tls" in tags:
        print("SKIP %s (already has %s-tls)" % (tag, tag)); continue
    todo.append((tag, i["port"], ss.get("wsSettings", {}).get("path", "/")))
if len(todo) > len(ports):
    print("ERROR need %d TLS ports for %d inbounds, only %d given in --ports" % (len(todo), len(todo), len(ports)))
    sys.exit(2)
for (tag, port, path), p in zip(todo, ports):
    print("ADD  %s-tls  tls:%d  <- clone of plain %s:%d  path %s" % (tag, p, tag, port, path))
if not todo:
    print("NOTHING to do")
PY
)
RC=$?
echo "$PLAN"
[ $RC -eq 0 ] || exit 1
echo "$PLAN" | grep -q '^NOTHING' && { echo "(all plain WebSocket inbounds already have a TLS copy)"; exit 0; }
NEWPORTS=$(echo "$PLAN" | awk '/^ADD/{print $3}' | sed 's/tls://')
for p in $NEWPORTS; do
  if port_busy "$p"; then
    [ "$DRY" -eq 1 ] && warn "port $p is busy now (fine for a dry run)" || die "port $p is already in use - choose other ports with --ports"
  fi
done

# ------------------------------------------------------------------ 2) certificate
if [ -z "$CERT" ]; then
  CERT=$TLSDIR/fullchain.pem; KEY=$TLSDIR/privkey.pem
  echo "== 2) certificate for $DOMAIN (Let's Encrypt, HTTP-01 on port 80)"
  if [ "$DRY" -eq 1 ]; then
    [ -f "$CERT" ] && echo "(dry run) certificate files already in $TLSDIR" || echo "(dry run) would request a certificate with acme.sh"
  else
    [ -x "$ACME" ] || die "acme.sh not found at $ACME. Install it (curl https://get.acme.sh | sh) or pass --cert/--key"
    if ! getent ahostsv4 "$DOMAIN" | awk '{print $1}' | grep -qxFf <(ip -4 -o addr show | awk '{print $4}' | cut -d/ -f1); then
      warn "$DOMAIN does not resolve to an address of this machine (CDN proxy? wrong record? NAT?) - validation may fail"
    fi
    if ! "$ACME" --list 2>/dev/null | grep -qF "$DOMAIN"; then
      port_busy 80 && die "port 80 is in use - acme.sh needs it for the challenge"
      "$ACME" --issue -d "$DOMAIN" --standalone --httpport 80 --server letsencrypt --keylength ec-256 2>&1 | tail -8
      "$ACME" --list 2>/dev/null | grep -qF "$DOMAIN" || die "certificate was not issued - nothing was changed"
    else
      echo "certificate for $DOMAIN already issued"
    fi
    mkdir -p "$TLSDIR" && chmod 755 "$TLSDIR"
    # hook acme.sh runs after every issue/renewal; it only acts once armed (after the config is live)
    cat > "$HOOK" <<EOF
#!/bin/bash
[ -f $TLSDIR/.armed ] || exit 0
systemctl restart $SERVICE
[ -f /etc/systemd/system/tunnel-dashboard.service ] && systemctl restart tunnel-dashboard
exit 0
EOF
    chmod 755 "$HOOK"
    "$ACME" --install-cert -d "$DOMAIN" --ecc --fullchain-file "$CERT" --key-file "$KEY" \
            --reloadcmd "$HOOK" 2>&1 | grep -E "Installing|ERROR|error" | head -4
    chmod 600 "$KEY"
  fi
else
  echo "== 2) using the given certificate: $CERT"
  [ "$DRY" -eq 1 ] || { [ -f "$CERT" ] && [ -f "$KEY" ] || die "certificate or key file not found"; }
fi
if [ -f "$CERT" ] && [ -f "$KEY" ]; then
  # `xray -test` does not read the certificate, so check it here: valid, matching key, not about to expire
  openssl x509 -in "$CERT" -noout 2>/dev/null || die "not a valid certificate: $CERT - nothing was changed"
  openssl pkey -in "$KEY" -noout 2>/dev/null  || die "not a valid private key: $KEY - nothing was changed"
  [ "$(openssl x509 -in "$CERT" -noout -pubkey | openssl md5)" = "$(openssl pkey -in "$KEY" -pubout | openssl md5)" ] \
    || die "certificate and private key do not match - nothing was changed"
  openssl x509 -in "$CERT" -noout -checkend 86400 >/dev/null || die "certificate is expired or expires within a day - nothing was changed"
  openssl x509 -in "$CERT" -noout -subject -enddate
fi

# ------------------------------------------------------------------ 3) patch the config
echo "== 3) xray config"
NEW=$(mktemp --suffix=.json); trap 'rm -f "$NEW"' EXIT
python3 - "$CONFIG" "$NEW" "$DOMAIN" "$CERT" "$KEY" "$PORTS" <<'PY' || die "could not build the new config - nothing was changed"
import copy, json, sys
cfg, out, dom, cert, key, ports = sys.argv[1:6] + [[int(p) for p in sys.argv[6].split(",") if p.strip()]]
c = json.load(open(cfg))
tags = {i.get("tag") for i in c["inbounds"]}
todo = []
for i in c["inbounds"]:
    ss = i.get("streamSettings") or {}
    if ss.get("network") == "ws" and ss.get("security", "none") in ("none", "") and i.get("protocol") in ("vless", "vmess", "trojan"):
        tag = i.get("tag") or "ws-%s" % i["port"]
        if tag + "-tls" not in tags:
            todo.append((i, tag))
for (src, tag), port in zip(todo, ports):
    n = copy.deepcopy(src)
    n["tag"], n["port"] = tag + "-tls", port
    n["streamSettings"] = {"network": "ws", "security": "tls", "wsSettings": src["streamSettings"].get("wsSettings", {}),
                           "tlsSettings": {"serverName": dom, "alpn": ["http/1.1"], "minVersion": "1.2",
                                           "certificates": [{"certificateFile": cert, "keyFile": key}]}}
    c["inbounds"].append(n)
    for r in c.get("routing", {}).get("rules", []):      # keep per-inbound routing identical for the clone
        if tag in r.get("inboundTag", []) and tag + "-tls" not in r["inboundTag"]:
            r["inboundTag"].append(tag + "-tls")
json.dump(c, open(out, "w"), indent=2)
print("inbounds after:", [(i.get("tag"), i["port"], (i.get("streamSettings") or {}).get("security", "none")) for i in c["inbounds"]])
PY
if [ -f "$CERT" ] && [ -f "$KEY" ]; then
  "$XRAY" run -test -c "$NEW" >/tmp/xray-tls-test.log 2>&1 && echo "xray config test: OK" || { cat /tmp/xray-tls-test.log | tail -5; die "xray rejected the new config - nothing was changed"; }
else
  echo "(certificate files do not exist yet - config test skipped)"
fi
[ "$DRY" -eq 1 ] && { echo "DRY RUN: nothing was changed."; exit 0; }

BK="$CONFIG.bak-tls-$TS"; cp -p "$CONFIG" "$BK"
cat "$NEW" > "$CONFIG"; echo "config updated (backup: $BK)"

# ------------------------------------------------------------------ 4) restart + verify
if [ "$NO_RESTART" -eq 1 ]; then echo "--no-restart: service not restarted."; exit 0; fi
echo "== 4) restart $SERVICE and verify"
systemctl restart "$SERVICE"; sleep 3
FAIL=0
systemctl is-active --quiet "$SERVICE" || FAIL=1
for p in $NEWPORTS; do
  port_busy "$p" || { echo "port $p is NOT listening"; FAIL=1; continue; }
  r=$(echo | timeout 8 openssl s_client -connect 127.0.0.1:"$p" -servername "$DOMAIN" 2>&1 | grep -E "Verification" | head -1)
  echo "port $p -> ${r:-no TLS answer}"
  echo "$r" | grep -q "OK" || FAIL=1
done
if [ $FAIL -ne 0 ]; then
  echo "VERIFICATION FAILED -> restoring the previous config"
  cp -p "$BK" "$CONFIG"; systemctl restart "$SERVICE"; exit 1
fi
touch "$TLSDIR/.armed"        # from now on certificate renewals restart the services

# ------------------------------------------------------------------ 5) optional extras
if [ "$WITH_DASH" -eq 1 ] && [ -d /opt/tunnel-dashboard/tls ]; then
  ( cd /opt/tunnel-dashboard/tls
    [ -L cert.pem ] || mv cert.pem "cert.pem.selfsigned-$TS" 2>/dev/null
    [ -L key.pem ]  || mv key.pem  "key.pem.selfsigned-$TS" 2>/dev/null
    ln -sf "$CERT" cert.pem; ln -sf "$KEY" key.pem )
  systemctl restart tunnel-dashboard 2>/dev/null && echo "dashboard now uses the certificate"
fi
if [ "$SET_HOST" -eq 1 ] && [ -f /etc/tunnel-panel.json ]; then
  python3 - "$DOMAIN" <<'PY'
import json, sys
p = "/etc/tunnel-panel.json"; c = json.load(open(p)); c["host"] = sys.argv[1]
json.dump(c, open(p, "w"), indent=2); print("panel link host ->", c["host"])
PY
fi

# ------------------------------------------------------------------ 6) client links
echo "== 6) client links (same users as the plain ports; paste into the client app)"
python3 - "$CONFIG" "$DOMAIN" <<'PY'
import json, sys, urllib.parse as u
c = json.load(open(sys.argv[1])); dom = sys.argv[2]
for i in c["inbounds"]:
    ss = i.get("streamSettings") or {}
    if ss.get("security") == "tls" and ss.get("network") == "ws" and (i.get("tag") or "").endswith("-tls"):
        path = ss["wsSettings"].get("path", "/")
        for cl in i.get("settings", {}).get("clients", []):
            print("vless://%s@%s:%d?encryption=none&security=tls&sni=%s&fp=chrome&alpn=http%%2F1.1&type=ws&path=%s#%s"
                  % (cl["id"], dom, i["port"], dom, u.quote(path, safe=""), i["tag"]))
PY
echo "DONE. Plain ports are unchanged. Keep the secrets above private."
