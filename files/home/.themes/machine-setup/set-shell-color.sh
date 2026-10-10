#!/bin/bash
# set-shell-color.sh <role> <new-hex-color>
#
# Sets one of 6 independent GNOME Shell quick-settings/calendar color roles,
# defined as explicit literal overrides in
# ~/.themes/Adwaita-custom/gnome-shell/gnome-shell.css (loaded by Knomadic's theme loader).
#
# These are NOT derived from GNOME Shell's own stock st-mix() formulas -
# real selectors confirmed 2026-10-01 by extracting gnome-shell-dark.css
# from /usr/share/gnome-shell/gnome-shell-theme.gresource and reading it
# directly. Deliberately placed OUTSIDE the grey-shift-auto-generated block
# in that file, so a future shift-neutral-grey-blue.sh run never touches
# them (per explicit user request - these roles must stay independent of
# any global grey-shift sweep).
#
# Each role edits only its own specific selector block(s) - never a blind
# file-wide hex replace (two roles, qs-background and calendar-background,
# currently happen to share the same literal value, so blind replace would
# silently cross-wire them).
#
# Roles:
#   qs-background       - .quick-settings / .quick-toggle-menu popover bg
#   qs-buttons           - ALL round icon buttons inside the QS popover (header row,
#                          slider-row speaker/> buttons, split-toggle arrows)
#   qs-widgets            - slider widget (volume/brightness) trough
#   qs-inactive          - "off" state of QS toggles (+ battery pill); a marked block
#                          (qs-inactive-toggle) with hover/active/focus shades derived
#                          from this one color - ALL its occurrences are replaced
#   calendar-background  - #calendarArea / .datemenu-popover bg
#   calendar-banners     - date header, "Today/No Events", "Add World Clocks..." and weather boxes
#   calendar-buttons     - day-number pills in the calendar grid
#   calendar-headers     - month label, prev/next arrows, weekday letters (marked block)
#
# Usage: ./set-shell-color.sh <role> <new-hex-color>
#   e.g. ./set-shell-color.sh qs-buttons 48484b

set -euo pipefail

# SHELL_CSS override exists so isolation tests can run against a scratch copy
CSS="${SHELL_CSS:-$HOME/.themes/Adwaita-custom/gnome-shell/gnome-shell.css}"

declare -A ANCHORS=(
    [qs-background]=".quick-settings,\n.quick-settings .background {|.quick-toggle-menu,\n.quick-toggle-menu .background {"
    [qs-buttons]=".quick-settings .icon-button {"
    [qs-widgets]=".quick-slider {"
    [calendar-background]="#calendarArea,\n.datemenu-popover,\n.datemenu-calendar-column {|.datemenu-popover {\n    border-color:"
    [calendar-banners]=".datemenu-today-button,\n.world-clocks-button,\n.events-button,\n.weather-button {"
    [qs-inactive]="BLOCK:qs-inactive-toggle"
    [calendar-headers]="BLOCK:calendar-headers"
    [calendar-buttons]=".calendar .calendar-day {"
)

if [ $# -lt 1 ]; then
    echo "Usage: $0 <role> <new-hex-color>"
    echo "  roles: ${!ANCHORS[@]}"
    exit 1
fi

ROLE="$1"
if [ -z "${ANCHORS[$ROLE]+x}" ]; then
    echo "Error: unknown role '$ROLE'. Valid roles: ${!ANCHORS[@]}" >&2
    exit 1
fi

if [ "${2:-}" == "--get" ]; then
    python3 - "$CSS" "${ANCHORS[$ROLE]}" <<'PYEOF'
import re, sys
path, anchors_raw = sys.argv[1], sys.argv[2]
text = open(path).read()
anchors = [a.replace('\\n', '\n') for a in anchors_raw.split('|')]
if anchors[0].startswith('BLOCK:'):
    name = anchors[0][6:]
    b = re.search(r'/\* BEGIN ' + name + r'.*?/\* END ' + name + r' \*/', text, re.S)
    m = re.search(r'background-color: #([0-9a-fA-F]{6})', b.group(0)) if b else None
    if m:
        print(m.group(1).lower())
    sys.exit(0)
for anchor in anchors:
    idx = text.find(anchor)
    if idx == -1:
        continue
    m = re.search(r'#([0-9a-fA-F]{6})', text[idx:idx+300])
    if m:
        print(m.group(1).lower())
        break
PYEOF
    exit 0
fi

if [ $# -ne 2 ]; then
    echo "Usage: $0 <role> <new-hex-color>"
    echo "  roles: ${!ANCHORS[@]}"
    exit 1
fi

NEW_HEX="${2#\#}"
NEW_HEX="${NEW_HEX,,}"
if ! [[ "$NEW_HEX" =~ ^[0-9a-f]{6}$ ]]; then
    echo "Error: '$2' doesn't look like a valid 6-digit hex color." >&2
    exit 1
fi

if [ ! -f "$CSS" ]; then
    echo "Error: $CSS not found - is this the right machine?" >&2
    exit 1
fi

BACKUP_SUFFIX=".bak-pre-${ROLE}-${NEW_HEX}"
cp "$CSS" "${CSS}${BACKUP_SUFFIX}"

python3 - "$CSS" "${ANCHORS[$ROLE]}" "$NEW_HEX" "$ROLE" <<'PYEOF'
import re, sys
path, anchors_raw, new_hex, role = sys.argv[1:5]
anchors = [a.replace('\\n', '\n') for a in anchors_raw.split('|')]
text = open(path).read()
changed = 0
if anchors[0].startswith('BLOCK:'):
    name = anchors[0][6:]
    b = re.search(r'/\* BEGIN ' + name + r'.*?/\* END ' + name + r' \*/', text, re.S)
    if not b:
        print(f"  Warning: block '{name}' not found - file structure may have changed.")
        sys.exit(0)
    blk = b.group(0)
    old = re.search(r'background-color: #([0-9a-fA-F]{6})', blk).group(1)
    # mask the accent-mix fragments so only the role color is replaced
    masks = re.findall(r'st-mix\(#[0-9a-fA-F]{6}, #ffffff, 60%\)', blk)
    for i, mk in enumerate(masks):
        blk = blk.replace(mk, f'@@MASK{i}@@')
    blk, n = re.subn('#' + old, '#' + new_hex, blk, flags=re.I)
    for i, mk in enumerate(masks):
        blk = blk.replace(f'@@MASK{i}@@', mk)
    text = text[:b.start()] + blk + text[b.end():]
    open(path, 'w').write(text)
    print(f"  {role}: updated to #{new_hex} ({n} occurrence(s) in block {name})")
    sys.exit(0)
for anchor in anchors:
    idx = text.find(anchor)
    if idx == -1:
        continue
    window = text[idx:idx+300]
    new_window, n = re.subn(r'#[0-9a-fA-F]{6}', f'#{new_hex}', window, count=1)
    if n:
        text = text[:idx] + new_window + text[idx+300:]
        changed += n
if changed == 0:
    print(f"  Warning: no anchor matched for role '{role}' - file structure may have changed.")
else:
    open(path, 'w').write(text)
    print(f"  {role}: updated to #{new_hex} ({changed} block(s))")
PYEOF

echo
echo "Done. Log out and back in to apply shell theme changes."
