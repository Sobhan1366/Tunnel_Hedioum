#!/usr/bin/env python3
"""panel_tool.py — manage a 3x-ui (Sanaei) panel that sends its users through the Hedioum tunnel.

Sub-commands:
  configure   point the panel's Xray at the Hedioum SOCKS port and create one Reality inbound
  add-user    create a user (optional data limit, expiry, auto-renew) and print its vless:// link
  list        show users, usage and expiry
  remove      delete a user
  link        print a user's link again
  show        print the settings this tool remembers

Safe by design: every change makes a consistent backup of the panel database first, stops the
panel for the few seconds it takes to edit it, starts it again and checks the running Xray config.
Only the Python standard library is used.
"""
import argparse, glob, json, os, random, re, secrets, shutil, sqlite3, string, subprocess, sys, time, uuid

DB = os.environ.get("XUI_DB", "/etc/x-ui/x-ui.db")
RUNTIME = os.environ.get("XUI_RUNTIME", "/usr/local/x-ui/bin/config.json")
BACKUPS = os.environ.get("XUI_BACKUPS", "/root/x-ui-backups")
CONF = os.environ.get("TUNNEL_PANEL_CONF", "/etc/tunnel-panel.json")
USERS_DIR = os.environ.get("TUNNEL_PANEL_USERS", "/root/panel-users")
SERVICE = os.environ.get("XUI_SERVICE", "x-ui")
GB = 1024 ** 3
DAY_MS = 86400000


def die(msg, code=1):
    print("ERROR: " + msg, file=sys.stderr); sys.exit(code)


def say(msg): print(msg, flush=True)


def sh(*cmd, check=False):
    return subprocess.run(cmd, capture_output=True, text=True, check=check)


def xray_bin():
    c = sorted(glob.glob("/usr/local/x-ui/bin/xray-linux-*"))
    if not c: die("Xray binary of the panel not found (is 3x-ui installed?)")
    return c[0]


def backup_db():
    os.makedirs(BACKUPS, mode=0o700, exist_ok=True)
    dst = os.path.join(BACKUPS, "x-ui-%s.db" % time.strftime("%Y%m%d-%H%M%S"))
    s = sqlite3.connect(DB); d = sqlite3.connect(dst); s.backup(d); d.close(); s.close(); os.chmod(dst, 0o600)
    old = sorted(glob.glob(os.path.join(BACKUPS, "x-ui-*.db")))
    for f in old[:-30]: os.remove(f)
    return dst


class PanelStopped:
    """stop the panel, let the caller edit the DB, start it again"""
    def __enter__(self):
        if not os.path.exists(DB): die("panel database %s not found (install the panel first)" % DB)
        self.backup = backup_db(); sh("systemctl", "stop", SERVICE); time.sleep(1); return self
    def __exit__(self, et, ev, tb):
        sh("systemctl", "start", SERVICE)
        if et is None: wait_runtime()
        return False


def wait_runtime(timeout=25):
    """wait until the panel has rewritten its Xray config after the start"""
    t0 = time.time(); m0 = os.path.getmtime(RUNTIME) if os.path.exists(RUNTIME) else 0
    while time.time() - t0 < timeout:
        if os.path.exists(RUNTIME) and os.path.getmtime(RUNTIME) >= m0 and sh("systemctl", "is-active", SERVICE).stdout.strip() == "active":
            time.sleep(2); return True
        time.sleep(1)
    return False


def runtime_clients(tag):
    try:
        for ib in json.load(open(RUNTIME))["inbounds"]:
            if ib.get("tag") == tag: return len(ib["settings"].get("clients", []))
    except Exception: pass
    return None


def load_conf():
    if not os.path.exists(CONF): die("not configured yet — run `configure` first (install-panel.sh does it for you)")
    return json.load(open(CONF))


def save_conf(c):
    os.makedirs(os.path.dirname(CONF), exist_ok=True)
    open(CONF, "w").write(json.dumps(c, indent=2)); os.chmod(CONF, 0o600)


def public_ip():
    r = sh("ip", "-4", "route", "get", "1.1.1.1").stdout
    m = re.search(r"src (\d+\.\d+\.\d+\.\d+)", r); return m.group(1) if m else ""


def rnd(n, al=string.ascii_lowercase + string.digits): return "".join(secrets.choice(al) for _ in range(n))


def gen_x25519():
    out = sh(xray_bin(), "x25519").stdout
    priv = pub = ""
    for line in out.splitlines():
        low = line.lower(); val = line.split(":", 1)[-1].strip()
        if "private" in low: priv = val
        elif "public" in low or low.startswith("password"): pub = val
    if not priv or not pub: die("could not generate Reality keys with `xray x25519`:\n" + out)
    return priv, pub


