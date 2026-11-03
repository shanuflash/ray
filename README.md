# Ray

Arc's sidebar on real, de-Googled Chromium. A native Mac browser for when Arc shuts down.

<!-- Hero GIF goes here: a short clip of the sidebar, ⌘S and the command bar. -->

## Install

macOS 14 or later, Apple Silicon.

1. Download `Ray-<version>.zip` from the [latest release](https://github.com/shanuflash/ray/releases/latest).
2. Unzip it and drag Ray to Applications. Don't run it from Downloads, or it can't update itself.
3. Open it. Ray isn't notarized yet, so the first time:
   - **macOS 15 and later:** open it once, then System Settings › Privacy & Security › **Open Anyway**.
   - **macOS 14:** right-click Ray › Open.

Ray updates itself after that (Ray › Check for Updates…).

## What you get

- **Arc's sidebar:** favorites, pinned tabs, Today tabs that archive themselves, folders with colours and icons,
  rename any tab, ⌘-click to select several. ⌘S hides it; the left edge brings it back.
- **Command bar** (⌘T, ⌘L): tabs, history, search, site searches, and every command and setting by name.
- **Real Chromium:** Chrome Web Store extensions, DevTools, print, Chrome's own pages. Helium's de-Googling patches.
- **Moving in:** bring pinned tabs, folders, history, bookmarks, passwords and cookies over from Arc, Dia, Chrome,
  Brave, Edge, Helium, Firefox, Zen or Safari. You stay signed in.
- **Native Mac app:** AppKit and Core Animation, no Electron. Light or dark, your own accent colour, a searchable
  Settings window, your own shortcuts.
- Your default browser if you want it. Passwords and cards behind Touch ID. JumpCloud Go sign-in, opt-in.

## Not yet

Spaces, profiles, Split View, Little Arc, Peek, a built-in ad blocker (use uBlock Origin Lite for now), installing
the extensions you import. The full list: [docs/MISSING.md](docs/MISSING.md).

## Privacy and security

Pages run in Chromium's sandbox with site isolation; Ray's own code never parses web content. No Safe Browsing
(Helium compiles it out). Passwords and cookies are encrypted with Ray's own key in your login keychain. Imports read
another browser only when you ask, and send nothing anywhere. Updates are signed and checked before they install.

## Build from source

Needs Xcode and Ray's engine, a Chromium build that takes a few hours and a lot of disk the first time
(`engine/patches/build/`). Then:

```sh
scripts/build-app.sh   # build/Ray.app
scripts/test.sh        # unit tests and checks on a hidden test build
open build/Ray.app
```

Details for contributors: [CLAUDE.md](CLAUDE.md) and [PLAN.md](PLAN.md).

## Credits and licence

Ray is GPL-3.0 ([LICENSE](LICENSE)). Its engine and importer come from [Ardia](https://github.com/mantrakp04/ardia)
(Apache-2.0, [LICENSE.Apache-2.0](LICENSE.Apache-2.0)), built on [Chromium](https://www.chromium.org) with
[Helium](https://github.com/imputnet/helium)'s patches; see [NOTICE](NOTICE). Thanks also to
[Cra](https://github.com/VictorKildahl/cra) and [Crest](https://github.com/pauljoda/Crest), whose work Ray learns from. Updates by
[Sparkle](https://sparkle-project.org).
