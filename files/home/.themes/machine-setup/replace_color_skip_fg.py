#!/usr/bin/env python3
"""
replace_color_skip_fg.py <hex|dec> <file> <old_value> <new_value>

Replaces every occurrence of old_value with new_value in file, EXCEPT on
lines whose key/variable name indicates a foreground/text/font color role
(GTK's `*_fg_color`, Qt/KDE's `Foreground*`/`*Text*` keys, etc).

Written 2026-10-01 after a real incident: set-dark-background.sh's old
blind whole-file sed replace swept up a foreground/text color that happened
to coincidentally equal the background hex at the time, turning fonts
invisible (dark-grey-on-dark-grey) until manually found and fixed in the
conf files. Both set-dark-background.sh and set-light-background.sh now
route their file edits through this script instead of a bare `sed -i`.

Lines inside KNOMADIC BEGIN/END blocks are skipped (added 2026-10-18).
Mode "hex": case-insensitive substring replace (matches old sed's `gI`).
Mode "dec": exact substring replace (decimal RGB, case doesn't apply).
"""
import re
import sys

FG_PATTERN = re.compile(r'fg[_-]?color|foreground|text[_-]?color|\btext\b', re.IGNORECASE)

# Qt QSS's text-color property is a bare `color:` with no prefix at all -
# none of the GTK/KDE-style names above would catch it. Anchored to the
# start of the (stripped) line so it doesn't also match `background-color:`
# or `border-color:`, which legitimately should be replaceable.
QSS_TEXT_COLOR_PATTERN = re.compile(r'^\s*color\s*:', re.IGNORECASE)

def main():
    mode, path, old_val, new_val = sys.argv[1:5]
    lines = open(path).readlines()
    changed = 0
    in_block = False   # lines inside a `KNOMADIC: <name> BEGIN ... END` block belong to one app/role (Text Editor, titlebars...): never swept
    for i, line in enumerate(lines):
        if 'KNOMADIC:' in line and re.search(r'\bBEGIN\b', line):
            in_block = True
        if in_block:
            if 'KNOMADIC:' in line and re.search(r'\bEND\b', line):
                in_block = False
            continue
        if FG_PATTERN.search(line) or QSS_TEXT_COLOR_PATTERN.match(line):
            continue
        if mode == 'hex':
            new_line, n = re.subn(re.escape(old_val), new_val, line, flags=re.IGNORECASE)
        else:
            new_line, n = re.subn(re.escape(old_val), new_val, line)
        if n:
            lines[i] = new_line
            changed += n
    open(path, 'w').writelines(lines)
    if changed == 0:
        print(f"    (no changes - no match outside foreground/text lines)")

if __name__ == '__main__':
    main()
