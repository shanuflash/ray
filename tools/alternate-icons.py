#!/usr/bin/env python3
"""Ray's app icons on the Neon CRT mark (owner's pick, 2026-11-24, docs/mocks/logo-scanline.html): writes each
theme's SVG layers to Branding/alternates/<name>/ and the themes' data into docs/mocks/app-icons.html (between its
GENERATED markers).

Every theme keeps the same mark on the same 1024 canvas: a sharp R cut into 16 scanlines, a soft bloom behind it,
faint scanlines across the tile and a vignette. Only colour (and, for Glitch and Clear, one effect) changes, so it
stays Ray at any size. Layers, bottom to top, for Icon Composer:
  Background.svg  the tile: fill, tile-wide scanlines, vignette (no glass)
  Glow.svg        the R blurred (an SVG filter: if Icon Composer drops it, export it as a PNG, or use the glyph
                  group's own blur/shadow)
  Glyph.svg       the R in scanlines (glass off: glass would smear the lines)
Run from the repo root: python3 tools/alternate-icons.py
"""
import json
import math
import os
import re
import shutil

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "Branding", "alternates")
HTML = os.path.join(ROOT, "docs", "mocks", "app-icons.html")

# The R: stem, bowl with its counter, leg. Sharp corners; 230 to 794 tall.
R = ('<path d="M300 230 H424 V794 H300 Z"/>'
     '<path fill-rule="evenodd" d="M300 230 H548 A182 182 0 0 1 548 594 H300 Z M424 346 H540 A66 66 0 0 1 540 478 H424 Z"/>'
     '<path d="M496 560 H630 L770 794 H636 Z"/>')
TOP, BOTTOM = 230, 794


def stripes(n=16, height=22):
    pitch = (BOTTOM - TOP) / n
    return "".join(f'<rect x="0" y="{TOP + i * pitch:.1f}" width="1024" height="{height}" fill="#fff"/>'
                   for i in range(n))


def lin(id_, stops, user=(0, TOP, 0, BOTTOM)):
    x1, y1, x2, y2 = user
    s = "".join(f'<stop offset="{o}" stop-color="{c}"/>' for o, c in stops)
    return f'<linearGradient id="{id_}" gradientUnits="userSpaceOnUse" x1="{x1}" y1="{y1}" x2="{x2}" y2="{y2}">{s}</linearGradient>'


def svg(body, defs=""):
    d = f"<defs>{defs}</defs>" if defs else ""
    return ('<?xml version="1.0" encoding="UTF-8"?>\n<svg xmlns="http://www.w3.org/2000/svg" width="1024" '
            f'height="1024" viewBox="0 0 1024 1024">{d}{body}</svg>\n')


def background(fill, lines="#FFFFFF", lines_opacity=.035, vignette=.7, extra=""):
    """The tile: a fill (a colour or a ready gradient), tile-wide scanlines, a vignette."""
    defs, paint = "", fill
    if isinstance(fill, list):
        defs += lin("bg", fill, user=(0, 0, 0, 1024))
        paint = "url(#bg)"
    defs += ('<radialGradient id="vg" gradientUnits="userSpaceOnUse" cx="512" cy="512" r="720">'
             f'<stop offset=".5" stop-color="#000" stop-opacity="0"/><stop offset="1" stop-color="#000" '
             f'stop-opacity="{vignette}"/></radialGradient>')
    scan = "".join(f'<rect x="0" y="{i * 16}" width="1024" height="2" fill="{lines}" opacity="{lines_opacity}"/>'
                   for i in range(64))
    vg = '<rect width="1024" height="1024" fill="url(#vg)"/>' if vignette else ""
    return svg(f'<rect width="1024" height="1024" fill="{paint}"/>{extra}{scan}{vg}', defs)


def glow(stops, opacity=.75, blur=34):
    return svg(f'<g fill="url(#g)" filter="url(#bl)" opacity="{opacity}">{R}</g>',
               lin("g", stops) + '<filter id="bl" x="-30%" y="-30%" width="160%" height="160%">'
               f'<feGaussianBlur stdDeviation="{blur}"/></filter>')


