#!/bin/bash
# tests/render.sh <out.png> [dir-a dir-b] - render the real Dolphin (split view of two dirs) offscreen with the live shim + generated QSS and save a PNG of the window.
# Needs tools/grab.so (build: g++ -std=c++20 -O2 -fPIC -shared -w $(pkg-config --cflags Qt6Widgets) tools/grab.cpp -o <GRAB_SO>). Env: GRAB_SO, THEMES (default ~/.themes).
# Deterministic enough for before/after pixel comparison of refactors: `cmp golden.png new.png`.
set -euo pipefail
OUT=$(realpath -m "$1"); A=${2:-$HOME}; B=${3:-$HOME}
T=${THEMES:-$HOME/.themes}; GRAB_SO=${GRAB_SO:?set GRAB_SO to the built grab.so}
rm -f "$OUT"
timeout 25 env QT_QPA_PLATFORM=offscreen DBUS_SESSION_BUS_ADDRESS=unix:path=/nonexistent QT_QPA_PLATFORMTHEME=qt6ct \
  GRAB_OUT="$OUT" LD_LIBRARY_PATH="$T/kf6-patched" \
  LD_PRELOAD="$T/kf6-patched/libdolphin-tweaks.so:$T/qt-noicons/libqt-noicons.so:$GRAB_SO" \
  dolphin -stylesheet "$T/dolphin-theme/dolphin-theme.qss" --split --new-window "$A" "$B" >/dev/null 2>&1 || true
[ -s "$OUT" ] && echo "wrote $OUT" || { echo "no image produced"; exit 1; }
