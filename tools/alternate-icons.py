#!/usr/bin/env python3
"""Ray's alternate app icons: writes each variant's SVG layers to Branding/alternates/<name>/ and the variants'
data into docs/mocks/app-icons.html (between its GENERATED markers).

Every variant keeps Ray's glyph (Branding/Ray.icon/Assets/RayGlyph.svg: the half sun, five rays and the horizon
bar) on the same 1024 canvas, so a local session can drop the layers into Icon Composer as Ray.icon does: a
background layer (no glass) under a glyph group (glass on). Run from the repo root: python3 tools/alternate-icons.py
"""
import json
import math
import os
import re

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "Branding", "alternates")
HTML = os.path.join(ROOT, "docs", "mocks", "app-icons.html")

# Ray's glyph, exactly as RayGlyph.svg draws it.
CX, CY = 512, 640
RAY_ANGLES = [-90, -54, -126, -18, -162]
SUN = 'M347 640 A165 165 0 0 1 677 640 Z'
RAYS = "".join(
    f'<rect x="235" y="-27.0" width="110" height="54" rx="27.0" transform="translate(512 640) rotate({a})"/>'
    for a in RAY_ANGLES)
BAR = '<rect x="252" y="688" width="520" height="50" rx="25"/>'


def glyph(fill, sun_fill=None, rays_fill=None, bar_fill=None):
    """The glyph in one fill, or its three parts in their own."""
    if sun_fill is None and rays_fill is None and bar_fill is None:
        return f'<g fill="{fill}"><path d="{SUN}"/>{RAYS}{BAR}</g>'
    return (f'<path fill="{sun_fill or fill}" d="{SUN}"/><g fill="{rays_fill or fill}">{RAYS}</g>'
            f'<g fill="{bar_fill or fill}">{BAR}</g>')


def lin(id_, stops, x1=0, y1=0, x2=0, y2=1, user=None):
    units = ''
    if user:
        units = ' gradientUnits="userSpaceOnUse"'
        x1, y1, x2, y2 = user
    s = "".join(f'<stop offset="{o}" stop-color="{c}"' + (f' stop-opacity="{a}"' if a != 1 else '') + '/>'
                for o, c, a in [(t + (1,))[:3] for t in stops])
    return f'<linearGradient id="{id_}"{units} x1="{x1}" y1="{y1}" x2="{x2}" y2="{y2}">{s}</linearGradient>'


def rad(id_, cx, cy, r, stops):
    s = "".join(f'<stop offset="{o}" stop-color="{c}"' + (f' stop-opacity="{a}"' if a != 1 else '') + '/>'
                for o, c, a in [(t + (1,))[:3] for t in stops])
    return (f'<radialGradient id="{id_}" gradientUnits="userSpaceOnUse" cx="{cx}" cy="{cy}" r="{r}">{s}'
            '</radialGradient>')


def svg(body, defs=""):
    d = f"<defs>{defs}</defs>" if defs else ""
    return ('<?xml version="1.0" encoding="UTF-8"?>\n<svg xmlns="http://www.w3.org/2000/svg" width="1024" '
            f'height="1024" viewBox="0 0 1024 1024">{d}{body}</svg>\n')


SUNRISE = [(0, "#FF9A3C"), (1, "#FF4F7B")]


# ---- Pixel: the glyph sampled on a 32-cell grid (32 px cells), so it stays Ray's shape, only blocky.

def inside_glyph(x, y):
    # Half sun.
    if y <= CY and math.hypot(x - CX, y - CY) <= 165:
        return True
    # Bar (rounded ends).
    if 688 <= y <= 738 and 252 + 25 <= x <= 772 - 25:
        return True
    for ex in (277, 747):
        if math.hypot(x - ex, y - 713) <= 25:
            return True
    # Rays: rounded rect from 235 to 345 along the angle, 54 thick.
    for a in RAY_ANGLES:
        t = math.radians(a)
        dx, dy = x - CX, y - CY
        u = dx * math.cos(t) + dy * math.sin(t)
        v = -dx * math.sin(t) + dy * math.cos(t)
        if abs(v) <= 27 and 235 + 27 <= u <= 345 - 27:
            return True
        for end in (235 + 27, 345 - 27):
            if math.hypot(u - end, v) <= 27:
                return True
    return False


def pixel_cells(cell=32):
    cells = []
    n = 4  # 4x4 samples per cell; a cell is on at half coverage.
    for gy in range(0, 1024, cell):
        for gx in range(0, 1024, cell):
            hits = sum(inside_glyph(gx + (i + .5) * cell / n, gy + (j + .5) * cell / n)
                       for i in range(n) for j in range(n))
            if hits >= n * n / 2:
                cells.append((gx, gy))
    return cells


def pixel_glyph(fill_for_cell, cell=32):
    out = []
    for gx, gy in pixel_cells(cell):
        out.append(f'<rect x="{gx}" y="{gy}" width="{cell}" height="{cell}" fill="{fill_for_cell(gx, gy)}"/>')
    return "".join(out)


