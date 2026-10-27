#!/bin/bash
# Extracts a home-theme-setup-*.tar.gz (built by build-theme-archive.sh) into
# a freshly-installed minimal GNOME install, and applies the dconf state.
#
# Assumes the same username as the source machine (confirmed always true).
# Does NOT install or remove any packages - that's distro-specific and TBD.
# Run this AFTER the underlying tools are installed (see the checklist this
# script prints at the end) for the copied config to actually take effect.

set -euo pipefail

if [ $# -ne 1 ]; then
  echo "Usage: $0 <home-theme-setup-archive>.tar.gz" >&2
  exit 1
fi

ARCHIVE="$1"
[ -f "$ARCHIVE" ] || { echo "Not found: $ARCHIVE" >&2; exit 1; }

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

tar -xzf "$ARCHIVE" -C "$STAGE"

echo "== Manifest from source build =="
cat "$STAGE/MANIFEST.txt"
echo

SRC_ARCH=$(grep '^Source host arch:' "$STAGE/MANIFEST.txt" | awk '{print $NF}')
THIS_ARCH=$(uname -m)

echo "== Extracting home files =="
cp -a "$STAGE/home/." "$HOME/"

if [ "$SRC_ARCH" != "$THIS_ARCH" ]; then
  echo "== Architecture mismatch ($SRC_ARCH -> $THIS_ARCH): disabling the Qt decoration plugin env file =="
  if [ -f "$HOME/.config/environment.d/qt-deco.conf" ]; then
    mv "$HOME/.config/environment.d/qt-deco.conf" "$HOME/.config/environment.d/qt-deco.conf.disabled-wrong-arch"
    echo "  Moved aside: ~/.config/environment.d/qt-deco.conf.disabled-wrong-arch"
    echo "  Read ~/.local/share/qt-decoration-vendor/NOTE_TO_DEBIAN_CLAUDE.md and run"
    echo "  its build-and-install.sh to compile the vendored+patched source fresh"
    echo "  for this architecture - it recreates qt-deco.conf itself."
  fi
  rm -rf "$HOME/.themes/qt-plugins/qt6/wayland-decoration-client"
fi

echo "== Loading dconf state =="
dconf load /org/gnome/desktop/interface/ < "$STAGE/dconf/desktop-interface.dconf"
dconf load /org/gnome/desktop/wm/preferences/ < "$STAGE/dconf/wm-preferences.dconf"
dconf load /org/gnome/shell/extensions/ < "$STAGE/dconf/shell-extensions.dconf"

echo "== Enabling GNOME Shell extensions =="
EXT_DIR="$HOME/.local/share/gnome-shell/extensions"
UUIDS=()
for d in "$EXT_DIR"/*@blank.local; do
  [ -d "$d" ] || continue
  UUIDS+=("$(basename "$d")")
done
if [ "${#UUIDS[@]}" -gt 0 ]; then
  LIST=$(printf "'%s', " "${UUIDS[@]}")
  LIST="[${LIST%, }]"
  gsettings set org.gnome.shell enabled-extensions "$LIST"
  echo "  enabled-extensions -> $LIST"
fi

echo "== Refreshing font cache =="
fc-cache -f "$HOME/.local/share/fonts" >/dev/null 2>&1 || true

cat <<'EOF'

== Manual steps still needed (package install/removal is distro-specific, not automated here) ==
  - adw-gtk3-dark (GTK3-matches-libadwaita theme)
  - A Qt style matching your GTK look (e.g. Breeze or Fusion)
  - fonttools (python3-fonttools) only if you ever need to re-extract more static font weights
  - On a different architecture than the source build: cmake, g++, qt6-base-dev,
    qt6-base-private-dev, qt6-wayland-dev, qt6-svg-dev (Debian/Ubuntu names) to
    build the vendored decoration plugin - see
    ~/.local/share/qt-decoration-vendor/NOTE_TO_DEBIAN_CLAUDE.md

A full logout/login is needed afterward for the GNOME Shell extensions and
shell theme to actually take effect - settings values apply live, but the
extensions themselves need a fresh Shell process to load for the first time.
EOF
