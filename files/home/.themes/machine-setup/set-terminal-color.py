#!/usr/bin/env python3
# set-terminal-color.sh base|titlebar|body|main <value|--get> - Ptyxis colours (Knomadic: Terminal > Palette / Titlebar / Body).
# Like the Text Editor: pick any palette (a Ptyxis built-in such as "Catppuccin Mocha", or "Black Plum" = ~/.local/share/org.gnome.Ptyxis/palettes/black-plum.palette),
# then override ONLY the backgrounds. State: ~/.config/fm-tweaks/terminal.conf (base=, titlebar=, body=; an empty override follows the palette).
# Output: ~/.local/share/org.gnome.Ptyxis/palettes/knomadic.palette (selected as the profile palette). Text/cursor/ANSI colours come from the base untouched.
# 'main' = the prompt user@host colour (ANSI green: Color2, and its bright twin Color10); 'main default' clears the override. Applies to NEW Ptyxis windows.
import sys, os, re, subprocess, configparser
H = os.path.expanduser('~'); CONF = H + '/.config/fm-tweaks/terminal.conf'; PD = H + '/.local/share/org.gnome.Ptyxis/palettes/'
role, arg = (sys.argv + ['', ''])[1:3]
if role == 'list':   # every palette that can be a base: Black Plum first, then Ptyxis' built-ins
    names = subprocess.check_output(['gresource', 'list', '/usr/bin/ptyxis']).decode().splitlines()
    print('Black Plum'); [print(re.sub(r'.*/(.*)\.palette$', r'\1', n)) for n in sorted(names) if n.startswith('/org/gnome/Ptyxis/palettes/')]; sys.exit()
if role not in ('base', 'titlebar', 'body', 'main') or not arg:
    sys.exit('Usage: set-terminal-color.sh base|titlebar|body|main <value|--get|default(main only)>')
cp = configparser.RawConfigParser(); cp.read(CONF)
if not cp.has_section('terminal'): cp.add_section('terminal')
g = lambda k, d='': cp.get('terminal', k, fallback=d)
def resolve(name):   # accept Ptyxis' palette ids (any case / dashes) as well as the display names
    import unicodedata
    norm = lambda x: re.sub(r'[^a-z0-9]', '', unicodedata.normalize('NFKD', x).encode('ascii', 'ignore').decode().lower())
    names = ['Black Plum'] + [re.sub(r'.*/(.*)\.palette$', r'\1', n) for n in subprocess.check_output(['gresource', 'list', '/usr/bin/ptyxis']).decode().splitlines() if n.startswith('/org/gnome/Ptyxis/palettes/')]
    return next((n for n in names if n == name), next((n for n in names if norm(n) == norm(name)), name))
def load_base(name):
    name = resolve(name)
    if name == 'Black Plum':
        txt = open(PD + 'black-plum.palette').read(); txt = txt.split('[Dark]')[-1] if '[Dark]' in txt else txt
    else:
        txt = subprocess.check_output(['gresource', 'extract', '/usr/bin/ptyxis', f'/org/gnome/Ptyxis/palettes/{name}.palette']).decode()
    return dict(l.split('=', 1) for l in txt.splitlines() if re.match(r'^[A-Za-z0-9]+=', l))
base = g('base', 'Black Plum'); 
try: pal = load_base(base)
except Exception: base = 'Black Plum'; pal = load_base(base)
bg0 = pal.get('Background', '#161618'); tb0 = pal.get('TitlebarBackground', bg0)
if arg == '--get':
    print({'base': base, 'body': g('body') or bg0, 'titlebar': g('titlebar') or g('body') or tb0, 'main': g('main') or pal.get('Color2', '#FFFFFF')}[role].lstrip('#').lower()) if role != 'base' else print(base); sys.exit()
if role == 'base':
    base = resolve(arg)
    try: pal = load_base(base)
    except Exception: sys.exit(f'unknown palette: {arg}')
    cp.set('terminal', 'base', base)
elif role == 'main' and arg == 'default':
    cp.remove_option('terminal', 'main')
else:
    h = arg.lstrip('#').upper()
    if not re.fullmatch(r'[0-9A-F]{6}', h): sys.exit('bad hex')
    cp.set('terminal', role, '#' + h)
os.makedirs(os.path.dirname(CONF), exist_ok=True); cp.write(open(CONF, 'w'))
bg = g('body') or pal.get('Background', '#161618'); tb = g('titlebar') or bg
out = dict(pal); out.update(Background=bg, TitlebarBackground=tb)
if g('main'): out.update(Color2=g('main'), Color10=g('main'))
if 'TitlebarForeground' not in out: out['TitlebarForeground'] = out.get('Foreground', '#FFFFFF')
out.pop('Name', None)
order = ['Foreground', 'Background', 'Cursor', 'TitlebarBackground', 'TitlebarForeground'] + [f'Color{i}' for i in range(16)]
body = ''.join(f'{k}={out[k]}\n' for k in order if k in out)
os.makedirs(PD, exist_ok=True); open(PD + 'knomadic.palette', 'w').write(f'[Palette]\nName=Knomadic\n\n[Light]\n{body}\n[Dark]\n{body}')
G4 = H + '/.config/gtk-4.0/gtk.css'   # header bar keeps ONE colour (focused, unfocused, hovered): block rewritten on every change
css = open(G4).read() if os.path.exists(G4) else ''
css = re.sub(r'/\* PTYXIS-TITLEBAR START \*/.*?/\* PTYXIS-TITLEBAR END \*/\n?', '', css, flags=re.S)
sel = ', '.join(f'window.ptyxis-window headerbar.main-header-bar{x}' for x in ('', ':backdrop', ':hover', ':active'))
css += f'/* PTYXIS-TITLEBAR START */\n{sel} {{ background: {tb}; background-color: {tb}; background-image: none; color: inherit; }}\n/* PTYXIS-TITLEBAR END */\n'
open(G4, 'w').write(css)
u = subprocess.check_output(['gsettings', 'get', 'org.gnome.Ptyxis', 'default-profile-uuid']).decode().strip().strip("'")
subprocess.run(['gsettings', 'set', f'org.gnome.Ptyxis.Profile:/org/gnome/Ptyxis/Profiles/{u}/', 'palette', 'knomadic'], check=True)
print(f'{base}: body={bg} titlebar={tb} main={g("main") or "palette"}')
