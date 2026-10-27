#!/bin/bash
# set-flat-surfaces.sh [--off] - no structural lines anywhere: flat surfaces, colour does the separating (user request 2026-10-24).
# Writes one marked block /* KNOMADIC: flat-surfaces BEGIN..END */ at the END of ~/.config/gtk-4.0/gtk.css and ~/.config/gtk-3.0/gtk.css (the GTK3 file is the same
# file as ~/.themes/gtk-3.0/gtk.css). Re-run after anything that regenerates those files (it replaces its own block). --off removes the block again.
#  GTK4/libadwaita: (a) the CSS variables libadwaita draws its sidebar/headerbar/shade lines with are set transparent in :root (the INSTALLED libadwaita is newer than
#  the cooked gtk.css and draws e.g. `.sidebar-pane { box-shadow: inset -1px 0 var(--sidebar-border-color) }`); (b) every cooked rule whose only box-shadow is a 1px white
#  `inset ... rgba(255,255,255,0.12)` line on scroll-undershoot / paned separators / menubar / top-bar / bottom-bar / statusbar gets `box-shadow: none` (same selector, later = wins).
#  GTK3/adw-gtk3: the named colours behind headerbar / sidebar / shade lines become transparent, plus paned separators.
# Outlines too (user 2026-10-24 "flatten the outlines too, everything"): every border colour goes transparent (NOT border:none, so sizes/layout stay identical), box-shadows off on frames/buttons/entries/
# lists/tabs, ALL separators transparent. Keyboard focus rings (outline) are deliberately kept.
set -euo pipefail
G4="$HOME/.config/gtk-4.0/gtk.css"; G3="$HOME/.config/gtk-3.0/gtk.css"
MODE="${1:-on}"
python3 - "$G4" "$G3" "$MODE" <<'PYEOF'
import re, sys
g4, g3, mode = sys.argv[1:4]
B, E = '/* KNOMADIC: flat-surfaces BEGIN - do not edit by hand, see set-flat-surfaces.sh */', '/* KNOMADIC: flat-surfaces END */'
def strip(t):
    if B in t:
        s = t.index(B); e = t.index(E) + len(E)
        t = (t[:s].rstrip('\n') + '\n' + t[e:].lstrip('\n')) if t[e:].strip() else t[:s].rstrip('\n') + '\n'
    return t
def write(path, block):
    t = strip(open(path).read())
    if block: t = t.rstrip('\n') + '\n\n' + block + '\n'
    open(path, 'w').write(t)
if mode == '--off':
    for p in (g4, g3): write(p, None)
    print('flat-surfaces removed'); sys.exit(0)
# ---- GTK4
base = strip(open(g4).read())
nocomment = re.sub(r'/\*.*?\*/', '', base, flags=re.S)
pat = re.compile(r'inset[^;,]*rgba\(255, 255, 255, 0\.12\)')
want = re.compile(r'undershoot|paned|menubar|top-bar|bottom-bar|panelstatusbar')
sels = []
for sel, body in re.findall(r'([^{}]+)\{([^{}]*)\}', nocomment):
    m = re.search(r'box-shadow:\s*([^;]*);', body)
    if not m: continue
    parts = [p.strip() for p in re.split(r',(?![^(]*\))', m.group(1))]
    if all(p.startswith('inset') and pat.search(p) for p in parts) and want.search(sel):
        sels.append(' '.join(sel.split()))
vars_ = ['--sidebar-border-color', '--secondary-sidebar-border-color', '--headerbar-border-color', '--headerbar-shade-color', '--headerbar-darker-shade-color',
         '--sidebar-shade-color', '--secondary-sidebar-shade-color', '--card-shade-color', '--popover-shade-color', '--shade-color']
OUT = ['button', 'entry', 'spinbutton', 'spinbutton > button', 'combobox', 'dropdown', 'frame', 'frame > border', '.frame', 'scrolledwindow', 'viewport', 'notebook', 'notebook > header',
       'notebook > header > tabs > tab', 'treeview.view', 'list', 'row', 'toolbar', 'menubar', 'statusbar', 'popover > contents', 'popover.background > contents', 'menu', 'menuitem', 'switch',
       'scale trough', 'progressbar trough', 'levelbar trough', 'checkbutton check', 'radiobutton radio', 'columnview', 'treeview header button', 'tooltip', 'window.dialog', 'messagedialog',
       'filechooser', 'placessidebar', '.card', '.boxed-list', 'searchbar', 'actionbar', 'infobar', 'textview', 'textview > text']
SEP = ['separator', 'paned > separator', 'popover separator', 'menu separator', 'headerbar separator', 'toolbar separator', 'list > separator', 'treeview.view separator']
def outl(extra=''):
    return ''.join('%s {\n  border-color: transparent;\n  box-shadow: none;\n}\n' % ',\n'.join(OUT)) + \
           '%s {\n  background-color: transparent;\n  background-image: none;\n  border-color: transparent;\n  box-shadow: none;\n}\n' % ',\n'.join(SEP) + \
           '/* unchecked check/radio boxes are drawn ONLY by their border: without it they vanish, so give them a fill (colour does the work) */\ncheck:not(:checked):not(:indeterminate),\nradio:not(:checked):not(:indeterminate),\ncheckbutton check:not(:checked):not(:indeterminate),\nradiobutton radio:not(:checked):not(:indeterminate) {\n  background-color: alpha(currentColor, 0.18);\n  background-image: none;\n}\n' + \
           '/* row hover (libadwaita/adw-gtk3 use only 4-10% of the text colour): with the lines gone, colour must carry it */\nlistview > row:hover:not(:selected),\nlist > row:hover:not(:selected),\nrow.activatable:hover:not(:selected),\ncolumnview row:hover:not(:selected),\n.navigation-sidebar > row:hover:not(:selected),\ngridview > child:hover:not(:selected),\nflowbox > flowboxchild:hover:not(:selected) {\n  background-color: alpha(currentColor, 0.14);\n}\n'
b4 = B + '\n:root {\n  --border-opacity: 0%;\n  --border-color: transparent;\n' + ''.join('  %s: transparent;\n' % v for v in vars_) + '}\n' + \
     ''.join('%s {\n  box-shadow: none;\n}\n' % s for s in sels) + outl() + E
write(g4, b4)
# ---- GTK3
cols = ['borders', 'unfocused_borders', 'headerbar_border_color', 'headerbar_shade_color', 'headerbar_darker_shade_color', 'sidebar_shade_color', 'sidebar_border_color', 'card_shade_color', 'popover_shade_color', 'shade_color']
b3 = B + '\n' + ''.join('@define-color %s transparent;\n' % c for c in cols) + \
     outl() + '/* rounded window corners clip the bottom row of GTK3 windows (VeraCrypt, Xarchiver...): keep content clear of them */\nwindow.background:not(.popup):not(.tooltip) > box,\nwindow.background:not(.popup):not(.tooltip) > grid,\nwindow.background:not(.popup):not(.tooltip) > paned,\nwindow.background:not(.popup):not(.tooltip) > overlay,\nwindow.background:not(.popup):not(.tooltip) > stack,\nwindow.background:not(.popup):not(.tooltip) > notebook,\nwindow.background:not(.popup):not(.tooltip) > alignment,\nwindow.background:not(.popup):not(.tooltip) > fixed {\n  padding-bottom: 10px;\n}\n' + E
write(g3, b3)
print('flat-surfaces written: %d GTK4 selector groups, %d GTK4 variables, %d GTK3 colours' % (len(sels), len(vars_), len(cols)))
PYEOF
echo "Restart GTK apps to see it."
