#!/usr/bin/env python3
"""
shift_neutral_grey_blue.py - shift every neutral grey (R==G==B, midtones) in
GNOME-side theming toward blue by N, AND REMEMBER what it shifted so the amount
can be tuned later (a little more / less blue) without cumulative drift.
(Wrapped by shift-neutral-grey-blue.sh.)

What it manages
  Part 1  GTK3/GTK4 css files (7 known files): direct in-place hex edits.
  Part 2  GNOME Shell chrome: the `grey-shift-auto-generated` block in
          ~/.themes/Adwaita-custom/gnome-shell/gnome-shell.css, regenerated from
          the stock gnome-shell-dark.css every time (never cumulative).
  Qt/KDE files are out of scope, as before.

State: grey-shift-state.json next to this script (portable between machines).
  per file: { original_neutral_hex : currently_written_hex }
  plus: current shift, midtone range, timestamp.

Commands
  --status                show the remembered state
  --fresh N               first-ever run on UNSHIFTED files: record every neutral
                          midtone grey and shift it by N (refuses if state exists)
  --adopt S0 [--dry-run]  files were ALREADY shifted by S0 before this tracking
                          existed: record tokens with R==G and B==R+S0 as
                          "original = R,R,R" (preview first with --dry-run)
  --set N   (or bare N)   make the shift exactly N (absolute, safe to repeat);
                          0 restores the recorded originals
  --rescan                record neutral greys that appeared AFTER tracking began
                          (e.g. from picker scripts) and shift them by the current N

Adopt caveat: stock themes contain natural tints (e.g. #36363a). Tokens whose
offset happens to equal S0 are indistinguishable from shifted ones, so check the
--dry-run list. Recorded values are replaced token-for-token (case-insensitive,
whole hex only); a color changed later by a picker script simply stops matching.

Env overrides (for testing): GREY_SHIFT_STATE, GREY_SHIFT_GTK_FILES (colon-
separated), GREY_SHIFT_SHELL_CSS, GREY_SHIFT_SKIP_SHELL=1.
"""
import json, os, re, shutil, sys, time

HERE = os.path.dirname(os.path.realpath(__file__))
STATE = os.environ.get('GREY_SHIFT_STATE', os.path.join(HERE, 'grey-shift-state.json'))
H = os.path.expanduser('~')
GTK_FILES = [
    f'{H}/.config/gtk-4.0/gtk.css',
    f'{H}/.config/gtk-3.0/gtk.css',
    f'{H}/.config/gtk-3.0/gtk-dark.css',
    f'{H}/.themes/adw-gtk3-dark/gtk-3.0/gtk.css',
    f'{H}/.themes/adw-gtk3-dark/gtk-3.0/gtk-dark.css',
    f'{H}/.themes/adw-gtk3-dark/gtk-4.0/gtk.css',
    f'{H}/.themes/adw-gtk3-dark/gtk-4.0/gtk-dark.css',
]
if os.environ.get('GREY_SHIFT_GTK_FILES'):
    GTK_FILES = os.environ['GREY_SHIFT_GTK_FILES'].split(':')
SHELL_CSS = os.environ.get('GREY_SHIFT_SHELL_CSS', f'{H}/.themes/Adwaita-custom/gnome-shell/gnome-shell.css')
# near-black is not "the grey"; >=140 is reserved for font colors (2026-10-01)
LO, HI = 16, 139
HEX = re.compile(r'#([0-9a-fA-F]{6})\b')
TS = str(int(time.time()))


def die(msg):
    sys.exit('Error: ' + msg)


def load():
    if not os.path.isfile(STATE):
        return None
    return json.load(open(STATE))


def save(st):
    st['updated'] = time.strftime('%Y-%m-%d %H:%M:%S')
    st['midtone'] = [LO, HI]
    json.dump(st, open(STATE, 'w'), indent=1, sort_keys=True)


def parts(h):
    return int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16)


def shifted(h, n):
    r, g, b = parts(h)
    return '%02x%02x%02x' % (r, g, min(255, b + n))


def is_neutral_mid(h):
    r, g, b = parts(h)
    return r == g == b and LO <= r <= HI


