#!/usr/bin/env bash
# show-link.sh NAME — print a user's link again (and a QR code if `qrencode` is installed).
exec python3 "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/panel_tool.py" link "$@"
