#!/usr/bin/env python3
"""
Generate Golden Gate traffic light SVGs for Qt decoration plugin and GTK4.
Gradient values derived by pixel-sampling the macOS Golden Gate screenshot.
"""

import os
import subprocess
import gi
gi.require_version('Rsvg', '2.0')
gi.require_version('cairo', '1.0')
from gi.repository import Rsvg
import cairo

QT_SVG_DIR = os.path.expanduser(
    "~/.themes/machine-setup/qt-decoration-vendor/whitesur-src/src/resources/titlebuttons"
)
GTK_ASSET_DIR = os.path.expanduser("~/.config/gtk-4.0/windows-assets")

# ── Gradient data from pixel analysis ────────────────────────────────────────
# Each button: (body_stops, spec_top, spec_bot)
# body_stops: list of (offset_pct, hex_color)
# spec_top/spec_bot: (cy, r, peak_color, mid_color)  — overlaid radials

BUTTONS = {
    "close": {
        "body": [
            (  0, "#f9665d"),
            ( 20, "#f55048"),
            ( 30, "#f44f43"),   # darkest
            ( 55, "#f25e52"),
            ( 80, "#ef6a62"),
            (100, "#f3665e"),
        ],
        "spec_top": (2.0, 3.5, "#ffc8bc", "#ffa09a"),
        "spec_bot": (13.5, 2.8, "#ff9890"),
        # pressed: darken body by ~12%
        "body_pressed": [
            (  0, "#db5a52"),
            ( 20, "#d3443c"),
            ( 30, "#d14039"),   # darkest
            ( 55, "#d05248"),
            ( 80, "#cd5d55"),
            (100, "#d05952"),
        ],
        "spec_top_pressed": (2.0, 3.5, "#e8b0a6", "#e08880"),
        "spec_bot_pressed": (13.5, 2.8, "#e07f78"),
        "icon": """<path d="m5.1686 5.0913c-0.39175 0.39171-0.39175 1.0224 0 1.4142l1.4142 1.4142-1.4142 1.4142c-0.39175 0.39178-0.39175 1.0225 0 1.4142 0.39171 0.39182 1.0225 0.39182 1.4142 0l1.4142-1.4142 1.4142 1.4142c0.39171 0.39182 1.0225 0.39182 1.4142 0 0.39174-0.39167 0.39174-1.0224 0-1.4142l-1.4142-1.4142 1.4142-1.4142c0.39174-0.39178 0.39174-1.0225 0-1.4142-0.39171-0.39182-1.0225-0.39182-1.4142 0l-1.4142 1.4142-1.4142-1.4142c-0.39171-0.39182-1.0225-0.39182-1.4142 0z" opacity=".5"/>""",
    },
    "minimize": {
        "body": [
            (  0, "#fab500"),
            ( 18, "#fcb200"),   # darkest / deepest gold
            ( 45, "#fbb600"),
            ( 65, "#fdc100"),
            ( 80, "#ffce30"),
            (100, "#ffd040"),
        ],
        "spec_top": (2.0, 3.5, "#f6f66c", "#ffed50"),
        "spec_bot": (13.5, 2.8, "#fff060"),
        "body_pressed": [
            (  0, "#dc9e00"),
            ( 18, "#de9c00"),
            ( 45, "#dfa000"),
            ( 65, "#e0aa00"),
            ( 80, "#e3b520"),
            (100, "#e4b820"),
        ],
        "spec_top_pressed": (2.0, 3.5, "#d8d850", "#e8d030"),
        "spec_bot_pressed": (13.5, 2.8, "#e8d030"),
        "icon": """<rect x="3.9999" y="7.0095" width="8.0001" height="2" ry=".99998" opacity=".5"/>""",
    },
    "maximize": {
        "body": [
            (  0, "#38c200"),
            ( 15, "#18c000"),
            ( 25, "#00bc00"),   # darkest - pure green
            ( 50, "#20bf00"),
            ( 68, "#3dc120"),
            ( 80, "#50c438"),
            (100, "#50c438"),
        ],
        "spec_top": (2.0, 3.5, "#aef88d", "#80ef64"),
        "spec_bot": (13.5, 2.8, "#79ec65"),
        "body_pressed": [
            (  0, "#30aa00"),
            ( 15, "#14a800"),
            ( 25, "#00a400"),
            ( 50, "#1ca700"),
            ( 68, "#35a81c"),
            ( 80, "#46ac31"),
            (100, "#46ac31"),
        ],
        "spec_top_pressed": (2.0, 3.5, "#98d878", "#6ed050"),
        "spec_bot_pressed": (13.5, 2.8, "#68d056"),
        "icon": """<path d="m6.4107 4.9791 4.586 4.586v-3.5859c0-0.41552-0.5845-0.99998-1-0.99998zm-1.414 1.4141v3.5859c0 0.41552 0.58446 1 0.99998 1h3.5859z" opacity=".5"/>""",
    },
    "unmaximize": {
        "body": [
            (  0, "#38c200"),
            ( 15, "#18c000"),
            ( 25, "#00bc00"),
            ( 50, "#20bf00"),
            ( 68, "#3dc120"),
            ( 80, "#50c438"),
            (100, "#50c438"),
        ],
        "spec_top": (2.0, 3.5, "#aef88d", "#80ef64"),
        "spec_bot": (13.5, 2.8, "#79ec65"),
        "body_pressed": [
            (  0, "#30aa00"),
            ( 15, "#14a800"),
            ( 25, "#00a400"),
            ( 50, "#1ca700"),
            ( 68, "#35a81c"),
            ( 80, "#46ac31"),
            (100, "#46ac31"),
        ],
        "spec_top_pressed": (2.0, 3.5, "#98d878", "#6ed050"),
        "spec_bot_pressed": (13.5, 2.8, "#68d056"),
        "icon": """<path d="m8.0254 3.4141v3.5859c0 0.41552 0.58448 1 1 1h3.5859zm-4.6367 4.5859 4.5859 4.5859v-3.5859c0-0.41552-0.58448-1-1-1z" opacity=".5"/>""",
    },
}

