#!/bin/bash
# fm-color.sh <key> <hex|--get> - the ONE entry point Knomadic's color rows call (it runs `/bin/bash <script> <args> --get|<hex>`).
# Forwards to `fm-tweaks color`; see `fm-tweaks list` for the keys. Restart Thunar to apply.
exec python3 "$(dirname "$(readlink -f "$0")")/fm-tweaks" color "$@"
