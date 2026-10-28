#!/usr/bin/env python3
"""Tunnel dashboard - a tiny local web UI for the hub (stdlib only).

* listens on 127.0.0.1 only  -> reach it through an SSH tunnel (see Tunnel-Dashboard.bat)
* login page (user + password, PBKDF2 hash in /opt/tunnel-dashboard/auth.json), session cookie
* shows what the monitor records (services, pool, connections, outages, volume)
* lists panel users and creates/removes users with data + time limits by calling
  panel_tool.py (the same tested tool as the command line)
"""
import collections, datetime as dt, hashlib, hmac, json, os, re, secrets, sqlite3, subprocess, sys, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

BASE = os.environ.get("DASH_BASE", "/opt/tunnel-dashboard")
PORT = int(os.environ.get("DASH_PORT", "8088"))
BIND = os.environ.get("DASH_BIND", "127.0.0.1")          # 0.0.0.0 = reachable from the internet
TLS_CERT = os.environ.get("DASH_TLS_CERT", "")            # set both to serve HTTPS
TLS_KEY = os.environ.get("DASH_TLS_KEY", "")
TLS_ON = False
AUTH_FILE = os.path.join(BASE, "auth.json")
PANEL_TOOL = os.path.join(BASE, "panel_tool.py")
INDEX = os.path.join(BASE, "index.html")
CONF = os.environ.get("TUNNEL_PANEL_CONF", "/etc/tunnel-panel.json")
DB = os.environ.get("XUI_DB", "/etc/x-ui/x-ui.db")
SUMMARY = "/var/log/tunnel-monitor/hedioum_summary.log"
RAW = "/var/log/tunnel-monitor/hedioum_raw_events.log"
HEDIOUM_CFG = "/etc/hedioum/hedioum.json"
GB = 1024 ** 3
MONTHS = {m: i + 1 for i, m in enumerate("Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec".split())}
RX = re.compile(r"\b(\w+)=(\S*)")

SERVICES = ["hedioum", "xray-iran", "x-ui", "openvpn-bridge", "hedioum-monitor", "vnstat", "tunnel-jitter-restart.timer"]
WRITE_LOCK = threading.Lock()


PBKDF2_ITER = 200000
SESSION_TTL = 12 * 3600
SESSIONS = {}              # sid -> expiry (epoch seconds)
SESS_LOCK = threading.Lock()
FAILS = collections.defaultdict(list)   # client ip -> timestamps of failed logins
FAIL_LOCK = threading.Lock()
MAX_FAILS = 6              # per client IP, per 5 minutes


def _hash(pw, salt_hex, it=PBKDF2_ITER):
    return hashlib.pbkdf2_hmac("sha256", pw.encode("utf-8"), bytes.fromhex(salt_hex), it).hex()


def auth_load():
    try:
        return json.load(open(AUTH_FILE))
    except Exception:
        return None


def auth_save(user, pw):
    salt = secrets.token_hex(16)
    os.makedirs(BASE, exist_ok=True)
    with open(AUTH_FILE, "w") as f:
        json.dump({"user": user, "salt": salt, "iter": PBKDF2_ITER, "hash": _hash(pw, salt)}, f)
    os.chmod(AUTH_FILE, 0o600)


def auth_check(user, pw):
    a = auth_load()
    if not a:
        return False
    ok_user = hmac.compare_digest(str(user), a["user"])
    ok_pw = hmac.compare_digest(_hash(str(pw), a["salt"], a.get("iter", PBKDF2_ITER)), a["hash"])
    return ok_user and ok_pw


def locked_out(ip):
    now = time.time()
    with FAIL_LOCK:
        for k in [k for k, v in FAILS.items() if not any(now - t < 300 for t in v)]:
            FAILS.pop(k, None)
        FAILS[ip] = [t for t in FAILS.get(ip, []) if now - t < 300]
        return len(FAILS[ip]) >= MAX_FAILS


def note_fail(ip):
    with FAIL_LOCK:
        FAILS[ip].append(time.time())


def session_new():
    sid = secrets.token_urlsafe(32)
    with SESS_LOCK:
        now = time.time()
        for k in [k for k, v in SESSIONS.items() if v < now]:
            SESSIONS.pop(k, None)
        SESSIONS[sid] = now + SESSION_TTL
    return sid


