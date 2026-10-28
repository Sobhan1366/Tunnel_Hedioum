#!/bin/bash
# Hub-side monitor: one summary line every 60 s in /var/log/tunnel-monitor/hedioum_summary.log
# (the dashboard reads this file) plus the raw hedioum/xray journal of the last interval.
# Needs: hedioum.service, xray-iran.service, the hub's local SOCKS5 on 127.0.0.1:40007.
# Optional: /usr/local/bin/reality-target-check.py (adds reality_* fields).

SUMMARY="/var/log/tunnel-monitor/hedioum_summary.log"
RAW="/var/log/tunnel-monitor/hedioum_raw_events.log"
SOCKS="${HEDIOUM_SOCKS:-127.0.0.1:40007}"
mkdir -p /var/log/tunnel-monitor

echo "=== hedioum monitor started $(date '+%Y-%m-%d %H:%M:%S') ===" >> "$SUMMARY"
echo "=== hedioum monitor started $(date '+%Y-%m-%d %H:%M:%S') ===" >> "$RAW"

while true; do
  ts=$(date '+%Y-%m-%d %H:%M:%S')

  iran_hedioum=$(systemctl is-active hedioum.service 2>/dev/null)
  iran_xray=$(systemctl is-active xray-iran.service 2>/dev/null)
  # the exit IP seen THROUGH the tunnel; empty = hub -> foreign path is down
  exit_ip=$(curl -s --max-time 10 --socks5-hostname "$SOCKS" http://checkip.amazonaws.com 2>/dev/null)

  # plain TCP-connect timing to the local VLESS+WS port (a WebSocket upgrade would hang curl)
  t0=$(date +%s%N)
  if timeout 5 bash -c "cat < /dev/null > /dev/tcp/127.0.0.1/2100" 2>/dev/null; then ws_code=200; else ws_code=000; fi
  t1=$(date +%s%N)
  ws_ms=$(( (t1 - t0) / 1000000 ))

  vless_conns=$(ss -tn state established '( sport = :2100 )' | tail -n +2 | wc -l)

  # most recent pool sizes reported by hedioum itself
  pool_line=$(journalctl -u hedioum.service --no-pager -n 200 2>/dev/null | grep -E 'scaled (up|down)' | tail -1)
  udp_active=$(echo "$pool_line" | grep -oP 'pool=udp active=\K[0-9]+')
  tcp_active=$(echo "$pool_line" | grep -oP 'pool=tcp active=\K[0-9]+')

  # dead-pool / re-warm events in the last interval: early distress signal
  distress=$(journalctl -u hedioum.service --since '-70 sec' --no-pager 2>/dev/null | grep -cE 'purged dead physical connection|re-warming')

  # can the hub reach the Reality target of every inbound? (see reality-target-check.py)
  reality=""
  [ -x /usr/local/bin/reality-target-check.py ] && reality=$(timeout 20 /usr/local/bin/reality-target-check.py 2>/dev/null)

  iran_uptime=$(systemctl show hedioum.service -p ActiveEnterTimestamp --value 2>/dev/null)

  echo "$ts iran_hedioum=$iran_hedioum iran_xray=$iran_xray kharej_hedioum=$exit_ip ws2100_code=$ws_code ws2100_ms=$ws_ms vless_conns=$vless_conns udp_active=${udp_active:-NA} tcp_active=${tcp_active:-NA} distress_events=$distress $reality iran_since=[$iran_uptime] kharej_since=[n/a]" >> "$SUMMARY"

  {
    echo "--- $ts iran hedioum journal ---"
    journalctl -u hedioum.service --since '-70 sec' --no-pager 2>/dev/null
    echo "--- $ts iran xray journal ---"
    journalctl -u xray-iran.service --since '-70 sec' --no-pager 2>/dev/null
  } >> "$RAW"

  sleep 60
done
