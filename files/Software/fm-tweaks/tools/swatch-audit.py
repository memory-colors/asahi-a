#!/usr/bin/env python3
"""swatch-audit.py - monitored test of every colour swatch in Knomadic's prefs (the "Pick..." rows).

What it does: snapshots the config trees below (files + dconf + every swatch's --get value), then for each swatch runs its script with a
unique saturated colour, records what changed (the swatch's own getter, which files / marked CSS blocks, dconf keys, OTHER swatches' getters =
cross-talk, new files such as stray .bak-pre-*), and restores everything before the next one. Nothing is left changed; `verify` proves it.
The swatch list is NOT hard-coded: it is read from Knomadic's prefs.js (every makeColorPickRow call, plus the Thunar/SMPlayer row tables), so
new swatches are picked up automatically. Call sites it cannot parse are reported as UNPARSED (add them to EXTRA_ROWS below).
It only proves the FILE side (value lands, no overreach, restores clean). Whether an app/shell actually shows the colour needs a restart/logout.

Usage:  swatch-audit.py list                 show the discovered swatches (and unparsed call sites)
        swatch-audit.py snapshot             take the snapshot (do this first, on a quiet system)
        swatch-audit.py idle                 15 s idle pass: files/dconf keys that change by themselves are ignored afterwards
        swatch-audit.py run [label ...]      test all (or the named) swatches; prints one line each, details in results.json
        swatch-audit.py report               print findings from results.json (odd files, cross-talk, new files, unwatched writes)
        swatch-audit.py applyall             PHASE 2: set EVERY swatch at once to its own distinct colour and write legend.txt (state dir); you then log out /
                                             restart the apps and look at what changed colour; nothing is restored automatically
        swatch-audit.py keep PATH [PATH..]   after applyall, if you EDIT a watched file on purpose (script, template, prefs.js...): put its current content into the
                                             snapshot so `restore` does not revert your edit (anything changed since the snapshot is otherwise rolled back)
        swatch-audit.py restore              put every file and dconf key back from the snapshot (run after the visual check; then `verify`)
        swatch-audit.py verify               compare the live system with the snapshot (expect: no differences)
State (snapshot.pkl ~25 MB, results.json) lives in $AUDIT_OUT (default ~/.cache/fm-tweaks/swatch-audit): delete it when done.
Skips the GDM half of the shell swatches (SHELL_CSS makes those scripts skip their pkexec step). Watched roots: see ROOTS; writes elsewhere under
~/.config ~/.local ~/.themes ~/Software ~/.cache are reported as "unwatched" (reported, NOT restored).
"""
import os, sys, json, subprocess, hashlib, re, time, stat, pickle

HOME = os.path.expanduser('~')
OUT = os.environ.get('AUDIT_OUT', f'{HOME}/.cache/fm-tweaks/swatch-audit')
PREFS = f'{HOME}/.local/share/gnome-shell/extensions/knomadic@blank.local/prefs.js'
MS = f'{HOME}/.themes/machine-setup'
CSS = f'{HOME}/.themes/Adwaita-custom/gnome-shell/gnome-shell.css'

ROOTS = [f'{HOME}/.themes', f'{HOME}/.config', f'{HOME}/.local/share/gnome-shell', f'{HOME}/.local/share/icons',
         f'{HOME}/.local/share/applications', f'{HOME}/.local/share/themes', f'{HOME}/.local/share/org.gnome.Ptyxis',
         f'{HOME}/.local/bin', f'{HOME}/.local/libexec', f'{HOME}/Software/fm-tweaks', f'{HOME}/.cache/fm-tweaks']
SKIP_DIRS = {f'{HOME}/.config/{d}' for d in ('BraveSoftware', 'Claude', 'Mullvad VPN', 'LosslessCut', 'dconf', 'transmission', 'pulse', 'evolution', 'goa-1.0')}
SKIP_NAMES = {'.git', '__pycache__'}
SKIP_DIRS.add(OUT)   # never snapshot our own state

# script -> extra env (the two shell scripts would otherwise try pkexec for the GDM login screen)
SCRIPT_ENV = {'set-shell-accent-color.sh': {'SHELL_CSS': CSS}, 'set-shell-background-color.sh': {'SHELL_CSS': CSS}}
EXTRA_ROWS = []   # (label, script, [extra args]) for swatches that are not makeColorPickRow calls in prefs.js
ROWS, UNPARSED = [], []


def _table(src, name):
    m = re.search(name + r'\s*=\s*\[(.*?)\n\s*\];', src, re.S)
    return re.findall(r"\[\s*'([^']*)'\s*,\s*'([^']*)'", m.group(1)) if m else []