def backup(path):
    shutil.copy(path, f'{path}.bak-pre-grey-shift-{TS}')


# ---------- Part 1: GTK files ----------
def tokens(text):
    return [m.group(1).lower() for m in HEX.finditer(text)]


def scan_fresh(n):
    """neutral midtone tokens per file -> {orig: orig+n}"""
    out = {}
    for p in GTK_FILES:
        if os.path.isfile(p):
            s = {t for t in tokens(open(p).read()) if is_neutral_mid(t)}
            out[p] = {t: shifted(t, n) for t in sorted(s)}
    return out


def scan_adopt(s0):
    out = {}
    for p in GTK_FILES:
        if os.path.isfile(p):
            s = set()
            for t in tokens(open(p).read()):
                r, g, b = parts(t)
                if r == g and b - r == s0 and LO <= r <= HI:
                    s.add(t)
            out[p] = {'%02x%02x%02x' % ((parts(t)[0],) * 3): t for t in sorted(s)}
    return out


def rewrite(path, mapping_old_to_new, apply=True):
    """replace whole-hex tokens (case-insens). returns number replaced"""
    text = open(path).read()
    count = [0]

    def sub(m):
        k = m.group(1).lower()
        if k in mapping_old_to_new:
            count[0] += 1
            return '#' + mapping_old_to_new[k]
        return m.group(0)

    new = HEX.sub(sub, text)
    if apply and count[0]:
        backup(path)
        open(path, 'w').write(new)
    return count[0]


# ---------- Part 2: shell block ----------
def write_shell_block(n):
    if os.environ.get('GREY_SHIFT_SKIP_SHELL'):
        return
    import gi
    gi.require_version('Gio', '2.0')
    from gi.repository import Gio
    res = Gio.Resource.load('/usr/share/gnome-shell/gnome-shell-theme.gresource')
    res._register()
    stock = Gio.resources_lookup_data('/org/gnome/shell/theme/gnome-shell-dark.css',
                                      Gio.ResourceLookupFlags.NONE).get_data().decode()
    rgb_re = re.compile(r'rgba?\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)(\s*,\s*[\d.]+)?\s*\)')

    def neutral(r, g, b):
        return r == g == b and LO <= r <= HI

    def hx(m):
        r, g, b = parts(m.group(1))
        if not neutral(r, g, b):
            return m.group(0)
        nb = min(255, b + n)
        return m.group(0) if nb == b else '#%02x%02x%02x' % (r, g, nb)

    def rg(m):
        r, g, b = int(m.group(1)), int(m.group(2)), int(m.group(3))
        if not neutral(r, g, b):
            return m.group(0)
        nb = min(255, b + n)
        if nb == b:
            return m.group(0)
        a = m.group(4) or ''
        return f'rgba({r}, {g}, {nb}{a})' if a else f'rgb({r}, {g}, {nb})'

    overrides = []
    for m in re.finditer(r'([^{}]+)\{([^{}]*)\}', stock):
        sel = m.group(1).strip()
        if not sel or sel.startswith('/*'):
            continue
        decls = []
        for d in m.group(2).split(';'):
            d = d.strip()
            if not d or ':' not in d:
                continue
            prop, _, val = d.partition(':')
            prop, val = prop.strip(), val.strip()
            nv = rgb_re.sub(rg, HEX.sub(hx, val))
            if nv != val:
                decls.append(f'    {prop}: {nv} !important;')
        if decls:
            overrides.append((sel, decls))
    lines = [f'/* BEGIN grey-shift-auto-generated (shift-neutral-grey-blue.sh) shift=+{n} */']
    for sel, decls in overrides:
        lines.append(f'{sel} {{')
        lines += decls
        lines.append('}')
    lines.append('/* END grey-shift-auto-generated */')
    block = '\n'.join(lines) + '\n'
    existing = open(SHELL_CSS).read() if os.path.isfile(SHELL_CSS) else ''
    pat = re.compile(r'/\* BEGIN grey-shift-auto-generated.*?/\* END grey-shift-auto-generated \*/\n?', re.S)
    if pat.search(existing):
        shutil.copy(SHELL_CSS, f'{SHELL_CSS}.bak-pre-grey-shift-{TS}')
        existing = pat.sub(lambda m: block, existing)
    else:
        existing = existing.rstrip('\n') + '\n\n' + block
    open(SHELL_CSS, 'w').write(existing)
    print(f'  shell block: {len(overrides)} selector blocks at +{n} -> {SHELL_CSS}')


