#!/usr/bin/env bash
# add-user.sh — create a user and print the link to give them.
#
#   bash add-user.sh NAME                      unlimited data, never expires
#   bash add-user.sh NAME --monthly 30         30 GB per month, renews itself every 30 days
#   bash add-user.sh NAME --gb 50 --days 60    50 GB total, expires after 60 days
#   bash add-user.sh NAME --gb 20 --days 30 --renew 30
#   add  --devices 2   to allow at most 2 devices at the same time
#
# NAME may contain letters, digits, - and _ (it must be unique).
exec python3 "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/panel_tool.py" add-user "$@"
