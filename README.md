# Ray

Arc's sidebar on real, de-Googled Chromium. A native Mac browser for when Arc shuts down.

<!-- TODO before launch: a 10–15 s motion GIF or MP4 here (sidebar, ⌘S, ⌘T command bar, ⌃Tab). Under 10 MB so
     GitHub plays it inline. Then a link to the side-by-side video with Arc. -->
<p align="center"><em>Video coming soon.</em></p>

```sh
brew install shanuflash/tap/ray
```

Or download the DMG from the [latest release](https://github.com/shanuflash/ray/releases/latest).
macOS 14 or later, Apple Silicon. Free and open source.

> Use the full name, `shanuflash/tap/ray`. Plain `ray` on Homebrew is a different app.

### First open

Ray isn't notarized (no paid Apple developer account), so macOS asks once:

- **macOS 15 and later:** open it once, then System Settings › Privacy & Security › **Open Anyway**.
- **macOS 14:** right-click Ray › Open.

From the DMG, drag Ray to Applications first: run from the DMG or Downloads, it can't update itself. After that Ray
updates itself (Ray › Check for Updates…).

## Why Ray

- **Arc's feel.** The sidebar, pinned tabs, favorites, folders, ⌘S, the command bar, ⌃Tab. Fitted to Arc's sizes
  and motion.
- **Native.** AppKit and Core Animation. No Electron, no web UI around the page.
- **Real Chromium.** Chromium 158 with Helium's de-Googling patches. Chrome Web Store extensions work as in Chrome.
- **Your Arc comes with you.** One import: tabs, folders, history, passwords, and still signed in.
- **Yours.** GPL-3.0, no account, no usage stats.

## Coming from Arc

File › Import from Browser… (or the welcome screen on first run).

### What comes over

- Favorites, pinned tabs and folders, with your tab names
- Open Today tabs
- History, all of it (not just the last 90 days)
- Bookmarks, passwords, autofill
- Cookies: you stay signed in

Also from Dia, Chrome, Brave, Edge, Helium, Firefox, Zen and Safari.

<!-- TODO when Spaces land: Arc's Spaces import as Spaces. Until then they arrive as pinned folders. -->
Arc's Spaces arrive as pinned folders until Ray has Spaces. Not imported: extensions (reinstall them from the
Chrome Web Store), the Archive, Air Traffic Control rules, Boosts, Easels and Notes.

### Arc's keys that work

