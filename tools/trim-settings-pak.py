#!/usr/bin/env python3
"""Takes "Profiles" and "Appearance and behavior" out of the engine's own settings page (chrome://settings, shown as
ray://settings): Ray has its own Settings window for them (ray://settings/appearance opens it).

The page's code is the web components bundle `shared.rollup.js` (resource id varies with the engine) inside
resources.pak, gzip-compressed. It holds the left menu (`settings-menu`), the page that stamps one section per menu
item (`settings-main`) and the routes. The menu items are the `/people` ("Profiles") and `/appearance` ("Appearance
and behavior") links. What this changes, all in that one resource:

  1. `createPageVisibility()` (the page's own switch for hiding sections; it is only used for guest profiles) returns,
     for everyone, the guest object with every section visible except `people` and `appearance`. The routes
     (`/people` and its sub-pages, `/appearance`, `/fonts`), the sections `settings-main` stamps (so search can't find
     them) and the menu's `hidden` bindings all follow it, and a navigation to a missing route lands on the top-level
     page, as Chrome does for any unknown path.
  2. `getTopLevelRoute()`, which names the page `chrome://settings/` itself shows, was Appearance: it is Search engine
     now, the one Chrome itself picks for guests. Not Privacy (the next item down): only some pages draw their
     default views on the bare `/` route, and Privacy isn't one, so it would show nothing.
  3. The two `<a>` items are taken out of the menu's template, not just hidden.

Every pattern must match exactly once; if the engine moves any of them this exits 1 with a message that says which,
and the build stops. Nothing is skipped quietly. A file this tool already trimmed (it leaves a marker) is left alone.
Only gzip entries are read: if the bundle ever ships brotli-compressed, the anchor isn't found and the build stops.

  tools/trim-settings-pak.py <resources.pak>
"""
import gzip
import importlib.util
import os
import re
import sys

sys.dont_write_bytecode = True  # importing rebrand-pak.py must not leave a tools/__pycache__
MARKER = b"/*ray:settings-trimmed*/"
ANCHOR = b"function createPageVisibility(){"

here = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("rebrand_pak", os.path.join(here, "rebrand-pak.py"))
rebrand_pak = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rebrand_pak)


def literal(old: str, new: str):
    return (re.compile(re.escape(old.encode())), new.encode())


# A menu item: from its `<a role="menuitem" id="…"` to the first `</a>` after it, with no other `<a` in between.
def menu_item(item_id: str, href: str):
    return (
        re.compile(rb'<a\s+role="menuitem"\s+id="' + item_id.encode() + rb'"\s+href="' + href.encode()
                   + rb'"(?:(?!<a[\s>]).)*?</a>\s*', re.S),
        b"",
    )


PATCHES = [
    ("page visibility: the guest object is built for everyone",
     *literal('function createPageVisibility(){if(!loadTimeData.getBoolean("isGuest")){return undefined}const pageVisibility={',
              'function createPageVisibility(){const rayGuest=loadTimeData.getBoolean("isGuest");const pageVisibility={')),
    ("page visibility: everyone but guests sees every section except people and appearance",
     *literal("yourSavedInfo:false};return pageVisibility}let pageVisibility=createPageVisibility();",
              "yourSavedInfo:false};if(!rayGuest){for(const key in pageVisibility){pageVisibility[key]=true}"
              "pageVisibility.appearance=false;pageVisibility.people=false}return pageVisibility}"
              "let pageVisibility=createPageVisibility();")),
    ("top-level route: Search engine instead of Appearance",
     *literal('if(!loadTimeData.getBoolean("isGuest")){return routes.APPEARANCE}let guestTopLevelRoute=routes.SEARCH;',
              'if(!loadTimeData.getBoolean("isGuest")){return routes.SEARCH}let guestTopLevelRoute=routes.SEARCH;')),
    ("menu: the Profiles item (/people)", *menu_item("people", "/people")),
    ("menu: the Appearance and behavior item (/appearance)", *menu_item("appearance", "/appearance")),
]


def fail(message: str) -> None:
    print(f"error: trim-settings-pak: {message}", file=sys.stderr)
    print("error: the engine's settings page changed (engine.lock bump?); update PATCHES in "
          "tools/trim-settings-pak.py against the new bundle", file=sys.stderr)
    sys.exit(1)


def trim(path: str) -> None:
    with open(path, "rb") as f:
        data = f.read()
    parsed = rebrand_pak.split_pak(data)
    if parsed is None:
        fail(f"{path} isn't a pak v5 file")
    ids, sentinel_id, bodies, alias_bytes, header = parsed
    found = []
    for i, body in enumerate(bodies):
        if body[:2] != b"\x1f\x8b":
            continue
        try:
            text = gzip.decompress(body)
        except (OSError, EOFError):
            continue
        if ANCHOR in text:
            found.append((i, text))
    if not found:
        fail(f"no gzip-compressed resource in {path} holds `{ANCHOR.decode()}` (the settings page's code)")
    if len(found) > 1:
        fail(f"{len(found)} resources hold `{ANCHOR.decode()}`; expected one")
    index, text = found[0]
    if MARKER in text:
        print(f"trim-settings-pak: resource {ids[index]} is already trimmed", file=sys.stderr)
        return
    for name, pattern, replacement in PATCHES:
        hits = len(pattern.findall(text))
        if hits != 1:
            fail(f"resource {ids[index]}: `{name}` matched {hits} times, expected exactly 1")
        text = pattern.sub(lambda _: replacement, text, count=1)
    # The menu patches must not have eaten more than their own item.
    for left in (b'id="people"', b'id="appearance"'):
        if re.search(rb'<a\s+role="menuitem"\s+' + left, text):
            fail(f"resource {ids[index]}: a menu item with {left.decode()} is still there")
    bodies[index] = gzip.compress(text + b"\n" + MARKER, 9, mtime=0)
    with open(path, "wb") as f:
        f.write(rebrand_pak.join_pak(header, ids, sentinel_id, bodies, alias_bytes))
    print(f"trim-settings-pak: trimmed resource {ids[index]} of {os.path.basename(path)}", file=sys.stderr)


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    trim(sys.argv[1])
    return 0


if __name__ == "__main__":
    sys.exit(main())