def discover():
    """Fill ROWS from prefs.js: label, script, extra args, env."""
    src = open(PREFS).read()
    tables = {'THUNAR': _table(src, 'THUNAR_COLOR_ROWS'), 'SMPLAYER': _table(src, 'SMPLAYER_COLOR_ROWS')}
    group = None
    for m in re.finditer(r"makeColorPickRow\(|new Adw\.PreferencesGroup\(\{ title: _\('([^']*)'\)", src):
        if m.group(1):
            group = m.group(1); continue
        i = m.end(); depth = 1; j = i
        while depth and j < len(src):
            depth += {'(': 1, ')': -1}.get(src[j], 0); j += 1
        call = src[i:j - 1]
        if call.lstrip().startswith('title,') :   # the function definition's own parameter list
            continue
        mm = re.match(r"\s*_\(\s*(?:'([^']*)'|(\w+))\s*\)\s*,\s*(?:'[0-9a-fA-F]{6}'|\w+)\s*,\s*(?:'([\w.-]+\.(?:sh|py))'|(\w+))\s*(?:,\s*\[([^\]]*)\])?\s*$", call, re.S)
        if not mm:
            UNPARSED.append(re.sub(r'\s+', ' ', call)[:100]); continue
        title, tvar, script, svar, extra = mm.groups()
        extra = re.findall(r"'([^']*)'", extra or '')
        if title and script:
            ROWS.append((_label(title, script, extra), script, extra, SCRIPT_ENV.get(script, {})))
        elif tvar == 'label' and script:   # the loop over THUNAR_COLOR_ROWS / SMPLAYER_COLOR_ROWS: expand from the table
            key = 'SMPLAYER' if 'SMPlayer' in (group or '') else 'THUNAR'
            for lab, k in tables[key]:
                ROWS.append((_label(lab, script, [k]), script, [k], SCRIPT_ENV.get(script, {})))
        else:
            UNPARSED.append(re.sub(r'\s+', ' ', call)[:100])
    for lab, script, extra in EXTRA_ROWS:
        ROWS.append((_label(lab, script, extra), script, extra, SCRIPT_ENV.get(script, {})))


def _label(title, script, extra):   # unique even when two rows share a title (e.g. the two "Accent" rows)
    return f"{title} <{script.rsplit('.', 1)[0]}{':' + extra[0] if extra else ''}>"


discover()


def walk():
    """-> {path: (kind, mtime_ns, size, mode, link)}"""
    m = {}
    for root in ROOTS:
        if not os.path.lexists(root):
            continue
        stack = [root]
        while stack:
            d = stack.pop()
            if d in SKIP_DIRS:
                continue
            try:
                it = list(os.scandir(d))
            except OSError:
                continue
            for e in it:
                if e.name in SKIP_NAMES:
                    continue
                p = e.path
                try:
                    st = e.stat(follow_symlinks=False)
                except OSError:
                    continue
                if stat.S_ISLNK(st.st_mode):
                    m[p] = ('l', 0, 0, 0, os.readlink(p))
                elif stat.S_ISDIR(st.st_mode):
                    if p in SKIP_DIRS:
                        continue
                    m[p] = ('d', 0, 0, st.st_mode, None)
                    stack.append(p)
                elif stat.S_ISREG(st.st_mode):
                    m[p] = ('f', st.st_mtime_ns, st.st_size, st.st_mode, None)
    return m


UNW_TOPS = [f'{HOME}/.config', f'{HOME}/.local', f'{HOME}/.themes', f'{HOME}/Software']
UNW_PRUNE = {'Trash', 'BraveSoftware', 'Claude', 'state', 'containers', 'flatpak', 'LosslessCut', 'Mullvad VPN', 'dconf', 'keyrings', 'evolution', '.git', '__pycache__', 'recently-used.xbel', 'transmission', 'pulse'}


def unwatched_since(t0):
    """Files modified since t0 outside the snapshotted ROOTS (reported only - cannot be restored)."""
    out = []
    for top in UNW_TOPS:
        for d, dirs, files in os.walk(top):
            dirs[:] = [x for x in dirs if x not in UNW_PRUNE and os.path.join(d, x) not in ROOTS and os.path.join(d, x) not in SKIP_DIRS]
            if any(d == r or d.startswith(r + '/') for r in ROOTS):
                continue
            for f in files:
                p = os.path.join(d, f)
                try:
                    if os.lstat(p).st_mtime >= t0:
                        out.append(p.replace(HOME, '~'))
                except OSError:
                    pass
    return sorted(out)


