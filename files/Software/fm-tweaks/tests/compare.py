#!/usr/bin/env python3
"""tests/compare.py golden.png new.png - exit 0 when the two window renders match, ignoring the breadcrumb strip (y < 22; it animates / elides non-deterministically)."""
import sys
from PIL import Image, ImageChops
a, b = (Image.open(p).convert('RGB') for p in sys.argv[1:3])
if a.size != b.size:
    sys.exit('size differs: %s vs %s' % (a.size, b.size))
box = (0, 22, a.width, a.height)
d = ImageChops.difference(a.crop(box), b.crop(box)).getbbox()
print('IDENTICAL' if d is None else 'DIFFERENT in %s' % (d,))
sys.exit(0 if d is None else 1)
