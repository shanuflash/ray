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
  Decor.svg       themed icons only: what sits in front (palms, snow, bats, blossom)
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


def background(fill, lines="#FFFFFF", lines_opacity=.035, vignette=.7, extra="", extra_defs=""):
    """The tile: a fill (a colour or a ready gradient), tile-wide scanlines, a vignette."""
    defs, paint = extra_defs, fill
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


def glyph(stops):
    mask = f'<mask id="m" maskUnits="userSpaceOnUse" x="0" y="0" width="1024" height="1024">{stripes()}</mask>'
    return svg(f'<g fill="url(#g)" mask="url(#m)">{R}</g>', lin("g", stops) + mask)


SUNSET = [(0, "#FFB13C"), (.55, "#FF5A5F"), (1, "#E23A8A")]
CRT_NOTES = ("Background no glass. Glow under the glyph, no glass (or drop it and use the group's shadow, kind "
             "\"layer colour\", blur high). Glyph glass off, shadow none.")


def mix(hex_, toward, amount):
    r, g, b = (int(hex_[i:i + 2], 16) for i in (1, 3, 5))
    t = 255 if toward == "white" else 0
    return "#%02X%02X%02X" % tuple(round(c + (t - c) * amount) for c in (r, g, b))


def theme(name, title, blurb, bg, stops, family="Ray", notes=CRT_NOTES, glow_opacity=.75, color=None,
          decor=None, glyph_svg=None, **bgargs):
    """decor: (body, defs) drawn over the glyph as its own layer, Decor.svg; bgargs' extra: scenery under it."""
    return dict(name=name, title=title, family=family, color=color, blurb=blurb, composer=notes,
                layers={"Background.svg": background(bg, **bgargs),
                        "Glow.svg": glow(stops, glow_opacity) if glow_opacity else None,
                        "Glyph.svg": glyph_svg or glyph(stops),
                        "Decor.svg": svg(decor[0], decor[1]) if decor else None})


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


def inside_r(x, y):
    if 300 <= x <= 424 and TOP <= y <= BOTTOM:
        return True
    if x >= 300 and TOP <= y <= 594 and (x <= 548 or (x - 548) ** 2 + (y - 412) ** 2 <= 182 ** 2):
        counter = x >= 424 and 346 <= y <= 478 and (x <= 540 or (x - 540) ** 2 + (y - 412) ** 2 <= 66 ** 2)
        if not counter:
            return True
    if 560 <= y <= BOTTOM:
        k = (y - 560) * 140 / 234
        if 496 + k <= x <= 630 + k:
            return True
    return False


def blocks_glyph(cell=48, x0=276, y0=222):
    """The R as a wall of blocks: grass on the blocks with open sky above, dirt and stone below."""
    import random
    rnd = random.Random(4)
    on = {(cx, cy) for cy in range(y0, 820, cell) for cx in range(x0, 800, cell)
          if inside_r(cx + cell / 2, cy + cell / 2)}
    out = []
    for cx, cy in sorted(on, key=lambda c: (c[1], c[0])):
        grass = (cx, cy - cell) not in on
        deep = cy > 650
        base = "#5DBB3F" if grass else rnd.choice(["#7A7A80", "#6A6A70"] if deep else ["#8B5A2B", "#7A4D24", "#946235"])
        out.append(f'<rect x="{cx}" y="{cy}" width="{cell}" height="{cell}" fill="{base}"/>')
        if grass:  # grass hangs over the dirt below
            out.append(f'<rect x="{cx}" y="{cy + cell * .62:.0f}" width="{cell}" height="{cell * .38:.0f}" fill="#8B5A2B"/>')
            for i in range(0, cell, 12):
                out.append(f'<rect x="{cx + i}" y="{cy + cell * .62:.0f}" width="6" height="{rnd.choice([6, 12])}" fill="#5DBB3F"/>')
        else:
            for _ in range(2):
                out.append(f'<rect x="{cx + rnd.randrange(4, cell - 12, 4)}" y="{cy + rnd.randrange(4, cell - 12, 4)}" '
                           f'width="8" height="8" fill="#000" opacity=".18"/>')
        out.append(f'<rect x="{cx + .5}" y="{cy + .5}" width="{cell - 1}" height="{cell - 1}" fill="none" '
                   'stroke="#000" stroke-opacity=".22" stroke-width="3"/>')
    return svg("".join(out))


def palm(x, y, s, flip=1, ink="#0A0618"):
    fronds = [(-150, 40), (-120, -40), (-40, -80), (60, -70), (140, -10), (150, 70), (-90, 110)]
    f = "".join(f'<path d="M0 0 Q{dx * .5} {dy * .5 - 50} {dx} {dy}" stroke="{ink}" stroke-width="26" fill="none" '
                'stroke-linecap="round"/>' for dx, dy in fronds)
    trunk = f'<path d="M-10 0 C-30 180 -10 400 40 700" stroke="{ink}" stroke-width="30" fill="none"/>'
    return f'<g transform="translate({x} {y}) scale({s * flip} {s})">{trunk}{f}</g>'


