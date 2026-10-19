#!/usr/bin/env python3
"""Dolphin color dye-test harness (see README.md). Runs live under J; the real config is only ever READ (copied/symlinked)."""
import colorsys, json, os, re, shutil, subprocess, sys, collections

HERE = os.path.dirname(os.path.abspath(__file__))
J = os.environ.get('DYE_WORK') or os.path.expanduser('~/.cache/dolphin-dye')   # work dir: runs, screenshots, test files (safe to delete)
REAL = os.path.expanduser('~')
SRC = os.environ.get('DYE_SRC_HOME') or REAL           # where the color source files are copied from (default: live config)

class Reg:
    def __init__(self):
        self.i = 0
        self.legend = {}          # 'rrggbb' -> label
    def new(self, label):
        while True:
            h = (self.i * 0.6180339887) % 1.0
            s = (1.0, 0.65, 0.85)[(self.i // 3) % 3]
            v = (1.0, 0.8, 0.6)[self.i % 3]
            self.i += 1
            r, g, b = [round(x * 255) for x in colorsys.hsv_to_rgb(h, s, v)]
            hx = '%02x%02x%02x' % (r, g, b)
            if hx not in self.legend:
                self.legend[hx] = label
                return hx

COLOR_SECTIONS = ['View', 'Window', 'Button', 'Selection', 'Tooltip', 'Complementary', 'Header']
COLOR_KEYS = ['BackgroundNormal', 'BackgroundAlternate', 'ForegroundNormal', 'ForegroundInactive', 'ForegroundActive', 'ForegroundLink',
              'ForegroundVisited', 'ForegroundNegative', 'ForegroundNeutral', 'ForegroundPositive', 'DecorationFocus', 'DecorationHover']

def rgb(hx):
    return '%d,%d,%d' % (int(hx[0:2], 16), int(hx[2:4], 16), int(hx[4:6], 16))

def dye_kcs(src, dst, reg, tag):
    """KColorScheme ini (bluegrey.colors / kdeglobals): every key of every Colors:* set gets its own hue (missing keys/sets are added)."""
    lines = open(src).read().split('\n')
    out, sec, seen = [], None, {}
    want = {'Colors:' + s for s in COLOR_SECTIONS}
    for ln in lines:
        m = re.match(r'^\[(.+)\]\s*$', ln)
        if m:
            sec = m.group(1)
            out.append(ln)
            if sec in want:
                seen[sec] = set()
            continue
        m = re.match(r'^([^=\s][^=]*)=(.*)$', ln)
        if sec in want and m and m.group(1) in COLOR_KEYS:
            k = m.group(1)
            out.append('%s=%s' % (k, rgb(reg.new('%s %s %s' % (tag, sec, k)))))
            seen[sec].add(k)
            continue
        out.append(ln)
    # append missing keys/sets as new sections (a repeated [section] header is merged by KConfig)
    for s in sorted(want):
        miss = [k for k in COLOR_KEYS if k not in seen.get(s, set())]
        if miss:
            out.append('')
            out.append('[%s]' % s)
            for k in miss:
                out.append('%s=%s' % (k, rgb(reg.new('%s %s %s (added)' % (tag, s, k)))))
    open(dst, 'w').write('\n'.join(out) + '\n')

QT_ROLES = ['WindowText', 'Button', 'Light', 'Midlight', 'Dark', 'Mid', 'Text', 'BrightText', 'ButtonText', 'Base', 'Window', 'Shadow',
            'Highlight', 'HighlightedText', 'Link', 'LinkVisited', 'AlternateBase', 'NoRole', 'ToolTipBase', 'ToolTipText', 'PlaceholderText', 'Accent']

def dye_qt6ct_palette(src, dst, reg, tag):
    out = []
    for ln in open(src).read().split('\n'):
        m = re.match(r'^(active|disabled|inactive)_colors=(.*)$', ln)
        if m:
            g = m.group(1)
            n = len(m.group(2).split(','))
            cols = ['#ff' + reg.new('%s %s %s' % (tag, g, QT_ROLES[i] if i < len(QT_ROLES) else 'role%d' % i)) for i in range(n)]
            out.append('%s_colors=%s' % (g, ', '.join(cols)))
        else:
            out.append(ln)
    open(dst, 'w').write('\n'.join(out))

NAMED = {'white': 'ffffff', 'black': '000000'}
def dye_qss(src, dst, reg, tag):
    text = open(src).read()
    # selector/property context per occurrence
    res, pos = [], 0
    pat = re.compile(r'/\*.*?\*/|#[0-9a-fA-F]{6}\b|#[0-9a-fA-F]{3}\b|\b(?:white|black)\b', re.S)
    def ctx(at):
        head = re.sub(r'/\*.*?\*/', '', text[:at], flags=re.S)
        sel = head[head.rfind('}') + 1:head.rfind('{')].strip().replace('\n', ' ') if head.rfind('{') > head.rfind('}') else '?'
        prop = head[max(head.rfind(';'), head.rfind('{')) + 1:].strip().split(':')[0].strip()
        return sel[:60], prop
    for m in pat.finditer(text):
        if m.group(0).startswith('/*'):
            continue
        sel, prop = ctx(m.start())
        line = text.count('\n', 0, m.start()) + 1
        hx = reg.new('%s %s L%d [%s] %s' % (tag, os.path.basename(src), line, sel, prop))
        res.append((m.start(), m.end(), '#' + hx))
    out, last = [], 0
    for a, b, rep in res:
        out.append(text[last:a]); out.append(rep); last = b
    out.append(text[last:])
    open(dst, 'w').write(''.join(out))

def ensure_files():
    a, b = J + '/files/a', J + '/files/b'
    if os.path.isdir(a):
        return
    for d in (a + '/Documents', a + '/Downloads', a + '/Pictures', a + '/Projects', b + '/Music'):
        os.makedirs(d)
    for f in ('notes.txt', 'report.pdf', 'photo.jpg', 'archive.tar.gz', 'script.sh', 'data.csv', '.hidden_file', 'readme.md'):
        open(a + '/' + f, 'w').write('x\n')
    for f in ('song.mp3', 'clip.mkv', 'todo.txt'):
        open(b + '/' + f, 'w').write('x\n')
    for d in (a, b):
        open(d + '/.directory', 'w').write('[Dolphin]\nViewMode=2\nVersion=4\nShowPreview=false\n')

def build_home(run, spec, reg):
    ensure_files()
    H = '%s/%s/home' % (J, run)
    shutil.rmtree('%s/%s' % (J, run), ignore_errors=True)
    os.makedirs(H + '/.config'); os.makedirs(H + '/.local/share'); os.makedirs(H + '/.themes'); os.makedirs(H + '/.cache')
    def link_all(sub, skip):
        for e in os.listdir('%s/%s' % (REAL, sub)):
            if e not in skip:
                os.symlink('%s/%s/%s' % (REAL, sub, e), '%s/%s/%s' % (H, sub, e))
    link_all('.config', {'kdeglobals', 'qt6ct', 'dolphinrc', 'dolphin-kinetic-scroll.conf'})
    # the kinetic conf (shim reads it) is copied so nothing can write back to the live one
    shutil.copy('%s/.config/dolphin-kinetic-scroll.conf' % REAL, H + '/.config/')
    if os.environ.get('DYE_KINETIC_CONF_APPEND'):   # e.g. 'Log=true' (appended to the harness COPY of the kinetic conf)
        open(H + '/.config/dolphin-kinetic-scroll.conf', 'a').write(os.environ['DYE_KINETIC_CONF_APPEND'] + '\n')
    shutil.copy('%s/.config/dolphinrc' % REAL, H + '/.config/dolphinrc')
    link_all('.local/share', {'color-schemes', 'dolphin', 'kxmlgui5', 'recently-used.xbel', 'user-places.xbel', 'user-places.xbel.tbcache'})
    for e in ('dolphin', 'kxmlgui5'):
        shutil.copytree('%s/.local/share/%s' % (REAL, e), '%s/.local/share/%s' % (H, e), symlinks=True)
    for e in ('recently-used.xbel', 'user-places.xbel'):
        if os.path.exists('%s/.local/share/%s' % (REAL, e)):
            shutil.copy('%s/.local/share/%s' % (REAL, e), '%s/.local/share/%s' % (H, e))
    link_all('.themes', {'dolphin-theme', 'qt6ct', 'kdeglobals', 'color-schemes'})
    for e in os.listdir(REAL + '/.cache'):
        if e in ('fontconfig',):
            os.symlink('%s/.cache/%s' % (REAL, e), '%s/.cache/%s' % (H, e))
    # --- copies of the color sources (dyed or not)
    shutil.copytree('%s/.themes/qt6ct' % SRC, H + '/.config/qt6ct')
    os.makedirs(H + '/.local/share/color-schemes')
    shutil.copytree('%s/.themes/dolphin-theme' % SRC, H + '/.themes/dolphin-theme')
    shutil.copy('%s/.themes/kdeglobals' % SRC, H + '/.config/kdeglobals')
    shutil.copy('%s/.themes/color-schemes/bluegrey.colors' % SRC, H + '/.local/share/color-schemes/bluegrey.colors')
    # qt6ct.conf: point absolute paths at the copy
    p = H + '/.config/qt6ct/qt6ct.conf'
    t = open(p).read().replace('/home/blank/.config/qt6ct', H + '/.config/qt6ct')
    open(p, 'w').write(t)
    if 'kcs-scheme' in spec:
        dye_kcs('%s/.themes/color-schemes/bluegrey.colors' % REAL, H + '/.local/share/color-schemes/bluegrey.colors', reg, 'scheme')
    if 'kcs-globals' in spec:
        dye_kcs('%s/.themes/kdeglobals' % REAL, H + '/.config/kdeglobals', reg, 'kdeglobals')
    if 'qt6ct' in spec:
        dye_qt6ct_palette('%s/.themes/qt6ct/colors/Gradience.conf' % REAL, H + '/.config/qt6ct/colors/Gradience.conf', reg, 'qt6ct')
    if 'qss-global' in spec:
        dye_qss('%s/.themes/qt6ct/global-rounded-menus.qss' % REAL, H + '/.config/qt6ct/global-rounded-menus.qss', reg, 'qss-global')
    if 'qss-flag' in spec:
        dye_qss('%s/.themes/dolphin-theme/dolphin-lines.qss' % REAL, H + '/.themes/dolphin-theme/dolphin-lines.qss', reg, 'qss-flag')
    if 'no-global-qss' in spec:
        t = open(p).read()
        t = re.sub(r'^stylesheets=.*\n', '', t, flags=re.M)
        open(p, 'w').write(t)
    if 'menubar' in spec:
        q = H + '/.config/dolphinrc'
        s = open(q).read().replace('MenuBar=Disabled', 'MenuBar=Enabled')
        open(q, 'w').write(s)
    if 'no-scheme' in spec:
        q = H + '/.config/dolphinrc'
        s = open(q).read()
        s = re.sub(r'^ColorScheme=.*\n', '', s, flags=re.M)
        open(q, 'w').write(s)
    if 'breeze' in spec:
        hx = reg.new('breeze pathbar')
        open(H + '/.themes/dolphin-theme/breeze-colors.conf', 'w').write('pathbar=#%s\n' % hx)
    json.dump(reg.legend, open('%s/%s/legend.json' % (J, run), 'w'), indent=1)
    return H

def run_dolphin(run, H, split=False, extra=None, size='1200x760'):
    shotdir = '%s/%s' % (J, run)
    env = dict(os.environ)
    for k in ('XDG_CONFIG_HOME', 'XDG_DATA_HOME', 'XDG_CACHE_HOME'):
        env.pop(k, None)
    kp = REAL + '/.themes/kf6-patched'
    env.update(HOME=H, QT_QPA_PLATFORM=os.environ.get('DYE_PLATFORM', 'offscreen'), QT_QPA_PLATFORMTHEME='qt6ct', DBUS_SESSION_BUS_ADDRESS='unix:path=/nonexistent',
               DYE_SHOT_DIR=shotdir, DYE_SIZE=size, DYE_OPENWITH_FILE=J + '/files/a/notes.txt', DYE_ACTIONS=os.environ.get('DYE_ACTIONS_OVERRIDE', 'wait:5000;shot;hover:500,150;wait:700;shot;deactivate;wait:500;shot;quit'))
    shim = os.environ.get('DYE_SHIM') or (kp + '/libdolphin-expander-arrows.so')   # DYE_SHIM: test a candidate shim build
    pre = ['LD_PRELOAD=%s:%s/.themes/qt-noicons/libqt-noicons.so:%s/shot.so' % (shim, REAL, HERE), 'LD_LIBRARY_PATH=' + kp]
    args = ['dolphin', '--new-window']
    if extra:
        args += extra
    if os.environ.get('DYE_OPEN_DIR'):
        args += [os.environ['DYE_OPEN_DIR']]
    elif split:
        args += ['--split', J + '/files/a', J + '/files/b']
    else:
        args += ['--select', J + '/files/a/notes.txt', J + '/files/a/Documents']
    r = subprocess.run(['timeout', '60', 'env'] + pre + args, env=env, capture_output=True, text=True)
    return r

def read_ppm(path):
    b = open(path, 'rb').read()
    m = re.match(rb'P6\s+(\d+)\s+(\d+)\s+255\s', b)
    w, h = int(m.group(1)), int(m.group(2))
    return w, h, b[m.end():]

def analyze(run, shot='shot-0.ppm', topn=25):
    legend = json.load(open('%s/%s/legend.json' % (J, run)))
    w, h, px = read_ppm('%s/%s/%s' % (J, run, shot))
    cnt, box = collections.Counter(), {}
    for i in range(0, len(px), 3):
        c = px[i:i+3].hex()
        cnt[c] += 1
        n = i // 3
        x, y = n % w, n // w
        bx = box.get(c)
        if bx is None:
            box[c] = [x, y, x, y]
        else:
            if x < bx[0]: bx[0] = x
            if y < bx[1]: bx[1] = y
            if x > bx[2]: bx[2] = x
            if y > bx[3]: bx[3] = y
    print('image %dx%d' % (w, h))
    print('--- dye colors visible (count, bbox x0,y0-x1,y1) ---')
    vis = [(c, cnt[c]) for c in legend if cnt.get(c)]
    for c, n in sorted(vis, key=lambda t: legend[t[0]]):
        print('%7d  %-6s %s  [%s]' % (n, c, legend[c], ','.join(map(str, box[c][:2])) + '-' + ','.join(map(str, box[c][2:]))))
    print('dye colors total %d, visible %d' % (len(legend), len(vis)))
    print('--- top non-dye colors ---')
    k = 0
    for c, n in cnt.most_common():
        if c in legend:
            continue
        print('%7d  %-6s  [%s]' % (n, c, ','.join(map(str, box[c][:2])) + '-' + ','.join(map(str, box[c][2:]))))
        k += 1
        if k >= topn:
            break

if __name__ == '__main__':
    cmd, run = sys.argv[1], sys.argv[2]
    flags = set(a for a in sys.argv[3:] if not a.startswith('--') or True)
    split = '--split' in flags
    spec = {a[2:] for a in flags if a.startswith('--') and a != '--split'}
    if cmd == 'run':
        reg = Reg()
        H = build_home(run, spec, reg)
        extra = None
        if 'qss-flag' in spec or 'flag-plain' in spec:
            extra = ['-stylesheet', ('file:' if 'qss-flag-file' in spec else '') + H + '/.themes/dolphin-theme/dolphin-lines.qss']
        r = run_dolphin(run, H, split, extra)
        print('exit', r.returncode)
        print((r.stderr or '')[-800:])
        print(open('%s/%s/info.txt' % (J, run)).read() if os.path.exists('%s/%s/info.txt' % (J, run)) else 'NO info.txt')
    if cmd in ('run', 'analyze'):
        import glob
        for f in sorted(glob.glob('%s/%s/shot-*.ppm' % (J, run))):
            print('=================', os.path.basename(f))
            analyze(run, os.path.basename(f))

import zlib, struct
def write_png(path, w, h, rgb):
    raw = b''.join(b'\x00' + rgb[y*w*3:(y+1)*w*3] for y in range(h))
    def chunk(t, d):
        c = struct.pack('>I', len(d)) + t + d
        return c + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)
    open(path, 'wb').write(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(raw, 6)) + chunk(b'IEND', b''))

