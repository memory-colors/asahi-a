#!/bin/bash
# Builds the vendored/patched QWhiteSurGtkDecorations plugin (whitesur-src/)
# and installs it to the standard per-user Qt6 Wayland decoration plugin path.
# Works on any architecture with the Qt6/Wayland dev packages installed -
# this is the actual, proven recipe (built and visually verified on Asahi
# aarch64), not a guess. On Debian, the package names differ but the
# CMake/find_package requirements are identical: Qt6 Core/DBus/Gui/Svg/
# WaylandClient/Widgets + their Private variants, plus cmake and a C++
# compiler (e.g. qt6-base-dev, qt6-base-private-dev, qt6-wayland-dev,
# qt6-svg-dev, cmake, g++ on Debian/Ubuntu).

set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/whitesur-src" && pwd)"
DECO_DIR=~/.themes/qt-plugins/qt6/wayland-decoration-client
ENV_CONF=~/.config/environment.d/qt-deco.conf

cmake -B "$SRC_DIR/build" -S "$SRC_DIR" -DUSE_QT6=ON -DCMAKE_BUILD_TYPE=Release
cmake --build "$SRC_DIR/build" -j"$(nproc)"

mkdir -p "$DECO_DIR"
cp "$SRC_DIR/build/src/libqwhitesurgtkdecorations.so" "$DECO_DIR/libqwhitesurgtkdecorations.so"

mkdir -p "$(dirname "$ENV_CONF")"
cat > "$ENV_CONF" <<EOF
QT_PLUGIN_PATH=$HOME/.themes/qt-plugins/qt6
QT_WAYLAND_DECORATION=whitesur-gtk
EOF

echo
echo "Installed: $DECO_DIR/libqwhitesurgtkdecorations.so"
echo "Wrote: $ENV_CONF"
echo "Tunables (height/button size/spacing/margins/color/title-text) live in:"
echo "  ~/.config/qwhitesurgtkdecorations.conf (see whitesur-src's loadTweaks() for keys)"
echo
echo "A logout (or at minimum restarting Qt apps already running) is needed"
echo "for the environment.d change and any already-loaded plugin to update -"
echo "see live_swap_feedback.md if testing without a logout."
