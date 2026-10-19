#!/bin/bash
# Builds shot.so (the in-process screenshot/input shim). Needs g++ and Qt6 dev headers (Widgets + QtGui private headers for
# qpa/qwindowsysteminterface.h). Default header root: the private sysroot used for the Dolphin shim builds; override with QT_ROOT.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
R="${QT_ROOT:-$HOME/.local/share/qt6-dev-sysroot/root}"
export PKG_CONFIG_PATH="$R/usr/lib/x86_64-linux-gnu/pkgconfig" PKG_CONFIG_SYSROOT_DIR="$R"
Q="$R/usr/include/x86_64-linux-gnu/qt6"
g++ -std=c++20 -O2 -fPIC -shared -w $(pkg-config --cflags Qt6Widgets) -I"$Q/QtGui/6.11.2" -I"$Q/QtGui/6.11.2/QtGui" -I"$Q/QtCore/6.11.2" \
    "$HERE/shot.cpp" -o "$HERE/shot.so"
echo "built $HERE/shot.so"
