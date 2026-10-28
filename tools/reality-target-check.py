#!/usr/bin/env python3
"""Prints key=value fields for the monitor: can THIS host reach the Reality "target" of every
x-ui/xray inbound?

Why it exists: for every new client handshake xray opens a TCP connection to the target site and
relays the TLS exchange. If the hub cannot reach that site (its IP is blocked from this host, the
site is down...), every client of the inbound just times out while the tunnel and all services
still look healthy. This check turns that silent failure into a visible one.

  reality_targets=<distinct targets>  reality_fail=<unreachable>  reality_stuck=<xray sockets in SYN-SENT>
  reality_bad=<host:port,...|->
"""
import json
import socket
import subprocess
import sys

CFG = sys.argv[1] if len(sys.argv) > 1 else "/usr/local/x-ui/bin/config.json"


def targets(path):
    seen = []
    try:
        cfg = json.load(open(path))
    except Exception:
        return seen
    for ib in cfg.get("inbounds", []):
        rs = (ib.get("streamSettings") or {}).get("realitySettings") or {}
        tgt = str(rs.get("target") or rs.get("dest") or "")
        if not tgt or tgt[0] in "/@":          # unix socket / abstract socket: nothing to dial
            continue
        host, _, port = tgt.rpartition(":")
        if not host:
            host, port = tgt, "443"
        key = (host.strip("[]"), int(port) if port.isdigit() else 443)
        if key not in seen:
            seen.append(key)
    return seen


def reachable(host, port):
    try:
        socket.create_connection((host, port), timeout=3).close()
        return True
    except OSError:
        return False


def stuck_sockets():
    try:
        out = subprocess.run(["ss", "-tnpH", "state", "syn-sent"], capture_output=True, text=True, timeout=5).stdout
    except Exception:
        return 0
    return sum(1 for ln in out.splitlines() if "xray" in ln)


tg = targets(CFG)
bad = ["%s:%d" % t for t in tg if not reachable(*t)]
print("reality_targets=%d reality_fail=%d reality_stuck=%d reality_bad=%s"
      % (len(tg), len(bad), stuck_sockets(), ",".join(bad) or "-"))
