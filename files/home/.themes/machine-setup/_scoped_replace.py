#!/usr/bin/env python3
"""
_scoped_replace.py - scoped (never blind) color edits shared by set-light-background.sh and set-dark-background.sh.
(set-accent-color.sh uses its own tested helper _accent_apply.py with the same CSS rules.)

  css     <old_hex> <new_hex> [--skip-token a,b] FILE...
            whole-hex replace OLD->NEW in CSS, but NOT inside /* comments */, NOT inside
            `/* KNOMADIC: <name> BEGIN ... END */` blocks, and NOT on `@define-color <token>` lines whose token is
            in --skip-token (those belong to another role).
  palette <old_hex> <new_hex> <idx,idx,...> FILE...
            qt5ct/qt6ct color file: edit ONLY the given palette role indices (0-based) in every *_colors= line,
            and only where the value currently equals OLD (positional, never value matching across roles).
  ini     <old_dec> <new_dec> <section-regex> <key,key,...> FILE...
            KDE .colors/kdeglobals: edit only the listed keys inside sections matching the regex, only where
            the value currently equals OLD (decimal "r,g,b").
Env HOME honoured. Writes FILE.bak-pre-<new> before changing a file. --dry-run reports without writing.
"""
import os, re, shutil, sys

DRY = '--dry-run' in sys.argv
argv = [a for a in sys.argv[1:] if a != '--dry-run']
mode = argv[0]


def backup_write(path, text, new, what):
    if DRY:
        print(f'  [dry-run] would update {what}: {path}')
        return
    shutil.copy(path, f'{path}.bak-pre-{new}')
    open(path, 'w').write(text)
    print(f'  updated {what}: {path}')


def protected(text):
    spans = [(m.start(), m.end()) for m in re.finditer(r'/\* KNOMADIC: (\S+) BEGIN.*?END \*/', text, re.S)]
    spans += [(m.start(), m.end()) for m in re.finditer(r'/\*.*?\*/', text, re.S)]
    spans.sort()
    out = []
    for s, e in spans:
        if out and s <= out[-1][1]:
            out[-1] = (out[-1][0], max(out[-1][1], e))
        else:
            out.append((s, e))
    return out


def css(old, new, skip, files):
    pat = re.compile('#' + old + r'\b', re.I)
    for p in files:
        if not os.path.isfile(p):
            continue
        text = open(p).read()
        parts, pos, n = [], 0, 0
        for s, e in protected(text) + [(len(text), len(text))]:
            seg = text[pos:s]
            lines = seg.split('\n')
            for i, ln in enumerate(lines):
                m = re.match(r'\s*@define-color\s+(\S+)', ln)
                if m and m.group(1) in skip:
                    continue
                lines[i], c = pat.subn('#' + new, ln)
                n += c
            parts += ['\n'.join(lines), text[s:e]]
            pos = e
        if n:
            backup_write(p, ''.join(parts), new, f'{n} css token(s)')


def palette(old, new, idxs, files):
    for p in files:
        if not os.path.isfile(p):
            continue
        lines = open(p).read().split('\n')
        n = 0
        for i, ln in enumerate(lines):
            m = re.match(r'(\w*_colors)=(.*)$', ln)
            if not m:
                continue
            vals = [v.strip() for v in m.group(2).split(',')]
            for ix in idxs:
                if ix < len(vals) and vals[ix][-6:].lower() == old:
                    vals[ix] = vals[ix][:-6] + new
                    n += 1
            lines[i] = f'{m.group(1)}=' + ', '.join(vals)
        if n:
            backup_write(p, '\n'.join(lines), new, f'{n} palette role value(s) idx {idxs}')


def ini(old, new, sec_re, keys, files):
    for p in files:
        if not os.path.isfile(p):
            continue
        lines = open(p).read().split('\n')
        sec, n = '', 0
        for i, ln in enumerate(lines):
            if ln.startswith('['):
                sec = ln.strip('[]\n ')
            m = re.match(r'([A-Za-z]+)=(.*)$', ln)
            if m and m.group(1) in keys and re.fullmatch(sec_re, sec) and m.group(2).strip() == old:
                lines[i] = f'{m.group(1)}={new}'
                n += 1
        if n:
            backup_write(p, '\n'.join(lines), new.replace(',', '-'), f'{n} key(s) in sections /{sec_re}/')


if mode == 'css':
    skip = set()
    rest = argv[1:]
    if '--skip-token' in rest:
        i = rest.index('--skip-token')
        skip = set(rest[i + 1].split(','))
        rest = rest[:i] + rest[i + 2:]
    css(rest[0].lower(), rest[1].lower(), skip, rest[2:])
elif mode == 'palette':
    palette(argv[1].lower(), argv[2].lower(), [int(x) for x in argv[3].split(',')], argv[4:])
elif mode == 'ini':
    ini(argv[1], argv[2], argv[3], set(argv[4].split(',')), argv[5:])
else:
    sys.exit(__doc__)
