#!/usr/bin/env python3
"""_shell_text.py CSS ROLE (--get | HEX) - the shell TEXT/ICON colour roles of set-shell-color.sh (called by it; not run by hand).

Roles: qs-text, calendar-text, calendar-dim  (topbar-text is a plain in-place edit of the "Panel text" rules, done by set-shell-color.sh itself).

Each role owns ONE marked sub-block inside a single outer block that sits at the very END of gnome-shell.css (after the generated blocks), so its rules win
over equal-specificity rules above them:
    /* BEGIN shell-text-colors ... */
    /* BEGIN text-<role> */ rules /* END text-<role> */
    /* END shell-text-colors */
A role that was never set has no sub-block = stock/previous look. --get prints the colour in effect (the stock colour when unset).
GNOME Shell's St CSS does NOT support :not() (see the comment about calendar-day in the CSS), so checked toggles are re-asserted with an explicit rule instead.
"""
import re, sys

path, role, val = sys.argv[1:4]
OUT_B, OUT_E = '/* BEGIN shell-text-colors', '/* END shell-text-colors */'
STATES = ('', ':hover', ':focus', ':active')

def sel(bases, states=STATES):
    return ',\n'.join(b + s for b in bases for s in states)

BANNER = ['.datemenu-today-button', '.datemenu-today-button .day-label', '.datemenu-today-button .date-label', '.world-clocks-button', '.events-button', '.weather-button',
          '.events-button .events-box .events-title', '.events-button .events-box .events-list .event-box .event-time', '.events-button .events-box .events-list .event-placeholder',
          '.world-clocks-button .world-clocks-header', '.world-clocks-button .world-clocks-grid .world-clocks-timezone', '.weather-button .weather-box .weather-header-box .weather-header']

def rules(r, c):
    if r == 'qs-text':
        main = ['.quick-settings', '.quick-toggle-menu', '.quick-settings .quick-toggle', '.quick-settings .quick-toggle-menu-button', '.quick-settings .icon-button',
                '.quick-settings .button', '.quick-settings .popup-menu-item', '.quick-toggle-menu .popup-menu-item']
        checked = ['.quick-settings .quick-toggle', '.quick-settings .quick-toggle-menu-button']
        return ('%s {\n    color: #%s;\n}\n/* the slider handle is painted in the slider\'s text colour */\n%s {\n    color: #%s;\n}\n'
                '/* St has no :not(): switched-on toggles go back to the accent foreground explicitly */\n%s {\n    color: -st-accent-fg-color;\n}\n'
                % (sel(main), c, sel(['.quick-settings .slider'], ('', ':hover')), c, sel(checked, (':checked', ':checked:hover', ':checked:focus', ':checked:active'))))
    if r == 'calendar-text':
        days = ['.calendar .calendar-day', '.calendar .calendar-day-heading', '.calendar .calendar-month-header .pager-button']
        return ('%s {\n    color: #%s;\n}\n.calendar .calendar-month-header .calendar-month-label {\n    color: #%s !important;\n}\n%s {\n    color: #%s;\n}\n'
                % (sel(days), c, c, ',\n'.join(BANNER), c))
    if r == 'calendar-dim':
        return ('.calendar .calendar-day.calendar-other-month,\n.calendar .calendar-day.calendar-other-month.calendar-weekend {\n    color: #%s;\n}\n' % c)
    sys.exit('unknown text role ' + role)

def sub_re(r):
    return re.compile(r'/\* BEGIN text-' + re.escape(r) + r' \*/.*?/\* END text-' + re.escape(r) + r' \*/\n?', re.S)

text = open(path).read()
if val == '--get':
    m = sub_re(role).search(text)
    h = re.search(r'color: #([0-9a-fA-F]{6})', m.group(0)) if m else None
    if h:
        print(h.group(1).lower())
    elif role == 'calendar-dim':       # stock = white at 50% over the day-number pill
        i = text.find('.calendar .calendar-day {')
        b = re.search(r'#([0-9a-fA-F]{6})', text[i:i + 300]) if i >= 0 else None
        bg = [int(b.group(1)[k:k + 2], 16) for k in (0, 2, 4)] if b else [54, 54, 58]
        print(''.join('%02x' % round((255 + x) / 2) for x in bg))
    else:
        print('ffffff')
    sys.exit(0)

new = val.lstrip('#').lower()
if not re.fullmatch(r'[0-9a-f]{6}', new):
    sys.exit("Error: '%s' doesn't look like a valid 6-digit hex color." % val)
block = '/* BEGIN text-%s */\n%s/* END text-%s */\n' % (role, rules(role, new), role)
if OUT_B not in text:
    text = text.rstrip('\n') + '\n\n' + OUT_B + ' (set-shell-color.sh text roles; kept LAST so they win over equal-specificity rules above; do not move) */\n' + OUT_E + '\n'
m = sub_re(role).search(text)
if m:
    text = text[:m.start()] + block + text[m.end():]
else:
    i = text.index(OUT_E)
    text = text[:i] + block + text[i:]
open(path, 'w').write(text)
print('  %s: updated to #%s' % (role, new))
