# Tunnel_Hedioum

Two scripts that bring up an **Iran ⇄ foreign** tunnel on fresh servers, built on
[Hedioum Pool Tunnel](https://github.com/hedioum/Hedioum-Pool-Tunnel):

```
client (v2rayN, ...) --VLESS+WS--> Iran :2100 --Xray--> Hedioum SOCKS5 (127.0.0.1:40001)
        ==== Hedioum pool (protocol-mimicking TCP) ====> foreign server --> internet
```

| Script | Run on | What it does |
|---|---|---|
| `kharej/install-kharej.sh` | foreign server | installs Hedioum (foreign mode), creates the pairing token, downloads Xray, and puts everything the Iran side needs into a **bundle** directory |
| `iran/install-iran.sh` | Iran server | installs from the bundle (Iran servers often cannot reach GitHub), pairs with the foreign node, runs Xray VLESS+WS on the public port, prints a ready-to-import `vless://` link |

## Usage

1. On the **foreign** server (root):
   ```bash
   bash install-kharej.sh            # add --jitter-restart for randomized restarts
   ```
   It prints the exact `scp` command for the next step.
2. On the **Iran** server (root):
   ```bash
   scp -r root@<FOREIGN_IP>:/root/iran-bundle /root/
   bash install-iran.sh --bundle /root/iran-bundle
   ```
   The last lines contain the `vless://…` link (a fresh UUID is generated per install).
3. Delete the bundle on both servers: `rm -rf /root/iran-bundle` (it holds the pairing token).

Options: run each script with `--help`. Defaults: VLESS port `2100`, WS path `/hed-ssh`,
Hedioum local SOCKS5 `127.0.0.1:40001` (loopback only).

## Notes

- The scripts refuse to start if the chosen VLESS port is already in use. A leftover
  panel (e.g. x-ui) listening on the same port causes intermittent drops — check with
  `ss -tlnp | grep :2100`.
- `--jitter-restart` installs a systemd timer that restarts the tunnel services at
  irregular multi-hour intervals. In testing, after the foreign side restarted, the Iran
  Hedioum pool once stayed stuck "re-warming" until it was restarted manually; watch
  `journalctl -u hedioum` if you enable this unattended.
- Not covered: TLS/CDN fronting, OpenVPN/router integration.
- **Status:** the steps come from a manually built and tested setup; the scripts
  themselves were syntax-checked but not yet run end-to-end on fresh servers. Test on a
  throwaway pair first.

## فارسی (خلاصه)

۱) روی سرور خارج `install-kharej.sh` را اجرا کنید؛ دستور `scp` مرحله‌ی بعد را چاپ می‌کند.
۲) پوشه‌ی `iran-bundle` را به سرور ایران کپی کنید و `install-iran.sh --bundle /root/iran-bundle` را اجرا کنید؛
لینک `vless://` آماده‌ی ایمپورت چاپ می‌شود.
۳) پوشه‌ی bundle را بعد از نصب از هر دو سرور حذف کنید (توکن جفت‌سازی داخلش است).

## License
MIT
