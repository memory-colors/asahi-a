#!/usr/bin/env python3
"""
gen-shell-accent-overrides.py - unify every GNOME Shell use of the system accent
(-st-accent-color, e.g. GNOME's purple #9141ac) into ONE literal color.

Why: -st-accent-color is a built-in value libst fills in from the system accent
setting (org.gnome.desktop.interface accent-color, only 9 named colors), it cannot
be redefined from CSS. So this script re-emits every stock rule that uses it
(slider fill, active toggles, calendar today, focus rings, hover/active shades,
switches, selection, ...) with the literal accent in place of -st-accent-color,
keeping the stock st-mix()/st-lighten() formulas so hover/focus variants still
derive from the same color.

The accent is read from CURRENT_HEX in set-shell-accent-color.sh, so the existing
"Shell accent" row in Knomadic > Shell Colors drives everything: that script's
file-wide hex replace also rewrites this generated block.

Output is written between these markers in
~/.themes/Adwaita-custom/gnome-shell/gnome-shell.css, OUTSIDE the grey-shift block
(so shift-neutral-grey-blue.sh never touches it). Re-running replaces the block.
Hand-written !important role rules elsewhere in that file still win.

Usage: gen-shell-accent-overrides.py            (use accent from set-shell-accent-color.sh)
       gen-shell-accent-overrides.py <hex>      (override, e.g. 5a3e8b)
Then log out and back in to apply.
"""
import os, re, shutil, sys

CSS = os.environ.get('SHELL_CSS') or os.path.expanduser('~/.themes/Adwaita-custom/gnome-shell/gnome-shell.css')
ACCENT_SCRIPT = os.path.join(os.path.dirname(os.path.realpath(__file__)), 'set-shell-accent-color.sh')
BEGIN = '/* BEGIN accent-unified-auto-generated (gen-shell-accent-overrides.py) */'
END = '/* END accent-unified-auto-generated */'
GREY_BEGIN = '/* BEGIN grey-shift-auto-generated'


def accent_hex():
    if len(sys.argv) > 1:
        h = sys.argv[1].lstrip('#').lower()
    else:
        m = re.search(r'^CURRENT_HEX="([0-9a-fA-F]{6})"', open(ACCENT_SCRIPT).read(), re.M)
        if not m:
            sys.exit('could not read CURRENT_HEX from ' + ACCENT_SCRIPT)
        h = m.group(1).lower()
    if not re.fullmatch(r'[0-9a-f]{6}', h):
        sys.exit('bad hex: ' + h)
    return h


def stock_css():
    import gi
    gi.require_version('Gio', '2.0')
    from gi.repository import Gio
    res = Gio.Resource.load('/usr/share/gnome-shell/gnome-shell-theme.gresource')
    res._register()
    data = Gio.resources_lookup_data('/org/gnome/shell/theme/gnome-shell-dark.css',
                                     Gio.ResourceLookupFlags.NONE).get_data()
    return data.decode()


def main():
    hexv = accent_hex()
    stock = re.sub(r'/\*.*?\*/', '', stock_css(), flags=re.S)
    out, n_rules, n_decl = [], 0, 0
    for sel, body in re.findall(r'([^{}]+)\{([^{}]*)\}', stock):
        decls = [d.strip() for d in body.split(';') if '-st-accent-color' in d]
        if not decls:
            continue
        n_rules += 1
        n_decl += len(decls)
        sels = ',\n'.join(' '.join(s.split()) for s in sel.split(','))
        lines = ''.join('    %s;\n' % d.replace('-st-accent-color', '#' + hexv) for d in decls)
        out.append('%s {\n%s}\n' % (sels, lines))
    block = '%s\n/* accent #%s - %d rules / %d declarations from stock gnome-shell-dark.css */\n%s%s\n' % (
        BEGIN, hexv, n_rules, n_decl, ''.join(out), END)

    text = open(CSS).read()
    if BEGIN in text:
        text = re.sub(re.escape(BEGIN) + r'.*?' + re.escape(END) + r'\n', lambda m: block, text, flags=re.S)
    else:
        i = text.index(GREY_BEGIN)
        text = text[:i] + block + '\n' + text[i:]
    shutil.copy(CSS, CSS + '.bak-pre-accent-unify')
    open(CSS, 'w').write(text)
    print('accent #%s: wrote %d rules (%d declarations)' % (hexv, n_rules, n_decl))


if __name__ == '__main__':
    main()
