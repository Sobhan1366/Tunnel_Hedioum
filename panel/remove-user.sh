#!/usr/bin/env bash
# remove-user.sh NAME — delete a user (their link stops working).
# To print a user's link again use show-link.sh NAME.
exec python3 "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/panel_tool.py" remove "$@"
