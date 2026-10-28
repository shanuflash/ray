# Ray

A macOS browser with Arc's sidebar, on real Chromium. Native AppKit and Core Animation on top of Chrome's own
framework; no Electron, no WebKit, no React Native.

Early and personal. Expect rough edges.

## What works

- Arc-style sidebar: pinned tiles, pinned tabs (closing one unloads it and resets it to its pinned URL, `/` when you've
  wandered off), today tabs with Clear and 12-hour archiving, New Tab.
- ⌘S hides the sidebar; hovering the left edge slides it back in as a floating panel, sprung to Arc's recorded motion.
- Command bar (⌘T, ⌘L): open tabs, history, search suggestions, URLs.
- Sessions restored at launch; only the active tab loads.
- Full screen edge to edge when the sidebar is hidden.
- DevTools (⌥⌘I), popups and `target=_blank` as tabs.

Not yet: Spaces, drag and drop, permission prompts (requests are refused), downloads UI, find bar, extension buttons.

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

- **Engine updates** come from Ardia's releases; Ray is only as patched as the pinned engine.
- **Saved passwords and cookies** use Chromium's stand-in keychain (`--use-mock-keychain`) while on Ardia's prebuilt
  engine, so they're encrypted with a public key. Don't sign in to anything important yet.
- **No Safe Browsing**: Helium compiles it out.
- **Ad-hoc signed**, no hardened runtime, not notarized.

## License

GPL-3.0 (`LICENSE`), as the engine it ships with is built with Helium's GPL-3.0 patches. `engine/` is
from Ardia under Apache-2.0 (`LICENSE.Apache-2.0`); see `NOTICE`.