# ---- The variants. Each: title, blurb, background layer, glyph layer, Icon Composer notes.

def variants():
    v = []

    v.append(dict(
        name="sunrise", title="Sunrise", family="Ray",
        blurb="Ray's icon today, for comparison: white glass glyph on the sunrise gradient.",
        bg=svg('<rect width="1024" height="1024" fill="url(#bg)"/>', lin("bg", SUNRISE)),
        glyph=svg(glyph("#FFFFFF")),
        composer="As Branding/Ray.icon (the default; not an alternate)."))

    v.append(dict(
        name="daylight", title="Daylight", family="Ray",
        blurb="The sunrise moves into the glyph, on warm paper: the light twin of Ray's dark-mode icon.",
        bg=svg('<rect width="1024" height="1024" fill="url(#bg)"/>',
               lin("bg", [(0, "#FFFDF9"), (1, "#F6EEE6")])),
        glyph=svg(glyph("url(#g)"), lin("g", SUNRISE, user=(0, 290, 0, 740))),
        composer="Background no glass; glyph group glass on, translucency off, shadow neutral 0.35."))

    v.append(dict(
        name="midnight", title="Midnight", family="Ray",
        blurb="A night sky with the sunrise glyph and a low glow on the horizon. Ray's dark-mode look, kept all day.",
        bg=svg('<rect width="1024" height="1024" fill="url(#bg)"/><rect width="1024" height="1024" fill="url(#glow)"/>',
               lin("bg", [(0, "#221A3D"), (1, "#0B0A16")]) +
               rad("glow", 512, 720, 420, [(0, "#FF5E7A", .30), (.55, "#7A3B8F", .10), (1, "#0B0A16", 0)])),
        glyph=svg(glyph("url(#g)"), lin("g", SUNRISE, user=(0, 290, 0, 740))),
        composer="Background no glass; glyph group glass on, translucency off, shadow neutral 0.5."))

    v.append(dict(
        name="glass", title="Clear", family="Ray",
        blurb="Clear glass: the desktop shows through a frosted tile, the glyph a brighter pane of the same glass.",
        bg=svg('<rect width="1024" height="1024" fill="url(#bg)"/><rect width="1024" height="1024" fill="url(#sheen)"/>',
               lin("bg", [(0, "#FFFFFF", .42), (1, "#FFFFFF", .16)]) +
               lin("sheen", [(0, "#FFFFFF", .35), (.45, "#FFFFFF", 0)], 0, 0, 1, 1)),
        glyph=svg(glyph("#FFFFFF")),
        composer="Background glass on, translucency 0.7 (or Icon Composer's Clear appearance); glyph glass on, "
                 "opacity 0.95. The mock fakes the glass with a blur of the desktop behind it."))

    v.append(dict(
        name="contrast", title="High Contrast", family="Ray",
        blurb="Black and white, nothing else: the most legible at 16 px and in the menu bar's app switcher.",
        bg=svg('<rect width="1024" height="1024" fill="#000000"/>'),
        glyph=svg(glyph("#FFFFFF")),
        composer="Background no glass; glyph glass off, shadow none. Dark appearance: the same."))

    v.append(dict(
        name="aurora", title="Aurora", family="Ray",
        blurb="Arc's Space gradients: blue, violet and pink meeting softly, a white glyph over them.",
        bg=svg('<rect width="1024" height="1024" fill="#6C5CE7"/>'
               '<rect width="1024" height="1024" fill="url(#a)"/><rect width="1024" height="1024" fill="url(#b)"/>'
               '<rect width="1024" height="1024" fill="url(#c)"/>',
               rad("a", 120, 80, 760, [(0, "#4FA8FF"), (1, "#4FA8FF", 0)]) +
               rad("b", 980, 220, 700, [(0, "#FF7AC6"), (1, "#FF7AC6", 0)]) +
               rad("c", 520, 1100, 760, [(0, "#FFB36B", .9), (1, "#FFB36B", 0)])),
        glyph=svg(glyph("#FFFFFF")),
        composer="Background no glass (Icon Composer can't draw these radial blends itself: keep the SVG); "
                 "glyph glass on, translucency 0.4, as Ray.icon."))

    v.append(dict(
        name="retro", title="Retro", family="Ray",
        blurb="A seventies sunset: the half sun in bands with gaps through it, brown rays and horizon on cream.",
        bg=svg('<rect width="1024" height="1024" fill="url(#bg)"/>', lin("bg", [(0, "#FBEBCB"), (1, "#F2D7A8")])),
        glyph=svg(
            '<g mask="url(#bands)"><path fill="url(#sun)" d="' + SUN + '"/></g>'
            f'<g fill="#5B2A3C">{RAYS}{BAR}</g>',
            lin("sun", [(0, "#FFC23D"), (.5, "#FF7A3D"), (1, "#E8436A")], user=(0, 475, 0, 640)) +
            '<mask id="bands" maskUnits="userSpaceOnUse" x="0" y="0" width="1024" height="1024">'
            '<rect width="1024" height="1024" fill="#fff"/>'
            '<rect x="300" y="566" width="424" height="12" fill="#000"/>'
            '<rect x="300" y="596" width="424" height="16" fill="#000"/>'
            '<rect x="300" y="622" width="424" height="20" fill="#000"/></mask>'),
        composer="Glyph glass off (glass would smear the bands); shadow neutral 0.3. If Icon Composer drops the "
                 "mask, split the sun into its four bands as paths."))

    def pix(gx, gy):
        # A two-step dither on the sun, solid elsewhere: an 8-bit sunrise.
        if gy < 640:
            return "#FFD23F" if gy < 560 else "#FF8A3D"
        return "#FF4F7B"
    grid = "".join(f'<rect x="0" y="{y}" width="1024" height="2" fill="#000" fill-opacity=".18"/>'
                   for y in range(0, 1024, 32))
    v.append(dict(
        name="pixel", title="Pixel", family="Ray",
        blurb="Ray's glyph on a 32-cell grid, in three sunset steps, on a deep purple screen with faint scan lines.",
        bg=svg('<rect width="1024" height="1024" fill="url(#bg)"/>' + grid,
               lin("bg", [(0, "#2B1B4F"), (1, "#16102B")])),
        glyph=svg(pixel_glyph(pix)),
        composer="Glass off everywhere (glass rounds the cells); shadow none. Keep the cells on whole pixels: "
                 "1024/32 lands on every size macOS asks for down to 32 px."))

    # Spaces: the profile colours Settings › Theme offers (ProfileColor: lavender, then the presets), so a Space's
    # colour can choose its icon later. A lighter top, the colour, then a deeper bottom.
    spaces = [
        ("lavender", "Lavender", "#8257E5"), ("blue", "Blue", "#2F6BEA"), ("teal", "Teal", "#12A594"),
        ("green", "Green", "#3EA64A"), ("amber", "Amber", "#F2B01E"), ("coral", "Coral", "#F0654A"),
        ("pink", "Pink", "#E5589D"), ("graphite", "Graphite", "#6B7280"),
    ]
    for key, title, hex_ in spaces:
        top, bottom = shade(hex_, .28), shade(hex_, -.22)
        v.append(dict(
            name=f"space-{key}", title=title, family="Spaces", color=hex_,
            blurb=f"Ray in {title}, one of the colours a profile (and later a Space) can take.",
            bg=svg('<rect width="1024" height="1024" fill="url(#bg)"/>',
                   lin("bg", [(0, top), (.55, hex_), (1, bottom)])),
            glyph=svg(glyph("#FFFFFF")),
            composer="As Ray.icon: background no glass, glyph glass on, translucency 0.4."))
    return v


