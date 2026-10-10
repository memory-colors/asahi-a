#!/bin/bash
# shift-neutral-grey-blue.sh - thin wrapper around shift_neutral_grey_blue.py.
# The shift is now REMEMBERED (grey-shift-state.json) so it can be retuned:
#   ./shift-neutral-grey-blue.sh --status
#   ./shift-neutral-grey-blue.sh --adopt 4 --dry-run   # files already shifted by 4: preview
#   ./shift-neutral-grey-blue.sh --adopt 4
#   ./shift-neutral-grey-blue.sh --set 6               # absolute, safe to repeat; 0 = original greys
#   ./shift-neutral-grey-blue.sh --fresh 4             # first run on UNSHIFTED files
#   ./shift-neutral-grey-blue.sh --rescan              # record greys added since tracking began
# (the previous one-shot version is kept as shift-neutral-grey-blue.sh.orig-oneshot)
exec python3 "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/shift_neutral_grey_blue.py" "$@"
