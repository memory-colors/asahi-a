#!/bin/bash
# Knomadic runs scripts with /bin/bash; the logic is Python.
exec python3 "$(dirname "$(readlink -f "$0")")/set-terminal-color.py" "$@"