def glyph(stops, glitch=False):
    mask = f'<mask id="m" maskUnits="userSpaceOnUse" x="0" y="0" width="1024" height="1024">{stripes()}</mask>'
    if not glitch:
        return svg(f'<g fill="url(#g)" mask="url(#m)">{R}</g>', lin("g", stops) + mask)
    clips = ('<clipPath id="top"><rect x="0" y="0" width="1024" height="440"/></clipPath>'
             '<clipPath id="mid"><rect x="0" y="440" width="1024" height="160"/></clipPath>'
             '<clipPath id="bot"><rect x="0" y="600" width="1024" height="424"/></clipPath>')
    body = (f'<g mask="url(#m)"><g clip-path="url(#top)" fill="url(#g)">{R}</g>'
            f'<g clip-path="url(#mid)"><g transform="translate(18 0)" fill="#22E0FF">{R}</g>'
            f'<g transform="translate(70 0)" fill="#FF2F9A">{R}</g>'
            f'<g transform="translate(44 0)" fill="url(#g)">{R}</g></g>'
            f'<g clip-path="url(#bot)" fill="url(#g)">{R}</g></g>')
    return svg(body, lin("g", stops) + mask + clips)


SUNSET = [(0, "#FFB13C"), (.55, "#FF5A5F"), (1, "#E23A8A")]
CRT_NOTES = ("Background no glass. Glow under the glyph, no glass (or drop it and use the group's shadow, kind "
             "\"layer colour\", blur high). Glyph glass off, shadow none.")


def mix(hex_, toward, amount):
    r, g, b = (int(hex_[i:i + 2], 16) for i in (1, 3, 5))
    t = 255 if toward == "white" else 0
    return "#%02X%02X%02X" % tuple(round(c + (t - c) * amount) for c in (r, g, b))


def theme(name, title, blurb, bg, stops, family="Ray", notes=CRT_NOTES, glow_opacity=.75, color=None, **bgargs):
    glitch = bgargs.pop("glitch", False)
    return dict(name=name, title=title, family=family, color=color, blurb=blurb, composer=notes,
                layers={"Background.svg": background(bg, **bgargs),
                        "Glow.svg": glow(stops, glow_opacity) if glow_opacity else None,
                        "Glyph.svg": glyph(stops, glitch)})


def classic():
    """Ray's sun icon before the rebrand, kept for anyone who liked it."""
    rays = "".join(
        f'<rect x="235" y="-27.0" width="110" height="54" rx="27.0" transform="translate(512 640) rotate({a})"/>'
        for a in (-90, -54, -126, -18, -162))
    g = (f'<g fill="#FFFFFF"><path d="M347 640 A165 165 0 0 1 677 640 Z"/>{rays}'
         '<rect x="252" y="688" width="520" height="50" rx="25"/></g>')
    bg = svg('<rect width="1024" height="1024" fill="url(#bg)"/>',
             lin("bg", [(0, "#FF9A3C"), (1, "#FF4F7B")], user=(0, 0, 0, 1024)))
    return dict(name="classic", title="Classic", family="Ray", color=None,
                blurb="Ray's sunrise icon from before the rebrand, for anyone who'd rather keep it.",
                composer="As the old Branding/Ray.icon: background no glass, glyph glass on, translucency 0.4.",
                layers={"Background.svg": bg, "Glow.svg": None, "Glyph.svg": svg(g)})