def read(p):
    with open(p, 'rb') as f:
        return f.read()


def dconf():
    out = subprocess.run(['dconf', 'dump', '/'], capture_output=True, text=True).stdout
    d, sec = {}, ''
    for line in out.splitlines():
        if line.startswith('['):
            sec = line.strip('[]')
        elif '=' in line:
            k, v = line.split('=', 1)
            d[f'/{sec}/{k}'.replace('//', '/')] = v
    return d


def getters():
    g = {}
    for label, script, extra, env in ROWS:
        e = dict(os.environ); e.update(env)
        r = subprocess.run(['bash', f'{MS}/{script}', *extra, '--get'], capture_output=True, text=True, env=e, timeout=60)
        g[label] = (r.stdout.strip().lower().lstrip('#') if r.returncode == 0 else f'ERR rc={r.returncode}: {r.stderr.strip()[:80]}')
    return g


def snapshot():
    os.makedirs(OUT, exist_ok=True)
    man = walk()
    contents = {p: read(p) for p, v in man.items() if v[0] == 'f'}
    pickle.dump({'man': man, 'contents': contents, 'dconf': dconf(), 'getters': getters(), 'time': time.time()}, open(f'{OUT}/snapshot.pkl', 'wb'))
    print(f'snapshot: {len(man)} entries, {len(contents)} files, {sum(map(len, contents.values()))/1e6:.1f} MB')


def diff_state(snap):
    cur = walk()
    changed, added, removed = [], [], []
    for p, v in cur.items():
        o = snap['man'].get(p)
        if o is None:
            added.append(p)
        elif v != o:
            changed.append(p)
    for p in snap['man']:
        if p not in cur:
            removed.append(p)
    return changed, added, removed


def idle(seconds=15):
    snap = pickle.load(open(f'{OUT}/snapshot.pkl', 'rb'))
    time.sleep(seconds)
    c, a, r = diff_state(snap)
    noise = sorted(set(c + a + r))
    json.dump(noise, open(f'{OUT}/noise.json', 'w'), indent=1)
    print('idle noise:', *noise, sep='\n  ')
    dd = {k for k, v in dconf().items() if snap['dconf'].get(k) != v}
    print('idle dconf noise:', *sorted(dd), sep='\n  ')
    json.dump(sorted(dd), open(f'{OUT}/dconf_noise.json', 'w'))


def restore(snap, changed, added, removed):
    for p in changed + removed:
        o = snap['man'][p]
        if o[0] == 'f':
            if os.path.islink(p):
                os.unlink(p)
            with open(p, 'wb') as f:
                f.write(snap['contents'][p])
            os.chmod(p, o[3] & 0o7777)
            os.utime(p, ns=(o[1], o[1]))
        elif o[0] == 'l':
            if os.path.lexists(p):
                os.unlink(p)
            os.symlink(o[4], p)
        elif o[0] == 'd':
            os.makedirs(p, exist_ok=True)
    for p in added:
        if os.path.isfile(p) or os.path.islink(p):
            os.unlink(p)


def dconf_restore(snap, noise):
    cur = dconf()
    for k in set(cur) | set(snap['dconf']):
        if k in noise:
            continue
        if cur.get(k) != snap['dconf'].get(k):
            if k in snap['dconf']:
                subprocess.run(['dconf', 'write', k, snap['dconf'][k]], capture_output=True)
            else:
                subprocess.run(['dconf', 'reset', k], capture_output=True)