def shade(hex_, amount):
    """Toward white (amount > 0) or black (< 0)."""
    r, g, b = (int(hex_[i:i + 2], 16) for i in (1, 3, 5))
    t = 255 if amount > 0 else 0
    a = abs(amount)
    return "#%02X%02X%02X" % tuple(round(c + (t - c) * a) for c in (r, g, b))


def prefixed(svg_text, prefix):
    """The inner SVG with its ids made unique for inlining several icons in one page."""
    inner = re.sub(r'^.*?<svg[^>]*>', '', svg_text, flags=re.S)
    inner = inner.replace('</svg>', '').strip()
    inner = re.sub(r'id="([^"]+)"', lambda m: f'id="{prefix}-{m.group(1)}"', inner)
    inner = re.sub(r'url\(#([^)]+)\)', lambda m: f'url(#{prefix}-{m.group(1)})', inner)
    return inner


def main():
    vs = variants()
    for v in vs:
        d = os.path.join(OUT, v["name"])
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, "Background.svg"), "w") as f:
            f.write(v["bg"])
        with open(os.path.join(d, "Glyph.svg"), "w") as f:
            f.write(v["glyph"])
    data = [dict(name=v["name"], title=v["title"], family=v["family"], color=v.get("color"), blurb=v["blurb"],
                 composer=v["composer"], bg=prefixed(v["bg"], v["name"] + "-bg"),
                 glyph=prefixed(v["glyph"], v["name"] + "-gl")) for v in vs]
    with open(HTML) as f:
        html = f.read()
    start, end = "/* GENERATED:BEGIN */", "/* GENERATED:END */"
    i, j = html.index(start), html.index(end)
    html = html[:i + len(start)] + "\nconst VARIANTS = " + json.dumps(data, indent=0) + ";\n" + html[j:]
    with open(HTML, "w") as f:
        f.write(html)
    print(f"{len(vs)} variants -> {OUT}")


if __name__ == "__main__":
    main()
