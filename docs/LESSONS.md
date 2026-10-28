# Lessons learned (so you don't repeat them)

All observations are from one Iran hub and several foreign servers; they are evidence, not guarantees.

## Tests that mislead
* **Plain TCP bulk test** (random bytes to a Python listener): stalled after ~16 KB on a server that
  Hedioum used at full speed, and gave no signal on servers that Hedioum could not use. Don't use it
  to pick servers. Use `tools/check-foreign.sh` (TLS on a mail port) or attach a real node.
* **Cloudflare's speed endpoint** answers `HTTP 429` once your exit IP is rate-limited; fast
  "failures" and absurd numbers (thousands of Mbps) were this. Count only completed streams and
  use a second source (e.g. a file server with range requests).
* **`openssl s_client` as a data-transfer tester** returned 0 bytes even against a healthy host;
  use Python's `ssl` module for data tests.
* A UDP probe that never ran (no Python on the sender) looked like "UDP is blocked". Verify that
  the sender really sent. In our case UDP from inside Iran reached the hub (30/30) while UDP from
  abroad was ~90 % lost.
* ICMP, MTU (DF ping 1472) and TCP handshakes were perfect on servers that carried no data.

## What a throttled path looks like
* TLS ClientHello **without SNI**: an RST arrives a few ms after the hello (much earlier than the
  RTT), with a different TTL than the server's packets, and the server never sees the hello.
* Everything (TLS with SNI, plain bytes, any port) stalls after **~11 packets (~16 KB)** per flow.
* A capture on both ends shows the sender's packets arriving but most ACKs from the hub never
  reaching the server. Quick diagnosis: `tcpdump -nn -v` on both ends during one failing request
  and compare TTLs/timestamps/packet counts.
* Hedioum can look healthy ("pipe established", "authentic hub connection") and still carry zero
  data. The truth is `curl --socks5-hostname 127.0.0.1:PORT` through the node, repeated.

## Hedioum facts
* The v2 pairing token is self-contained: `add-node --mimics/--target-ip/--tls-servername` are
  ignored. Mimic set and SNI live in the token (`setup-foreign --mimics … --tls-servername …`);
  change the hub side later with `edit-node --alias X --mimics smtp`.
* `setup-iran` writes the hub config with ONE node and overwrites existing ones — use
  `add-node` to add more. Any node change needs `systemctl restart hedioum`.
* `bandwidth_limit_mbps` is per pipe (default 8). See README §3.
* Foreign `setup-foreign` re-run rewrites the config and may change the token; re-pair the hub.
* The SSH mimic can run on a custom `--listen-port` without moving sshd.
* `speedtest` only supports `--mimic tls|ssh`; `probe --node X` lists per-endpoint health.
* Hub-side dials to a private address are accepted; the foreign refuses loopback targets, so
  services that must be reached through the tunnel have to listen on a real address.

## Panel (3x-ui) facts — see README §4
Clients live in `clients` / `client_inbounds` (+ `client_traffics`); routing rule per inbound tag;
REALITY SNI must be in `serverNames`; stop the panel and use SQLite's backup API for a
consistent copy before editing its database by hand; email is UNIQUE across all inbounds.

## Operational traps (these bit us)
* `pkill -f PATTERN` / `pgrep -f PATTERN` over SSH match the shell that runs them and kill your own
  session; `pkill -x NAME -P 1` kills systemd-managed services. Kill by recorded PID.
* Rapid repeated SSH logins can get your address rate-limited/banned (sshd `MaxStartups`,
  fail2ban, provider firewalls): use **one** connection per task, one attempt, then wait minutes.
  A jump through a machine the server already trusts (`ssh -o ProxyCommand="ssh -W %h:%p hub" …`)
  worked when direct SSH timed out in the banner exchange.
* Don't write retry loops around SSH. Wait for a port/ping first, then try once.
* `${VAR:+text}` expands when `VAR=0` too; use explicit `if`. `grep -c` returning 0 aborts a
  `set -e` script. A systemd timer whose `OnBootSec` already elapsed fires immediately when first started.
* When a service restarts dependants (`Requires=`), a "restart this tunnel" timer restarts them too.
* Remove old firewall DROP rules left by earlier panels before diagnosing a "closed" port.
* Kill your own test processes by PID and delete temp configs/keys you created.

## Capacity
Per-user speed is bounded by the hub/path, not by the number of tunnels: extra nodes to the same
foreign server did not add throughput. Measure with parallel *completed* downloads, one node at a
time, then both together.

## Script-writing traps found while testing the panel scripts
* `set -o pipefail` + `tr -dc … </dev/urandom | head -c N` exits with SIGPIPE (141) and `set -e` kills the script silently
  right after the previous log line. Generate random strings with Python instead.