def port_free(p):
    return sh("bash", "-c", "ss -tln | awk '{print $4}' | grep -qE ':%d$'" % p).returncode != 0


# ------------------------------------------------------------------ configure
def cmd_configure(a):
    c = {}
    if os.path.exists(CONF): c = json.load(open(CONF))
    port = a.port or c.get("port") or random.choice([p for p in range(20000, 50000) if port_free(p)])
    if not a.direct and not a.socks_port: die("give --socks-port N (the Hedioum SOCKS port on this hub) or --direct for a test without a tunnel")
    with PanelStopped() as ps:
        db = sqlite3.connect(DB)
        row = db.execute("select value from settings where key='xrayTemplateConfig'").fetchone()
        if row:
            t = json.loads(row[0])
        else:
            # fresh install: the panel has not stored a template yet, so start from the config it is running with
            if not os.path.exists(RUNTIME): die("the panel has not generated its Xray config yet — wait a few seconds and retry")
            t = json.load(open(RUNTIME))
            t["inbounds"] = [i for i in t.get("inbounds", []) if i.get("tag") == "api"]
            db.execute("insert into settings (key, value) values ('xrayTemplateConfig', ?)", (json.dumps(t, indent=2),))
        outs = [o for o in t["outbounds"] if o.get("tag") not in ("hediom",)]
        if a.direct:
            first = {"tag": "hediom", "protocol": "freedom", "settings": {}}
        else:
            first = {"tag": "hediom", "protocol": "socks", "settings": {"servers": [{"address": "127.0.0.1", "port": a.socks_port}]}}
        t["outbounds"] = [first] + outs
        tags = {o["tag"] for o in t["outbounds"]} | {"api"}
        rules = [r for r in t["routing"]["rules"] if r.get("outboundTag") in tags]
        def has(pred): return any(pred(r) for r in rules)
        if not has(lambda r: r.get("ip") == ["geoip:private"]):
            rules.append({"type": "field", "ip": ["geoip:private"], "outboundTag": "blocked"})
        if not has(lambda r: r.get("protocol") == ["bittorrent"]):
            rules.append({"type": "field", "protocol": ["bittorrent"], "outboundTag": "blocked"})
        tag = "in-%d-tcp" % port
        if not db.execute("select 1 from inbounds where port=?", (port,)).fetchone():
            priv, pub = gen_x25519()
            sids = [secrets.token_hex(n // 2) for n in (2, 4, 6, 8, 10, 12, 14, 16)]
            stream = {"network": "tcp", "tcpSettings": {"acceptProxyProtocol": False, "header": {"type": "none"}}, "security": "reality",
                      "realitySettings": {"show": False, "xver": 0, "target": a.sni + ":443", "serverNames": [a.sni], "privateKey": priv,
                                          "minClientVer": "", "maxClientVer": "", "maxTimediff": 0, "shortIds": sids, "mldsa65Seed": "",
                                          "settings": {"publicKey": pub, "fingerprint": "chrome", "serverName": "", "spiderX": "/" + rnd(16), "mldsa65Verify": ""}}}
            settings = {"clients": [], "decryption": "none", "encryption": "none", "testseed": [900, 500, 900, 256]}
            cols = [r[1] for r in db.execute("pragma table_info(inbounds)")]
            row = {"user_id": 1, "up": 0, "down": 0, "total": 0, "remark": a.remark, "sub_sort_index": 1, "enable": 1, "expiry_time": 0,
                   "traffic_reset": "never", "traffic_reset_day": 1, "last_traffic_reset_time": 0, "listen": "", "port": port, "protocol": "vless",
                   "settings": json.dumps(settings, indent=2), "stream_settings": json.dumps(stream, indent=2), "tag": tag,
                   "sniffing": json.dumps({"enabled": False}), "node_id": None, "share_addr_strategy": "listen", "share_addr": "", "origin_node_guid": ""}
            row = {k: v for k, v in row.items() if k in cols}
            db.execute("insert into inbounds (%s) values (%s)" % (",".join(row), ",".join("?" * len(row))), list(row.values()))
            iid = db.execute("select id from inbounds where port=?", (port,)).fetchone()[0]
            say("created Reality inbound id %d on port %d (camouflage site %s)" % (iid, port, a.sni))
        else:
            iid = db.execute("select id from inbounds where port=?", (port,)).fetchone()[0]
            tag = db.execute("select tag from inbounds where id=?", (iid,)).fetchone()[0]
            say("inbound on port %d already exists (id %d) — kept" % (port, iid))
        rules = [r for r in rules if tag not in r.get("inboundTag", [])]
        rules.append({"type": "field", "inboundTag": [tag], "outboundTag": "hediom"})
        t["routing"]["rules"] = rules
        db.execute("update settings set value=? where key='xrayTemplateConfig'", (json.dumps(t, indent=2),))
        db.commit(); db.close()
    c.update({"host": a.host or c.get("host") or public_ip(), "port": port, "inbound_id": iid, "tag": tag, "sni": a.sni})
    save_conf(c)
    say("OK. Users leave through %s. Settings saved to %s" % ("a DIRECT connection (test mode)" if a.direct else "the Hedioum node on 127.0.0.1:%d" % a.socks_port, CONF))
    say("Backup of the panel database: " + ps.backup)


# --------------------------------------------------------------------- users
def make_link(db, c, email):
    st, ss = db.execute("select settings, stream_settings from inbounds where id=?", (c["inbound_id"],)).fetchone()
    cl = [x for x in json.loads(st)["clients"] if x["email"] == email]
    if not cl: die("no such user: " + email)
    r = json.loads(ss)["realitySettings"]; rs = r["settings"]
    sni = rs.get("serverName") or r["serverNames"][0]
    sid = r["shortIds"][3] if len(r["shortIds"]) > 3 else r["shortIds"][0]
    return ("vless://%s@%s:%d?type=tcp&encryption=none&security=reality&pbk=%s&fp=%s&sni=%s&sid=%s&spx=%%2F&flow=xtls-rprx-vision#%s"
            % (cl[0]["id"], c["host"], c["port"], rs["publicKey"], rs.get("fingerprint", "chrome"), sni, sid, email))


def print_link(link, name):
    say("\nLink for %s (copy it into the client app):\n\n%s\n" % (name, link))
    if shutil.which("qrencode"): subprocess.run(["qrencode", "-t", "ANSIUTF8", link])


def cmd_add_user(a):
    c = load_conf()
    name = re.sub(r"[^a-z0-9_-]", "", a.name.lower())
    if not name: die("the user name must contain letters/digits")
    if a.monthly: a.gb, a.days, a.renew = a.monthly, 30, 30
    if a.renew is None: a.renew = a.days if (a.gb and a.days) else 0
    with PanelStopped() as ps:
        db = sqlite3.connect(DB)
        if db.execute("select 1 from clients where email=?", (name,)).fetchone(): die("a user named '%s' already exists (names must be unique in the whole panel)" % name)
        now = int(time.time() * 1000); uid = str(uuid.uuid4()); sub, pw, au = rnd(16), rnd(16), rnd(16)
        exp = now + a.days * DAY_MS if a.days else 0; total = int(a.gb * GB) if a.gb else 0
        note = a.note or ("%s GB" % a.gb if a.gb else "unlimited") + (", %d days" % a.days if a.days else "") + (", auto-renew %d days" % a.renew if a.renew else "")
        st, = db.execute("select settings from inbounds where id=?", (c["inbound_id"],)).fetchone(); j = json.loads(st)
        j["clients"].append({"id": uid, "flow": "xtls-rprx-vision", "email": name, "limitIp": a.devices, "totalGB": total, "expiryTime": exp, "enable": True,
                             "tgId": 0, "subId": sub, "comment": note, "reset": a.renew, "security": "auto", "password": pw, "auth": au, "created_at": now, "updated_at": now})
        db.execute("update inbounds set settings=? where id=?", (json.dumps(j, indent=2), c["inbound_id"]))
        cols = [r[1] for r in db.execute("pragma table_info(clients)")]
        row = {"email": name, "sub_id": sub, "uuid": uid, "password": pw, "auth": au, "flow": "xtls-rprx-vision", "security": "auto", "limit_ip": a.devices,
               "total_gb": int(a.gb) if a.gb else 0, "expiry_time": exp, "enable": 1, "tg_id": 0, "comment": note, "reset": a.renew, "created_at": now, "updated_at": now}
        row = {k: v for k, v in row.items() if k in cols}
        db.execute("insert into clients (%s) values (%s)" % (",".join(row), ",".join("?" * len(row))), list(row.values()))
        cid = db.execute("select id from clients where email=?", (name,)).fetchone()[0]
        db.execute("insert into client_inbounds (client_id,inbound_id,flow_override,created_at) values (?,?,?,?)", (cid, c["inbound_id"], "xtls-rprx-vision", now))
        db.execute("insert into client_traffics (inbound_id,enable,email,up,down,expiry_time,total,reset,last_online) values (?,?,?,?,?,?,?,?,?)",
                   (c["inbound_id"], 1, name, 0, 0, exp, total, a.renew, 0))
        db.commit(); link = make_link(db, c, name); db.close()
    os.makedirs(USERS_DIR, mode=0o700, exist_ok=True)
    p = os.path.join(USERS_DIR, name + ".txt"); open(p, "w").write(link + "\n"); os.chmod(p, 0o600)
    n = runtime_clients(c["tag"])
    say("user '%s' created: %s" % (name, note)); say("(the running Xray now has %s user(s) on this inbound)" % n)
    print_link(link, name); say("Saved to " + p)


def cmd_list(a):
    c = load_conf(); db = sqlite3.connect("file:%s?mode=ro" % DB, uri=True); now = time.time() * 1000
    rows = db.execute("select email,up,down,total,expiry_time,enable,last_online,reset from client_traffics where inbound_id=? order by id", (c["inbound_id"],)).fetchall()
    if not rows: say("no users yet — create one with add-user"); return
    say("%-22s %-9s %-26s %-18s %-10s %s" % ("user", "state", "used / limit", "expires", "renew", "last seen"))
    for e, up, dn, tot, exp, en, lo, rs in rows:
        used = (up + dn) / GB; lim = ("%.1f / %.0f GB" % (used, tot / GB)) if tot else ("%.1f GB / unlimited" % used)
        ex = ("in %.0f days" % ((exp - now) / DAY_MS)) if exp else "never"
        seen = ("%.0f min ago" % ((now - lo) / 60000)) if lo else "never"
        say("%-22s %-9s %-26s %-18s %-10s %s" % (e, "active" if en else "OFF", lim, ex, ("%d d" % rs) if rs else "-", seen))


def cmd_remove(a):
    c = load_conf(); name = a.name.lower()
    with PanelStopped() as ps:
        db = sqlite3.connect(DB)
        st, = db.execute("select settings from inbounds where id=?", (c["inbound_id"],)).fetchone(); j = json.loads(st)
        n0 = len(j["clients"]); j["clients"] = [x for x in j["clients"] if x["email"] != name]
        if len(j["clients"]) == n0: die("no such user: " + name)
        db.execute("update inbounds set settings=? where id=?", (json.dumps(j, indent=2), c["inbound_id"]))
        cid = db.execute("select id from clients where email=?", (name,)).fetchone()
        if cid:
            db.execute("delete from client_inbounds where client_id=?", (cid[0],)); db.execute("delete from clients where id=?", (cid[0],))
        db.execute("delete from client_traffics where email=?", (name,)); db.commit(); db.close()
    f = os.path.join(USERS_DIR, name + ".txt")
    if os.path.exists(f): os.remove(f)
    say("user '%s' removed" % name)


def cmd_link(a):
    c = load_conf(); db = sqlite3.connect("file:%s?mode=ro" % DB, uri=True)
    print_link(make_link(db, c, a.name.lower()), a.name)


def cmd_show(a):
    c = load_conf(); say(json.dumps(c, indent=2))


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sp = p.add_subparsers(dest="cmd", required=True)
    s = sp.add_parser("configure"); s.add_argument("--socks-port", type=int); s.add_argument("--direct", action="store_true")
    s.add_argument("--port", type=int); s.add_argument("--sni", default="digikala.com"); s.add_argument("--remark", default="tunnel")
    s.add_argument("--host", default=""); s.set_defaults(f=cmd_configure)
    s = sp.add_parser("add-user"); s.add_argument("name"); s.add_argument("--gb", type=float, default=0, help="data limit in GB (0 = unlimited)")
    s.add_argument("--days", type=int, default=0, help="expiry in days (0 = never)"); s.add_argument("--renew", type=int, default=None, help="auto-renew every N days (resets the data)")
    s.add_argument("--monthly", type=float, help="shortcut: this many GB per month, expires in 30 days, auto-renews every 30 days")
    s.add_argument("--devices", type=int, default=0, help="max simultaneous devices (0 = no limit)"); s.add_argument("--note", default="")
    s.set_defaults(f=cmd_add_user)
    s = sp.add_parser("list"); s.set_defaults(f=cmd_list)
    s = sp.add_parser("remove"); s.add_argument("name"); s.set_defaults(f=cmd_remove)
    s = sp.add_parser("link"); s.add_argument("name"); s.set_defaults(f=cmd_link)
    s = sp.add_parser("show"); s.set_defaults(f=cmd_show)
    a = p.parse_args(); a.f(a)


if __name__ == "__main__":
    if os.geteuid() != 0: die("run as root")
    main()