def session_ok(sid):
    with SESS_LOCK:
        exp = SESSIONS.get(sid or "")
        return bool(exp and exp > time.time())


def init_auth(user="admin"):
    pw = secrets.token_urlsafe(12)
    auth_save(user, pw)
    print("username: %s" % user)
    print("password: %s" % pw)


def sh(cmd, timeout=30):
    try:
        return subprocess.run(cmd, shell=isinstance(cmd, str), capture_output=True, text=True, timeout=timeout).stdout.strip()
    except Exception:
        return ""


def num(x):
    return int(x) if x is not None and str(x).isdigit() else None


# ------------------------------------------------------------------ live (cheap)
def live():
    o = {"now_utc": dt.datetime.utcnow().strftime("%Y-%m-%d %H:%M:%S"),
         "services": {s: sh(["systemctl", "is-active", s], 5) for s in SERVICES},
         "boot_since_utc": sh(["uptime", "-s"], 5)}
    last = {}
    try:
        with open(SUMMARY, "rb") as f:
            f.seek(0, 2); size = f.tell(); f.seek(max(0, size - 12288))
            lines = f.read().decode("utf-8", "ignore").strip().splitlines()
        last = dict(RX.findall(lines[-1])); last["ts"] = lines[-1][:19]
        # the monitor writes tcp_active=NA while the pool is steady (no scaling events);
        # show the most recent numeric value instead of "NA"
        if not str(last.get("tcp_active", "")).isdigit():
            for ln in reversed(lines):
                v = dict(RX.findall(ln)).get("tcp_active")
                if v and v.isdigit():
                    last["tcp_active"] = v
                    break
    except Exception:
        pass
    o["monitor_last"] = {k: last.get(k) for k in ("ts", "kharej_hedioum", "ws2100_ms", "vless_conns", "tcp_active", "distress_events",
                                                  "reality_targets", "reality_fail", "reality_stuck", "reality_bad")}
    exit_ip = last.get("kharej_hedioum") or ""
    o["exit_ok"] = bool(exit_ip)
    try:
        cfg = json.load(open(HEDIOUM_CFG)); n = cfg["foreign_nodes"][0]
        o["node"] = {"min": n.get("min_connections"), "max": n.get("max_connections"),
                     "bw_mbps": n.get("bandwidth_limit_mbps"), "jitter_mbps": n.get("bandwidth_jitter_mbps"),
                     "mimics": sorted({e.get("mimic") for e in n.get("endpoints", [])})}
    except Exception:
        o["node"] = {}
    nic = sh("ip route show default | awk '{print $5; exit}'", 5)
    dev = sh("awk -v i='%s:' '$1==i {print $2, $10}' /proc/net/dev" % nic, 5).split()
    vol = {"iface": nic}
    try:
        boot = dt.datetime.strptime(o["boot_since_utc"], "%Y-%m-%d %H:%M:%S")
        hrs = max((dt.datetime.utcnow() - boot).total_seconds() / 3600, 0.01)
        rx, tx = int(dev[0]) / GB, int(dev[1]) / GB
        vol.update({"rx_gb": round(rx, 2), "tx_gb": round(tx, 2), "hours": round(hrs, 1),
                    "nic_gb_per_day": round((rx + tx) / hrs * 24, 1), "intl_gb_per_day_est": round((rx + tx) / hrs * 12, 1)})
    except Exception:
        pass
    try:
        j = json.loads(sh("vnstat --json d 10", 10) or "{}")
        days = j["interfaces"][0]["traffic"].get("day", [])
        vol["vnstat_days"] = [{"date": "%04d-%02d-%02d" % (d["date"]["year"], d["date"]["month"], d["date"]["day"]),
                               "rx_gb": round(d["rx"] / GB, 2), "tx_gb": round(d["tx"] / GB, 2)} for d in days]
    except Exception:
        vol["vnstat_days"] = []
    o["volume"] = vol
    t = sh("systemctl list-timers tunnel-jitter-restart.timer --no-pager --no-legend", 5).split()
    o["next_restart"] = ("%s %s" % (t[1], t[2][:5])) if len(t) >= 3 else ""
    o["recent_restarts"] = sh("journalctl -u tunnel-jitter-restart --since '-2 days' --no-pager | grep Finished | awk '{print $1\" \"$2\" \"$3}' | tail -6", 10).splitlines()
    return o


