# Ray

A macOS browser with Arc's sidebar, on real Chromium. Native AppKit and Core Animation on top of Chrome's own
framework; no Electron, no WebKit, no React Native.

Early and personal. Expect rough edges.

## What works

- Arc-style sidebar: pinned tiles, pinned tabs (closing one unloads it and resets it to its pinned URL, `/` when you've
  wandered off), today tabs with Clear and 12-hour archiving, New Tab. Rename any tab (right-click › Rename…, or
  double-click its title); the name sticks across pages and relaunches, and Arc's names come over on import.
- ⌘S hides the sidebar; hovering the left edge slides it back in as a floating panel, sprung to Arc's recorded motion.
- Command bar (⌘T, ⌘L): open tabs, history, search suggestions, URLs, and Ray's own commands by name ("task manager",
  "clear cache", "zoom in"…) with their shortcuts.
- Moving in: a first-run welcome that imports from Arc (recommended), Dia, Chrome, Brave, Edge, Helium, Firefox, Zen
  or Safari: pinned tabs and folders, favorites, open tabs, history, bookmarks, passwords, cookies (you stay signed
  in), addresses and cards. Never another browser's settings. Later: File › Import from Browser….
- Dia's address bar above the page, with its loading glow; site controls; find (⌘F); downloads; permission prompts;
  extension buttons and popups from the Chrome Web Store.
- Chrome's basics: Print (⌘P), Show Full History (⌘Y), zoom (⌘+ ⌘− ⌘0, with Arc's zoom level note), View Source
  (⌥⌘U), Save Page As, Task Manager, Clear Browsing Data (⇧⌘⌫).
- Settings window (⌘,) with your profile colour, which every accent in Ray follows.
- Sessions restored at launch; only the active tab loads.
- Full screen edge to edge when the sidebar is hidden.
- DevTools (⌥⌘I), popups and `target=_blank` as tabs.
- Updates itself (Ray › Check for Updates…).
- Can be your default browser (System Settings › Desktop & Dock › Default web browser): links from other apps, and
  HTML or PDF files you open with Ray, open as tabs, also when they launch Ray.

Not yet: Spaces, drag and drop between windows, Split View, Little Arc, installing imported extensions. The full
list is in [docs/MISSING.md](docs/MISSING.md).

## Engine

Ray's engine is Chromium 156 with [Helium](https://github.com/imputnet/helium)'s de-Googling patches and
[Ardia](https://github.com/mantrakp04/ardia)'s hosting layer, built from `engine/` (Ardia's engine, renamed for Ray
by `tools/engine/sync-engine.sh`). Building it takes about 45 GB of disk and a few hours the first time: the steps
are in `engine/patches/build/` (1, 3, 4, 2, 5), and `scripts/fetch-engine.sh` finds the result.

## Build

Apple Silicon, macOS 14+, Xcode.

```sh
scripts/build-app.sh      # build/Ray.app, plus build/RayTests.app with test hooks
scripts/test.sh           # unit tests, then checks against a hidden RayTests.app
open build/Ray.app
```

## Security

Pages run in Chromium's sandbox with site isolation. Ray's own code never parses web content. Read before using it
with real accounts:

- **Engine updates**: Ray builds its own engine from `engine/` (Chromium 156); it's only as patched as that build.
- **Saved passwords and cookies** are encrypted with "Ray Safe Storage" in your login keychain. Ray 0.1 used
  Chromium's stand-in keychain (a public key); the first launch of a newer Ray moves that data to the real key.
  Builds share one self-signed identity, so macOS asks only once to let Ray use the item.
- **Importing** reads another browser's saved logins only when you choose passwords, cookies or cards, after macOS
  asks for your password for that browser's own key; nothing is sent anywhere.
- **No Safe Browsing**: Helium compiles it out.
- **Self-signed** ("Ray Code Signing"), no hardened runtime, not notarized.

## License

GPL-3.0 (`LICENSE`), as the engine it ships with is built with Helium's GPL-3.0 patches. `engine/` is
from Ardia under Apache-2.0 (`LICENSE.Apache-2.0`); see `NOTICE`.