def diff(run, a, b, topn=15):
    legend = json.load(open('%s/%s/legend.json' % (J, run)))
    w, h, pa = read_ppm('%s/%s/%s' % (J, run, a)); _, _, pb = read_ppm('%s/%s/%s' % (J, run, b))
    ch = collections.Counter(); box = {}
    for n in range(w * h):
        i = n * 3
        if pa[i:i+3] != pb[i:i+3]:
            k = (pa[i:i+3].hex(), pb[i:i+3].hex())
            ch[k] += 1
            x, y = n % w, n // w
            bx = box.setdefault(k, [x, y, x, y])
            bx[0] = min(bx[0], x); bx[1] = min(bx[1], y); bx[2] = max(bx[2], x); bx[3] = max(bx[3], y)
    print('%s vs %s: %d distinct changes' % (a, b, len(ch)))
    for (ca, cb), n in ch.most_common(topn):
        print('%7d  %s%s -> %s%s  [%s]' % (n, ca, ('(' + legend[ca] + ')') if ca in legend else '', cb, ('(' + legend[cb] + ')') if cb in legend else '', ','.join(map(str, box[(ca, cb)][:2])) + '-' + ','.join(map(str, box[(ca, cb)][2:]))))

def mask(run, shot, colors, out):
    w, h, px = read_ppm('%s/%s/%s' % (J, run, shot))
    cs = {bytes.fromhex(c) for c in colors}
    o = bytearray(b'\x30' * (w * h * 3))
    for n in range(w * h):
        if px[n*3:n*3+3] in cs:
            o[n*3:n*3+3] = b'\xff\xff\x00'
    write_png(out, w, h, bytes(o))

