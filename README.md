# Tunnel_Hedioum

> 🔰 **New here? Start with the beginner guides:** [فارسی — راهنمای قدم‌به‌قدم](docs/GUIDE-FA.md) · [English — step-by-step](docs/GUIDE-EN.md)

Scripts and field notes for an **Iran hub ⇄ foreign exit** tunnel built on
[Hedioum Pool Tunnel](https://github.com/hedioum/Hedioum-Pool-Tunnel):

```
client --VLESS--> Iran hub (Xray / 3x-ui) --SOCKS5--> Hedioum hub
        ==== Hedioum pool (smtp-mimicking TCP pipes) ====> foreign server --> internet
```

| File | Run on | Purpose |
|---|---|---|
| `tools/check-foreign.sh` | **Iran hub** | tells you in ~2 minutes whether a candidate foreign server is usable (run this *before* installing anything) |
| `kharej/install-kharej.sh` | foreign server | installs Hedioum (foreign), creates the pairing token, bundles Xray for the hub |
| `iran/install-iran.sh` | Iran hub | pairs with the foreign node and exposes a VLESS+WS entry point |
| `panel/install-panel.sh` | Iran hub | installs the 3x-ui panel (online or **offline tarball**), wires it to Hedioum, creates a Reality inbound |
| `panel/add-user.sh` · `list-users.sh` · `show-link.sh` · `remove-user.sh` | Iran hub | create users (data limit, expiry, monthly auto-renew), list usage, print links, delete |
| `docs/GUIDE-FA.md` · `docs/GUIDE-EN.md` | — | very simple step-by-step guides for beginners |
| `docs/LESSONS.md` | — | everything we learned the hard way (read it) |

## 1. Pick the server first — `tools/check-foreign.sh`

Not every foreign server works from every Iran hub. In our tests four brand-new servers
(different providers) *looked* fine (ping 0 % loss, TCP connects, SSH works, MTU 1500) yet
carried no data through Hedioum, while others worked at full speed. A plain TCP speed test
does **not** predict the result (it failed on a server that worked and passed on ones that
did not). What predicts it is TLS-looking mail traffic on a mail port, so the script
emulates exactly that.

```bash
# on the Iran hub, as root; needs an SSH key that logs into the candidate
bash tools/check-foreign.sh CANDIDATE_IP --key /root/.ssh/id_ed25519
```

It starts a throw-away SMTP → STARTTLS → TLS (with SNI) test server on the candidate,
runs 12 × 1 MB sessions, one big download, 4 parallel downloads and an upload from the hub,
prints a verdict (`GOOD` / `MARGINAL` / `BAD`, exit code 0 / 1 / 2) and removes everything
it created. The hub's tunnel is **not touched** in this mode. A transfer that stalls
around 16 KB is the signature of a path that throttles new destinations — reject that server.

* `--port N` if 587 is busy on the candidate (use 465, 25, 2525 …).
* `--full --installer kharej/install-kharej.sh` additionally attaches the candidate as a
  **real** Hedioum node and compares downloads. It restarts `hedioum` on the hub twice
  (~20 s each) and removes the node afterwards — use it for the final confirmation.

**Honest limits:** quick mode was validated on a known-good server (GOOD, ~87 Mbps) but we
no longer had a server that failed in the field, so its `BAD` verdict is a heuristic
(it flags the stall/throttle signature). Treat `--full` as the final word.

## 2. Install

1. Foreign server (root): `bash kharej/install-kharej.sh` — prints the `scp` command for step 2.
   Default camouflage is **`--mimics smtp`**; TLS-based mimics (`tls`, `https-alt`, `imaps`,
   `cpanel` …) stalled behind DPI in our tests and made a share of requests hang.
2. Iran hub (root): `scp -r root@FOREIGN:/root/iran-bundle /root/` then
   `bash iran/install-iran.sh --bundle /root/iran-bundle` — prints a `vless://` link.
3. Delete the bundle on both servers: `rm -rf /root/iran-bundle` (it holds the pairing token).

Both scripts prompt interactively (Enter = default); `-y` + flags for unattended runs.
Highlights: `--random-port`, `--vless-port`, `--ws-path`, `--uuid`, `--socks-port`,
`--jitter-restart`, and on the hub `--bw MBPS --min N --max N` (see §3).

## 3. Speed

Hedioum caps **each pipe** (`bandwidth_limit_mbps`, default 8 Mbps), so a single download
tops out near 8–10 Mbps. Raising it on the hub node:

```bash
hedioum-tunnel edit-node --alias NODE --bw 100 --jitter 0 --min 12 --max 30   # then: systemctl restart hedioum
```

Measured on one hub/foreign pair: single download 8.6 → ~46 Mbps, single upload 10.7 → ~50 Mbps.
Trade-offs and limits:

* The cap is deliberate traffic shaping; removing it makes the traffic look less like an ordinary session.
* Aggregate throughput plateaued at ~35–54 Mbps and was shared by all users. **Adding a second
  node to the *same* foreign server did not add capacity (it made it worse)**, and two different
  foreign servers did not add up either, so the bottleneck sat at the hub/path, not in the number
  of tunnels. For more total speed look at the hub's own bandwidth plan.
* A VLESS+WebSocket hop on a 1-vCPU hub limits a *single* stream to ~29 Mbps; Reality+vision
  measured about the same (29–38 Mbps).

## 4. Many users with quotas — 3x-ui (Sanaei) panel

**Easy way:** `bash panel/install-panel.sh --tarball x-ui-linux-amd64.tar.gz --socks-port 40001` then `bash panel/add-user.sh ali --monthly 30` (30 GB/month, auto-renews every 30 days) or `bash panel/add-user.sh me` (unlimited). Full walkthrough: [docs/GUIDE-EN.md](docs/GUIDE-EN.md). The manual notes below explain what the scripts do.

Per-user data caps only work for inbounds **managed by the panel**; links served by a plain
Xray process (like the one `install-iran.sh` sets up) have no quotas.

1. Point the panel's Xray template at Hedioum: outbound `socks` → `127.0.0.1:<node socks port>`.
2. Add a routing rule per inbound tag → that outbound (**without it users leave through the
   Iranian IP directly**, bypassing the tunnel). Put the `geoip:private` and `bittorrent`
   block rules *before* them.
3. Quota + monthly renewal for a client: total = 30 GB, expiry = now + 30 days,
   `reset` (auto-renew) = 30 days. Verified in the panel counters.
4. A REALITY client's SNI must be one of the inbound's `serverNames` (the panel can store a
   different default `serverName`; the server rejects it with `server name mismatch`).
5. Do **not** insert clients only into an inbound's JSON `settings` when editing the DB by
   hand: 3x-ui v3 builds the running config from the `clients` and `client_inbounds` tables
   (symptom: `invalid request user id`, clients see "Empty reply"). Insert all of
   `clients`, `client_inbounds`, `client_traffics`.
6. Don't expose the panel's login on a default port in the clear; change the password,
   and ideally listen on `127.0.0.1` and reach it through an SSH tunnel.

## 5. Randomized restarts (anti-fingerprinting)

`--jitter-restart` installs a systemd timer that restarts the tunnel services at irregular
multi-hour intervals (`OnUnitActiveSec` + `RandomizedDelaySec` + a random sleep in the script).
After `enable --now`, if `systemctl list-timers` shows no NEXT time, restart the timer once.
**What it does not do:** restarts vary connection lifetimes/counters; they do not change what a
censor sees on the wire (destination IP, protocol, ports). More effective: keep the exit server
clean (nothing public except SSH), per-user UUIDs, don't push huge volumes through one IP, keep a
spare foreign server, and rotate servers if one gets throttled.

## 6. Status

The scripts come from a manually built and repeatedly tested setup. `install-kharej.sh` was run
end-to-end on several fresh servers and `install-iran.sh` on a hub, with fixes along the way;
`check-foreign.sh` is validated only on the "good" side (see §1). The panel scripts were tested end-to-end on a clean server (offline install, one-command fresh install, users with and without limits, each user connecting with its own link, removal) in `--direct` test mode; through a real Hedioum hub they were verified by hand. Test on a throw-away pair first.

---

### فارسی (خلاصه)

* **قبل از هر نصبی** روی هاب ایران `tools/check-foreign.sh CANDIDATE_IP --key ...` را اجرا کنید؛
  می‌گوید سرور خارج برای هدیوم مناسب است یا نه (بدون دست‌زدن به تونل فعلی).
* پیش‌فرض نصب فقط mimic **smtp** است؛ mimicهای مبتنی بر TLS پشت DPI گیر می‌کنند.
* سرعت هر اتصال هدیوم به‌صورت پیش‌فرض ۸Mbps است؛ با `--bw 100` حدود ۵ برابر می‌شود (به قیمت عادی‌نبودن بیشتر ترافیک).
* نود دوم به همان سرور ظرفیت کل را زیاد نمی‌کند؛ گلوگاه هاب/مسیر است.
* حجم ماهانه‌ی کاربر فقط روی اینباندهای پنل 3x-ui کار می‌کند؛ مسیریابی هر اینباند را به خروجی هدیوم فراموش نکنید.
* جزئیات و اشتباهات رایج: `docs/LESSONS.md`.

## License
MIT
