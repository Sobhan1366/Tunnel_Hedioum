#!/usr/bin/env bash
# check-foreign.sh — is this foreign server usable for a Hedioum tunnel from THIS Iran hub?
#
# Run it ON THE IRAN HUB (as root). It needs SSH key access from the hub to the
# candidate server. It never touches the hub's tunnel configuration in the default
# mode, so live users are not disturbed.
#
# What it does (quick mode, default):
#   1. path check from the hub: ping loss/latency, TCP connect success
#   2. starts a throw-away SMTP+STARTTLS+TLS test server on the candidate (the same
#      on-wire pattern Hedioum's `smtp` mimic uses), on a standard mail port
#   3. from the hub, opens N full sessions: banner -> EHLO -> STARTTLS -> TLS (with SNI)
#      -> download 1 MB, then one big download, parallel downloads, and an upload
#   4. prints a verdict: GOOD / MARGINAL / BAD, and where a transfer stalled
#   5. removes everything it created on the candidate
#
# Why not a plain TCP test? Because such a test failed on servers that Hedioum
# works fine on, and passed on servers where it did not. Only TLS-looking traffic
# on a mail port predicts the real result. Quick mode is still a heuristic: use
# --full for the final word (it attaches the candidate as a real Hedioum node, which
# restarts hedioum on the hub twice, ~20 s each).
#
# Usage:
#   sudo bash check-foreign.sh CANDIDATE_IP --key /root/.ssh/id_ed25519 [options]
#
# Options:
#   --key FILE        SSH private key (on the hub) that logs into the candidate (required)
#   --user NAME       SSH user on the candidate (default: root)
#   --ssh-port N      SSH port of the candidate (default: 22)
#   --port N          port for the test server (default: 587; must be free on the candidate)
#   --sni NAME        TLS server name the client sends (default: www.google.com)
#   --sessions N      number of 1 MB sessions (default: 12)
#   --size-mb N       size of the big download in MB (default: 20)
#   --full            also run the real Hedioum node test (needs --installer, restarts hedioum)
#   --installer FILE  path to install-kharej.sh on the hub (for --full)
#   --keep            with --full: keep the candidate configured as a Hedioum foreign
#   -h, --help
#
# Exit code: 0 = GOOD, 1 = MARGINAL, 2 = BAD, 3 = could not test.
set -uo pipefail

CAND=""; KEY=""; SUSER="root"; SSHP=22; PORT=587; SNI="www.google.com"; NS=12; BIGMB=20
FULL=0; INSTALLER=""; KEEP=0
log()  { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 3; }

while [ $# -gt 0 ]; do
  case "$1" in
    --key)       KEY="${2:?}"; shift 2;;
    --user)      SUSER="${2:?}"; shift 2;;
    --ssh-port)  SSHP="${2:?}"; shift 2;;
    --port)      PORT="${2:?}"; shift 2;;
    --sni)       SNI="${2:?}"; shift 2;;
    --sessions)  NS="${2:?}"; shift 2;;
    --size-mb)   BIGMB="${2:?}"; shift 2;;
    --full)      FULL=1; shift;;
    --installer) INSTALLER="${2:?}"; shift 2;;
    --keep)      KEEP=1; shift;;
    -h|--help)   sed -n '2,45p' "$0"; exit 0;;
    -*)          die "unknown option: $1";;
    *)           CAND="$1"; shift;;
  esac
done