# --------------------------------------------------------------- history (heavy, cached)
_hist = {}                      # days -> {"t": epoch, "data": {...}}
_hist_lock = threading.Lock()
IP_RX = re.compile(r"^\d{1,3}(\.\d{1,3}){3}$")
_first = {"d": None}


def first_data():
    """day of the first monitor sample (the date filter's lower bound)"""
    if _first["d"] is None:
        d = None
        try:
            with open(SUMMARY, errors="ignore") as f:
                for line in f:
                    try:
                        d = dt.datetime.strptime(line[:10], "%Y-%m-%d"); break
                    except ValueError:
                        continue
        except Exception:
            pass
        _first["d"] = d or (dt.datetime.utcnow() - dt.timedelta(days=30)).replace(hour=0, minute=0, second=0, microsecond=0)
    return _first["d"]
RANGES = (4, 14, 30, 60, 0)                    # 0 = everything
_era = {"start": None}


def exit_ip_era_start():
    """first sample that carries the exit IP (before that, an empty kharej field means 'could not ssh', not 'down')"""
    if _era["start"] is None:
        start = dt.datetime(2099, 1, 1)
        try:
            for line in open(SUMMARY, errors="ignore"):
                m = re.search(r"kharej_hedioum=(\S*)", line)
                if m and IP_RX.match(m.group(1)):
                    start = dt.datetime.strptime(line[:19], "%Y-%m-%d %H:%M:%S"); break
        except Exception:
            pass
        _era["start"] = start
    return _era["start"]


def is_down(t, d):
    kh = d.get("kharej_hedioum", "")
    if IP_RX.match(kh):
        down = False
    elif kh in ("inactive", "failed", "deactivating"):
        down = True
    elif kh == "active":
        down = False
    else:                                       # empty
        down = t >= exit_ip_era_start()
    for k in ("iran_hedioum", "iran_xray"):
        v = d.get(k)
        if v and v != "active":
            down = True
    return down