if __name__ == '__main__' and sys.argv[1] == 'diff':
    diff(sys.argv[2], sys.argv[3], sys.argv[4])
if __name__ == '__main__' and sys.argv[1] == 'mask':
    mask(sys.argv[2], sys.argv[3], sys.argv[5:], sys.argv[4])

def summary(run):
    import glob
    legend = json.load(open('%s/%s/legend.json' % (J, run)))
    seen = {}
    for f in sorted(glob.glob('%s/%s/shot-*.ppm' % (J, run))):
        _, _, px = read_ppm(f)
        cnt = collections.Counter(px[i:i+3].hex() for i in range(0, len(px), 3))
        for c in legend:
            if cnt.get(c):
                seen.setdefault(c, []).append((os.path.basename(f)[5:-4], cnt[c]))
    print('--- roles visible in any shot (shot:pixels) ---')
    for c in sorted(seen, key=lambda c: legend[c]):
        print('%-6s %-70s %s' % (c, legend[c], ' '.join('%s:%d' % s for s in seen[c])))
    print('--- never visible: %d of %d ---' % (len(legend) - len(seen), len(legend)))
    for c in sorted(legend, key=lambda c: legend[c]):
        if c not in seen:
            print('   ', legend[c])
if __name__ == '__main__' and sys.argv[1] == 'summary':
    summary(sys.argv[2])

