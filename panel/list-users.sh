#!/usr/bin/env bash
# list-users.sh — show every user with usage, expiry and when they were last seen.
exec python3 "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/panel_tool.py" list
