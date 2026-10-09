# Beginner's step-by-step guide

You only need to **copy and paste** the commands. Each step has a ✅ check so you know it worked.
Stuck? Jump to "9. Troubleshooting". (فارسی: [GUIDE-FA.md](GUIDE-FA.md))

```
user's phone/PC  →  Iran server ("hub")  →  foreign server ("exit")  →  internet
```

**You need:** an Iran VPS (hub), a foreign VPS (exit, Ubuntu, ≥1 GB RAM), a computer, and the root password (or SSH key) from your hosting provider.

> Not every foreign server works from every Iran hub. Some IPs look fine (ping OK, SSH OK) yet carry no data. That's why step 3 tests the server **before** you install anything.

## 1. Words you need
**VPS/server** = a rented always-on computer · **IP** = its address · **SSH** = how you type commands on it · **root** = the admin user · **hub** = Iran server · **exit** = foreign server · **token** = secret string that pairs the two servers · **`vless://` link** = what you give users · **panel** = web page to manage users.

## 2. Connect to a server (first time)
Windows: open **PowerShell**. Mac/Linux: open **Terminal**. Type:
```
ssh root@SERVER_IP
```
Answer `yes` to the first question, then type the password (nothing shows while typing — that is normal). ✅ You see `root@...:~#`. Leave with `exit`.

⚠️ Don't retry in a loop. Many providers (e.g. Vultr) temporarily ban an address after several fast logins.

## 3. Is the foreign server suitable? (2 minutes)
1. **Put the project on the hub** (Iran servers usually can't reach GitHub): on GitHub press **Code → Download ZIP**, unzip, then in PowerShell:
   ```
   scp -r C:\Users\YOU\Downloads\Tunnel_Hedioum-main root@HUB_IP:/root/Tunnel_Hedioum
   ```
2. **On the hub** create a key:
   ```
   ssh-keygen -t ed25519 -N "" -C "check-foreign" -f /root/.ssh/check_key
   ```
   ```
   cat /root/.ssh/check_key.pub
   ```
   Copy the printed line.
3. **On the foreign server** allow that key (paste your line instead of `PUBLIC_KEY_LINE`):
   ```
   mkdir -p ~/.ssh && chmod 700 ~/.ssh && echo 'PUBLIC_KEY_LINE' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys
   ```
   (Or, from the hub: `ssh-copy-id -i /root/.ssh/check_key.pub root@FOREIGN_IP`.)
4. **On the hub** run the test:
   ```
   cd /root/Tunnel_Hedioum
   bash tools/check-foreign.sh FOREIGN_IP --key /root/.ssh/check_key
   ```
   Add `--port 465` if it says port 587 is busy.

| Result | Meaning | Next |
|---|---|---|
| **GOOD** | suitable | go on |
| **MARGINAL** | maybe | test again or try another server |
| **BAD** | data does not pass well from Iran | **use a different server** |

## 4. Install on the foreign server
```
curl -fsSL -o install-kharej.sh https://raw.githubusercontent.com/Sobhan1366/Tunnel_Hedioum/main/kharej/install-kharej.sh
```
```
bash install-kharej.sh
```
Press **Enter** for every question. ✅ At the end it prints an `scp` command — copy it.

## 5. Install on the hub
```
scp -r root@FOREIGN_IP:/root/iran-bundle /root/
```
```
cd /root/Tunnel_Hedioum
bash iran/install-iran.sh --bundle /root/iran-bundle
```
Press **Enter** for every question. ✅ It prints a `vless://…` link.

Import it: **v2rayN** (Windows) → copy link → `Ctrl+V` in the app; **v2rayNG / NekoBox** (Android) → `+` → import from clipboard; **Streisand / V2Box** (iPhone) → `+` → import from clipboard. Connect, open `ifconfig.me`: you should see the **foreign** server's IP. 🎉

Then delete the secret bundle on **both** servers: `rm -rf /root/iran-bundle`

## 6. Users with data limits (panel)
1. On your computer download `https://github.com/MHSanaei/3x-ui/releases/latest/download/x-ui-linux-amd64.tar.gz` and send it to the hub:
   ```
   scp C:\Users\YOU\Downloads\x-ui-linux-amd64.tar.gz root@HUB_IP:/root/
   ```
2. On the hub find Hedioum's SOCKS port (e.g. `40001`):
   ```
   grep local_socks_port /etc/hedioum/hedioum.json
   ```
3. Install the panel (use your number):
   ```
   cd /root/Tunnel_Hedioum/panel
   bash install-panel.sh --tarball /root/x-ui-linux-amd64.tar.gz --socks-port 40001
   ```
   ✅ It prints the panel address, username and password (also saved in `/root/panel-credentials.txt`).
4. Create users:
   ```
   bash add-user.sh ali --monthly 30
   ```
   (30 GB per month, renews itself every 30 days)
   ```
   bash add-user.sh me
   ```
   (unlimited)
   ```
   bash add-user.sh sara --gb 50 --days 60
   ```
   Add `--devices 2` to limit simultaneous devices. Each command prints a link — give it to that user.
5. Manage: `bash list-users.sh` (usage/expiry) · `bash show-link.sh ali` (link again) · `bash remove-user.sh ali`.

Users created without the panel (step 5) have **no** limits; only `add-user.sh` users do.

## 7. More speed (optional)
Hedioum caps each connection at 8 Mbps. On the hub:
```
hedioum-tunnel edit-node --alias KHAREJ --bw 100 --jitter 0 --min 12 --max 30
```
```
systemctl restart hedioum
```
A single download gets ~5× faster, traffic looks less ordinary, and the *total* speed is still shared by everyone (roughly 50 Mbps in our tests; extra nodes to the same server don't add capacity).

## 8. Randomized restarts (optional)
Answer `y` to "Install the randomized-restart timer?" on both servers. It breaks the pattern of a never-ending connection; it does **not** hide what a censor can see on the wire.

## 9. Troubleshooting
| Problem | Fix |
|---|---|
| `Permission denied` | wrong password/key — retry **once** |
| `timed out` / `reset` | probably a temporary ban: wait 5–10 min, try once |
| GitHub unreachable on the hub | normal; send files from your computer with `scp` (steps 3.1 and 6.1) |
| test says **BAD** | change the foreign server (other datacenter/country) |
| connected but no internet | on the hub: `systemctl status hedioum xray-iran` (both `active`), then `systemctl restart hedioum` |
| panel user can't connect | the app must support **Reality + XTLS-Vision** (update v2rayN/NekoBox/Streisand) |
| panel won't open | use the full address incl. the secret path; the provider firewall may block that port |
| nothing works after reboot | wait 2 min, then `systemctl restart hedioum xray-iran x-ui` |

## 10. Safety
Never share links, tokens, panel passwords or keys. Delete `/root/iran-bundle` after installing. Change the panel password. No tool guarantees you won't be detected or blocked.
