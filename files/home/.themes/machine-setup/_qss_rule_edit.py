#!/usr/bin/env python3
"""
_qss_rule_edit.py --get <qss> <selector> <property>
_qss_rule_edit.py --set <qss> <selector> <property> <hex>

Anchor-scoped edit of ONE property inside ONE rule of a QSS file. <selector> is the
rule's full selector text (comma/newline/whitespace-normalized), matched against the
text right before its `{`. Only the first `<property>: #xxxxxx` in that rule changes.
Never a file-wide hex replace (same bug class as the invisible-fonts incident).
"""
import re, sys

def norm(s):
    return re.sub(r'\s+', ' ', s.strip()).replace(' ,', ',')

def blocks(text):
    for m in re.finditer(r'([^{}]+)\{([^{}]*)\}', text):
        yield m, m.group(1), m.group(2)

def find(text, selector, prop):
    target = norm(selector)
    for m, sel, body in blocks(text):
        # drop any leading /* comment */ swept into the capture
        s = norm(re.sub(r'/\*.*?\*/', '', sel, flags=re.S))
        if s == target:
            pm = re.search(r'(' + re.escape(prop) + r'\s*:\s*)#([0-9a-fA-F]{6})', body)
            if pm:
                return m, pm
    return None, None

def main():
    mode, path, selector, prop = sys.argv[1:5]
    text = open(path).read()
    m, pm = find(text, selector, prop)
    if mode == '--get':
        if pm:
            print(pm.group(2).lower())
        return
    if not pm:
        print(f"  WARNING: rule `{norm(selector)}` with `{prop}: #hex` not found - nothing changed", file=sys.stderr)
        sys.exit(2)
    new = sys.argv[5].lower()
    body_start = m.start(2)
    a, b = body_start + pm.start(2), body_start + pm.end(2)
    open(path, 'w').write(text[:a] + new + text[b:])
    print(f"  updated `{norm(selector)}` {prop} -> #{new}")

if __name__ == '__main__':
    main()