[ "$(id -u)" -eq 0 ] || die "run as root"
[[ "$CAND" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "give the candidate's IPv4 address as the first argument"
[ -r "$KEY" ] || die "--key FILE is required and must be readable"
command -v python3 >/dev/null || die "python3 is required on the hub"
[ "$FULL" -eq 1 ] && { [ -r "$INSTALLER" ] || die "--full needs --installer /path/to/install-kharej.sh"; command -v hedioum-tunnel >/dev/null || die "hedioum-tunnel not found on this machine (is this the hub?)"; }

SSH=(ssh -i "$KEY" -p "$SSHP" -o BatchMode=yes -o ConnectTimeout=20 -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=10 "$SUSER@$CAND")
TAG="hchk$$"; REMOTE_DIR="/tmp/$TAG"
VERDICT=3

cleanup_remote() { "${SSH[@]}" "kill \$(cat $REMOTE_DIR/pid 2>/dev/null) 2>/dev/null; rm -rf $REMOTE_DIR" >/dev/null 2>&1 || true; }
trap cleanup_remote EXIT

# ---------------------------------------------------------------- 1. path
echo "== 1/4 path from this hub to $CAND"
PING_OUT="$(ping -c 20 -i 0.2 -W 2 "$CAND" 2>&1 | tail -2)"
LOSS="$(echo "$PING_OUT" | grep -oE '[0-9.]+% packet loss' | head -1)"; RTT="$(echo "$PING_OUT" | grep -oE 'rtt .*' | head -1)"
echo "   ping: ${LOSS:-no answer}  ${RTT}"
TCPOK=0; for i in $(seq 1 20); do timeout 4 bash -c "echo > /dev/tcp/$CAND/$SSHP" 2>/dev/null && TCPOK=$((TCPOK+1)); sleep 0.1; done
echo "   TCP connects to port $SSHP: $TCPOK/20"
[ "$TCPOK" -ge 1 ] || die "the candidate does not answer on TCP $SSHP from this hub"

# ------------------------------------------------------------ 2. test server
echo "== 2/4 starting a throw-away SMTP+STARTTLS+TLS test server on $CAND:$PORT"
"${SSH[@]}" "true" 2>/dev/null || die "cannot SSH to $SUSER@$CAND:$SSHP with that key (that alone is a bad sign if it worked from elsewhere)"
BUSY="$("${SSH[@]}" "ss -tln | awk '{print \$4}' | grep -cE ':$PORT\$'")"
[ "${BUSY:-0}" = "0" ] || die "port $PORT is already used on the candidate — pass another one with --port (465, 25, 2525 ...)"
"${SSH[@]}" "mkdir -p $REMOTE_DIR && cat > $REMOTE_DIR/srv.py" <<'PYSRV' || die "could not copy the test server"
import os, socket, ssl, sys, threading, time
port = int(sys.argv[1]); d = sys.argv[2]
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); ctx.load_cert_chain(d + "/c.pem", d + "/k.pem")
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(("0.0.0.0", port)); s.listen(64)
end = time.time() + 900  # self-destruct after 15 minutes
BLOCK = os.urandom(1 << 16)
def line(c):
    b = b""
    while not b.endswith(b"\n"):
        x = c.recv(1)
        if not x: raise EOFError
        b += x
    return b.strip()
def handle(c):
    try:
        c.settimeout(30); c.sendall(b"220 mail ESMTP\r\n")
        line(c); c.sendall(b"250-mail\r\n250-STARTTLS\r\n250 OK\r\n")
        line(c); c.sendall(b"220 2.0.0 Ready to start TLS\r\n")
        t = ctx.wrap_socket(c, server_side=True)
        cmd = line(t).split()
        if cmd[0] == b"GET":
            n = int(cmd[1])
            while n > 0:
                k = min(n, len(BLOCK)); t.sendall(BLOCK[:k]); n -= k
        elif cmd[0] == b"PUT":
            n = int(cmd[1]); got = 0
            while got < n:
                x = t.recv(1 << 16)
                if not x: break
                got += len(x)
            t.sendall(b"OK %d\n" % got)
        t.close()
    except Exception:
        try: c.close()
        except Exception: pass
s.settimeout(1)
while time.time() < end:
    try: c, _ = s.accept()
    except socket.timeout: continue
    threading.Thread(target=handle, args=(c,), daemon=True).start()
PYSRV
"${SSH[@]}" "cd $REMOTE_DIR && openssl req -x509 -newkey rsa:2048 -nodes -keyout k.pem -out c.pem -days 1 -subj '/CN=mail' >/dev/null 2>&1 && (nohup python3 srv.py $PORT $REMOTE_DIR >/dev/null 2>&1 & echo \$! > pid) ; sleep 2; ss -tln | grep -c ':$PORT ' " | grep -q '^1' || die "the test server did not start on the candidate (python3/openssl missing?)"
log "test server is up"

# --------------------------------------------------------------- 3. client
echo "== 3/4 running the tests from this hub"
RESULT="$(CAND="$CAND" PORT="$PORT" SNI="$SNI" NS="$NS" BIGMB="$BIGMB" python3 - <<'PYCLI'
import os, socket, ssl, threading, time, json
cand, port, sni, ns, bigmb = os.environ["CAND"], int(os.environ["PORT"]), os.environ["SNI"], int(os.environ["NS"]), int(os.environ["BIGMB"])
ctx = ssl.create_default_context(); ctx.check_hostname = False; ctx.verify_mode = ssl.CERT_NONE
def rl(s):
    b = b""
    while not b.endswith(b"\n"):
        x = s.recv(1)
        if not x: raise EOFError
        b += x
    return b
def session(cmd, nbytes, timeout=25):
    """one full SMTP->STARTTLS->TLS session; returns (ok, bytes, seconds, error)"""
    t0 = time.time(); got = 0
    try:
        s = socket.create_connection((cand, port), timeout=10); s.settimeout(timeout)
        rl(s); s.sendall(b"EHLO test.example\r\n")
        while True:
            l = rl(s)
            if l.startswith(b"250 "): break
        s.sendall(b"STARTTLS\r\n"); rl(s)
        t = ctx.wrap_socket(s, server_hostname=sni)
        if cmd == "GET":
            t.sendall(b"GET %d\n" % nbytes)
            while got < nbytes:
                x = t.recv(1 << 16)
                if not x: break
                got += len(x)
            ok = got >= nbytes
        else:
            t.sendall(b"PUT %d\n" % nbytes)
            blk = b"x" * (1 << 16); sent = 0
            while sent < nbytes:
                k = min(len(blk), nbytes - sent); t.sendall(blk[:k]); sent += k
            r = rl(t); got = int(r.split()[1]); ok = got >= nbytes
        return ok, got, time.time() - t0, ""
    except Exception as e:
        return False, got, time.time() - t0, type(e).__name__
out = {"sessions": [], "stall_bytes": []}
for i in range(ns):
    ok, got, dt, err = session("GET", 1_000_000, 20)
    out["sessions"].append((ok, got, round(dt, 2), err))
    if not ok: out["stall_bytes"].append(got)
    time.sleep(0.3)
ok, got, dt, err = session("GET", bigmb * 1_000_000, 90)
out["big"] = (ok, got, round(dt, 2), err)
if not ok: out["stall_bytes"].append(got)
res = []
def worker():
    res.append(session("GET", 5_000_000, 60))
th = [threading.Thread(target=worker) for _ in range(4)]; t0 = time.time()
[x.start() for x in th]; [x.join() for x in th]; dtp = time.time() - t0
out["par"] = (sum(1 for r in res if r[0]), sum(r[1] for r in res), round(dtp, 2))
for r in res:
    if not r[0]: out["stall_bytes"].append(r[1])
out["up"] = session("PUT", 5_000_000, 60)
print(json.dumps(out))
PYCLI
)"
[ -n "$RESULT" ] || die "the client produced no result"

