# Ray

Arc's sidebar on real, de-Googled Chromium. A native Mac browser for when Arc shuts down.

<!-- Hero GIF goes here: a short clip of the sidebar, ⌘S and the command bar. -->

## Install

macOS 14 or later, Apple Silicon.

1. Download `Ray-<version>.dmg` from the [latest release](https://github.com/shanuflash/ray/releases/latest), open it
   and drag Ray to Applications. Or with Homebrew (the full name matters: plain `ray` is a different app):

   ```sh
   brew install shanuflash/tap/ray
   ```

2. Open it. Ray isn't notarized (no paid Apple developer account), so the first time:
   - **macOS 15 and later:** open it once, then System Settings › Privacy & Security › **Open Anyway**.
   - **macOS 14:** right-click Ray › Open.

Ray updates itself after that (Ray › Check for Updates…).

## What works

- Arc's sidebar
- Favorites, pinned tabs and folders
- Hide the sidebar with ⌘S
- Command bar (⌘T)
- Chrome extensions
- Import from Arc, still signed in
- Native Mac app, no Electron

### More

- **Sidebar**
  - Rename tabs
  - Arc's right-click menus: duplicate, mute, move, tab icons
  - A sound icon on playing tabs: click to mute
  - Folder colours and icons
  - Select several tabs
  - ⌃Tab switcher with page previews, like Arc
  - Pinned tabs reset when closed
  - Today tabs archive after 12 hours
- **Moving in**
  - Also from Dia, Chrome, Brave, Edge, Helium, Firefox, Zen and Safari
  - Tabs, folders, history, bookmarks, passwords and cookies
  - Asks once to open links from other apps, then rarely
- **Other**
  - Address bar above the page, like Dia
  - A link's address at the bottom corner on hover
  - Back and forward history lists: right-click or hold
  - Edge-to-edge full screen
  - Settings in the command bar
  - Your own colour and shortcuts
  - Offers to save passwords when you sign in
  - Offers to save addresses and cards from forms
  - Asks before a link opens another app; shows blocked pop-ups
  - Its own crashed-page and "not responding" prompts
  - Its own screen-sharing picker, sharing note and shared-tab marks
  - Asks before quitting cancels downloads
  - Bookmarks in a panel, the menu bar and the command bar
  - JumpCloud Go sign-in

## Coming

- Spaces
- Profiles
- Split View
- Little Arc
- Installing your imported extensions

Full list: [docs/MISSING.md](docs/MISSING.md).

## Privacy and security

Pages run in Chromium's sandbox with site isolation; Ray's own code never parses web content. No Safe Browsing
(Helium compiles it out). Passwords and cookies are encrypted with Ray's own key in your login keychain. Imports read
another browser only when you ask, and send nothing anywhere. Updates are signed and checked before they install.
A site that asks to share your screen gets only the tab, window or screen you pick in Ray's picker.

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
