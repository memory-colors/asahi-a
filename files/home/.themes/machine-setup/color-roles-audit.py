#!/usr/bin/env python3
"""
color-roles-audit.py - READ-ONLY. Shows, for the three shared color roles, every target a script is
supposed to own and its current value, flagging disagreements. Changes nothing.

Roles (as ruled by the user, 2026-10-05):
  accent  : GTK accent tokens, qt6ct Highlight, bluegrey Selection bg, and ALL DecorationFocus/DecorationHover
            keys (overlap with accent is intentional - they should carry the accent value)
  grey    : window_bg_color / sidebar_* tokens, the SIDEBAR-SIDE header of split apps (Settings, Tweaks -
            where the traffic lights live), qt Window role. NOT the Dolphin sidebar (its own role).
  master  : view_bg_color, headerbar_bg_color (single-pane GTK app titlebars stay dark), the CONTENT-SIDE
            header of split apps, kdeglobals View, qt Button/Base/AlternateBase.
"""
import os, re

H = os.path.expanduser('~')
def rd(f):
    p = f if f.startswith('/') else H + '/' + f
    return open(p).read() if os.path.isfile(p) else ''
def hexdec(h): return '%d,%d,%d' % (int(h[:2], 16), int(h[2:4], 16), int(h[4:6], 16))
def dechex(d):
    r, g, b = [int(x) for x in d.split(',')[:3]]; return '%02x%02x%02x' % (r, g, b)

rows = []   # (role, target, value, expected-name)
def add(role, target, value): rows.append((role, target, (value or '-').lower()))

def token(f, name):
    m = re.search(r'@define-color\s+' + name + r'\s+(#[0-9a-fA-F]{6}|[^;]+);', rd(f))
    if not m: return None
    v = m.group(1).strip()
    mm = re.match(r'#([0-9a-fA-F]{6})$', v)
    return mm.group(1) if mm else v

def rule_bg(f, sel_regex):
    """background-color of the first rule whose selector text matches the regex"""
    for m in re.finditer(r'([^{}]+)\{([^{}]*)\}', rd(f)):
        if re.search(sel_regex, m.group(1)):
            bm = re.search(r'background-color:\s*#([0-9a-fA-F]{6})', m.group(2))
            if bm: return bm.group(1)
    return None

def palette(f, idx):
    m = re.search(r'^active_colors=(.*)$', rd(f), re.M)
    if not m: return None
    cols = [c.strip() for c in m.group(1).split(',')]
    return cols[idx][-6:] if idx < len(cols) else None

def ini(f, section, key):
    sec = ''
    for line in rd(f).split('\n'):
        if line.startswith('['): sec = line.strip()
        elif sec == '[%s]' % section and line.startswith(key + '='): return line.split('=', 1)[1].strip()
    return None

G4 = '.config/gtk-4.0/gtk.css'
for f in (G4, '.themes/adw-gtk3-dark/gtk-3.0/gtk.css', '.config/gtk-3.0/gtk.css'):
    add('accent', f + ' accent_bg_color', token(f, 'accent_bg_color'))
add('accent', 'qt6ct Highlight (idx12)', palette('.config/qt6ct/colors/Gradience.conf', 12))
bg = '.local/share/color-schemes/bluegrey.colors'
sel = ini(bg, 'Colors:Selection', 'BackgroundNormal')
add('accent', 'bluegrey [Colors:Selection] BackgroundNormal', dechex(sel) if sel else None)
accent = token(G4, 'accent_bg_color')
# Decoration keys: every section, active schemes
for f in ('.config/kdeglobals', bg):
    sec = ''
    for line in rd(f).split('\n'):
        if line.startswith('['): sec = line.strip('[]\n ')
        m = re.match(r'(DecorationFocus|DecorationHover)=(.*)', line)
        if m: add('accent', f"{f.split('/')[-1]} [{sec}] {m.group(1)}", dechex(m.group(2)))

for f in (G4, '.themes/adw-gtk3-dark/gtk-3.0/gtk.css', '.config/gtk-3.0/gtk.css'):
    add('grey', f + ' window_bg_color', token(f, 'window_bg_color'))
    add('grey', f + ' sidebar_bg_color', token(f, 'sidebar_bg_color'))
add('grey', G4 + ' sidebar-side header rule (traffic lights)', rule_bg(G4, r'tweak-titlebar-left|unfolded > box > headerbar'))
add('grey', 'qt6ct Window (idx10)', palette('.config/qt6ct/colors/Gradience.conf', 10))

for f in (G4, '.themes/adw-gtk3-dark/gtk-3.0/gtk.css', '.config/gtk-3.0/gtk.css'):
    add('master', f + ' view_bg_color', token(f, 'view_bg_color'))
    add('master', f + ' headerbar_bg_color', token(f, 'headerbar_bg_color'))
add('master', G4 + ' content-side header rule', rule_bg(G4, r'tweak-titlebar-right|stack > widget > box > widget > headerbar'))
kv = ini('.config/kdeglobals', 'Colors:View', 'BackgroundNormal')
add('master', 'kdeglobals [Colors:View] BackgroundNormal', dechex(kv) if kv else None)
for name, i in (('Button', 1), ('Base', 9), ('AlternateBase', 16)):
    add('master', f'qt6ct {name} (idx{i})', palette('.config/qt6ct/colors/Gradience.conf', i))

ref = {'accent': accent, 'grey': token(G4, 'window_bg_color'), 'master': token(G4, 'view_bg_color')}
print("Reference values (from gtk-4.0/gtk.css): " + ", ".join(f"{k}=#{v}" for k, v in ref.items()))
cur = None
for role, target, val in rows:
    if role != cur:
        print(f"\n[{role.upper()}]  expected #{ref[role]}"); cur = role
    flag = 'ok ' if val == (ref[role] or '').lower() else 'DIFF'
    print(f"  {flag}  #{val:14s} {target}")
print("\nRead-only audit. Nothing was changed.")