def run(labels):
    snap = pickle.load(open(f'{OUT}/snapshot.pkl', 'rb'))
    noise = set(json.load(open(f'{OUT}/noise.json'))) if os.path.exists(f'{OUT}/noise.json') else set()
    dnoise = set(json.load(open(f'{OUT}/dconf_noise.json'))) if os.path.exists(f'{OUT}/dconf_noise.json') else set()
    base = snap['getters']
    results = json.load(open(f'{OUT}/results2.json')) if os.path.exists(f'{OUT}/results2.json') else {}
    for i, (label, script, extra, env) in enumerate(ROWS):
        if labels and label not in labels:
            continue
        hexv = f'ff{(i * 5) % 256:02x}{(255 - i * 5) % 256:02x}'
        e = dict(os.environ); e.update(env)
        t0 = time.time()
        try:
            r = subprocess.run(['bash', f'{MS}/{script}', *extra, hexv], capture_output=True, text=True, env=e, timeout=90, stdin=subprocess.DEVNULL)
            rc, so, se = r.returncode, r.stdout.strip(), r.stderr.strip()
        except subprocess.TimeoutExpired:
            rc, so, se = -9, '', 'TIMEOUT'
        time.sleep(1.0)
        after = getters()
        changed, added, removed = diff_state(snap)
        changed = [p for p in changed if p not in noise]
        added = [p for p in added if p not in noise]
        removed = [p for p in removed if p not in noise]
        dnow = dconf()
        dch = sorted(k for k in set(dnow) | set(snap['dconf']) if dnow.get(k) != snap['dconf'].get(k) and k not in dnoise)
        files = []
        for p in changed + added:
            try:
                data = read(p)
            except OSError:
                continue
            txt = data.decode('utf8', 'replace').lower()
            old = snap['contents'].get(p, b'').decode('utf8', 'replace').lower().splitlines()
            new = txt.splitlines()
            oldset = set(old)
            newlines = [l for l in new if l not in oldset]
            removed_l = [l for l in old if l not in set(new)]
            blk = {}
            if p.endswith(('gtk-4.0/gtk.css', 'gnome-shell.css')):
                def blocks(lines):
                    d, cur, out = {}, None, []
                    for l in lines:
                        m = re.search(r'knomadic: (\S+) begin', l)
                        if m: cur = m.group(1); d[cur] = []; continue
                        if cur and re.search(r'knomadic: \S+ end', l): cur = None; continue
                        (d[cur] if cur else out).append(l)
                    d['<<outside marked blocks>>'] = out
                    return d
                bo, bn = blocks(old), blocks(new)
                blk = {k: 'changed' for k in set(bo) | set(bn) if bo.get(k) != bn.get(k)}
            files.append({'blocks': blk, 'removed_lines': len(removed_l), 'content_changed': data != snap['contents'].get(p), 'path': p.replace(HOME, '~'), 'new': p in added, 'has_hex': hexv in txt, 'lines_changed': len(newlines),
                          'changed_lines_without_hex': sum(1 for l in newlines if hexv not in l), 'size': len(data)})
        self_ok = after[label] == hexv
        talk = {k: (base[k], v) for k, v in after.items() if k != label and v != base[k]}
        results[label] = {'hex': hexv, 'rc': rc, 'stdout': so[-300:], 'stderr': se[-300:], 'getter_after': after[label], 'getter_base': base[label],
                          'getter_ok': self_ok, 'crosstalk': talk, 'files': files, 'removed': [p.replace(HOME, '~') for p in removed],
                          'dconf': dch, 'unwatched': unwatched_since(t0), 'secs': round(time.time() - t0, 1)}
        restore(snap, changed, added, removed)
        dconf_restore(snap, dnoise)
        time.sleep(0.5)
        back = getters()
        results[label]['restored_getters_ok'] = (back == base)
        print(f'{label[:52]:52s} rc={rc} getter={"OK " if self_ok else "BAD"} files={len(files)} dconf={len(dch)} xtalk={len(talk)} restored={back == base}', flush=True)
        json.dump(results, open(f'{OUT}/results2.json', 'w'), indent=1)


def verify():
    snap = pickle.load(open(f'{OUT}/snapshot.pkl', 'rb'))
    noise = set(json.load(open(f'{OUT}/noise.json'))) if os.path.exists(f'{OUT}/noise.json') else set()
    c, a, r = diff_state(snap)
    bad = []
    for p in c:
        if p in noise: continue
        if snap['man'][p][0] == 'f' and read(p) == snap['contents'][p]:
            continue  # mtime-only
        bad.append(p)
    print('content differences vs snapshot:', *bad, sep='\n  ')
    print('added:', *[p for p in a if p not in noise], sep='\n  ')
    print('removed:', *[p for p in r if p not in noise], sep='\n  ')
    dnow = dconf(); dn = set(json.load(open(f'{OUT}/dconf_noise.json'))) if os.path.exists(f'{OUT}/dconf_noise.json') else set()
    print('dconf differences:', *sorted(k for k in set(dnow) | set(snap['dconf']) if dnow.get(k) != snap['dconf'].get(k) and k not in dn), sep='\n  ')
    print('getters equal baseline:', getters() == snap['getters'])