def variants():
    v = [
        theme("crt", "Neon CRT", "The new Ray: a sunset R in glowing scanlines on a dark screen. The default.",
              "#090B1E", SUNSET),
        theme("phosphor", "Phosphor", "A green terminal from the eighties: phosphor lines on black glass.",
              "#04110A", [(0, "#B8FFB0"), (.5, "#3DFF6E"), (1, "#0FB34A")], lines="#3DFF6E", lines_opacity=.05),
        theme("amber", "Amber", "The amber monochrome monitor: warm, calm, one colour.",
              "#140B02", [(0, "#FFE2A0"), (.5, "#FFB020"), (1, "#E07A00")], lines="#FFB020", lines_opacity=.05),
        theme("ice", "Ice", "Cold blue light, like a screen in a dark room at night.",
              "#050B1C", [(0, "#E4FBFF"), (.5, "#5CD6FF"), (1, "#2F6BEA")]),
        theme("vapor", "Vaporwave", "Pink into cyan on deep purple: the loudest theme.",
              [(0, "#2A0F4F"), (1, "#12082A")], [(0, "#FF6AD5"), (.5, "#C774E8"), (1, "#5BE3FF")]),
        theme("glitch", "Glitch", "The default with its middle lines slipping sideways in cyan and magenta.",
              "#090B1E", SUNSET, glitch=True),
        theme("paper", "Paper", "Light mode: the sunset lines printed on warm paper, no glow, no vignette.",
              [(0, "#FFFBF3"), (1, "#F3E9DC")], [(0, "#FF9A3C"), (.55, "#F2475F"), (1, "#C42A7A")],
              glow_opacity=0, lines="#000000", lines_opacity=.025, vignette=0,
              notes="Background no glass. No glow layer. Glyph glass off, shadow neutral 0.2."),
        theme("mono", "Mono", "White lines on black, nothing else: the plainest and the most legible small.",
              "#000000", [(0, "#FFFFFF"), (1, "#FFFFFF")], glow_opacity=.35, vignette=0, lines_opacity=.04),
        theme("glass", "Clear", "The lines glow on smoked glass and the desktop shows through.",
              "#1A1A3366", [(0, "#FFFFFF"), (1, "#FFFFFF")], glow_opacity=.6, vignette=0, lines_opacity=.08,
              notes="Background glass on, translucency 0.7 (Icon Composer's Clear appearance); glow and glyph "
                    "glass off. The mock fakes the glass with a blur of the desktop behind it."),
        classic(),
    ]
    # Spaces: the profile colours Settings › Theme offers (ProfileColor: lavender, then the presets), as the CRT's
    # light: a pale top, the colour, a deeper bottom, on a screen tinted with it.
    for key, title, hex_ in [
            ("lavender", "Lavender", "#8257E5"), ("blue", "Blue", "#2F6BEA"), ("teal", "Teal", "#12A594"),
            ("green", "Green", "#3EA64A"), ("amber", "Amber", "#F2B01E"), ("coral", "Coral", "#F0654A"),
            ("pink", "Pink", "#E5589D"), ("graphite", "Graphite", "#9AA1AE")]:
        v.append(theme(f"space-{key}", title, f"The CRT in {title}, one of the colours a profile (and later a "
                       "Space) can take.", mix(hex_, "black", .9),
                       [(0, mix(hex_, "white", .6)), (.5, hex_), (1, mix(hex_, "black", .25))],
                       family="Spaces", color=hex_))
    return v


def prefixed(svg_text, prefix):
    """The inner SVG with its ids made unique for inlining several icons in one page."""
    inner = re.sub(r'^.*?<svg[^>]*>', '', svg_text, flags=re.S).replace('</svg>', '').strip()
    inner = re.sub(r'id="([^"]+)"', lambda m: f'id="{prefix}-{m.group(1)}"', inner)
    return re.sub(r'url\(#([^)]+)\)', lambda m: f'url(#{prefix}-{m.group(1)})', inner)


def main():
    vs = variants()
    if os.path.isdir(OUT):
        shutil.rmtree(OUT)
    data = []
    for v in vs:
        d = os.path.join(OUT, v["name"])
        os.makedirs(d)
        for file, text in v["layers"].items():
            if text:
                with open(os.path.join(d, file), "w") as f:
                    f.write(text)
        glyph_html = "".join(prefixed(v["layers"][k], f'{v["name"]}-{k[:2].lower()}')
                             for k in ("Glow.svg", "Glyph.svg") if v["layers"][k])
        data.append(dict(name=v["name"], title=v["title"], family=v["family"], color=v["color"], blurb=v["blurb"],
                         composer=v["composer"], bg=prefixed(v["layers"]["Background.svg"], v["name"] + "-bg"),
                         glyph=glyph_html))
    with open(HTML) as f:
        html = f.read()
    start, end = "/* GENERATED:BEGIN */", "/* GENERATED:END */"
    i, j = html.index(start), html.index(end)
    html = html[:i + len(start)] + "\nconst VARIANTS = " + json.dumps(data, indent=0) + ";\n" + html[j:]
    with open(HTML, "w") as f:
        f.write(html)
    print(f"{len(vs)} icons -> {OUT}")


if __name__ == "__main__":
    main()