* A fresh 3x-ui database has **no** `xrayTemplateConfig` row until the panel saves one from the UI; derive it from the panel's running
  `bin/config.json` (keep only the `api` inbound) and insert it.
* The offline release archive unpacks to a top-level `x-ui/` folder; the systemd unit and `x-ui.sh` ship inside it
  (`x-ui.service.debian` on Ubuntu). `x-ui setting -username … -password … -port … -webBasePath …` creates the database and the login.
* Editing the panel database while the panel runs races with it: backup (SQLite backup API), stop, edit, start, then check the running config.

## A hub-wide international cut (not the tunnel's fault)
Symptom: every user dies at once, the hub's own `ping 1.1.1.1` / `8.8.8.8` fails, and `tcpdump` shows outbound SYNs to
foreign addresses with no SYN-ACK. All services still say `active`. Reachability *from abroad* to the hub's ports is
dropped too (check it from several countries with check-host.net, not only from your own PC). That is the hub's IP or
its upstream being restricted, **not** DPI of the tunnel protocol (a plain ping would not be affected). What worked:
the provider changed the hub's IP; nothing on the servers needed repairing. Do not conclude "we were detected because
we raised the speed" from timing alone - rule the cut out first.
* **Put a DNS name, not an IP, in client links** ("DNS only", not CDN-proxied). Then a new IP is a DNS edit, not a new
  link for every user. Keep the hub's host name in one place (`/etc/tunnel-panel.json`).
* After an IP change re-check everything that embeds the old address: panel link host, dashboard certificate
  (`subjectAltName`), any client or router that dials the hub by IP.
* A VPN/proxy on the admin's own PC can make a *domestic* dashboard unreachable (the traffic leaves via a foreign
  exit and the Iranian host drops it). If the page "just won't open", turn that off first.

## Reality inbound: the target must be reachable FROM THE HUB
For every new client handshake xray connects to the Reality `target` site and relays the TLS exchange. If the hub
cannot reach that site, every client of the inbound times out - while the tunnel, xray and the panel all look healthy.
* Signature: the client's ClientHello arrives, the server sends **nothing** (for minutes); `ss -tnp` shows many
  xray sockets in **SYN-SENT** to the target; `ss -ti` on the client connections shows received bytes but none sent.
* It was one *address* of a big site that was dropped from the hub (SYN, no answer) while other addresses of the same
  site, other sites and other networks reached it fine. Test per address with `curl --resolve` or `/dev/tcp/IP/443`.
* **Fix that keeps every client link valid:** keep the SNI/`serverNames`, change only the `target` to another
  address of the same site that serves the same real certificate (`target: "IP:443"`, same `serverNames`). Switching
  to a *different* site changes what the server shows for the old SNI, and old links failed on most sites we tried.
* Validate in a throw-away xray server/client pair on loopback ports before touching the live inbound; use a
  public address as the probe destination (recent xray refuses `freedom` to loopback/private targets:
  "blocked target").
* Recent xray warns that Reality has a default **minimum client version** and flags some popular domains as risky
  targets; a client with an old core may be refused. When *one* user times out and others do not, rule the target
  out first, then ask for the client app and version.
* `tools/reality-target-check.py` (run by the monitor) turns this into a visible, per-minute signal.

## Dashboard / monitor notes
* Wrap the TLS socket **without** handshaking in the accept loop and do the handshake in the worker thread with a
  timeout; otherwise one idle or plain-HTTP client blocks every other connection.
* Lock out per client IP, not globally, or an attacker (or you, after a typo storm) locks the owner out.
* `panel_tool.py add-user --gb N --days D` used to switch monthly auto-renew on by itself; pass `--renew 0` when the
  user should simply expire.
* Open the panel database read-only (`file:...?mode=ro`) for statistics; only `panel_tool.py` writes, and it stops the
  panel around the edit.
* The monitor must record the exit IP seen *through* the tunnel; "service active" is not "tunnel works". Parsing is
  tolerant of missing fields, so older log lines and new fields can coexist.
* `vnstat` gives volume that survives reboots; NIC counters reset at boot.

## TLS for the WebSocket link - see [TLS.md](TLS.md)
Highlights: a `security=tls` link on a plain port looks like "connects but no ping"; a CDN-proxied name breaks
non-web ports; `xray -test` does not read certificates; xray decides the config format from the file extension;
WebSocket is deprecated in recent xray (plan XHTTP); add a TLS copy on a new port instead of converting the old one.

## Testing habit that paid off
Build the sandbox first: copy the config, move every listener to loopback/test ports, run the real binaries, run
the **negative** cases too (wrong UUID, broken certificate, missing files) and check the live service is untouched.
This found three real bugs (a temp file without `.json`, an unchecked certificate, an installer that would have
`chmod`ed shared directories) before any of it reached a production host.
