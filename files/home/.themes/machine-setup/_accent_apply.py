#!/usr/bin/env python3
"""
_accent_apply.py <old_hex> <new_hex> [--decoration-only] [--dry-run]

Scoped accent edits (replaces the blind `sed s/OLD/NEW/g` calls in set-accent-color.sh):
  1. GTK3/GTK4 css: whole-hex replace OLD->NEW, but ONLY outside /* comments */ and outside
     `/* KNOMADIC: <name> BEGIN ... END */` marked blocks (those belong to other roles, e.g. the text editor).
     These files are cooked copies of libadwaita where each literal belongs to exactly one role, so a value
     replace is acceptable here with those exclusions.
  2. dolphin-theme.qss: ONLY the `QMenu::item:selected` rule (background-color + selection-background-color),
     via _qss_rule_edit.py.
  3. KDE color files, by [section] + key (never by value alone):
       bluegrey.colors  [Colors:Selection] BackgroundNormal/BackgroundAlternate/DecorationFocus  (only if == OLD)
       bluegrey.colors + kdeglobals  DecorationFocus and DecorationHover in EVERY section -> accent
         (user ruling 2026-10-05: the overlap with the accent is intentional; they must carry the accent value)
qt6ct's positional Highlight edit stays in set-accent-color.sh. SMPlayer's qt5ct palette is NOT touched.
HOME is honoured (tests run against a fake HOME).
"""
import os, re, shutil, subprocess, sys

args = [a for a in sys.argv[1:] if not a.startswith('--')]
old, new = args[0].lower(), args[1].lower()
DEC_ONLY = '--decoration-only' in sys.argv
DRY = '--dry-run' in sys.argv
H = os.path.expanduser('~')
HERE = os.path.dirname(os.path.realpath(__file__))
BAK = f'.bak-pre-accent-{new}'


def dec(h): return '%d,%d,%d' % (int(h[:2], 16), int(h[2:4], 16), int(h[4:6], 16))


def write(path, text, label):
    if DRY:
        print(f'  [dry-run] would update {label}: {path}')
        return
    shutil.copy(path, path + BAK)
    open(path, 'w').write(text)
    print(f'  updated {label}: {path}')


# ---- 1. CSS (skip comments + KNOMADIC blocks) ----
def protected_spans(text):
    spans = []
    for m in re.finditer(r'/\* KNOMADIC: (\S+) BEGIN.*?END \*/', text, re.S):
        spans.append((m.start(), m.end()))
    for m in re.finditer(r'/\*.*?\*/', text, re.S):
        spans.append((m.start(), m.end()))
    spans.sort()
    merged = []
    for s, e in spans:
        if merged and s <= merged[-1][1]:
            merged[-1] = (merged[-1][0], max(merged[-1][1], e))
        else:
            merged.append((s, e))
    return merged


def scoped_hex_replace(text, o, n):
    pat = re.compile('#' + o + r'\b', re.I)
    out, pos, count = [], 0, 0
    for s, e in protected_spans(text) + [(len(text), len(text))]:
        seg = text[pos:s]
        seg, c = pat.subn('#' + n, seg)
        count += c
        out.append(seg)
        out.append(text[s:e])
        pos = e
    return ''.join(out), count


CSS = ['.config/gtk-4.0/gtk.css', '.themes/adw-gtk3-dark/gtk-3.0/gtk.css', '.themes/adw-gtk3-dark/gtk-3.0/gtk-dark.css',
       '.config/gtk-3.0/gtk.css', '.config/gtk-3.0/gtk-dark.css']
if not DEC_ONLY and old != new:
    for f in CSS:
        p = f'{H}/{f}'
        if os.path.isfile(p):
            t = open(p).read()
            nt, c = scoped_hex_replace(t, old, new)
            if c:
                write(p, nt, f'{c} token(s) (comments/KNOMADIC blocks skipped)')

    # ---- 2. QSS: one rule ----
    qss = f'{H}/.themes/dolphin-theme/dolphin-theme.qss'
    if os.path.isfile(qss):
        helper = os.path.join(HERE, '_qss_rule_edit.py')
        for prop in ('background-color', 'selection-background-color'):
            cur = subprocess.run([sys.executable, helper, '--get', qss, 'QMenu::item:selected', prop],
                                 capture_output=True, text=True).stdout.strip()
            if cur == old:
                if DRY:
                    print(f'  [dry-run] would update QMenu::item:selected {prop}')
                else:
                    shutil.copy(qss, qss + BAK)
                    subprocess.run([sys.executable, helper, '--set', qss, 'QMenu::item:selected', prop, new], check=True)


# ---- 3. KDE color files by section+key ----
def ini_edit(path, rule, label):
    """rule(section, key, value) -> new value or None"""
    if not os.path.isfile(path):
        return
    lines = open(path).read().split('\n')
    sec, changed = '', []
    for i, line in enumerate(lines):
        if line.startswith('['):
            sec = line.strip('[]\n ')
        m = re.match(r'([A-Za-z]+)=(.*)$', line)
        if m:
            nv = rule(sec, m.group(1), m.group(2).strip())
            if nv is not None and nv != m.group(2).strip():
                changed.append(f'[{sec}] {m.group(1)} {m.group(2).strip()} -> {nv}')
                lines[i] = f'{m.group(1)}={nv}'
    if changed:
        for c in changed:
            print('     ', c)
        write(path, '\n'.join(lines), f'{len(changed)} key(s) {label}')


od, nd = dec(old), dec(new)


def bluegrey_rule(sec, key, val):
    if key in ('DecorationFocus', 'DecorationHover'):
        return nd
    if not DEC_ONLY and sec == 'Colors:Selection' and key in ('BackgroundNormal', 'BackgroundAlternate') and val == od:
        return nd
    return None


def kdeglobals_rule(sec, key, val):
    return nd if key in ('DecorationFocus', 'DecorationHover') else None


ini_edit(f'{H}/.local/share/color-schemes/bluegrey.colors', bluegrey_rule, 'in bluegrey.colors')
ini_edit(f'{H}/.config/kdeglobals', kdeglobals_rule, 'in kdeglobals')
