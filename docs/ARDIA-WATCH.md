# Ardia watch

What Ardia (github.com/mantrakp04/ardia, Ray's upstream) ships after the source Ray's engine came from
(`engine.lock`'s `ardia_tag`), and what Ray should take, copy or answer. Newest release first. A daily task
re-checks Ardia's releases against the line below: keep it accurate.

Last reviewed: v0.2.44-nightly.3 (engine-7ad5405dbe6d), 2026-11-02

Ray's engine: Ardia v0.2.42's `engine/` (tree `529394c5`), Chromium 156.0.8078.47. Chrome stable for Mac on
chromiumdash, checked 2026-11-02: 156.0.8078.80 (.76/.79 before it) and 157.0.8103.26. Ardia moved to
156.0.8078.79 on Helium 0.20.3 in engine-1982453a46fe (v0.2.43). Chrome's own security releases are tracked in
`docs/CHROMIUM-WATCH.md`.

## Ray should

In priority order. Nothing here is started; engine items cost one engine rebuild (the owner's call).

1. **Rebuild the engine on Chromium 156.0.8078.79+ (Helium 0.20.3).** Ray is on .47, 32 patch builds behind
   Chrome stable (.80), and those builds carry Chrome's stable security fixes of 2026-10-28/29. Ardia has done the
   work: engine-1982453a46fe bumps `helium-pins.ini` / `env.sh` to Chromium .79, Helium 0.20.3 and helium-macos
   0.20.3.1, and fixes the two patches that broke (`chromium-helium-bangs-off`: Helium's reworked bangs loader;
   `chromium-extension-omaha-attributes`: ungoogled's safebrowsing fix deletes a variable the patch now restores).
   Taking Ardia's engine (item 2) brings all of it. Xcode 27.2 needs the Metal Toolchain downloaded once
   (ANGLE's Metal shaders; Ardia's `docs/engine-build.md`).
2. **Take engine-7ad5405dbe6d** (includes 1982453a, 4d8c6403 and 2f172eb5) through `sync-engine.sh`, then
   re-check `engine-ray/`'s fixups against the reorganised `ac_*.cc` files (4d8c64 rewrites every call's prelude
   and drops 15 export headers; see its section), move `Downloads` to `ac_downloads_command`, and diff `ArdiaCore.h`
   against `RayCore.h`: new delegate methods `engine:extensionInstallFailed:tab:` (or a failed .crx drop says
   nothing) and `tab:shareFromContextMenu:` (7ad5405; the page menu's Share… items show only when the delegate
   answers it, so Ray can leave it out at first). Brings: Chromium .79, install by dropping a .crx, bookmarks export
   (`ac_bookmarks_export_html`), the "Allow User Scripts" switch, Memory Saver calls, Picture in Picture reopening
   where it was left, Obsidian Web Clipper's app links, Dia's page menu order, engine-side private-window gating and
   secret zeroing, and a host-shown page menu that runs the picked item before tearing the menu down (7ad5405).
3. **Decide Memory Saver.** Ray has no tab sleeping of its own: Ardia's 20-minute sleep lived in Ardia's app, which
   Ray never copied. But Ray's engine still skips Helium's `memory-saving-by-default.patch` with the reason "would
   fight Ray's own tab sleeping", so Memory Saver is off unless the user turns it on in chrome://settings/performance
   (which Ray's trim keeps). Ardia 0.2.43 (stable) ships Helium's way: on by default, Moderate / Balanced /
   Maximum, "Always keep these sites active", pinned and current tabs never sleep. Taking item 2 turns it on by
   default; Settings should give it rows through `ac_memory_saver` (MISSING, Ardia settings 15).
4. **Follow the Mac's language.** Ardia 0.2.43 confirms the fix: Chrome took its UI locale from the app bundle's
   localizations; with none declared every extension saw `en` (uBlock Origin's text was blank). Ray's Info.plist
   (`scripts/build-app.sh`) declares no `CFBundleLocalizations` either (not tried). App-side, no engine: declare
   Chromium's 55 desktop locales (Helium's list) and keep their `locale.pak`s. Ray's own UI stays English.
5. **Per-tab mute and a sound icon** (MISSING, Arc #8 and Chrome #12). Copy Ardia's corrected model: the speaker
   and Mute Tab mute that tab only (kept across navigation and relaunch); Mute Site is its own choice behind ⌥ and
   in Site controls. New in 0.2.44-nightly.2: a muted tab's or site's notifications post without a sound
   (`0a71e81d`); do the same when mute lands.
6. **Collapse the pinned section** (MISSING, Arc #17): shipped in Ardia's stable 0.2.43.
7. **Downloads: a cancelled Save As row.** Ardia 0.2.43 fixed the nameless "Cancelled" row a cancelled save panel
   left. Ray's `Downloads` lists every item with no path check: likely the same (not tried). Fix: list a download
   once it has a path; drop one cancelled before it had one.
8. **No peek while Ray is in the background** (new, MISSING known limitation). Ardia 0.2.44-nightly.2 (`4530d075`,
   `19b3e1da`, its issue #698): hovering a background window's left edge slid the collapsed sidebar out; now a
   peek opens only while the app is active, a hover that arrived in the background opens when the app comes forward
   with the pointer still there, and one that left opens nothing. Ray's `pointer(at:appActive:)` only narrows the
   reach to the window's own edge strip when inactive, so it still peeks from a background window (not tried).
9. **Peek decision input** (PLAN.md open decision): Ardia's stable 0.2.43 opens other sites' links from Top Apps
   and pinned tabs in Peek, as Arc does, behind Settings › Tabs › Links (off by default).
10. **Reserved keys:** Ardia's stable now reserves Helium's set by menu command; Ray's (`Shortcuts.isReserved`)
    lacks Developer Tools (⌥⌘I), Toggle Developer Tools (F12) and Search Tabs (⇧⌘A). Small.
11. **Tab-switch blank frame** (another chat is on it): Ardia 0.2.43 ships its fix: the outgoing page stays up until
    the incoming page's render widget shows new content (≤ 250 ms), and ⌘W hands the closing tab's page view to the
    one replacing it (`d18f3414`, `277c8256`).
12. **Closing the last tab keeps the window while anything is pinned** (Ardia 0.2.43, as Arc). Try by hand in Ray
    with only pinned tabs and favorites left (MISSING known limitation 28).
13. **Share from the page menu** (new, MISSING Chrome gap): Share… for selected text, an image, a link with
    trackers removed, a video/audio source or the page, through macOS's share sheet; File › Share › Share… on ⌥⌘S.
    Engine part comes with item 2; Ray then implements `tab:shareFromContextMenu:` with `NSSharingServicePicker`.
14. **Look:** Ardia went flat, then back to glass, and v0.2.43 ships a Glass / Classic choice (Glass on pinned
    tiles, address field, buttons, Downloads and site controls, tintable). Ray's Panels and notes setting already
    offers Glass / Solid on its surfaces; nothing to take beyond watching what users pick.
15. **Sidebar on the right** (MISSING, Arc #15): Ardia's main has it, unreleased (below). Its commit lists every
    place a left edge was assumed; use it as Ray's checklist when this is built.

## Unreleased on main (6cb71745 "Nightly 0.2.44-nightly.4", 2026-11-02)

Read from Ardia's `main` on 2026-11-03, before a release: the commit is there, the tag and release aren't. The daily
task reviews it again when it ships. No change under `engine/`, so nothing for Ray's engine. Range
`v0.2.44-nightly.3..6cb71745`: 157 files, mostly the `ardia browse` CLI and Ardia's React app.

**App** (for Ray to copy or answer):
- **Sidebar on the right** (`4844d5a1`, Ardia #216): `sidebarSide` Left/Right, in the sidebar layout only (tabs on
  top and Little Ardia ignore it). Mirrored: the card's padding, the dock slide, the hidden sidebar's peek (slides in
  from the right; the edge watcher watches either edge), the resize handle (left edge, drag inverted), hover cards
  and popovers beside the sidebar (open leftward), drops onto the sidebar, the command bar from the sidebar's field,
  the downloads panel, the tour card. Traffic lights stay at the window's top left, as in Arc; with no toolbar the
  page card leaves a 30 pt strip above it for them. Chosen in onboarding, Settings › Tabs, View › Sidebar on Right
  and the sidebar's background menu. Ray: item 15. In Ray the pieces to mirror are `layout()`'s dock and peek
  frames, `pointer(at:appActive:)`'s edge, `Panels` anchors beside the sidebar (downloads, folder icon picker), and
  the lights, which Ray draws in the sidebar (`WindowLightButton`) and would have to leave behind on the left.
- **Little Ardia: "Open new-tab links inside Little Ardia"** (`0f82079a`, `0680c90e`, `9da89bc1`; off by default).
  A `target=_blank` click in Little Ardia normally opens behind, in the main window, which reads as a dead click.
  The page script notes a trusted, uncancelled primary click on an http(s) link with a new-context target (read
  after dispatch, so a handler that rewrites `href` or `target` is honoured); Chrome's new foreground tab whose URL
  matches a note under 2 s old is closed and the link loads in Little Ardia's own tab. ⌘-clicks, forms,
  `window.open()` and sized popups still go to the main window. Ray: design input for Little Arc (MISSING, Arc #4).
- **Moved tabs land where a new tab opens** (`221b27c1`, `3461c31f`, `09651f55`, `80f2c113`, `e17ba09b`): a tab
  moved into a window goes where "New tabs open at" puts a new one, as one block, joining the current tab's group only
  if every moved tab may. Ray has no move-between-windows yet; follow `insertToday` when it does.
- Group box's last row rounds with the box (`6f2762d0`); New Tab search box, emoji picker and click-away name fixes
  filmed. Ardia's React layout only.

**Fixes:**
- **Expand mid-redirect stranded the tab on about:blank** (`193b45a5`, Ardia #550): a tab moved while loading
  reported its initial about:blank, and the receiving view loaded it, cancelling the real navigation. Ray has no tab
  moves yet; when Little Arc or Move to Window lands, never load a handed-over tab's reported URL (and never
  about:blank) over its live page.
- **Traffic lights in the peeked sidebar** (`2b92e041`, `954d7ab5`, Ardia #770): AppKit's lights moved below their
  titlebar container took no clicks or hover. Not Ray's problem: Ray hides the system lights and draws its own.

**Not for Ray:** `ardia browse` (`20e2d458` and three follow-ups), agent-browser 0.35's commands driving the running
Ardia over CDP through a per-session daemon (0600 socket, peer uid checked, refs that go stale on navigation, a
password vault in the login Keychain); Ray left the `ardia` CLI out on purpose. uBlock Origin 1.75.0 → 1.75.2 for
Ardia's built-in blocker (`53884d2a`); Ray has none (open decision).

**Competitive:** Ardia now lets AI agents drive the user's own browser with a tool they already know
(agent-browser). Ray has no equivalent and left Ardia's CLI out on purpose; the owner may want to revisit that.

## v0.2.44-nightly.3 (2026-11-02), engine-7ad5405dbe6d

**Engine** (tree `7ad5405d`, from `1982453a`; no Chromium bump, still 156.0.8078.79):
- `ac_context_menu_share.{h,mm}` (new) and `ac_context_menu.mm`: the page's right-click menu gets "Share…" items
  (text, link with trackers removed, image file, video/audio source, page), each placed after its neighbour group,
  only when the tab's delegate answers the new `tab:shareFromContextMenu:`. Shared images go to a per-process 0700
  folder with a flock'ed lock, removed on cancel/finish/after an hour and by a startup sweep that never follows
  symlinks. Ray: item 13.
- `ShowThroughHost`: the picked item now runs (`ActivatedAt`) before `MenuClosed`, and `MenuClosed` only while the
  menu still exists. Ray's `ac_context_menu.mm` has the old order (`MenuClosed` first, then the pick only if the
  weak pointer survived): comes with item 2; if Ray ever drops picks from a host-shown page menu, this is why.
- No security fixes.

**App:** Share a pinned folder through iCloud Drive (`.webloc` files, three-way merge, per profile); a real emoji
and SF Symbol picker for profile and sidebar icons; Share in the page menu (⌥⌘S); text fields commit on click-away;
⌘L on a New Tab page goes to the page's own search box. Ray: Change Icon… already has Arc's 24 symbols plus emoji
(`FolderIconPicker`); a searchable full emoji grid is a possible follow-up. Shared folders: Ardia-only for now (Ray
has no sync).

**Competitive:** Ardia keeps adding Arc-beyond features (shared folders, dotfiles config). Ray's edge stays native
AppKit Settings and panels, but it's now an engine rebuild behind on security.

## v0.2.44-nightly.2 (2026-11-01)

No engine change (engine-1982453a46fe).

**App:** settings, keybindings and themes from `~/.config/ardia/config.json` (dotfiles style, read-only, applied
at launch and on save) and an `ardia` command that can run commands and hooks; custom themes from the New Tab page;
the sidebar player shows the time left. **Fixes Ray shares:** muted tabs' notifications are silent (item 5); the
collapsed sidebar doesn't peek while another app is in front (item 8). Ray: the config file and CLI stay "left out
on purpose" (MISSING); the player is MISSING Arc #8.

## v0.2.44-nightly.1 (2026-10-31)

No engine change. **App:** Ardia's text sizes, corners, spacing and animation timings collapse into one small token
set; badges, dividers, toasts, key caps, segmented controls and dialog buttons become shared components. Ray already
works this way in places (`PanelKit`, `SettingsControls`, `SurfaceBackdrop`, the one spring); nothing to take.

## v0.2.43 (2026-10-31, stable), engine-1982453a46fe

**Engine** (tree `1982453a`, from `4d8c6403`):
- **Chromium 156.0.8078.79 on Helium 0.20.3 / helium-macos 0.20.3.1** (`a55758e4`): Chrome's stable updates of
  2026-10-28 and -29 (.73 and .79), with their security fixes. Helium's series unchanged in content and order.
  Patches reworked: `chromium-helium-bangs-off` (LoadBangs answers an empty catalogue before any fetch) and
  `chromium-extension-omaha-attributes` (re-declares `should_perform_action_on_omaha_attributes`). Ray has both
  patches through the rename map, so it hits the same breakage if it bumps alone: take Ardia's. Ray: item 1.

**App** (the stable roll-up of nightlies 1–9; items already covered above and below): Glass / Classic look; Dia's
right-click menu order with icons on macOS 27, move tabs/groups to another profile or window, Reload's menu turns
the ad blocker off or clears cookies; sidebar player expands on hover; Memory Saver replaces Ardia's tab sleeping;
profile icons; collapsible pinned section; bookmarks bar drag and drop and HTML export; per-tab mute; a zoom-level
panel and ⌘-scroll to the page first; compact 28 pt toolbar; Peek for other sites' links; .crx drop and user
scripts; tab cleanup to the minute.

**Fixes Ray shares or should check:** no blank frame on tab switch or ⌘W (item 11); Sign in with Google popups
blank since 0.2.41 (`1c3d5dee`, the page under Ardia's origin strip: Ardia's own popup UI, Ray's popups are
Chrome's, nothing to take); extensions in the Mac's language (item 4); cancelled Save As row (item 7); PiP where
left (engine); a website gets every key first except Helium's reserved ones (item 10); old copies of the app no
longer in Open With (Launch Services: Ray could `lsregister -u` stale copies on update; not tried).

**Competitive:** Ardia is now on .79, Ray on .47: Ardia is ahead on security until Ray rebuilds. Ray is ahead on a
native Settings window and AppKit panels.

## v0.2.43-nightly.9 (2026-10-31)

No engine change. **App:** Glass covers Downloads and site controls too; the separate "Use glass for panels" switch
is gone; glass at half strength. Ray: item 14.

## v0.2.43-nightly.8 (2026-10-31)

No engine change. **App:** Glass or Classic in Settings › Appearance and setup, Glass tintable; ⌘N opens on the
current profile; usage stats now include changed settings (opt-in). Ray: item 14; Ray has one profile and no stats.

## v0.2.43-nightly.7 (2026-10-30)

No engine change. **App:** the sidebar player grows into full controls on hover; glass back on pinned tiles, the
address field, Downloads and onboarding; the divider under pinned tiles spaced evenly. Ray: player is MISSING Arc #8.

## v0.2.43-nightly.6 (2026-10-30)

No engine change (still engine-4d8c64033b08).

**App:** every surface on macOS 26 (pinned tiles, buttons, address field, command bar, hover cards, popovers,
Downloads, Peek, New Tab cards, onboarding) drops liquid glass for Dia's faint fills and one-pixel outlines
(`17b469a6`); PiP controls lose their glass plates; "Highlight pinned tabs in their icon's colors" is gone from
Settings (the selected Top App always gets the ring in its icon's colours, as Dia). Ray: item 12; Ray has no such
setting or ring (its favorites are tiles with no icon-colour ring: worth a look against Dia when tiles are next
touched).

## v0.2.43-nightly.5 (2026-10-29), engine-4d8c64033b08

**Engine** (tree `4d8c6403`, from `2f172eb5`; no Chromium bump, still 156.0.8078.47):
- **Security hardening:**
  - `chromium-os-crypt-decrypt-erase.patch` and `chromium-password-string-erase.patch` (new, in `series`):
    os_crypt's decrypt paths zero their plaintext temporaries before freeing them, and a `PasswordString` zeroes its
    password on destruction (`b0d62beb`, `f64e9bb6`). Defence in depth against secrets lingering in freed memory;
    Ray gets them through the rename map.
  - Private windows: the engine alone decides which calls serve an off-the-record profile (`de37bffe`,
    `0581835b`). One argument parser (`ardia::ArgsCall`, optional size cap for sensitive calls) refuses
    `offTheRecord` unless the call says `kAllow` (site settings, site data, zoom); every other call, including
    profile-less and sensitive ones that used to skip the flag, answers "no engine data for a private profile".
    `ac_extensions_watch_actions` is refused for private profiles again; sensitive calls reject a null or empty
    argument string instead of reading it as `{}`. Ray's app passes `offTheRecord` itself and checks in Host
    (`SiteControls`, `Downloads`, `SettingsDataRows`, …), so this moves the guard to where a missed Host check
    can't leak the regular profile's data into a private window. Worth taking for that alone.
  - Memory Saver's kept-active sites go only to regular profiles (not guest or system ones; `d7ca2394`).
- `ac_passwords_logins.cc` (new): reads every saved login for Ardia's sync, all or nothing. Ray has no sync; harmless.
- Refactor: `AC_PROFILE_CALL` / `AC_ARGS_CALL` preludes replace 25 inline ones; 15 headers that only declared
  exports are deleted; `ac_downloads_command {id, command}` replaces five `ac_downloads_<verb>` exports (Ray's
  `Downloads` calls cancel, keep, pause, remove and resume and must move to the new call); `ac_omnibox_opened` and
  `ac_tab_restore_load` removed (Ray calls neither); bookmarks and history watchers become profile state.
- ArdiaCore: page views get ArdiaCore's own delegate with typed scroll/overscroll acks (`ac_page_view.mm`, new),
  `ac_app_urls.mm` (new), page script loading in `ac_page_script.cc`; `ArdiaCore.h` changes by 34 lines: diff it
  against `RayCore.h` for renamed or removed delegate methods before building (Swift would only warn "nearly
  matches").
- PiP: glass tab and close buttons and a stash handle (`2f1743e3`, `ac_pip_mac.mm`), taken back out of the app's
  look in nightly.6.
- Ray's fixups: 0002 and 0004 touch `BUILD.gn`, `series` and raycore files this release rewrites; expect to
  rebase them.

**App:**
- Unified liquid glass with no outlines on macOS 26 (reverted in nightly.6).

**Fixes to shared behaviour:**
- Closing the last tab keeps the window while it has pinned tiles or a pinned group; a window with nothing pinned
  closes and asks first (`d8e1098b`). Ray: item 11.
- Switching update channel keeps the downloaded update; quit waits at most 8 s for it (`55a78c6c`, `7b2090f4`).
  Ray has no channels (one Sparkle feed); nothing to take.
- Sync, profile themes, split views, sidebar drag refactors: Ardia-only.

**Competitive:** Ardia is ahead on engine-side private-window gating and secret zeroing; Ray is ahead on staying
flat (Ardia spent two nightlies on glass) and on a native Settings window.

## v0.2.43-nightly.4 (2026-10-29), engine-2f172eb50b89

**Engine** (tree `2f172eb5`, from `d3393236`; no Chromium bump):
- `ac_memory_saver.cc` (new): Memory Saver state, mode (moderate / balanced / maximum) and kept-active sites
  (validated as URL filters, per profile, never off-the-record). `03-helium.py` drops the SKIP of Helium's
  `memory-saving-by-default.patch`, so Memory Saver is on by default. Ray's copy of that SKIP gives a reason that
  isn't true for Ray (no tab sleeping of its own); rename map carries the removal through cleanly.
- `chromium-component-extension-disk-messages.patch` (new, in `series` after
  `chromium-component-extension-restricted-urls`): a component extension loaded from disk gets its `chrome.i18n`
  messages. Matters for Ardia's own uBlock Origin; harmless for Ray, which loads no component extension of its own.
- `ac_external_apps.mm`: Open on an external-app prompt raised by the browser or an extension launches the app even
  when no page frame asked (Obsidian Web Clipper). Ray doesn't implement `externalAppRequest` yet (MISSING, Chrome
  #4), so this matters once it does. Also a test-only stand-in app.
- `pip/ac_pip_window.cc`: PiP reopened from the same tab comes back where it was left, on the same display; a saved
  frame on a display that's gone lands bottom-right of the main one. Ray shares it as-is.
- Ray's fixups: none touch these files. `BUILD.gn` and `series` gain lines away from 0002's and 0004's hunks.

**App** (Ardia's React Native, for Ray to copy or answer):
- Memory Saver replaces Ardia's own tab sleeping; Settings › Advanced › Performance has the switch, the three
  modes and "Always keep these sites active". Ray: item 3.
- Zoom note "Zoom: 110%" after ⌘+ ⌘− ⌘0. **Ray had it first** (`17dabae`, Arc's figure toast).
- Collapse a profile's pinned tabs. Ray: item 6, new gap.
- Peek for other sites' links from Top Apps and pinned tabs (opt-in). Ray: item 8.
- Bookmarks bar: drag and drop, folders, favicons, a Large size. Ray has no bookmarks bar (Arc has none; skip).
- Mute a single tab; Mute Site separate. Ray: item 5.

**Fixes to shared behaviour:**
- Locale follows the Mac's language (`b13d9f79`). Ray: item 4.
- Reserved shortcuts by Helium's set; a page gets every other key first (`dd242aac`). Ray already routes this way
  (`preHandleKeyEvent`); item 9 for the missing keys.
- Updates: Sparkle's staged copy stayed registered with Launch Services and showed in the default browser and Open
  With lists (`60ae7d11`, `5d200938`). Cause was Ardia's update prewarm *running* the staged copy; Sparkle's copy
  left alone isn't registered. Ray doesn't prewarm, so it shouldn't happen; worth a look after Ray's first Sparkle
  update now that Ray can be the default browser (`937b617`): System Settings' list should show one Ray.
- Settings window drag flicker; sync pairing. Ardia-only.

## v0.2.43-nightly.3 (2026-10-28), engine tree d33932365033 (no engine tag)

**Engine** (`d3393236`, from `31f64952`, published only as this release's asset): `ac_context_menu.mm` gains
`ArrangeLikeDia()`: removes "Open link as <profile>", puts Save Link As… before Copy Link Address, and shows Back and
Forward (greyed when unusable) whenever Reload is there. Ray's page menu is the engine's, so Ray gets Dia's order
with the sync. No conflict.

**App:** every right-click menu rebuilt in Dia's order (tab: Pin first, Close last); move several tabs or a group
to another profile or window; right-click Reload for the site's ad blocker and cookies; right-click a profile to edit
it; the sidebar menu on the New Tab row, top and footer. Ray's tab and sidebar menus should be checked against Dia's
order when Ray next touches them (Ardia's `sidebarMenu.ts` and `menus-test.mjs` list each). No profiles or groups in
Ray yet.

**Fixes:** a cancelled Save As left an empty download row (Ray: item 7); tab rows no longer bounce on press; menus
show SF Symbols on macOS 27; Clear Cookies and Site Data clears the site its confirmation named (Ardia's own panel;
Ray's Site controls take the tab's `committedOrigin`, so not affected).

## v0.2.43-nightly.2 (2026-10-28)

No engine change (tree `31f64952`). App only: ⌘W no longer flashes a blank page in release builds. Ardia's cause was
React committing the closing tab's unmount before the next tab's first frame; Ray has no React layer, but the same
Chrome behaviour (a page view leaving the window is hidden and drops its compositor frame) applies. Ray: item 10.

## v0.2.43-nightly.1 (2026-10-28)

Engine: engine-31f649524b11 (below). App:
- **Profiles as icons** in the sidebar switcher; **Little Ardia** gets back and forward. Ray has neither profiles
  nor Little Arc (MISSING, Arc #2 and #4).
- **Compact toolbar** (28 pt instead of 41) so a 16:9 video in web full screen fills a maximized window. Ray's
  `PageToolbar` is 41 pt only. Small new gap.
- **Clean up old tabs after any time**: Ray keeps Arc's 12 h on purpose (owner 2026-10-29). Skip.
- **Export bookmarks**, **drop a .crx**, **Allow User Scripts**: engine calls arrive with the sync (item 2); Ray
  needs the UI (bookmarks export in the command bar and File menu; user scripts in the Extensions screen,
  "From Ardia's settings" #6).
- **⌘-scroll goes to the page first**, with a switch to turn Ardia's ⌘-scroll zoom off. Ray has no ⌘-scroll zoom of
  its own, so the page already gets it, as in Chrome. Nothing to do.
- Calendar countdown timing. Ray has no Live Calendar (gap "From Ardia's settings" #3).
- Fixed: no blank frame on tab switch (Ray: item 10); Sign in with Google popups blank (Ardia's origin strip
  drawing over the page; Ray has no such strip); a Downloads panel crash (React Native animation); tabs sleep after
  4 h instead of 20 min (Ray never had Ardia's sleep); one-row sidebar player; Gmail's dark toolbar; middle-click
  closes tabs on top; Tencent Video through WebKit (Ray: no WebKit, decided).

## engine-31f649524b11 (2026-10-28)

Tree `31f64952` from v0.2.42's `529394c5`. No Chromium bump, no security fix, no change to `patches/`.
- `ac_extension_drop.mm` (new): a .crx dropped on a tab's page installs through Chrome's `CrxInstaller` with the
  normal install prompt (so Ray's `Extensions` prompt: deny by default, 0.5 s guard). Not in private windows or
  when policy blocklists by default. Off-store installs are allowed as from chrome://extensions. A page can't fake a
  native file drop, so this is user-only. New delegate `engine:extensionInstallFailed:tab:` (optional: an unhandled
  error is silent).
- `PageChannel::GrantUserActivation` / `-[tab grantUserActivationToFrame:]` (new): the host grants a frame a user
  activation (Ardia uses it to resume a slept tab's media from the sidebar player). **Security:** if Ray ever uses
  it, call it only from a real user action in Ray's UI, never from a page message, or a page gets popups and
  autoplay without a gesture.
- `ac_bookmarks_export_html` (new): writes Chrome's bookmarks HTML to an absolute path.
- `ac_extensions`: `userScriptsAvailable` / `userScripts` in the list, `userScripts` in `ac_extensions_configure`
  (Chrome's per-extension "Allow User Scripts", needed by Tampermonkey and other userscript managers on MV3).
- Ray's fixups: no overlap (`BUILD.gn` in `raycore` isn't touched by `engine-ray/`).

## Competitive notes

**Where Ardia is ahead of Ray (2026-10-29):**
- Signed with Developer ID and notarized: download, drag, open. Ray is self-signed; friends need Open Anyway.
- Profiles, Spaces-like groups, split view, Little Ardia, Peek, sync between Macs, Live Folders and Calendar, a
  bookmarks bar, per-tab and per-site mute with a sidebar player, Memory Saver settings, a search engine choice,
  native data screens and an Extensions screen, 28 pt toolbar, localized engine.
- Ships a nightly a day with a filmed before-and-after for every fix.

**Where Ray is ahead:**
- Native AppKit + Core Animation all the way: no React Native bridge. Two of Ardia's nightly.1/.2 fixes (⌘W blank
  frame from React's commit timing, a Downloads panel animation crash) are bugs Ray's architecture can't have.
- Smaller surface: no WebKit tabs, no `ardia` CLI control server (`chromium-devtools-control-token` dropped), no
  sync service.
- Arc's zoom figure note shipped a day before Ardia's; the command bar ranks pages like Arc's; reopen closed tab
  back in its sidebar place.
- Arc-first onboarding and import from nine browsers through Ardia's own import core.