def _name(h):
    import colorsys
    r, g, b = (int(h[i:i + 2], 16) / 255 for i in (0, 2, 4))
    hh, l, sat = colorsys.rgb_to_hls(r, g, b)
    hue = ['red', 'orange', 'yellow', 'lime', 'green', 'spring green', 'cyan', 'azure', 'blue', 'violet', 'magenta', 'rose'][int(((hh * 360 + 15) % 360) // 30)]
    return ('light ' if l > 0.62 else 'dark ' if l < 0.42 else '') + hue


def applyall():
    import colorsys
    snap = pickle.load(open(f'{OUT}/snapshot.pkl', 'rb'))   # refuses to run without a snapshot
    lines = []
    for i, (label, script, extra, env) in enumerate(ROWS):
        hh = (i * 137.508) % 360 / 360; l = (0.42, 0.55, 0.68)[i % 3]
        hexv = '%02x%02x%02x' % tuple(round(c * 255) for c in colorsys.hls_to_rgb(hh, l, 1.0))
        e = dict(os.environ); e.update(env)
        r = subprocess.run(['bash', f'{MS}/{script}', *extra, hexv], capture_output=True, text=True, env=e, timeout=90, stdin=subprocess.DEVNULL)
        lines.append(f'{i + 1:2d}. #{hexv}  {_name(hexv):13s} {label}' + ('' if r.returncode == 0 else f'   !! exit {r.returncode}: {r.stderr.strip()[:80]}'))
        print(lines[-1], flush=True)
    open(f'{OUT}/legend.txt', 'w').write('\n'.join(lines) + '\n')
    print(f'\nlegend: {OUT}/legend.txt\nto undo: python3 -I {os.path.abspath(__file__)} restore')


def restore_all():
    snap = pickle.load(open(f'{OUT}/snapshot.pkl', 'rb'))
    noise = set(json.load(open(f'{OUT}/noise.json'))) if os.path.exists(f'{OUT}/noise.json') else set()
    dnoise = set(json.load(open(f'{OUT}/dconf_noise.json'))) if os.path.exists(f'{OUT}/dconf_noise.json') else set()
    c, a, r = diff_state(snap)
    restore(snap, [p for p in c if p not in noise], [p for p in a if p not in noise], [p for p in r if p not in noise])
    dconf_restore(snap, dnoise)
    print('restored; checking...'); verify()


def keep():
    S = f'{OUT}/snapshot.pkl'; d = pickle.load(open(S, 'rb'))
    for p in sys.argv[2:]:
        p = os.path.abspath(os.path.expanduser(p)); st = os.lstat(p)
        d['contents'][p] = read(p); d['man'][p] = ('f', st.st_mtime_ns, st.st_size, st.st_mode, None); print('kept', p)
    pickle.dump(d, open(S, 'wb'))


def list_rows():
    print(f'{len(ROWS)} swatches discovered from {PREFS}')
    for lab, script, extra, env in ROWS:
        print(f'  {lab}   [{script} {" ".join(extra)}]{"  (SHELL_CSS: GDM step skipped)" if env else ""}')
    print('UNPARSED makeColorPickRow call sites (add to EXTRA_ROWS or extend discover()):' if UNPARSED else 'no unparsed call sites', *UNPARSED, sep='\n  ')


def report():
    r = json.load(open(f'{OUT}/results.json'))
    print(f'{len(r)} swatches tested')
    for k, v in r.items():
        notes = []
        if v['rc'] != 0: notes.append(f"exit code {v['rc']}")
        if v['stderr']: notes.append('stderr: ' + v['stderr'][:80].replace('\n', ' '))
        if not v['getter_ok']: notes.append(f"getter reads {v['getter_after']!r}, expected {v['hex']}")
        if not v['files'] and not v['dconf']: notes.append('NO EFFECT: no file or dconf change')
        for f in v['files']:
            if f['new']: notes.append('new file ' + f['path'])
            elif not f['has_hex'] and f.get('content_changed', True) and f['lines_changed']: notes.append(f"{f['path']}: {f['lines_changed']} changed lines without the colour")
        for t, (b, a) in v['crosstalk'].items(): notes.append(f'cross-talk: {t} {b} -> {a}')
        if v.get('unwatched'): notes.append('unwatched writes: ' + ', '.join(v['unwatched'][:5]))
        if not v['restored_getters_ok']: notes.append('RESTORE: getters differ from baseline afterwards')
        print(f'{"!!" if notes else "ok"} {k}' + ''.join(f'\n      {n}' for n in notes))


if __name__ == '__main__':
    cmd = sys.argv[1] if len(sys.argv) > 1 else 'list'
    {'snapshot': snapshot, 'idle': idle, 'verify': verify, 'list': list_rows, 'report': report, 'applyall': applyall, 'restore': restore_all, 'keep': keep}.get(cmd, lambda: run(sys.argv[2:]))()
