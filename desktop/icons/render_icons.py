#!/usr/bin/env python3
"""Re-render icons/png/g2hub-<size>.png from the SVGs (run after editing an SVG).

    python3 desktop/icons/render_icons.py

Uses GdkPixbuf's librsvg loader (system PyGObject, no extra packages). 16-32 px come from the
simplified g2hub-small.svg, the rest from g2hub.svg.
"""
import os
import gi
gi.require_version('GdkPixbuf', '2.0')
from gi.repository import GdkPixbuf  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
SIZES = (16, 24, 32, 48, 64, 128, 256, 512)

out = os.path.join(HERE, 'png')
os.makedirs(out, exist_ok=True)
for size in SIZES:
    src = os.path.join(HERE, 'g2hub-small.svg' if size <= 32 else 'g2hub.svg')
    pb = GdkPixbuf.Pixbuf.new_from_file_at_size(src, size, size)
    pb.savev(os.path.join(out, f'g2hub-{size}.png'), 'png', [], [])
    print(f'png/g2hub-{size}.png')