def bat(x, y, s):
    return (f'<path transform="translate({x} {y}) scale({s})" fill="#0B0614" d="M-60 0 Q-45 -25 -25 -8 Q-15 -22 -6 -10 '
            'L0 -18 L6 -10 Q15 -22 25 -8 Q45 -25 60 0 Q40 -6 30 8 Q20 -2 10 10 Q0 2 -10 10 Q-20 -2 -30 8 Q-40 -6 -60 0 Z"/>')


def blossom(x, y, s, fill="#FFB7D0"):
    petals = "".join(f'<ellipse cx="0" cy="-16" rx="11" ry="17" transform="rotate({a})"/>' for a in range(0, 360, 72))
    return (f'<g transform="translate({x} {y}) scale({s})" fill="{fill}">{petals}'
            '<circle r="6" fill="#FFE08A"/></g>')


def dots(seed, n, fill, rmin, rmax, area=(0, 0, 1024, 1024), opacity=1):
    import random
    rnd = random.Random(seed)
    x0, y0, x1, y1 = area
    return "".join(f'<circle cx="{rnd.uniform(x0, x1):.0f}" cy="{rnd.uniform(y0, y1):.0f}" '
                   f'r="{rnd.uniform(rmin, rmax):.1f}" fill="{fill}" opacity="{opacity}"/>' for _ in range(n))


THEMED_NOTES = ("Background (with its scenery) no glass; Glow and Glyph as the CRT; Decor on top, glass off. "
                "Seasonal: could switch itself on for its dates later.")