# Backdrop (inactive window) — keep as a muted gray circle, no changes from original.
# (User said "ok with leaving inactive ones as is for now")

def stops_css(stops):
    parts = []
    for offset, color in stops:
        parts.append(f'<stop offset="{offset}%" stop-color="{color}"/>')
    return "\n      ".join(parts)

def make_svg(btn_name, variant, dark=True):
    """
    variant: 'normal' | 'hover' | 'active'
    dark: whether this is the dark-theme version
    """
    b = BUTTONS[btn_name]
    suffix = "-dark" if dark else ""

    if variant == "active":
        body = b["body_pressed"]
        spec_top = b["spec_top_pressed"]
        spec_bot = b["spec_bot_pressed"]
    else:
        body = b["body"]
        spec_top = b["spec_top"]
        spec_bot = b["spec_bot"]

    body_stops = stops_css(body)

    cy_top, r_top, peak_top, mid_top = spec_top[0], spec_top[1], spec_top[2], spec_top[3]
    cy_bot, r_bot, peak_bot = spec_bot[0], spec_bot[1], spec_bot[2]

    icon_element = b["icon"] if variant in ("hover", "active") else ""

    # unique gradient IDs per file to avoid SVG namespace collisions
    uid = f"{btn_name}-{variant}"

    svg = f"""<svg width="16" height="16" version="1.1" xmlns="http://www.w3.org/2000/svg">
  <defs>
    <clipPath id="clip-{uid}">
      <circle cx="8" cy="8" r="7"/>
    </clipPath>
    <!-- Main body: vertical gradient from pixel samples -->
    <linearGradient id="body-{uid}" x1="8" y1="1" x2="8" y2="15" gradientUnits="userSpaceOnUse">
      {body_stops}
    </linearGradient>
    <!-- Top specular spot: bright highlight at top of sphere -->
    <radialGradient id="st-{uid}" cx="{8}" cy="{cy_top}" r="{r_top}" gradientUnits="userSpaceOnUse">
      <stop offset="0%"   stop-color="{peak_top}"/>
      <stop offset="45%"  stop-color="{mid_top}" stop-opacity="0.6"/>
      <stop offset="100%" stop-color="{mid_top}" stop-opacity="0"/>
    </radialGradient>
    <!-- Bottom specular spot: subtle secondary highlight -->
    <radialGradient id="sb-{uid}" cx="{8}" cy="{cy_bot}" r="{r_bot}" gradientUnits="userSpaceOnUse">
      <stop offset="0%"   stop-color="{peak_bot}" stop-opacity="0.75"/>
      <stop offset="100%" stop-color="{peak_bot}" stop-opacity="0"/>
    </radialGradient>
  </defs>
  <!-- Invisible bounding rect (matches original SVG convention) -->
  <rect width="16" height="16" opacity="0"/>
  <!-- Main body -->
  <circle cx="8" cy="8" r="7" fill="url(#body-{uid})"/>
  <!-- Top specular overlay (clipped to circle) -->
  <rect x="1" y="1" width="14" height="7" fill="url(#st-{uid})" clip-path="url(#clip-{uid})"/>
  <!-- Bottom specular overlay (clipped to circle) -->
  <rect x="1" y="8" width="14" height="7" fill="url(#sb-{uid})" clip-path="url(#clip-{uid})"/>
  <!-- Icon overlay for hover/active states -->
  {icon_element}
</svg>"""
    return svg


