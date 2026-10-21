# Note to whichever Claude session picks this up on Debian

This folder (`~/.local/share/qt-decoration-vendor/` once extracted from the
theme archive) contains a working, already-patched Qt Wayland decoration
plugin - it makes Qt/KDE apps (Konsole, Ark, etc.) get a
custom titlebar under GNOME/Wayland instead of none at all. It was built and
visually verified on Asahi Fedora (aarch64); it needs a fresh compile here
because it's architecture-specific machine code, not because anything about
it is Debian-unfriendly. The source and the 3 personal patches applied to it
are completely portable.

## What to do

1. Install build deps (exact package names may need a quick check against
   whatever Debian/Ubuntu version this is, but these are the right Qt6
   modules): `cmake`, `g++`, `qt6-base-dev`, `qt6-base-private-dev`,
   `qt6-wayland-dev`, `qt6-svg-dev`.
2. Run `./build-and-install.sh` from this directory. It configures, builds,
   and installs the plugin to `~/.themes/qt-plugins/qt6/wayland-decoration-client/`,
   and writes `~/.config/environment.d/qt-deco.conf`.
3. A logout is needed for the environment.d change to take effect for new
   sessions (or set `QT_PLUGIN_PATH`/`QT_WAYLAND_DECORATION` directly in the
   current shell to test one app without logging out).
4. Open a Qt app (Konsole is the easiest test) and confirm: thin titlebar, no
   title text, dark `#1d1d20`-ish background, red/yellow/green traffic-light
   buttons top-left, no title text.

## If it looks visually off

Every visual constant (titlebar height, button width/spacing/margins, the
background color, whether title text shows) is read at runtime from
`~/.config/qwhitesurgtkdecorations.conf` - **no rebuild needed to tune it**,
just edit the file and relaunch the app (or log out). See `whitesur-src/src/qwhitesurgtkdecorations.cpp`'s `loadTweaks()` function for the exact keys, or copy
this reference (already the confirmed-correct values on Asahi, at 2x display
scale there - if Debian's display scale is different, these pixel-derived
numbers may need re-tuning for how it actually looks here):

```
[Titlebar]
Height=32
ButtonWidth=14
ButtonSpacing=8
ButtonMarginLeft=0
ButtonMarginRight=15
ButtonMarginBottom=4
CornerRadius=12
ShadowsWidth=10
BorderWidth=1
BackgroundColor=#1d1d20
ShowTitleText=false
```

**How these were actually derived** (in case something needs re-measuring
here): pixel-sampled directly from real screenshots via Python/Pillow,
comparing raw pixel deltas between builds with known constants rather than
assuming a single screenshot's absolute measurement was correct outright -
one real bug was caught this way (`ceButtonMarginLeft` needed to be `0`, not
a naive halved-pixel-count, because the plugin's own layout formula adds
`ceButtonSpacing` into the first button's position too - a quirk of the
upstream code, not obvious from a single screenshot). If retuning here,
prefer the same decisive-measurement approach over guessing.

## Provenance, if this ever needs re-deriving from scratch

Real upstream: `github.com/FengZhongShaoNian/QWhiteSurGtkDecorations` (a fork
of `github.com/FedoraQt/QAdwaitaDecorations`). The 3 personal patches already
applied in `whitesur-src/src/qwhitesurgtkdecorations.cpp` (search for
`loadTweaks`/`ceShowTitleText`/`ceTitlebarBackgroundDark`): no titlebar text,
thinner titlebar, background color changed - all now runtime-tunable rather
than hardcoded. A `CMakeLists.txt` fix is also included (added `DBus` as an
explicit `find_package`/`target_link_libraries` component) - the upstream
project's build file doesn't declare it despite the source unconditionally
using QtDBus APIs; without this fix the build may fail to link on some
setups.