def cmp_runs(a, b):
    """Pixel-compare every shot-N.ppm of run a against run b (regression check: 0 differing pixels = identical render)."""
    import glob
    total = 0
    for f in sorted(glob.glob('%s/%s/shot-*.ppm' % (J, a))):
        name = os.path.basename(f)
        g = '%s/%s/%s' % (J, b, name)
        if not os.path.exists(g):
            print('%s: missing in %s' % (name, b)); total += 1; continue
        wa, ha, pa = read_ppm(f); wb, hb, pb = read_ppm(g)
        if (wa, ha) != (wb, hb):
            print('%s: size differs' % name); total += 1; continue
        n, x0, y0, x1, y1 = 0, wa, ha, -1, -1
        for i in range(0, len(pa), 3):
            if pa[i:i+3] != pb[i:i+3]:
                n += 1
                x, y = (i // 3) % wa, (i // 3) // wa
                x0 = min(x0, x); y0 = min(y0, y); x1 = max(x1, x); y1 = max(y1, y)
        print('%s: %d differing pixels%s' % (name, n, ('  bbox %d,%d-%d,%d' % (x0, y0, x1, y1)) if n else '')); total += n
    print('TOTAL differing pixels: %d' % total)
    return total
if __name__ == '__main__' and sys.argv[1] == 'cmp':
    cmp_runs(sys.argv[2], sys.argv[3])
