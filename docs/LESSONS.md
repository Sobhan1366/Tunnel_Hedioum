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