# --------------------------------------------------------------- 4. verdict
echo "== 4/4 results"
export RESULT_JSON="$RESULT" NS
python3 - <<'PYV'
import json, os, sys
r = json.loads(os.environ["RESULT_JSON"]); ns = int(os.environ["NS"])
ok = sum(1 for s in r["sessions"] if s[0]); times = [s[2] for s in r["sessions"] if s[0]]
big = r["big"]; bigmbps = big[1] * 8 / 1e6 / big[2] if big[2] > 0 else 0
parok, parbytes, pardt = r["par"]; parmbps = parbytes * 8 / 1e6 / pardt if pardt > 0 else 0
up = r["up"]; upmbps = up[1] * 8 / 1e6 / up[2] if up[2] > 0 else 0
print("   1 MB sessions complete : %d/%d   (median %.2f s)" % (ok, ns, sorted(times)[len(times) // 2] if times else 0))
print("   big download           : %s  %.1f MB in %.1f s = %.1f Mbps %s" % ("OK " if big[0] else "FAIL", big[1] / 1e6, big[2], bigmbps, ("(%s)" % big[3]) if big[3] else ""))
print("   4 parallel x 5 MB      : %d/4 complete, %.1f Mbps total" % (parok, parmbps))
print("   upload 5 MB            : %s  %.1f Mbps %s" % ("OK " if up[0] else "FAIL", upmbps, ("(%s)" % up[3]) if up[3] else ""))
st = sorted(set(r["stall_bytes"]))
if st: print("   transfers that stalled stopped after (bytes): %s" % st[:6])
if any(10000 < b < 30000 for b in st):
    print("   NOTE: a stall near 16 KB is the signature of a path that throttles/blackholes new destinations — this server will NOT work well.")
good = ok >= max(1, int(0.9 * ns + 0.999)) and big[0] and parok == 4 and up[0] and bigmbps >= 8
marg = ok >= int(0.6 * ns) and (big[0] or parok >= 2)
verdict = "GOOD" if good else ("MARGINAL" if marg else "BAD")
print("\n   VERDICT: %s" % verdict)
sys.exit({"GOOD": 0, "MARGINAL": 1, "BAD": 2}[verdict])
PYV
VERDICT=$?
cleanup_remote; trap - EXIT
log "test server removed from the candidate"

# ----------------------------------------------------------------- --full
if [ "$FULL" -eq 1 ]; then
  echo
  echo "== FULL: attaching $CAND as a real Hedioum node (hedioum will restart on this hub twice)"
  ALIAS="CHK$RANDOM"; SPORT=$((40100 + RANDOM % 200)); BK="/root/hedioum.json.before-$ALIAS"
  cp -a /etc/hedioum/hedioum.json "$BK" || die "cannot back up /etc/hedioum/hedioum.json"
  scp -q -i "$KEY" -P "$SSHP" -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$INSTALLER" "$SUSER@$CAND:/root/install-kharej.sh" || die "cannot copy the installer"
  "${SSH[@]}" "bash /root/install-kharej.sh -y --mimics smtp >/tmp/install-kharej.log 2>&1; test -s /root/iran-bundle/pairing.token" || die "installer failed on the candidate (see /tmp/install-kharej.log there)"
  "${SSH[@]}" "cat /root/iran-bundle/pairing.token" | { umask 077; cat > "/root/$ALIAS.token"; }
  hedioum-tunnel add-node --alias "$ALIAS" --token "$(cat /root/$ALIAS.token)" --socks-port "$SPORT" >/dev/null 2>&1 || die "add-node failed"
  hedioum-tunnel edit-node --alias "$ALIAS" --mimics smtp >/dev/null 2>&1 || true
  systemctl restart hedioum.service; sleep 25
  ok=0; for i in $(seq 1 12); do r="$(curl -s -o /dev/null --max-time 20 -w '%{size_download}' --socks5-hostname 127.0.0.1:$SPORT http://speedtest.tele2.net/1MB.zip)"; [ "${r:-0}" -ge 1048576 ] && ok=$((ok+1)); done
  big="$(curl -s -o /dev/null --max-time 90 -w '%{size_download} %{time_total}' --socks5-hostname 127.0.0.1:$SPORT http://speedtest.tele2.net/10MB.zip)"
  exitip="$(curl -s --max-time 20 --socks5-hostname 127.0.0.1:$SPORT http://checkip.amazonaws.com)"
  echo "   real Hedioum node: 1 MB downloads $ok/12 | 10 MB: $big | exit IP: ${exitip:-none}"
  hedioum-tunnel remove-node --alias "$ALIAS" >/dev/null 2>&1; rm -f "/root/$ALIAS.token"
  systemctl restart hedioum.service
  if [ "$KEEP" -eq 0 ]; then "${SSH[@]}" "hedioum-tunnel uninstall --yes >/dev/null 2>&1; rm -rf /root/iran-bundle /root/install-kharej.sh" >/dev/null 2>&1; log "candidate cleaned"; fi
  log "temporary node removed; hub config backup kept at $BK"
  [ "$ok" -ge 11 ] && echo "   FULL RESULT: GOOD" || echo "   FULL RESULT: NOT GOOD ($ok/12)"
fi
exit "$VERDICT"