def compute_history(since, until):
    now = dt.datetime.utcnow()
    span = max(1.0, (until - since).total_seconds() / 86400)
    bucket_h = 1 if span <= 7 else (3 if span <= 21 else 6)      # keeps every chart at <= ~170 points
    rows = []
    try:
        for line in open(SUMMARY, errors="ignore"):
            try:
                t = dt.datetime.strptime(line[:19], "%Y-%m-%d %H:%M:%S")
            except ValueError:
                continue
            if since <= t < until:
                rows.append((t, dict(RX.findall(line))))
    except Exception:
        pass

    def bkey(t):
        return t.replace(hour=(t.hour // bucket_h) * bucket_h, minute=0, second=0).strftime("%Y-%m-%dT%H:00")

    series, daily = collections.OrderedDict(), collections.OrderedDict()
    flags = []
    for t, d in rows:
        c = num(d.get("vless_conns")) or 0
        dist = num(d.get("distress_events")) or 0
        dn = 1 if is_down(t, d) else 0
        flags.append((t, dn))
        for store, key in ((series, bkey(t)), (daily, t.strftime("%Y-%m-%d"))):
            a = store.setdefault(key, [0, 0, 0, 0, 0])
            a[0] += 1; a[1] += c; a[2] = max(a[2], c); a[3] += dist; a[4] += dn
    fmt = lambda s: [{"t": k, "samples": a[0], "avg": round(a[1] / a[0], 1), "max": a[2], "distress": a[3],
                      "down": a[4], "down_frac": round(a[4] / a[0], 2)} for k, a in s.items()]

    outs, cur = [], None
    def close(cur):
        if cur and (cur[2] >= 5 or (cur[2] >= 2 and (cur[1] - cur[0]).total_seconds() >= 480)):
            outs.append(cur)
    for t, dn in flags:
        if dn:
            if cur is None: cur = [t, t, 1]
            else: cur[1] = t; cur[2] += 1
        else:
            close(cur); cur = None
    close(cur)

    gaps = []
    for i in range(1, len(rows)):
        gap = (rows[i][0] - rows[i - 1][0]).total_seconds() / 60
        if gap > 20:
            gaps.append({"from": rows[i - 1][0].strftime("%Y-%m-%d %H:%M"), "to": rows[i][0].strftime("%Y-%m-%d %H:%M"), "minutes": int(gap)})

    # dial timeouts / established pipes: only the 60-second-cadence era has the full journal copy
    dial_from = max(since, exit_ip_era_start() if exit_ip_era_start().year < 2099 else since)
    dial = collections.OrderedDict()
    raw = sh("grep -aE ' (pipe dial failed|failed to dial new connection|pipe established)' %s" % RAW, 120)
    seen = set()
    for ln in raw.splitlines():
        if ln in seen: continue
        seen.add(ln)
        m = re.match(r"^([A-Z][a-z]{2}) +(\d+) (\d\d):", ln)
        if not m or m.group(1) not in MONTHS: continue
        try:
            ts = dt.datetime(now.year, MONTHS[m.group(1)], int(m.group(2)), int(m.group(3)))
        except ValueError:
            continue
        if ts < dial_from or ts >= until or ts > now + dt.timedelta(hours=1): continue
        k = ts.replace(hour=(ts.hour // bucket_h) * bucket_h).strftime("%Y-%m-%dT%H:00")
        a = dial.setdefault(k, [0, 0]); a[0 if "pipe established" in ln else 1] += 1
    era = exit_ip_era_start()
    return {"bucket_hours": bucket_h, "from": since.strftime("%Y-%m-%d"),
            "first": first_data().strftime("%Y-%m-%d"), "ip_era": era.strftime("%Y-%m-%d") if era.year < 2099 else None,
            "to": (until - dt.timedelta(seconds=1)).strftime("%Y-%m-%d"),
            "series": fmt(series), "daily": fmt(daily),
            "outages": [{"start": a.strftime("%Y-%m-%d %H:%M"), "end": b.strftime("%Y-%m-%d %H:%M"), "samples": n,
                         "minutes": max(1, int((b - a).total_seconds() / 60))} for a, b, n in outs],
            "gaps": gaps[-30:],
            "dial": [{"t": k, "ok": v[0], "fail": v[1]} for k, v in sorted(dial.items())],
            "dial_from": dial_from.strftime("%Y-%m-%d")}


DATE_RX = re.compile(r"^\d{4}-\d{2}-\d{2}$")


def parse_range(qs):
    """?from=YYYY-MM-DD&to=YYYY-MM-DD (inclusive, UTC days) -> (start, end_exclusive); default: last 4 days"""
    now = dt.datetime.utcnow()
    soon = now + dt.timedelta(minutes=1)
    try:
        f = qs.get("from", [""])[0]; t = qs.get("to", [""])[0]
        end = (dt.datetime.strptime(t, "%Y-%m-%d") + dt.timedelta(days=1)) if DATE_RX.match(t) else soon
        start = dt.datetime.strptime(f, "%Y-%m-%d") if DATE_RX.match(f) else end - dt.timedelta(days=4)
    except ValueError:
        end = soon; start = end - dt.timedelta(days=4)
    if start > end:                                   # reversed by mistake: swap instead of failing
        start, end = end - dt.timedelta(days=1), start + dt.timedelta(days=1)
    start = max(start, first_data())
    end = min(end, soon)
    if end <= first_data():                             # the whole range is before the first sample
        end = first_data() + dt.timedelta(days=1)
    if start >= end:
        start = max(first_data(), end - dt.timedelta(days=1))
    return start, end


def history(start=None, end=None):
    if start is None or end is None:
        end = dt.datetime.utcnow() + dt.timedelta(minutes=1)
        start = max(first_data(), end - dt.timedelta(days=4))
    key = (start.strftime("%Y-%m-%d"), end.strftime("%Y-%m-%d %H"))
    with _hist_lock:
        e = _hist.get(key)
        if not e or time.time() - e["t"] > 600:
            try:
                _hist[key] = {"t": time.time(), "data": compute_history(start, end)}
            except Exception as ex:
                if not e: _hist[key] = {"t": time.time(), "data": {"error": str(ex)}}
            if len(_hist) > 24:                       # keep the cache small
                for k in sorted(_hist, key=lambda k: _hist[k]["t"])[:-12]:
                    _hist.pop(k, None)
        return _hist[key]["data"]


# ------------------------------------------------------------------------ users
def conf():
    try:
        return json.load(open(CONF))
    except Exception:
        return {}


def users():
    c = conf(); managed = c.get("inbound_id")
    out = []
    try:
        db = sqlite3.connect("file:%s?mode=ro" % DB, uri=True)
        q = """select t.email, t.up, t.down, t.total, t.expiry_time, t.enable, t.last_online, t.reset, t.inbound_id,
                      i.remark, i.port, i.enable, coalesce(cl.limit_ip,0), coalesce(cl.comment,'')
               from client_traffics t join inbounds i on i.id = t.inbound_id
               left join clients cl on cl.email = t.email
               order by t.inbound_id, t.id"""
        now = time.time() * 1000
        for e, up, dn, tot, exp, en, lo, rs, iid, rem, port, ien, lim, note in db.execute(q):
            out.append({"name": e, "enabled": bool(en) and bool(ien), "used_gb": round((up + dn) / GB, 2), "up_gb": round(up / GB, 2),
                        "down_gb": round(dn / GB, 2), "limit_gb": round(tot / GB, 1) if tot else None,
                        "expires": dt.datetime.utcfromtimestamp(exp / 1000).strftime("%Y-%m-%d") if exp else None,
                        "days_left": round((exp - now) / 86400000, 1) if exp else None,
                        "renew_days": rs or 0, "devices": lim or 0,
                        "last_seen_min": round((now - lo) / 60000) if lo else None,
                        "inbound": rem, "port": port, "managed": iid == managed, "note": note})
    except Exception as ex:
        return {"error": str(ex), "users": out}
    return {"users": out, "managed_inbound": managed, "host": c.get("host"), "port": c.get("port")}


NAME_RX = re.compile(r"^[a-z0-9_-]{2,32}$")


def run_tool(*args, timeout=120):
    r = subprocess.run(["python3", PANEL_TOOL] + [str(a) for a in args], capture_output=True, text=True, timeout=timeout)
    return r.returncode, (r.stdout + r.stderr)


def first_link(text):
    m = re.search(r"vless://\S+", text)
    return m.group(0) if m else None


def add_user(body):
    name = re.sub(r"[^a-z0-9_-]", "", str(body.get("name", "")).lower())
    if not NAME_RX.match(name):
        return 400, {"error": "نام کاربر باید ۲ تا ۳۲ حرف انگلیسی/عدد/خط تیره باشد"}
    try:
        gb = float(body.get("gb") or 0); days = int(body.get("days") or 0); dev = int(body.get("devices") or 0)
    except (TypeError, ValueError):
        return 400, {"error": "مقادیر عددی نامعتبر است"}
    monthly = bool(body.get("monthly"))
    if not (0 <= gb <= 5000 and 0 <= days <= 3650 and 0 <= dev <= 50):
        return 400, {"error": "مقدار خارج از محدوده"}
    if monthly and gb <= 0:
        return 400, {"error": "برای حالت ماهانه حجم لازم است"}
    args = ["add-user", name]
    if monthly: args += ["--monthly", gb]
    else:
        if gb: args += ["--gb", gb]
        if days: args += ["--days", days]
        # panel_tool would silently enable auto-renew when both GB and days are set;
        # a plain "limit + expiry" user must NOT renew, so say so explicitly.
        args += ["--renew", 0]
    if dev: args += ["--devices", dev]
    with WRITE_LOCK:
        rc, out = run_tool(*args)
    link = first_link(out)
    if rc != 0 or not link:
        return 500, {"error": (out.strip().splitlines() or ["خطا"])[-1][:300]}
    history_cache_clear()
    return 200, {"ok": True, "name": name, "link": link}


def remove_user(body):
    name = str(body.get("name", "")).lower()
    if not NAME_RX.match(name):
        return 400, {"error": "نام نامعتبر"}
    with WRITE_LOCK:
        rc, out = run_tool("remove", name)
    return (200, {"ok": True}) if rc == 0 else (500, {"error": out.strip()[-300:]})


def user_link(name):
    if not NAME_RX.match(name):
        return 400, {"error": "نام نامعتبر"}
    rc, out = run_tool("link", name, timeout=30)
    link = first_link(out)
    return (200, {"link": link}) if link else (404, {"error": "کاربر پیدا نشد یا فقط کاربران مدیریت‌شده لینک دارند"})


def history_cache_clear():
    _hist.clear()


# ---------------------------------------------------------------------- server
LOGIN_HTML = """<!doctype html>
<html lang="fa" dir="rtl"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1"><title>ورود - داشبورد تانل</title>
<style>
:root{--bg:#F3F5F9;--card:#fff;--ink:#18202E;--muted:#566277;--line:#E1E6EE;--accent:#6B4EFF;--bad:#C0392B}
@media (prefers-color-scheme:dark){:root{--bg:#13101F;--card:#1B1730;--ink:#EFEBFA;--muted:#A9A0C6;--line:#2D2748;--accent:#B79CFF;--bad:#EF7A6B;--btn-ink:#1A1030}}
*{box-sizing:border-box}
body{margin:0;min-height:100vh;display:grid;place-items:center;background:var(--bg);color:var(--ink);font-family:Tahoma,"Segoe UI",Vazirmatn,system-ui,sans-serif}
.box{width:min(360px,92vw);background:var(--card);border:1px solid var(--line);border-radius:14px;padding:22px}
h1{font-size:19px;margin:0 0 4px}.sub{color:var(--muted);font-size:13px;margin-bottom:16px}
label{display:block;font-size:13px;color:var(--muted);margin:10px 0 3px}
input{width:100%;font:inherit;color:var(--ink);background:var(--bg);border:1px solid var(--line);border-radius:8px;padding:10px;direction:ltr;text-align:left}
button{width:100%;margin-top:16px;font:inherit;background:var(--accent);color:var(--btn-ink,#fff);border:0;border-radius:8px;padding:10px;cursor:pointer}
button:disabled{opacity:.6}.err{color:var(--bad);font-size:13px;margin-top:10px;min-height:18px}
</style></head><body>
<form class="box" id="f" autocomplete="on">
  <h1>داشبورد تانل</h1><div class="sub">برای ورود نام کاربری و رمز را وارد کنید</div>
  <label for="u">نام کاربری</label><input id="u" name="username" autocomplete="username" autofocus required>
  <label for="p">رمز عبور</label><input id="p" name="password" type="password" autocomplete="current-password" required>
  <button id="b" type="submit">ورود</button><div class="err" id="e"></div>
</form>
<script>
document.getElementById("f").addEventListener("submit", async ev => {
  ev.preventDefault();
  const b = document.getElementById("b"), e = document.getElementById("e");
  b.disabled = true; e.textContent = "";
  try {
    const r = await fetch("/api/login", {method:"POST", headers:{"Content-Type":"application/json","X-Dash":"1"},
      body: JSON.stringify({user: document.getElementById("u").value.trim(), password: document.getElementById("p").value})});
    const j = await r.json().catch(() => ({}));
    if (r.ok) { location.href = "/"; return; }
    e.textContent = j.error || "ورود ناموفق";
  } catch (x) { e.textContent = "خطای ارتباط"; }
  b.disabled = false;
});
</script></body></html>"""


class H(BaseHTTPRequestHandler):
    server_version = "dash"
    timeout = 20                      # slow / idle clients are dropped (also covers the TLS handshake)
    def log_message(self, *a): pass

    def setup(self):
        if TLS_ON:                    # handshake here (worker thread), not in the accept loop
            self.request.settimeout(15)
            self.request.do_handshake()
        super().setup()

    def _host_ok(self):
        return True                   # reachable by IP or any domain; protection = login + CSRF header

    def _cookie_flags(self):
        return "Path=/; HttpOnly; SameSite=Strict" + ("; Secure" if TLS_ON else "")

    def _ip(self):
        return self.client_address[0]

    def _sid(self):
        m = re.search(r"(?:^|;\s*)dash_sid=([^;]+)", self.headers.get("Cookie") or "")
        return m.group(1) if m else ""

    def _authed(self):
        return session_ok(self._sid())

    def _send(self, code, obj=None, body=None, ctype="application/json; charset=utf-8", headers=None):
        data = body if body is not None else json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Content-Security-Policy", "default-src 'self'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; img-src 'self' data:")
        for k, v in (headers or {}).items(): self.send_header(k, v)
        self.end_headers(); self.wfile.write(data)

    def do_GET(self):
        u = urlparse(self.path); qs = parse_qs(u.query)
        if not self._host_ok(): return self._send(403, {"error": "host"})
        if u.path == "/login":
            if self._authed(): return self._send(302, body=b"", headers={"Location": "/"})
            return self._send(200, body=LOGIN_HTML.encode("utf-8"), ctype="text/html; charset=utf-8")
        if not self._authed():
            if u.path.startswith("/api/"): return self._send(401, {"error": "unauthorized"})
            return self._send(302, body=b"", headers={"Location": "/login"})
        if u.path == "/":
            return self._send(200, body=open(INDEX, "rb").read(), ctype="text/html; charset=utf-8")
        if u.path == "/api/overview":
            start, end = parse_range(qs)
            return self._send(200, {"live": live(), "history": history(start, end), "users": users(), "me": (auth_load() or {}).get("user")})
        if u.path == "/api/users":
            return self._send(200, users())
        if u.path == "/api/link":
            code, obj = user_link(qs.get("name", [""])[0].lower()); return self._send(code, obj)
        self._send(404, {"error": "not found"})

    def do_POST(self):
        u = urlparse(self.path)
        if not self._host_ok(): return self._send(403, {"error": "host"})
        if self.headers.get("X-Dash") != "1": return self._send(403, {"error": "csrf"})
        try:
            n = int(self.headers.get("Content-Length") or 0)
            body = json.loads(self.rfile.read(min(n, 4096)) or b"{}")
        except Exception:
            return self._send(400, {"error": "bad json"})

        if u.path == "/api/login":
            ip = self._ip()
            if locked_out(ip):
                return self._send(429, {"error": "تلاش‌های ناموفق زیاد بود؛ چند دقیقه بعد دوباره تلاش کنید"})
            if auth_check(body.get("user", ""), body.get("password", "")):
                sid = session_new()
                return self._send(200, {"ok": True}, headers={"Set-Cookie": "dash_sid=%s; %s; Max-Age=%d" % (sid, self._cookie_flags(), SESSION_TTL)})
            note_fail(ip)
            time.sleep(1.0)
            return self._send(401, {"error": "نام کاربری یا رمز اشتباه است"})

        if not self._authed(): return self._send(401, {"error": "unauthorized"})

        if u.path == "/api/logout":
            with SESS_LOCK: SESSIONS.pop(self._sid(), None)
            return self._send(200, {"ok": True}, headers={"Set-Cookie": "dash_sid=; %s; Max-Age=0" % self._cookie_flags()})
        if u.path == "/api/password":
            a = auth_load() or {}
            new = str(body.get("new", ""))
            if not auth_check(a.get("user", ""), body.get("current", "")):
                time.sleep(1.0); return self._send(403, {"error": "رمز فعلی اشتباه است"})
            if len(new) < 10:
                return self._send(400, {"error": "رمز جدید باید حداقل ۱۰ نویسه باشد"})
            auth_save(a["user"], new)
            with SESS_LOCK:
                keep = self._sid(); SESSIONS.clear(); SESSIONS[keep] = time.time() + SESSION_TTL
            return self._send(200, {"ok": True})
        if u.path == "/api/users":
            code, obj = add_user(body)
        elif u.path == "/api/users/remove":
            code, obj = remove_user(body)
        else:
            code, obj = 404, {"error": "not found"}
        self._send(code, obj)


def warm():
    while True:
        try: history()
        except Exception: pass
        time.sleep(600)


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--init-auth":
        init_auth(sys.argv[2] if len(sys.argv) > 2 else "admin"); sys.exit(0)
    if not auth_load():
        print("no auth.json - run:  python3 dashboard.py --init-auth [username]", file=sys.stderr); sys.exit(2)
    threading.Thread(target=warm, daemon=True).start()

    class Quiet(ThreadingHTTPServer):
        daemon_threads = True
        def handle_error(self, request, client_address):   # scanners / plain HTTP on the TLS port: no traceback spam
            pass

    srv = Quiet((BIND, PORT), H)
    if TLS_CERT and TLS_KEY and os.path.exists(TLS_CERT) and os.path.exists(TLS_KEY):
        import ssl
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.minimum_version = ssl.TLSVersion.TLSv1_2
        ctx.load_cert_chain(TLS_CERT, TLS_KEY)
        srv.socket = ctx.wrap_socket(srv.socket, server_side=True, do_handshake_on_connect=False)
        TLS_ON = True
    print("dashboard on %s:%d  tls=%s" % (BIND, PORT, TLS_ON), flush=True)
    srv.serve_forever()