| Key | Does |
|---|---|
| ⌘T | Command bar (again to close) |
| ⌘L | Command bar on this page; Return reloads, ⌘↩ opens in a new tab |
| ⌘S | Hide or show the sidebar |
| ⌘D | Pin or unpin the tab |
| ⌘1 – ⌘9 | Go to a sidebar item |
| ⌃Tab | Recent tabs, with previews |
| ⌥⌘↓ / ⌥⌘↑ | Next / previous tab |
| ⇧⌘C | Copy the page's link |
| ⇧⌥⌘C | Copy the link as Markdown |
| ⌥⌘V | Paste a link as a new tab |
| ⇧⌘K | Clear Today (keeps the tab you're on) |
| ⇧⌘T, ⌘Z | Reopen closed tabs |
| ⌘O | Open a Little Ray in Ray |
| ⇧⌘N | Private window |

Every key can be changed in Settings › Shortcuts.

### What's missing

Honest list. The full one is [docs/MISSING.md](docs/MISSING.md).

<!-- TODO before launch: drop Spaces and Profiles from this list once they ship. -->
- **Spaces** and **Profiles** (in progress)
- **Split View**
- **Peek**: links from a pinned tab open in that tab, not a floating card
- **Archive view**: stale Today tabs are archived but can't be browsed yet
- **Several normal windows**: ⌘N brings the one window forward; no dragging a tab out
- **Boosts**, **Easels**, **Notes**, **Library**, **Capture**, **Live Folders**, **Air Traffic Control**
- **Sidebar on the right**, **media controls in the sidebar**
- **Sync between Macs**
- **A built-in ad blocker**: install uBlock Origin Lite from the Web Store
- **Notifications while a site's tab is closed** (Web Push): Slack, Gmail and Teams notify only while open
- Keys: ⌘. to focus the sidebar, Back to Pinned URL, ⌃⇧⌘C copy as quote, ⌥⌘⌫ to remove a suggestion

Left out on purpose: Arc Max's AI features.

## What works

- Arc's sidebar
- Favorites, pinned tabs and folders
- Hide the sidebar with ⌘S
- Command bar (⌘T)
- Chrome extensions
- Import from Arc, still signed in
- Native Mac app, no Electron

<!-- TODO before launch: add Spaces and Profiles here once they ship. -->

### More

- **Sidebar**
  - Drag its edge to resize
  - Rename tabs
  - Arc's right-click menus: duplicate, mute, move, tab icons
  - A sound icon on playing tabs: click to mute
  - Videos pop out into picture in picture when you switch away
  - Folder colours and icons
  - Select several tabs
  - ⌃Tab switcher with page previews, like Arc
  - Pinned tabs reset when closed
  - Closing a tab goes back to the tab you used before it, like Arc
  - The list scrolls to the tab you switch to
  - Double-click empty space for a new tab
  - Drop a link, a file or text on it to open a tab there; ⌥-drag a tab to copy it
  - Clear Today (⇧⌘K) keeps the tab you're on; ⇧⌘T or ⌘Z brings the rest back
  - Today tabs archive after 12 hours
- **Moving in**
  - Also from Dia, Chrome, Brave, Edge, Helium, Firefox, Zen and Safari
  - Tabs, folders, history (all of it, not just the last 90 days), bookmarks, passwords and cookies
  - Asks once to open links from other apps, then rarely
- **Other**
  - Address bar above the page, like Dia
  - A link's address at the bottom corner on hover
  - Back and forward history lists: right-click or hold; ⌘-click opens the page in a new tab
  - Back on a tab a link opened closes it and returns to the page that opened it
  - Videos' full screen fills the screen
  - Links from other apps open in Little Ray, a small window for a quick look; ⌘O moves the page into Today
  - Sign-in pop-ups open in a small window with their address on top, not as tabs, and stay on a full-screen Ray's
    Space
  - Drag a link, file or text to the window's left edge to bring a hidden sidebar out and drop it there
  - ⌘L then Return reloads; ⌘↩ opens in a new tab
  - Arc's keys: ⌥⌘↓/↑ for the next tab, ⌥⌘V pastes a link as a new tab, ⇧⌥⌘C copies a Markdown link
  - Swiping back or forward shows a frosted chip that ticks when letting go will navigate
  - Edge-to-edge full screen
  - Settings in the command bar
  - Arrow keys in the command bar show the row in the field, like Chrome
  - Tab to search YouTube, Wikipedia, GitHub and more, in the site's colour, like Arc
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

<!-- TODO before launch: move whatever has shipped (Spaces, Profiles) out of this list. -->
- Spaces
- Profiles
- Split View
- Installing your imported extensions

Full list: [docs/MISSING.md](docs/MISSING.md).

## Privacy and security

The engine is Chromium 158 (from 0.10.0). Pages run in Chromium's sandbox with site isolation; Ray's own code never parses web content. No Safe Browsing
(Helium compiles it out). Passwords and cookies are encrypted with Ray's own key in your login keychain. Imports read
another browser only when you ask, and send nothing anywhere. Updates are signed and checked before they install, and download only what changed when they can.
A site that asks to share your screen gets only the tab, window or screen you pick in Ray's picker.
Third-party cookies are allowed outside private windows, as in Chrome and Arc (sites that embed another site, like
Teams' app tabs, need them); chrome://settings/cookies blocks them if you prefer.
Preloading is on, as in Chrome: Ray may connect to a site you're about to open before you press Enter (turn it
off in chrome://settings/performance, Preload pages).

## Build from source

Needs Xcode and Ray's engine, a Chromium build that takes a few hours and a lot of disk the first time
(`engine/patches/build/`). Then:

```sh
scripts/build-app.sh   # build/Ray.app
scripts/test.sh        # unit tests and checks on a hidden test build
open build/Ray.app
```

How to build, test and send a change: [CONTRIBUTING.md](CONTRIBUTING.md). Small tasks to start with:
[docs/GOOD-FIRST-ISSUES.md](docs/GOOD-FIRST-ISSUES.md). Deeper notes: [CLAUDE.md](CLAUDE.md) and [PLAN.md](PLAN.md).

## Credits and licence

Ray is GPL-3.0 ([LICENSE](LICENSE)). Its engine and importer come from [Ardia](https://github.com/mantrakp04/ardia)
(Apache-2.0, [LICENSE.Apache-2.0](LICENSE.Apache-2.0)), built on [Chromium](https://www.chromium.org) with
[Helium](https://github.com/imputnet/helium)'s patches; see [NOTICE](NOTICE). Thanks also to
[Cra](https://github.com/VictorKildahl/cra) and [Crest](https://github.com/pauljoda/Crest), whose work Ray learns from. Updates by
[Sparkle](https://sparkle-project.org).
