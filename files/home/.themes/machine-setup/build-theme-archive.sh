#!/bin/bash
# Builds a distro/arch-agnostic archive of everything theming-related in $HOME,
# for extraction into a freshly-installed minimal GNOME install (Debian x86_64
# or Fedora/Asahi aarch64) via restore-theme-archive.sh.
#
# Only ever run this ON the source machine (the one with the real setup).
# Package installation/removal is deliberately NOT part of this - that's
# distro-specific and handled separately. This script only packs portable
# config/data files plus a dconf dump.

set -euo pipefail

OUT_DIR=~/.themes/machine-setup/archives
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

mkdir -p "$OUT_DIR"
mkdir -p "$STAGE/home"

echo "== Staging home-relative paths =="

# Paths are relative to $HOME. Whitelist, not blacklist - deliberately explicit
# about what's portable rather than trying to exclude machine-specific cruft
# from a much bigger "everything" copy.
INCLUDE_PATHS=(
  ".config/gtk-3.0"
  ".config/gtk-4.0"
  ".config/qt5ct"
  ".config/qt6ct"
  ".config/dolphinrc"
  ".config/konsolerc"
  ".config/kdeglobals"
  ".themes/dolphin-theme"
  ".config/mimeapps.list"
  ".config/environment.d/qt-deco.conf"
  ".config/qwhitesurgtkdecorations.conf"
  ".local/share/color-schemes"
  ".local/share/applications/org.kde.dolphin.desktop"
  ".local/share/fonts"
  ".local/share/libgedit-gtksourceview-300/styles"
  ".themes/Adwaita-custom"
  ".themes/qt-plugins/qt6/wayland-decoration-client"
)

for rel in "${INCLUDE_PATHS[@]}"; do
  src="$HOME/$rel"
  if [ -e "$src" ]; then
    mkdir -p "$STAGE/home/$(dirname "$rel")"
    # -L: gtk/qt/kde dirs and kdeglobals now live in ~/.themes behind symlinks (2026-10-05) - archive the CONTENT
    cp -aL "$src" "$STAGE/home/$rel"
    echo "  + $rel"
  else
    echo "  ! MISSING (skipped): $rel"
  fi
done