def themed():
    """Original themed icons around the CRT R. Never a game's or brand's name, logo, characters or art: each is
    the mood of a place or season (owner 2026-11-24 asked for GTA VI, Minecraft, beach and Christmas ideas)."""
    t = []
    t.append(theme(
        "vice", "Vice Nights", "A neon night in a beach city: pink and violet sky, palm silhouettes, the R in "
        "electric cyan. The 80s Miami mood, with no game's name or art.",
        [(0, "#120A2E"), (.55, "#5A1A6E"), (.8, "#FF4F8B"), (1, "#FF9A5C")],
        [(0, "#F2FFFF"), (.5, "#3DF2FF"), (1, "#00A3FF")], family="Themes", notes=THEMED_NOTES, vignette=.45,
        extra='<circle cx="512" cy="760" r="230" fill="#FFB35C" opacity=".55"/>'
              '<rect x="0" y="840" width="1024" height="184" fill="#0C0A24"/>'
              + "".join(f'<rect x="{220 + i * 40}" y="{860 + i * 34}" width="{584 - i * 80}" height="6" fill="#FF7AB8" '
                        f'opacity="{.5 - i * .12:.2f}"/>' for i in range(4)),
        decor=(palm(150, 470, .9) + palm(905, 560, .7, flip=-1), "")))
    t.append(theme(
        "blocks", "Blocks", "The R built from blocks: grass on top, dirt and stone below, under a blocky sky. "
        "The block-building game feeling, drawn from scratch.",
        [(0, "#6EC3FF"), (1, "#BDE6FF")], [(0, "#5DBB3F"), (1, "#5DBB3F")], family="Themes", glow_opacity=0,
        notes="Background no glass; no glow; the Glyph is the blocks (glass off, crisp edges). Keep the cells on "
              "whole pixels (48 of 1024 lands well down to 64 px).",
        vignette=0, lines_opacity=0,
        extra='<g fill="#fff" opacity=".9"><rect x="96" y="120" width="192" height="48"/><rect x="144" y="72" width="96" height="48"/>'
              '<rect x="720" y="168" width="216" height="48"/><rect x="768" y="120" width="96" height="48"/></g>'
              '<rect x="0" y="840" width="1024" height="184" fill="#5DBB3F"/><rect x="0" y="880" width="1024" height="144" fill="#8B5A2B"/>',
        glyph_svg=blocks_glyph()))
    t.append(theme(
        "beach", "Beach", "A summer afternoon: the R in sunset lines over turquoise water, a warm sun, foam on the "
        "sand.", [(0, "#8FE3FF"), (.6, "#3EC6E8"), (.62, "#1FA2D6"), (1, "#1592C4")],
        [(0, "#FFF6C9"), (.5, "#FFB13C"), (1, "#FF5A5F")], family="Themes", notes=THEMED_NOTES, glow_opacity=.5,
        vignette=.15, lines_opacity=.04,
        extra='<circle cx="800" cy="210" r="110" fill="#FFE66B"/><circle cx="800" cy="210" r="170" fill="#FFE66B" opacity=".25"/>'
              '<path d="M0 840 C120 815 240 860 360 835 C480 810 600 860 720 835 C840 810 940 850 1024 830 V1024 H0 Z" fill="#F7D9A0"/>'
              '<path d="M0 840 C120 815 240 860 360 835 C480 810 600 860 720 835 C840 810 940 850 1024 830" fill="none" stroke="#fff" stroke-width="14" stroke-linecap="round"/>',
        decor=('<g transform="translate(840 905)"><circle r="56" fill="#fff"/><path d="M0 -56 A56 56 0 0 1 48 -28 L0 0 Z" fill="#FF5A5F"/>'
               '<path d="M48 28 A56 56 0 0 1 0 56 L0 0 Z" fill="#3EC6E8"/><path d="M-48 28 A56 56 0 0 1 -48 -28 L0 0 Z" fill="#FFB13C"/></g>', "")))
    lights = "".join(f'<circle cx="{x}" cy="{150 + 60 * math.sin((x - 40) / 940 * math.pi)}" r="20" fill="{c}"/>'
                     f'<circle cx="{x}" cy="{150 + 60 * math.sin((x - 40) / 940 * math.pi)}" r="38" fill="{c}" opacity=".3"/>'
                     for x, c in zip(range(80, 1000, 115), ["#FF3B3B", "#FFD23F", "#3DDC84", "#3DB2FF"] * 3))
    t.append(theme(
        "christmas", "Christmas", "Snow on the R, fairy lights strung across the top, snow falling on a pine-green "
        "night. Red and white lines like a candy cane.",
        [(0, "#0E3322"), (1, "#04140C")], [(0, "#FFFFFF"), (.25, "#FF6B6B"), (.6, "#E3262E"), (1, "#A3101A")],
        family="Themes", notes=THEMED_NOTES, extra=dots(11, 60, "#fff", 3, 9, opacity=.8),
        decor=('<path d="M140 150 Q512 270 884 150" fill="none" stroke="#2B4A3A" stroke-width="6"/>' + lights +
               '<path fill="#FFFFFF" d="M286 240 C286 214 312 204 334 210 C384 196 434 214 474 206 C522 196 562 210 '
               '602 222 C642 236 692 252 714 292 C724 314 702 322 692 302 C674 282 642 272 604 270 C592 294 570 296 '
               '566 272 C522 264 474 264 444 268 C438 300 412 302 410 270 C380 272 344 270 322 268 C318 290 296 292 '
               '294 268 Z"/>', "")))
    t.append(theme(
        "halloween", "Halloween", "A pumpkin-orange R under a full moon, bats flying past, on a purple night.",
        [(0, "#2A0F45"), (1, "#0D0518")], [(0, "#FFE29A"), (.5, "#FF8A1F"), (1, "#D9480F")], family="Themes",
        notes=THEMED_NOTES,
        extra='<circle cx="760" cy="250" r="150" fill="#FFE8A3"/><circle cx="760" cy="250" r="230" fill="#FFE8A3" opacity=".15"/>',
        decor=(bat(640, 160, 2.6) + bat(880, 380, 1.8) + bat(190, 260, 2.2), "")))
    t.append(theme(
        "space", "Deep Space", "The R glowing violet among the stars, a ringed planet drifting below.",
        "#05030F", [(0, "#F0EAFF"), (.5, "#9B7BFF"), (1, "#4D7CFF")], family="Themes", notes=THEMED_NOTES,
        extra=dots(5, 90, "#fff", 1.5, 5, opacity=.85) +
              '<circle cx="190" cy="850" r="120" fill="url(#pl)"/>'
              '<ellipse cx="190" cy="850" rx="210" ry="40" fill="none" stroke="#FFB36B" stroke-width="12" opacity=".8" transform="rotate(-18 190 850)"/>',
        extra_defs=lin("pl", [(0, "#FF9A5C"), (1, "#7A2E8F")], user=(0, 730, 0, 970))))
    t.append(theme(
        "sakura", "Sakura", "Spring: the R in plum-pink lines on a soft pink sky, a blossoming branch and petals "
        "drifting down.", [(0, "#FFE7EF"), (1, "#FFF6E8")], [(0, "#FF9EC4"), (.5, "#E0457B"), (1, "#8E1F5A")],
        family="Themes", glow_opacity=.35, vignette=0, lines="#000000", lines_opacity=.02, notes=THEMED_NOTES,
        decor=('<path d="M60 230 C160 190 250 140 360 70 M170 175 C200 130 205 100 195 50" stroke="#5A2A2A" '
               'stroke-width="22" fill="none" stroke-linecap="round"/>' +
               blossom(260, 110, 2.2) + blossom(160, 70, 1.8) + blossom(350, 50, 1.9) + blossom(80, 180, 2) +
               blossom(840, 300, 1.5, "#FFC9DB") + blossom(890, 640, 1.3, "#FFC9DB") + blossom(190, 870, 1.6, "#FFC9DB") +
               blossom(780, 890, 1.2, "#FFC9DB"), "")))
    return t


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
    ] + themed()
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
        for file, text in v["layers"].items():  # a missing or None layer isn't written
            if text:
                with open(os.path.join(d, file), "w") as f:
                    f.write(text)
        glyph_html = "".join(prefixed(v["layers"][k], f'{v["name"]}-{k[:-4].lower()}')
                             for k in ("Glow.svg", "Glyph.svg", "Decor.svg") if v["layers"].get(k))
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
