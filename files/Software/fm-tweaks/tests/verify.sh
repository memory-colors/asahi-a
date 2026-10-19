#!/bin/bash
# tests/verify.sh - is the installed setup healthy? Exits non-zero on the first failing group; prints one line per check.
#   1. generator: `dolphin-tweaks status` ok, and `apply` twice changes nothing (idempotent)
#   2. shim symbols: every hooked symbol is exported by the installed Dolphin libs
#   3. shim bindings: a throwaway offscreen Dolphin run (LD_DEBUG=bindings) shows every hook bound to the shim
#   (pixel checks are separate: tests/render.sh <out.png> <dirA> <dirB> + tests/compare.py golden.png out.png, see README)
# Needs GRAB_SO (built from tools/grab.cpp, see render.sh) for 3 and 4. Env: THEMES (default ~/.themes), DOLPHIN_TWEAKS_LIBDIR.
set -uo pipefail
R="$(cd "$(dirname "$0")/.." && pwd)"; T=${THEMES:-$HOME/.themes}; LIB=${DOLPHIN_TWEAKS_LIBDIR:-$T/kf6-patched}; SO="$LIB/libdolphin-tweaks.so"
fail=0; ok() { echo "ok    $*"; }; bad() { echo "FAIL  $*"; fail=1; }

# 1 generator
python3 "$R/bin/dolphin-tweaks" status >/dev/null && ok "dolphin-tweaks status" || bad "dolphin-tweaks status (run: dolphin-tweaks apply)"
python3 "$R/bin/dolphin-tweaks" apply --quiet; [ "$(python3 "$R/bin/dolphin-tweaks" apply | tail -1)" = "already in sync, nothing to do." ] && ok "apply is idempotent" || bad "apply changed files on the second run"

# 2 symbols
[ -f "$SO" ] || { bad "shim not installed: $SO (build: shim/build.sh --install)"; exit 1; }
LIBS=$(ldd "$(command -v dolphin)" | awk '/=>/ {print $3}' | grep -E 'dolphin|KF6KIO|KF6Item')
nm -D --defined-only $LIBS 2>/dev/null | awk 'NF == 3 {print $3}' | sort -u > /tmp/dt-avail.$$
HOOKS=$(nm -D --defined-only "$SO" | awk '$2=="T" && $3 ~ /^_ZN/ {print $3}')
miss=0; for s in $HOOKS; do grep -qxF "$s" /tmp/dt-avail.$$ || { echo "      not exported by Dolphin: $s"; miss=1; }; done
[ $miss = 0 ] && ok "all $(echo "$HOOKS" | wc -w) hooked symbols exist in the installed libraries" || bad "hooked symbol(s) missing (Dolphin changed? rebuild: shim/build.sh)"

# 3 bindings in one offscreen run
if [ -z "${GRAB_SO:-}" ]; then echo "skip  bindings (set GRAB_SO)"; rm -f /tmp/dt-avail.$$; exit $fail; fi
D=$(mktemp -d); mkdir -p "$D/a" "$D/b"; touch "$D/a/file.txt" "$D/b/.hidden"
timeout 40 env QT_QPA_PLATFORM=offscreen DBUS_SESSION_BUS_ADDRESS=unix:path=/nonexistent QT_QPA_PLATFORMTHEME=qt6ct GRAB_OUT="$D/w.png" \
  LD_DEBUG=bindings LD_DEBUG_OUTPUT="$D/bind" LD_LIBRARY_PATH="$LIB" LD_PRELOAD="$SO:$T/qt-noicons/libqt-noicons.so:$GRAB_SO" \
  dolphin -stylesheet "$T/dolphin-theme/dolphin-theme.qss" --split --new-window "$D/a" "$D/b" >/dev/null 2>&1
cat "$D"/bind* 2>/dev/null | grep "to $SO" | grep -o "symbol \`[^']*'" | sed "s/symbol \`//;s/'//" | sort -u > "$D/bound"
nb=0; for s in $HOOKS; do grep -qxF "$s" "$D/bound" || { echo "      not bound to the shim: $s"; nb=1; }; done
[ $nb = 0 ] && ok "every hook is bound to the shim at runtime" || bad "hook(s) not bound (see above)"
rm -rf "$D" /tmp/dt-avail.$$
exit $fail