def write_svg(path, content):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(content)
    print(f"  wrote {os.path.basename(path)}")


def render_svg_to_png(svg_content, out_path, size):
    """Render SVG string to PNG at given size using librsvg2."""
    handle = Rsvg.Handle.new_from_data(svg_content.encode())
    surface = cairo.ImageSurface(cairo.FORMAT_ARGB32, size, size)
    ctx = cairo.Context(surface)
    vp = Rsvg.Rectangle()
    vp.x, vp.y, vp.width, vp.height = 0, 0, size, size
    handle.render_document(ctx, vp)
    surface.write_to_png(out_path)
    print(f"  rendered {os.path.basename(out_path)} @ {size}x{size}")


def main():
    print("=== Generating Qt SVGs ===")
    for btn_name in ("close", "minimize", "maximize", "unmaximize"):
        for variant, suffix in [("normal", ""), ("hover", "-hover"), ("active", "-active")]:
            # dark theme
            fname = f"titlebutton-{btn_name}{suffix}-dark.svg"
            path = os.path.join(QT_SVG_DIR, fname)
            svg = make_svg(btn_name, variant, dark=True)
            write_svg(path, svg)
            # light theme (same gradients, same look — user didn't mention light)
            # skip for now since existing light variants weren't requested

    print("\n=== Rendering GTK4 PNGs ===")
    # GTK4 uses the same set but as PNGs (no unmaximize, uses 'maximize' for that)
    for btn_name in ("close", "minimize", "maximize"):
        for variant, suffix in [("normal", ""), ("hover", "-hover"), ("active", "-active")]:
            fname_base = f"titlebutton-{btn_name}{suffix}-dark"
            svg = make_svg(btn_name, variant, dark=True)
            render_svg_to_png(svg, os.path.join(GTK_ASSET_DIR, fname_base + ".png"), 16)
            render_svg_to_png(svg, os.path.join(GTK_ASSET_DIR, fname_base + "@2.png"), 32)

    print("\nDone. Qt SVGs need a cmake rebuild; GTK4 PNGs are live.")


if __name__ == "__main__":
    main()