# ---------- commands ----------
def cmd_status():
    st = load()
    if not st:
        print('no state yet - use --fresh N (unshifted files) or --adopt S0 (already shifted)')
        return
    print(f"shift: +{st['shift']}   midtone {st.get('midtone')}   updated {st.get('updated')}   source: {st.get('source')}")
    for p, m in st['files'].items():
        print(f'  {len(m):3d} remembered greys  {p}')


def cmd_fresh(n):
    if load():
        die('state already exists; use --set N (or delete grey-shift-state.json if you know the files are unshifted)')
    files = scan_fresh(n)
    st = {'shift': n, 'source': f'fresh +{n}', 'files': {}}
    for p, m in files.items():
        c = rewrite(p, {o: s for o, s in m.items()})
        st['files'][p] = m
        print(f'  shifted {c} token(s), {len(m)} distinct grey(s): {p}')
    save(st)
    write_shell_block(n)


def cmd_adopt(s0, dry):
    if load() and not dry:
        die('state already exists')
    files = scan_adopt(s0)
    for p, m in files.items():
        print(f'  {p}: {len(m)} token(s) treated as shifted by +{s0}')
        for o, c in m.items():
            print(f'      original #{o}  <-  current #{c}')
    if dry:
        print('\n(dry run - nothing recorded)')
        return
    save({'shift': s0, 'source': f'adopted at +{s0}', 'files': files})
    print(f'\nrecorded. Now --set N to retune (shell block is regenerated at that time).')


def cmd_set(n):
    st = load()
    if not st:
        die('no state yet. Use --adopt S0 (files already shifted, preview with --dry-run) or --fresh N (unshifted files).')
    old = st['shift']
    print(f'shift +{old} -> +{n}')
    for p, m in st['files'].items():
        if not os.path.isfile(p):
            continue
        # current written value -> new value; all keys are distinct, none chain
        mp = {cur: shifted(orig, n) for orig, cur in m.items()}
        c = rewrite(p, mp)
        st['files'][p] = {orig: shifted(orig, n) for orig in m}
        print(f'  rewrote {c} token(s): {p}')
    st['shift'] = n
    save(st)
    write_shell_block(n)


def cmd_rescan():
    st = load()
    if not st:
        die('no state yet')
    n = st['shift']
    for p in GTK_FILES:
        if not os.path.isfile(p):
            continue
        known = set(st['files'].get(p, {}).values()) | set(st['files'].get(p, {}).keys())
        new = {t: shifted(t, n) for t in sorted({t for t in tokens(open(p).read()) if is_neutral_mid(t)}) if t not in known}
        if new:
            rewrite(p, new)
            st['files'].setdefault(p, {}).update(new)
            print(f'  {p}: recorded + shifted {len(new)} new grey(s): ' + ', '.join(new))
    save(st)


def main():
    a = sys.argv[1:]
    if not a or a[0] in ('-h', '--help'):
        print(__doc__)
    elif a[0] == '--status':
        cmd_status()
    elif a[0] == '--fresh':
        cmd_fresh(int(a[1]))
    elif a[0] == '--adopt':
        cmd_adopt(int(a[1]), '--dry-run' in a)
    elif a[0] == '--set':
        cmd_set(int(a[1]))
    elif a[0] == '--revert':
        cmd_set(0)
    elif a[0] == '--rescan':
        cmd_rescan()
    elif a[0].isdigit():
        cmd_set(int(a[0]))
    else:
        die('unknown option ' + a[0])
    if a and a[0] not in ('--status', '-h', '--help') and '--dry-run' not in a:
        print('\nGTK3/4 apps: restart them. Shell: log out and back in')


if __name__ == '__main__':
    main()
