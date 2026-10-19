# Dolphin dye harness (2026-10-13)

Renders the real Dolphin offscreen (`QT_QPA_PLATFORM=offscreen`) on a THROWAWAY HOME made of copies of the color sources, screenshots itself,
and counts pixels. Your live config is only read (copied/symlinked), never written. Work dir: `~/.cache/dolphin-dye` (safe to delete).

Files: `dye.py` (driver + analysis), `shot.cpp` -> `shot.so` (preload shim: screenshots, simulated hover/current/click/Esc, popups), `build.sh`.
Build once: `./build.sh` (needs g++ + the Qt6 dev headers in ~/.local/share/qt6-dev-sysroot/root, or set QT_ROOT).

    python3 -I dye.py run <name> [flags]     run + analyze every shot      python3 -I dye.py summary <name>   dye roles seen in any shot
    python3 -I dye.py cmp <runA> <runB>      pixel-compare all shots       python3 -I dye.py diff <run> shot-0.ppm shot-1.ppm
    python3 -I dye.py mask <run> shot-0.ppm out.png <hex>...               highlight where given colors appear

Flags: `--kcs-scheme` (dye bluegrey.colors) `--kcs-globals` (kdeglobals) `--qt6ct` (palette) `--qss-global` `--qss-flag` `--breeze` (pathbar)
`--no-scheme` `--no-global-qss` `--menubar` `--split` `--flag-plain` `--qss-flag-file`. Each dyed role gets a unique color; `analyze` maps pixels back to roles.
Env: `DYE_ACTIONS_OVERRIDE` (steps: wait:ms shot sethover:x,y setcurrent:x,y click:x,y esc urledit tooltip menu shotpop deactivate activate action:name quit),
`DYE_SRC_HOME` (copy sources from another home, e.g. a scratch copy), `DYE_SHIM` (test a candidate shim build), `DYE_WORK`, `DYE_SIZE`, `DYE_PLATFORM` (offscreen default; wayland flashes a real window), `DYE_OPEN_DIR` (open this folder instead of the test folders, e.g. a 600-file folder for scroll tests).

Regression recipe (what verified the consolidation): render with no flags before a change (`golden_before`), again after (`golden_after`), `cmp` them.
Use the full step list, e.g. `wait:4500;shot;sethover:500,150;wait:1800;shot;setcurrent:500,204;wait:800;shot;urledit;wait:800;shot;tooltip;wait:600;shotpop;menu;wait:500;shotpop;deactivate;wait:800;shot;quit`.
Two runs of the same state are pixel-identical (only live data such as the status bar's "GiB free" text can differ).
Notes: hover is driven by calling KItemListWidget::setHovered (synthetic window-system hover never reached the item view); clicks/Esc use real
window-system events and DO work for the URL bar. The Terminal panel's colors come from Konsole's own profile, not Dolphin.

Scroll / performance steps (added later the same evening): `flick:<n>` sends a synthetic touchpad flick (ScrollBegin, n ScrollUpdate 8 ms apart, ScrollEnd) over the main file view;
`trace:<ms>` logs (time, scrollbar value) on every UpdateRequest ("F") + every 4 ms ("T") to <run>/trace.txt (start `trace` BEFORE `flick`, folder must be scrollable: use DYE_OPEN_DIR);
`bench:<N>` times N full paints of the file-view viewport (per-frame cost of the shim hooks: 0.48 ms each with the overhaul shim AND with the pre-overhaul one = no measurable overhead).
Offscreen UpdateRequest cadence is ~6 ms (a timer), not vsync, so trace tells you "one position step per frame, no 0/2 pattern", not real display smoothness.