echo "== Staging GNOME Shell extension forks (*@blank.local) =="
mkdir -p "$STAGE/home/.local/share/gnome-shell/extensions"
shopt -s nullglob
for ext in ~/.local/share/gnome-shell/extensions/*@blank.local; do
  uuid=$(basename "$ext")
  cp -a "$ext" "$STAGE/home/.local/share/gnome-shell/extensions/$uuid"
  echo "  + extensions/$uuid"
done
shopt -u nullglob

echo "== Staging unpackaged icon/cursor themes (re-homed from /usr/share to ~/.local/share/icons) =="
mkdir -p "$STAGE/home/.local/share/icons"
for icon_dir in /usr/share/icons/MacTahoe-* /usr/share/icons/Bibata-*; do
  [ -d "$icon_dir" ] || continue
  name=$(basename "$icon_dir")
  if rpm -qf "$icon_dir" >/dev/null 2>&1; then
    echo "  ! SKIPPED (package-owned, not portable as a raw copy): $name"
    continue
  fi
  cp -a "$icon_dir" "$STAGE/home/.local/share/icons/$name"
  echo "  + icons/$name"
done

echo "== Staging vendored Qt decoration plugin source (arch-agnostic, needs a rebuild on the target) =="
VENDOR_SRC=~/.themes/machine-setup/qt-decoration-vendor
if [ -d "$VENDOR_SRC" ]; then
  mkdir -p "$STAGE/home/.local/share/qt-decoration-vendor"
  cp -a "$VENDOR_SRC/build-and-install.sh" "$STAGE/home/.local/share/qt-decoration-vendor/"
  cp -a "$VENDOR_SRC/NOTE_TO_DEBIAN_CLAUDE.md" "$STAGE/home/.local/share/qt-decoration-vendor/"
  mkdir -p "$STAGE/home/.local/share/qt-decoration-vendor/whitesur-src"
  # Exclude build/ - it's a compiled-for-this-arch directory, not portable,
  # and the whole point is to rebuild fresh on the target with build-and-install.sh.
  (cd "$VENDOR_SRC/whitesur-src" && tar -cf - --exclude=build --exclude=.git .) | (cd "$STAGE/home/.local/share/qt-decoration-vendor/whitesur-src" && tar -xf -)
  echo "  + qt-decoration-vendor/ (patched source + build-and-install.sh, no build/ dir)"
fi

echo "== Dumping theming-relevant dconf state =="
mkdir -p "$STAGE/dconf"
dconf dump /org/gnome/desktop/interface/ > "$STAGE/dconf/desktop-interface.dconf"
dconf dump /org/gnome/desktop/wm/preferences/ > "$STAGE/dconf/wm-preferences.dconf"
dconf dump /org/gnome/shell/extensions/ > "$STAGE/dconf/shell-extensions.dconf"

ARCH=$(uname -m)
DECO_PRESENT="no"
[ -d "$HOME/.themes/qt-plugins/qt6/wayland-decoration-client" ] && DECO_PRESENT="yes"

cat > "$STAGE/MANIFEST.txt" <<EOF
Built: $(date -Iseconds)
Source host arch: $ARCH
Qt Wayland decoration plugin included: $DECO_PRESENT (binary, compiled for $ARCH -
  will NOT load on a different architecture; restore-theme-archive.sh checks
  uname -m before wiring up its environment.d file)

On a non-$ARCH target (e.g. Debian x86_64), this compiled binary can't be
reused as-is - but the fix is already done, not just planned: the real
upstream (github.com/FengZhongShaoNian/QWhiteSurGtkDecorations, a fork of
github.com/FedoraQt/QAdwaitaDecorations) is vendored + patched at
~/.local/share/qt-decoration-vendor/whitesur-src/ (shipped in this same
archive), with all 3 personal mods applied directly in source: no titlebar
text, thinned titlebar, background color #1d1d20 - plus every one of those
(height/button size/spacing/margins/color/title-text) now reads from
~/.config/qwhitesurgtkdecorations.conf at runtime, so future tweaks are a
config edit + relaunch, not a rebuild. This exact source was built and
visually verified (via direct pixel measurement against a screenshot) on
Asahi aarch64 - proven, not a guess. On any target: install the Qt6/Wayland
dev packages (Debian/Ubuntu: qt6-base-dev, qt6-base-private-dev,
qt6-wayland-dev, qt6-svg-dev, cmake, g++), then run
~/.local/share/qt-decoration-vendor/build-and-install.sh.

NOT included, by design:
- Any package installation/removal (dnf/apt) - TBD, distro-specific, handled
  separately, not by this archive.
- Brave/Chromium profile data - full profile dirs contain history, cookies,
  saved passwords, etc; not safe to blanket-copy into a portable archive.
  Needs its own narrowly-scoped pass if/when specific theme-relevant Brave
  settings are identified.
- Anything under /usr/share (system-owned, package-managed) that IS owned by
  an RPM/dpkg - only genuinely unpackaged, manually-installed assets were
  re-homed into ~/.local/share for portability.

Restore with: restore-theme-archive.sh <this-archive>.tar.gz
Assumes the same username on the target machine (confirmed always true).
EOF

TS=$(date +%Y%m%d-%H%M%S)
ARCHIVE="$OUT_DIR/home-theme-setup-$TS.tar.gz"
tar -czf "$ARCHIVE" -C "$STAGE" .

# Keep only the latest, same retention convention as the other backup scripts
# in this project.
find "$OUT_DIR" -maxdepth 1 -name 'home-theme-setup-*.tar.gz' ! -name "$(basename "$ARCHIVE")" -delete

echo
echo "Done: $ARCHIVE"
