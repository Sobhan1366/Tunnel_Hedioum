# TLS (wss) for the WebSocket configs

The hub's `xray-iran` serves VLESS over **plain WebSocket** (`security=none`). Plain WebSocket is the
easiest thing for a middlebox to recognise and the only config in this project that carries no encryption of
its own on the Iran-side leg. This page explains how to put **real TLS** in front of it, and what we learned.

| config | needs a certificate? |
|---|---|
| VLESS + **Reality** (panel inbounds, `security=reality`) | **No.** Reality *is* a TLS 1.3 handshake borrowed from the target site; it uses its own key pair, not a certificate. Adding TLS on top is pointless. |
| VLESS + WebSocket, `security=none` (xray-iran, installed by `install-iran.sh`) | **Yes, if you want TLS.** This page. |

## The idea: add, don't convert

A port is either plain or TLS, never both. A TLS listener answers a plain client with garbage and vice versa,
so *converting* the existing port breaks **every link already handed out**. `tools/enable-tls.sh` therefore
**clones** each plain WebSocket inbound (same users, same path, same routing) onto a new TLS port and leaves
the plain port alone:

```
plain  :2100  /hed-ssh   -> unchanged
plain  :2105  /hed-66    -> unchanged
TLS    :443   /hed-ssh   <- new, same users as :2100
TLS    :8443  /hed-66    <- new, same users as :2105
```

**Use 443 for the main one.** TLS on port 443 looks like ordinary HTTPS; a TLS service on an odd port such as
2100 stands out more. If you really want TLS on the original port, convert it deliberately and give every user
the new link first - or put a TLS-sniffing front (e.g. nginx `stream` + `ssl_preread`) on that port.

## Before you start

1. **A DNS name that points at the hub**: an `A` record, **"DNS only"**. If the name is behind a CDN proxy
   (e.g. Cloudflare's orange cloud) it resolves to the CDN's addresses and the CDN forwards only a few web
   ports - 443 may work for HTTP traffic, but our other ports and the certificate challenge will not.
2. **Port 80 free and reachable from the internet** (Let's Encrypt HTTP-01 challenge), and the TLS ports free.
3. **acme.sh** on the hub (`curl https://get.acme.sh | sh`). If the hub cannot reach the internet freely, copy
   the script over with `scp`, or get a certificate elsewhere and pass `--cert/--key`.
4. A public certificate puts the **host name into the public Certificate Transparency logs**. If that is not
   acceptable, do not use a public CA for this name.

## Run it

```bash
bash tools/enable-tls.sh --domain hub.example.com --dry-run      # shows the plan, tests the config, changes nothing
bash tools/enable-tls.sh --domain hub.example.com                 # does it
```

| option | meaning |
|---|---|
| `--domain D` | the DNS name (required) |
| `--ports 443,8443` | TLS ports for the clones, in inbound order |
| `--config F` / `--service S` | xray config / systemd unit (default: `/usr/local/etc/xray/config.json`, `xray-iran`) |
| `--cert F --key F` | use an existing certificate instead of acme.sh |
| `--with-dashboard` | use the same certificate for `/opt/tunnel-dashboard` (HTTPS without a browser warning) |
| `--set-panel-host` | write the domain into `/etc/tunnel-panel.json`, so panel-generated links carry the name instead of an IP |
| `--no-restart` | patch the config only |

What it does, in order: plan -> certificate (acme.sh, ECC, `--server letsencrypt`) -> validate certificate and
key -> build the new config in a temp file and run `xray -test` -> back up and install it -> restart ->
check each new port with a real TLS handshake -> **roll back automatically if anything fails** -> print the
client links. Re-running is safe: inbounds that already have a `-tls` copy are skipped.

## The client link

```
vless://UUID@hub.example.com:443?encryption=none&security=tls&sni=hub.example.com&fp=chrome&alpn=http%2F1.1&type=ws&path=%2Fhed-ssh#name
```

The script prints the real ones. `sni` must be the certificate's name; `fp`/`alpn`/`sni` exist **only** on TLS
links. Put the **name**, not the IP, in links: when the hub's IP changes you only update DNS.

## Check it

```bash
echo | openssl s_client -connect hub.example.com:443 -servername hub.example.com 2>&1 | grep Verification   # Verification: OK
ss -ltn | grep -E ':(443|8443|2100|2105) '
```
and a real end-to-end test: a throw-away xray client with `security: tls` against the new port, then
`curl --socks5-hostname 127.0.0.1:PORT http://checkip.amazonaws.com` must print the foreign server's IP.

## Renewal

acme.sh renews by cron. The script registers a hook that restarts xray (and the dashboard) after a renewal; it
only acts once the new config is live, so installing never causes a surprise restart. A restart drops
connections for about a second.

## Rollback

The script prints the backup path (`<config>.bak-tls-<time>`):
```bash
cp -p /usr/local/etc/xray/config.json.bak-tls-<time> /usr/local/etc/xray/config.json && systemctl restart xray-iran
```

## Lessons

- **`security=tls` on a plain port = "no ping".** The client sends a TLS ClientHello, the plain WebSocket
  server answers with plain text, the handshake dies (`wrong version number` in `openssl s_client`). Nothing is
  wrong with the server. Rule: plain port -> `security=none` (no `sni`, `fp`, `alpn`); TLS port -> `security=tls`.
- **A CDN-proxied name looks fine and does not work** for non-web ports (see "Before you start").
- **acme.sh v3 defaults to another CA** than Let's Encrypt; pass `--server letsencrypt` explicitly.
- **`xray -test` does not read certificate files**: a garbage certificate passes it and only fails at runtime.
  The script validates the certificate itself (parses, key matches, not expiring) before touching the config.
- **xray picks the config format from the file extension**: a temp file without `.json` is rejected with
  "Failed to get format". Use `mktemp --suffix=.json` (found by testing the script).
- **WebSocket is deprecated in recent xray** (it logs a warning on every start and says to migrate to XHTTP).
  It still works; plan the migration of these two routes.
- **WS + TLS is easier to fingerprint than Reality.** Use it for clients that cannot do Reality, not as a
  replacement.
- Test a script like this on a *copy* of the config with loopback-only listeners first (the project's scripts
  were developed that way): real handshakes, real traffic, zero risk to the live service.
