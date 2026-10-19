#!/bin/bash
# shim/build.sh [--install] - build libdolphin-tweaks.so against the INSTALLED Dolphin's version, then preflight it.
#  * version: `dolphin --version` (override: DOLPHIN_VERSION=26.08.1); the matching source tarball supplies the private kitemviews headers
#    (cached in ~/.cache/dolphin-tweaks/src; override with DOLPHIN_SRC=<unpacked dolphin-X.Y.Z dir>). Needs Qt6 headers (Fedora: qt6-qtbase-devel,
#    qt6-qtbase-private-devel; Debian: qt6-base-dev) and a C++20 compiler.
#  * preflight: every symbol the shim hooks must be exported by the installed Dolphin libraries (a wrong/renamed one would hook nothing, silently).
#  * --install: copy to $DOLPHIN_TWEAKS_LIBDIR (default ~/.themes/kf6-patched) via a temp name + mv -f (never overwrite a loaded .so in place).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LIBDIR="${DOLPHIN_TWEAKS_LIBDIR:-$HOME/.themes/kf6-patched}"
BUILD="$HERE/build"; mkdir -p "$BUILD"
VER="${DOLPHIN_VERSION:-$(dolphin --version 2>/dev/null | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -1)}"
[ -n "$VER" ] || { echo "cannot determine the Dolphin version (set DOLPHIN_VERSION)"; exit 1; }
SRC="${DOLPHIN_SRC:-}"
if [ -z "$SRC" ]; then
    CACHE="$HOME/.cache/dolphin-tweaks/src"; mkdir -p "$CACHE"
    SRC="$CACHE/dolphin-$VER"
    if [ ! -d "$SRC" ]; then
        echo "fetching dolphin-$VER source (private headers only)..."
        URL="https://download.kde.org/stable/release-service/$VER/src/dolphin-$VER.tar.xz"
        TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
        curl -fsSL "$URL" -o "$TMP/src.tar.xz"; curl -fsSL "$URL.sha256" -o "$TMP/src.sha256"
        [ "$(sha256sum "$TMP/src.tar.xz" | cut -d' ' -f1)" = "$(cut -d' ' -f1 "$TMP/src.sha256")" ] || { echo "sha256 mismatch for $URL"; exit 1; }
        tar -xJ -C "$TMP" -f "$TMP/src.tar.xz" && mv "$TMP/dolphin-$VER" "$SRC"     # published only once complete and verified
    fi
fi
[ -f "$SRC/src/kitemviews/kstandarditemlistwidget.h" ] || { echo "no Dolphin source at $SRC"; exit 1; }
mkdir -p "$BUILD/stub"; echo '#define DOLPHIN_EXPORT' > "$BUILD/stub/dolphin_export.h"
OUT="$BUILD/libdolphin-tweaks.so"
echo "building for Dolphin $VER ..."
g++ -std=c++20 -O2 -fPIC -shared -w -DDT_TESTED_VERSIONS="\"$VER\"" -I"$BUILD/stub" -I"$SRC/src" -I"$HERE" \
    $(pkg-config --cflags Qt6Widgets) "$HERE"/*.cpp -o "$OUT"
# ---- preflight: hooked symbols vs the installed Dolphin libraries
LIBS=$(ldd "$(command -v dolphin)" | awk '/=>/ {print $3}' || true)
AVAIL="$BUILD/available-symbols.txt"
nm -D --defined-only $LIBS 2>/dev/null | awk 'NF == 3 {sub(/@.*/, "", $3); print $3}' | sort -u > "$AVAIL"
missing=0
for sym in $(nm -D --defined-only "$OUT" | awk '$2=="T" && $3 ~ /^_ZN/ {print $3}'); do
    grep -qxF "$sym" "$AVAIL" || { echo "PREFLIGHT: $sym is not exported by the installed Dolphin libs (hook would do nothing)"; missing=1; }
done
# ... and everything the shim IMPORTS (e.g. DolphinView::isActive) must still exist, or the first call would abort Dolphin
for sym in $(nm -D --undefined-only "$OUT" | awk '$3 ~ /^_ZN/ || $2 ~ /^_ZN/ {print ($3 != "" ? $3 : $2)}' | sed 's/@.*//'); do
    grep -qxF "$sym" "$AVAIL" || { echo "PREFLIGHT: imported $sym is not exported by any library Dolphin loads"; missing=1; }
done
[ "$missing" = 0 ] && echo "preflight ok: every hooked symbol exists in the installed libraries" || exit 2
if [ "${1:-}" = "--install" ]; then
    mkdir -p "$LIBDIR"; cp "$OUT" "$LIBDIR/libdolphin-tweaks.so.new" && mv -f "$LIBDIR/libdolphin-tweaks.so.new" "$LIBDIR/libdolphin-tweaks.so"
    echo "installed $LIBDIR/libdolphin-tweaks.so"
else
    echo "built $OUT (use --install to deploy)"
fi
