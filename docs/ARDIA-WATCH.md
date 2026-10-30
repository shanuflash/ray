# Ardia watch

What Ardia (github.com/mantrakp04/ardia, Ray's upstream) ships after the source Ray's engine came from
(`engine.lock`'s `ardia_tag`), and what Ray should take, copy or answer. Newest release first. A daily task
re-checks Ardia's releases against the line below: keep it accurate.

Last reviewed: v0.2.43-nightly.6 (engine-4d8c64033b08), 2026-10-30

Ray's engine: Ardia v0.2.42's `engine/` (tree `529394c5`), Chromium 156.0.8078.47. Chrome stable for Mac on
chromiumdash, checked 2026-10-29: 156.0.8078.74 / .75 and 157.0.8103.26. None of the releases below bumps
Chromium, so Ardia is on .47 too. Chrome's own security releases are tracked in `docs/CHROMIUM-WATCH.md`.

## Ray should

In priority order. Nothing here is started; engine items cost one engine rebuild (the owner's call).

1. **Plan the next engine rebuild around a Chromium bump.** Ray is about 28 patch builds behind Chrome stable on
   156 (.47 against .75), and 157 is out; Chrome's stable security fixes land in those builds. Ardia hasn't bumped
   either. Ray's Chromium is pinned to Helium's (`engine/patches/build/helium-pins.ini`), and Helium 0.20.2.1
   (helium-macos, 2026-10-28) is on 156.0.8078.73: bump the pins to it ourselves (PLAN.md section 6: "every 4
   weeks") and take Ardia's engine changes below (now engine-4d8c64033b08) in the same rebuild.
2. **Take engine-4d8c64033b08** (it includes engine-2f172eb50b89) through `sync-engine.sh`, then
   re-check `engine-ray/`'s fixups against the reorganised `ac_*.cc` files (4d8c64 rewrites every call's prelude
   and drops 15 export headers; see its section), then
   implement the one new delegate method, `engine:extensionInstallFailed:tab:` (renamed to `RayCoreEngine`), or a
   failed .crx drop says nothing. Brings: install by dropping a .crx, bookmarks export (`ac_bookmarks_export_html`),
   the "Allow User Scripts" switch (`ac_extensions_configure` `userScripts`), Memory Saver calls
   (`ac_memory_saver`), extension i18n for component extensions, Picture in Picture reopening where it was left,
   links an extension opens in another app (Obsidian Web Clipper), and Dia's page menu order.
3. **Decide Memory Saver.** Ray has no tab sleeping of its own: Ardia's 20-minute sleep lived in Ardia's app, which
   Ray never copied. But Ray's engine still skips Helium's `memory-saving-by-default.patch` with the reason "would
   fight Ray's own tab sleeping", so Memory Saver is off unless the user turns it on in chrome://settings/performance
   (which Ray's trim keeps). Ardia now does what Helium does: Memory Saver on by default, Moderate / Balanced /
   Maximum, "Always keep these sites active". Taking item 2 turns it on by default; the Settings revamp (PLAN.md
   section 13) should give it rows through `ac_memory_saver`.
4. **Follow the Mac's language.** Ardia found Chrome took its UI locale from the app bundle's localizations; with
   none declared, the engine ran in en-US and every extension saw `en` (uBlock Origin's text was blank). Ray's
   Info.plist (written by `scripts/build-app.sh`) declares no `CFBundleLocalizations` either, so Ray very likely has
   the same bug (not tried). Fix is app-side, no engine: declare Chromium's 55 desktop locales (Helium's list) and
   keep their `locale.pak`s (Ray already copies every `*.lproj/locale.pak`). Ray's own UI stays English.
5. **Per-tab mute and a sound icon** (MISSING, Arc #8 and Chrome #12). Copy Ardia's corrected model, not its first
   one: the speaker and Mute Tab mute that tab only (Chrome's per-tab mute, kept across navigation and relaunch);
   Mute Site is its own choice behind ⌥ and in Site controls.
6. **Collapse the pinned section** (new gap): a "Pinned" toggle on the divider above Today; collapsed, only the
   entry holding the active tab shows. Ardia's top-asked issue (#521).
7. **Downloads: a cancelled Save As row.** Ardia listed Chrome's download item before the save panel had a path, so
   cancelling left a nameless "Cancelled" row. Ray's `Downloads` lists every item with no path check: likely the same
   (not tried). Fix: list a download once it has a path; drop one cancelled before it had one.
8. **Peek decision input** (PLAN.md open decision): Ardia now opens other sites' links from Top Apps and pinned tabs
   in Peek, as Arc does, behind a Settings › Tabs › Links switch (off by default). Ardia keeps Peek on the
   `chromium-temporary-tab-restore-hook` patch Ray dropped.
9. **Reserved keys:** Ardia now reserves Helium's set, by menu command: Ray's (`Shortcuts.isReserved`) lacks
   Developer Tools (⌥⌘I), Toggle Developer Tools (F12) and Search Tabs (⇧⌘A). ⇧⌘C stays Ray's setting. Small.
10. **Tab-switch blank frame** (another chat is on it): Ardia's fix keeps the outgoing page up until the incoming
    page's render widget shows new content (at most 250 ms), and on ⌘W hands the closing tab's page view to the one
    replacing it so Chrome never hides it before the next tab draws (`ArdiaWebView+Painting.mm`,
    `ArdiaWebView+StandIn.mm`, commits `d18f3414`, `277c8256`). Measured: 0 blank frames in 1,730.
11. **Closing the last tab keeps the window while anything is pinned** (Ardia 0.2.43-nightly.5, `d8e1098b`, as
    Arc): unloaded pinned tiles counted as "asleep" made ⌘W on the last Today tab close the whole window. Ray's
    `close-last-window` covers closing the window, not ⌘W on the last tab: try it by hand with only pinned tabs
    and favorites left (MISSING known limitation 28).
12. **Look:** Ardia tried one liquid glass everywhere (nightly.5) and backed out a day later to Dia's flat fills and
    one-pixel outlines on macOS 26 (nightly.6, "measured against Dia itself"). Ray is already flat AppKit and avoids
    popovers; keep it that way, no glass.

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
