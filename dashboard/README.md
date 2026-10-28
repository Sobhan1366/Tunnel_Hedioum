# Hub dashboard: monitoring + users

A small web page that runs **on the hub** and shows what the tunnel is doing, with a login page and (optionally)
user management for the 3x-ui panel.

* Python standard library only (no pip, no Flask). One process, one port (default `8088`).
* **Login page** (user + password). Passwords are stored as PBKDF2-SHA256 hashes (`auth.json`, mode 600);
  sessions are random HttpOnly + SameSite=Strict (+ Secure on HTTPS) cookies valid 12 h; 6 failed logins from
  one IP within 5 minutes lock that IP for a few minutes; state-changing requests need an `X-Dash` header (CSRF);
  a strict Content-Security-Policy is sent. The password can be changed from the *Settings* tab.
* **Safe default**: it listens on `127.0.0.1` only. Opening it to the internet needs HTTPS (the installer refuses
  `--public` without a certificate).
* **Layout**: a right-hand sidebar with one tab per topic (overview, connections, dial attempts, outages,
  volume, users, add user, settings). Light and dark theme (`auto` follows the system).
* **Date filter** (from / to, or last 4 / 14 / 30 days / all) on the time-series tabs. Bucket size adapts to the
  range. Data exists from the first monitor sample on.
* **Overview**: services, exit path through the tunnel, pool size, concurrent connections, hub -> foreign dial
  timeouts, outages and gaps, daily table, traffic volume (NIC counters + vnstat).
* **Reality target check**: a pill next to the services and a red warning when the hub cannot reach the site a
  Reality inbound borrows its handshake from. In that state every client of that inbound times out while all
  services look healthy (see `docs/LESSONS.md`).
* **Users** (needs the panel, see below): usage / limit / expiry / renewal / last seen for every panel user; for the
  managed inbound you can add a user (GB limit, days, monthly auto-renew, device limit), copy a link and remove a
  user. It calls `panel/panel_tool.py`, the same tested tool as the command line.

## Install (on the hub)

Copy the whole project folder to the hub (the hub often cannot reach GitHub: use `scp -r`), then:

```bash
# local only (default) - reach it through an SSH tunnel
sudo bash dashboard/install-dashboard.sh
```
```bash
# reachable by address, with the certificate made by tools/enable-tls.sh
sudo bash dashboard/install-dashboard.sh --public --cert /etc/xray-tls/fullchain.pem --key /etc/xray-tls/privkey.pem
```
```bash
# reachable by address, self-signed (the browser warns once)
sudo bash dashboard/install-dashboard.sh --public --self-signed hub.example.com
```

The script installs the **monitor** (`tools/hedioum-monitor.sh` + `tools/reality-target-check.py` as
`hedioum-monitor.service`, one summary line per minute), the dashboard (`tunnel-dashboard.service`) and
`panel_tool.py`, creates the login and prints the password **once**. Options: `--port`, `--user`,
`--reset-password`, `--no-monitor`, `--with-vnstat`, `--no-start`; `--help` lists them. Re-running is safe.

Open it:
* local: `ssh -N -L 8088:127.0.0.1:8088 root@HUB`, then `http://127.0.0.1:8088/` (https if you gave a certificate);
* public: `https://NAME-OR-IP:8088/` (allow the port in the provider firewall).

**The users tabs** need the 3x-ui panel wired to Hedioum first (`panel/install-panel.sh`); that script writes
`/etc/tunnel-panel.json` (`inbound_id`, `tag`, `host`, `port`). Without it the monitoring tabs still work.
Put a **domain name** in `host` so a future IP change only needs a DNS update, not new links.

Forgot the password? `DASH_BASE=/opt/tunnel-dashboard python3 /opt/tunnel-dashboard/dashboard.py --init-auth admin`
prints a new one; restart `tunnel-dashboard` to drop old sessions.

## Settings (environment of `tunnel-dashboard.service`)

| variable | default | meaning |
|---|---|---|
| `DASH_BASE` | `/opt/tunnel-dashboard` | folder with `dashboard.py`, `index.html`, `panel_tool.py`, `auth.json` |
| `DASH_PORT` | `8088` | port |
| `DASH_BIND` | `127.0.0.1` | `0.0.0.0` = reachable from the internet |
| `DASH_TLS_CERT`, `DASH_TLS_KEY` | empty | set both to serve HTTPS |
| `TUNNEL_PANEL_CONF` | `/etc/tunnel-panel.json` | panel wiring written by `panel/install-panel.sh` |
| `XUI_DB` | `/etc/x-ui/x-ui.db` | the panel's database (opened read-only for statistics) |

## Behaviour worth knowing

* Adding or removing a user briefly stops and starts the 3x-ui panel (about 3 s): users of the panel inbounds
  reconnect by themselves. Routes that are not managed by the panel (xray-iran) are not touched.
* "Limit + days" creates a user that **expires** and does **not** renew. "Monthly" creates N GB / 30 days with
  auto-renew every 30 days (data reset + expiry extended).
* The charts read `/var/log/tunnel-monitor/hedioum_summary.log`, written by the monitor. Samples from before a
  field existed simply lack it (older logs have no exit-IP field: "down" is then inferred from service states).
* Without `vnstat` the volume section shows only NIC counters since boot (reset on every reboot).
* Make the page reachable only as far as you need: a long password, HTTPS, and ideally a firewall rule that
  limits the port to your own addresses.
