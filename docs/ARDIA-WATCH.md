# Ardia watch

What Ardia (github.com/mantrakp04/ardia, Ray's upstream) ships after the source Ray's engine came from
(`engine.lock`'s `ardia_tag`), and what Ray should take, copy or answer. Newest release first. A daily task
re-checks Ardia's releases against the line below: keep it accurate.

Last reviewed: v0.2.47-nightly.4 (engine-3a64a10704ff), 2026-11-16

Ray's engine: Ardia v0.2.42's `engine/` (tree `529394c5`), Chromium 156.0.8078.47. Chrome stable for Mac
(`docs/CHROMIUM-WATCH.md`, 2026-11-05): 157.0.8103.39, 158 in early stable. Ardia moved to 156.0.8078.79 on Helium
0.20.3 in engine-1982453a46fe (v0.2.43), then to 157.0.8103.38 on Helium 0.21.1 / helium-macos 0.21.1.1 in
engine-44666813bf29 (stable v0.2.45, engine-bc84a70be65a), then to 157.0.8103.50 on Helium 0.21.2 / helium-macos
0.21.2.1 in engine-6fa48cb43cec (stable v0.2.46, engine-1c2355ca844e). Chrome stable is now 157.0.8103.78/.79
(2026-11-11, 83 security fixes), which Ardia hasn't taken yet (engine-ee28c4b3a7d9, v0.2.47-nightly.1, is still
157.0.8103.50; so is the Mac engine of v0.2.47-nightly.4, engine-3a64a10704ff, 2026-11-15). Chrome's own security
releases are tracked in
`docs/CHROMIUM-WATCH.md`.

## Ray should

In priority order. Nothing here is started; engine items cost one engine rebuild (the owner's call).

1. **Rebuild the engine on M157 by taking Ardia's engine-1c2355ca844e** (v0.2.46 stable: Chromium 157.0.8103.50,
   Helium 0.21.2, helium-macos 0.21.2.1; all 354 Helium patches apply with no fuzz). Even .50 lacks Chrome
   157.0.8103.78/.79's 83 security fixes (5 Critical): take Helium's next tag if it lands first, or bump
   `helium-pins.ini` to .79 ourselves. v0.2.46 adds to the list below: extensions kept when the Safe Storage key
   changes (item 1d), the upscaler crash fix (1e), a page drag that always ends (`chromium-drag-always-ends.patch`:
   a lost drag end left a page deaf to clicks and keys), Memory Saver sleeping pinned tabs on its timer, and
   `ac_search_suggest.cc`. Was: engine-bc84a70be65a (v0.2.45 stable). Ray is on 156.0.8078.47: it misses M156's fixes through .88 and all
   213 of M157's (7 Critical). helium-macos 0.21.1.1 now exists, so M157 is buildable; Ardia did the work
   (`f8aaa24c`: fourteen patches refreshed, Settings' privacy page is Lit now, 157's CHECKs at two hook sites,
   `//chrome/browser/ui:ui` gone, `ChromeMainDelegate` crash keys moved). Its range from Ray's v0.2.42 adds
   everything listed under the older engines below (38b319ab, 2da3ca19, b2c15dac, 7ad5405d, 1982453a, 4d8c6403,
   2f172eb5) plus v0.2.45's: the display-capture click rule (item 1a), glic off (1b), Widevine answering as
   supported (Apple Store checkout), same-site swaps that keep the old frame, PiP that ignores a page's
   `disablePictureInPicture`, a capture wake lock only while awake, no crash on `chrome.action.openPopup()` or a
   badge change in a tabless window, on Cast remoting without a BrowserView or a tab moved into a closing window,
   the startup TPM benchmark off, and (engine-054c7f68) a Web Store install that goes on when the listing's icon
   can't be fetched (MISSING 55). Through `sync-engine.sh`, then re-check `engine-ray/`'s fixups against the
   reorganised `ac_*.cc` files (4d8c64) and M157's rewrites, move `Downloads` to `ac_downloads_command`, and diff
   `ArdiaCore.h` against `RayCore.h`: delegate methods `engine:extensionInstallFailed:tab:`,
   `tab:shareFromContextMenu:`, `windowCanTakeTabs:`; `adoptTab:` now returns refused/adopted/busy (and
   `canAdoptTab:`); `ArdiaCoreEngine.pagesPickDisplayMedia` (on by default). Xcode 27.2 needs the Metal Toolchain
   once. One rebuild, the owner's call (on hold since 2026-11-05).
1a. **No page opens Chrome's screen-share picker without a click** (security, new, MISSING 41; not tried). Ardia
   `b18165de`/`38096782`: a page calling `getDisplayMedia` during load, or from a same-origin about:blank iframe,
   reached Chrome's own picker with no click; its live ScreenCaptureKit thumbnails set off a steady stream of
   screen-capture permission checks (replayd, tccd) that froze the owner's mouse and keyboard. Ray implements no
   picker (MISSING Chrome 6) and its page script shims nothing, so any page can open Chrome's picker unasked.
   Engine fix: refuse native display capture in the web contents delegate unless the host's picker asked (comes with
   item 1, or as an `engine-ray` fixup). Ray then needs its own picker (Chrome 6) behind a click.
1b. **Turn glic (Gemini in Chrome) off** (new, engine, small, MISSING 43). Helium leaves `kGlic` on, so every tab gets glic's
   TabFeatures; Ardia's #954 crashed in `SelectionOverlayController`'s destructor. Ardia `0365b06a` merges Glic,
   GlicActor, GlicActorUi, ApiGlicPrivate, ContextualCueing and GlicZeroStateSuggestions into `--disable-features`.
   Ray's `ac_main_delegate.cc` has no such line: comes with item 1, or an `engine-ray` fixup on its own.
1c. **Closing a window waits 4 s before its tabs go** (new, engine, one-line fixup, MISSING 52; not tried in Ray).
   Ardia `cba28a9c`: `CloseContents` in `ac_web_contents_delegate.mm` dropped a page's unload-done reply while
   Chrome was closing the window, so the close sat on two 2 s fallback timers: tabs freed 4 s late and saved as lone
   closed tabs, so a reopen right after came back without Back/Forward, and a private session outlived its window
   by 4 s. Ray's `engine/raycore/src/ray/core/ac_web_contents_delegate.mm:192` has the identical code. Fix: when
   `CanCloseContents` is false, call `BrowserWebContentsDelegate::CloseContents(source)` before returning. Take it
   as an `engine-ray` fixup with item 1 (or alone at the next rebuild); matters most for private windows.
   Ardia 0.2.46's notes confirm the result: a closed window now goes at once and ⇧⌘T brings its tabs back with Back.
1d. **Check that Ray 0.1 profiles kept their extensions** (new, engine, MISSING 59; not tried, may already bite).
   Ardia `004fcffc` (its FB-5GA3): tracked prefs (each extension's `extensions.settings` entry, developer mode) carry a
   hash encrypted with the Safe Storage key; after a key change every check fails and Chrome silently removes all
   extensions. Ray's `SafeStorage` move from the mock keychain's key to "Ray Safe Storage" is such a change. First
   test a 0.1-era data dir with an extension through the move; if it loses it, take
   `chromium-pref-hash-safe-storage-key-change.patch` (HMAC fallback, re-hash under the current key) as an
   `engine-ray` patch at the next rebuild, ahead of item 1 if need be.
1e. **Video upscaler leak crash** (new, engine, MISSING 60). Ray's engine has Ardia's upscaler, on by default; the
   synchronous VideoToolbox call leaked a pooled object per frame and the GPU process died after ~36 min at 30 fps.
   Ardia `0998bfa6` rewrites `ac_video_upscaler_job.mm` on the async call. Comes with item 1; until then, consider
   `RayCoreEngine.setVideoUpscaling(false)` if long-video crashes show up.
2. ~~**Command bar: arrowing shows the row in the field**~~ (Done 2026-11-10, MISSING known limitation 42). Ardia 0.2.45 (PR #782):
   a search row puts its query in the field, a page row its address, Escape brings back what you typed, as Chrome and
   Dia do. Ray's `CommandBarView.moveSelection` only moves the highlight. App-side, small; mind the inline host
   completion (`complete`) and the scope chip.
3. **Decide Memory Saver.** Ray has no tab sleeping of its own: Ardia's 20-minute sleep lived in Ardia's app, which
   Ray never copied. But Ray's engine still skips Helium's `memory-saving-by-default.patch` with the reason "would
   fight Ray's own tab sleeping", so Memory Saver is off unless the user turns it on in chrome://settings/performance
   (which Ray's trim keeps). Ardia 0.2.43 (stable) ships Helium's way: on by default, Moderate / Balanced /
   Maximum, "Always keep these sites active", pinned and current tabs never sleep. Taking item 1 turns it on by
   default; Settings should give it rows through `ac_memory_saver` (MISSING, Ardia settings 15). Ardia
   0.2.47-nightly.4 (`2d64f525`) adds a budget on top: past about one loaded tab per GB (Balanced, at least 10) the
   tabs hidden longest sleep after an hour, since Chrome's own 2–6 h timer let almost none sleep.
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
8a. **macOS 27: the green button's Move & Resize / Fill & Arrange may crash Ray** (new, MISSING 39; not tried).
   Ardia 0.2.44 (`9e5b115b`): on macOS 27 a submenu's parent item still targets NSMenu with `submenuAction:`,
   which NSMenu no longer implements, so choosing either threw. Fix is app-side, five lines: at launch, if
   `NSMenu.instancesRespond(to: "submenuAction:")` is false, `class_addMethod` an empty one. The owner is on macOS 27:
   try it in Ray first, it's cheap.
9. **Peek decision input** (PLAN.md open decision): Ardia's stable 0.2.43 opens other sites' links from Top Apps
   and pinned tabs in Peek, as Arc does, behind Settings › Tabs › Links. Since 0.2.46-nightly.5 it's on by default
   for new profiles (other sites' links and new-tab links open in a Peek, as in Arc).
10. **Reserved keys:** Ardia's stable now reserves Helium's set by menu command; Ray's (`Shortcuts.isReserved`)
    lacks Developer Tools (⌥⌘I), Toggle Developer Tools (F12) and Search Tabs (⇧⌘A). Small.
11. **Tab-switch blank frame** (another chat is on it): Ardia 0.2.43 ships its fix: the outgoing page stays up until
    the incoming page's render widget shows new content (≤ 250 ms), and ⌘W hands the closing tab's page view to the
    one replacing it (`d18f3414`, `277c8256`).
12. **Closing the last tab keeps the window while anything is pinned** (Ardia 0.2.43, as Arc). Try by hand in Ray
    with only pinned tabs and favorites left (MISSING known limitation 28).
13. **Share from the page menu** (new, MISSING Chrome gap): Share… for selected text, an image, a link with
    trackers removed, a video/audio source or the page, through macOS's share sheet; File › Share › Share… on ⌥⌘S.
    Engine part comes with item 1; Ray then implements `tab:shareFromContextMenu:` with `NSSharingServicePicker`.
14. **Look:** Ardia went flat, then back to glass, and v0.2.43 ships a Glass / Classic choice (Glass on pinned
    tiles, address field, buttons, Downloads and site controls, tintable). Ray's Panels and notes setting already
    offers Glass / Solid on its surfaces; nothing to take beyond watching what users pick.
15. **Sidebar on the right** (MISSING, Arc #15): shipped in Ardia 0.2.44-nightly.4–6. Its commits list every
    place a left edge was assumed (`4844d5a1`), then the traffic lights riding the sidebar (`1544dabc`; Ray draws
    its own in the sidebar, so they come along) and a right-hand peek that stays open under the pointer
    (`d47b7dee`). Use them as Ray's checklist when this is built.
16. **Back and Forward history lists** (new, MISSING Chrome gap): Ray's back/forward buttons have no list at all
    (no hold or right-click menu, no two-finger swipe-and-hold). Ardia 0.2.44-nightly.6 copies Dia's swipe-and-hold
    list (opens upward from the swipe, nearest page at the bottom under the fingers, 38 pt rows, the list slides per
    step; `a97d6db7`). Ray's engine already exports `navigationEntries`; start with Chrome's hold-Back menu as a
    `Panels` panel, then the swipe.
17. **Unread counts on tabs** (new, MISSING Arc 18). Ardia 0.2.45 shows a web app's unread count on pinned
    tabs, tiles and rows, from the page title ("(3) Inbox"), the Badging API or a favicon dot. Ray could start with
    the title count (app-side, pinned tabs and favorites first); the Badging API needs an engine hook.
18. **Keep the window when the last one closes** is already Ray's way (the normal window keeps its tabs for ⌘N);
    Ardia 0.2.45 only now matches Arc there. Nothing to take; the pinned-only ⌘W case (item 12) is still untried.
19. **Decide Ardia's frame-rate patches** (new, engine, the owner's call at the next rebuild). Ardia `0f289583`
    dropped four of its own engine patches "per the Helium-base decision": begin-frame warm-up (never switched on),
    main-frame throttle after show and full rate on input (`ThrottleMainFrameTo60Hz`, `UrgentMainFrameForInput`)
    and battery-saver full rate on input, plus the 600 s unfreeze interval; it keeps only "a tab with a live
    connection is never frozen" (`chromium-freeze-spares-live-connections.patch`, was `thaw-live-connections`).
    Ray's `engine/patches/` still carries all five from v0.2.42. Taking item 1 drops them with Ardia; Ardia ran no
    timing runs, so measure scrolling and typing latency before and after on Ray.
20. **Sidebar divider spacing** (small, look). Ardia `5fe71832` makes the divider under the pinned section Dia's
    14 pt band (1 pt line 6.5 pt from each neighbour; was 30 pt edge to edge). Compare Ray's divider against the
    owner's Arc captures before changing anything (Ray matches Arc, not Dia).

21. ~~**Auto PiP when switching apps**~~ (withdrawn 2026-11-13, MISSING 53). Ardia reverted nightly.5's latch in
    `2acfd1df` (its #1236: a video popped out while the user watched it beside another app or on a second display);
    0.2.46 pops out only when the window is out of sight, which is Ray's `// MARK: Window sight` already. Nothing to do.
22. **Extensions in private windows** (new, MISSING 54; not tried). Ardia `df9b9c0e`: its private window listed
    only `"incognito": "split"` extensions, so ordinary spanning ones allowed in Incognito never showed; their popups
    run fine as Chrome's ExtensionViewHost, and Options opens in the normal window. Ray's tiles come from
    `ac_extensions_list` on the private profile: check a spanning extension allowed in Incognito shows a tile and its
    popup opens in a private window. Ardia 0.2.46 ships the fix (with @FedyaLight's PR #1144).
23. **Switch tabs on mouse down** (new, app-side, small, MISSING 61). Ardia 0.2.46 (as Chrome, Safari and Arc):
    about 0.1 s off every click switch; drags, ⌘-click and ⇧-click unchanged. Ray's `SidebarView.pointer` switches in
    `drop` at the release. Switch at `.leftMouseDown` for a plain click on an unselected tab; keep the release for
    multi-select's pending clear and for folders; extend `multi-select` and `switch-no-blank`.
24. **A loading tab's address isn't about:blank** (check, small). Ardia `0f04b997`: a tab opened from a link or
    another app showed and copied about:blank a second into a slow first load. Ray's `showPendingAddress` covers the
    address field (`pending-address`); check ⇧⌘C and the row's tooltip on such a tab (`appopen link` to a slow page).
25. **⌃Tab skips tabs never looked at** (check, small). Ardia 0.2.46: a background-opened tab joins the recent order
    only once shown. Check Ray's `recentOrder` after a ⌘-click link (likely already right: it orders by activation).
26. **Closing a tab goes back to the tab used before it** (new, app-side, small, MISSING 63). Ardia
    0.2.47-nightly.1 (PR #416, `024afbee`, "as in Arc"): the most recently used tab, not a neighbour; a sleeping tab
    isn't woken while an awake one is left (`83df00c3`); the tab a close shows counts as used (`69206f36`). Ray's
    `window(_:didRemove:)` calls `activateNeighbor`; `lastActive` (the ⌃Tab order) is already there to pick from.
    Confirm against the owner's Arc first (Chrome goes to the opener or a neighbour).
27. **Back on a tab a link opened closes it** (new, app-side, small, MISSING 64). Ardia 0.2.47-nightly.1 (PR #1401,
    `47f41df9`, `state/tabs/navigation.ts`): Back with no history on a tab a link opened closes it and returns to
    its opener; the swipe shows it too. Ray's back button is just disabled there. Check Arc before building.
28. **Keep history past 90 days** (new, app-side, one argument, MISSING 66). Ardia `8e47868d`: Chromium expires
    visits after 90 days, so an imported Arc history loses its old pages on the next expiry pass. Helium's
    `keep-old-history` switch is in Ray's engine already; append `--keep-old-history` in `main.swift`. Do it before
    the Arc shutdown wave of imports.
29. **Pages blank under a same-size window** (new, app-side, one argument, MISSING 65; not reproduced in Ray). Ardia
    `fcbf63f61`: Chrome's own occlusion guess pauses every page of a window that another browser window of the same
    size covers, and nothing corrects it. Ardia passes bare `MacOcclusionForceShutoff`, which in Chromium 156's
    `web_contents_occlusion_checker_mac.mm` is a no-op (`ShutoffType` defaults to `kNoShutoff`); Ray should pass
    `MacOcclusionForceShutoff:ShutoffType/1` (macOS 26+) after reproducing it with two same-size windows.
30. **The page keeps the keyboard after the command bar closes** (check, small). Ardia `82847d45` (#1894): after
    the bar closed by a click elsewhere, or a tab switch with the bar open, Space and the arrows reached nothing.
    Check both in Ray (`type`, `escape`, a click outside, then a key to the page through DevTools).

## v0.2.47-nightly.2 to .4 (2026-11-14 to 11-15), engine ee28c4b3 → 3a64a107; Windows alpha

Range `v0.2.47-nightly.1..v0.2.47-nightly.4`: 1,571 commits (584 engine files, +96,760), most of them Linux
(nightly.3, x86-64, Wayland/X11, `.deb`/AppImage) and Windows (installers for x64 and Arm, `windows-alpha` release,
its own `scripts/windows/engine/helium-pins.ini` on 157.0.8103.38). The nine `engine-*` tags of 2026-11-15 are Linux
x64 prebuilts. nightly.3 was Linux and Windows only; nightly.4 is the Mac's first since nightly.2. Release notes now
link github.com/ardia-browser/ardia (the repo moved; `mantrakp04/ardia` still resolves).

**Engine:**
- Mac Chromium unchanged: 157.0.8103.50, Helium 0.21.2 / helium-macos 0.21.2.1. Still without Chrome stable's
  157.0.8103.78/.79 (83 security fixes, 5 Critical). Nothing security-related in the Mac engine this range.
- `engine/patches/series` marks every Mac-only patch `mac` (and the ArdiaCore layer); `helium-linux` 0.21.2.1 is
  pinned. No Mac patch added or dropped.
- ArdiaCore: idle profiles can unload (`ardiacore_engine_idle_profiles.mm`, `sleepIdleProfile:hostedTabs:`,
  `unloadIdleProfile:`), tabs get `sleepIfHiddenFor:` and `unloadKeepingHistory` (the Memory Saver budget,
  `2d64f525`); `ac_main_delegate.cc` adds `keep-old-history` (item 28); Google Meet auto PiP on leaving its tab
  (`ac_host_visibility.mm`, `6b1298ca`). For item 1's `RayCore.h` diff: those three API additions.
- App-side launch flag: `MacOcclusionForceShutoff` (item 29; as passed, a no-op in Chromium's code we read).

**App features Ray lacks:**
- Air Traffic Control per profile (MISSING Arc 12), Interface Size, Minimalism mode, Reading mode, Hide Element,
  autoplay and notification blocking everywhere, pop-ups as tabs, a chosen new-tab address (MISSING Ardia settings
  17–19); custom uBlock filter lists (Ray has no content blocker: open decision); themes that restyle fonts and
  layout; unloading idle profiles (Ray has one profile); FairPlay Spotify in Chromium (Ardia's way around its
  WebKit fallback; Ray has neither, not tried how Spotify plays in Ray).
- Peek kept across a tab switch, PiP ±10 s clicks, a loading pill, tabs-on-top polish, the `ardia` CLI: features
  Ray hasn't built or left out.
- The command bar runs Arc's menu commands (Inspect Elements, Task Manager, Manage Extensions): Ray's `BarActions`
  has done this since the bar landed.

**Fixes to behaviour Ray shares:**
- Pages blank under a same-size window (item 29, MISSING 65); history past 90 days (item 28, MISSING 66); the page
  losing the keyboard after the command bar (item 30).
- Pages stay put while Chrome's screen-sharing bar slides (`c8e37b8b`): Ray hides Chrome's bar (`ChromeShareBar`)
  for 4 s after a share starts; check the page doesn't move when it comes back. The sidebar marks the shared tab:
  Ray's share marks do.
- Downloads panel: a new download opens it, a click outside reaches the page. Ray's downloads are notes plus a
  panel on request; nothing to take.
- A `javascript:` bookmark runs in the page: Ray greys bookmarklets on purpose (`Bookmark.opens`, security rule).
- A link no app opens no longer asks: Ray shows only a note already.
- ⌥⌘I closes DevTools on a second press; ⌘W on an empty window closes without asking; shortcuts may use arrows,
  Home/End and F-keys (Ray's Settings › Shortcuts takes F-keys; arrows not tried).
- Small windows (500 pt wide, the sidebar narrows): Ray keeps 400 pt for the page and lowers the sidebar's maximum.

**Competitive notes:** Ardia is now on Mac, Linux and Windows, with a Windows engine a Chromium step behind its
Mac one. Ardia ahead: Air Traffic Control, reading mode, interface size, Memory Saver's budget, kept imported
history. Ray ahead: an occlusion fix that would actually turn Chrome's guess off (if item 29 lands), bookmarklets
refused rather than run, ⌃Tab pictures and the command bar's menu commands already shipped. The engine gap
(item 1) is unchanged; neither browser has Chrome's 157.0.8103.79 fixes.

## v0.2.47-nightly.1 (2026-11-13), engine 1c2355ca → ee28c4b3

Range `v0.2.46..v0.2.47-nightly.1`: 73 commits. Most of the diff (594 files, +74,746) is a new Android app
(`d46f2bbc`, `docs/android.md`) and iPhone bottom-bar work; the Mac app and engine are +4,397/−1,113 in 181 files.

**Engine:**
- Chromium unchanged: 157.0.8103.50, no file under `engine/patches/` touched. Nothing security-related. Chrome
  stable's 157.0.8103.78/.79 (83 security fixes, 5 Critical) is still missing from Ardia and Ray.
- Engine diff is +183/−198 in 16 files, all for `ardia browse set viewport` (the CLI): windows can be marked
  `automation` (`ArdiaCoreWindow.automation`; their tabs can't be adopted and skip tab restore, `ac_seams.mm`),
  and `ac_cli_owned_tabs.cc` / `ac_cli_token_policy*.cc`. Ray has no CLI; nothing to take.
- API change to note for item 1's `RayCore.h` diff: `noteInShownSlot` returns void now and `whenSizeRestored:` is
  gone (`ac_host_visibility.mm` lost its size-restore wait). Ray's v0.2.42 engine has neither; nothing breaks.

**App features Ray lacks:**
- Closing a tab goes back to the tab used before it (item 26, MISSING 63).
- Back on a link-opened tab closes it (item 27, MISSING 64).
- ⌘T then Return goes back to the most recent tab, and ↓ ↑ over tab rows don't fill the field (PR #1355). Ray's bar
  never offers the active tab and fills the field while arrowing, as Chrome does (the owner's `bar-arrow-fill`): no
  change unless Arc's recording says otherwise.
- "Put links from other apps first" (Settings › Tabs, PR #803): such links open just below the pinned tabs. Ray
  opens them as Today tabs per `newTabNextToActive`; a possible setting once Little Arc (MISSING Arc 4) is decided.
- Tidy leaves pins alone, the clean-up suggestion's Don't show again and Undo, Live folders hiding a pull request:
  Ray has neither Tidy nor Live Folders (MISSING, Ardia settings 1). Little Ardia swipe-back and Esc: Little Arc
  isn't built.
- Android and iPhone apps: out of Ray's scope (Mac only).

**Fixes to behaviour Ray shares:**
- ⌘S hides the sidebar in its own window only (`0dc0bd59`, as Dia): Ray's `state.sidebarHidden` is already per
  window. Nothing to do.
- ⌘Y focuses History's search field: Ray's ⌘Y opens Chrome's history page, which focuses its own field.
- Delete on an inline completion keeps the caret after what was typed (`c82c43d3`): check Ray's
  `CommandBarView.complete` by hand (not tried).
- Tabs a page opened without a click paint 200 ms sooner (`e84c779c`): Ardia's own link-tab wait, which Ray
  doesn't have.
- The back and forward buttons crossfade as history changes, a rename field lined up with its row: look only;
  Ray's rename field already sits on the row's baseline.

**Competitive notes:** Ardia's ⌃Tab now shows page pictures in a row with sleeping tabs left out (PR #1486): what
Ray's `TabSwitcher` has done since 2026-11-04. Ardia ahead: close-goes-back, Back closing a link's tab, and now an
Android app beside the iPhone one. Ray ahead: nothing new; the engine gap (item 1) is unchanged.

## v0.2.46 (2026-11-13), nightly.6 and .7, engine 054c7f68 → 1c2355ca

Range `v0.2.46-nightly.5..v0.2.46`: 201 commits; engines 933c196a (nightly.6), f1e7a822 (nightly.7), 6fa48cb4,
72ea0e84, 1c2355ca (stable). Engine diff: +2,104/−125 in 33 files, four new patches.

**Engine:**
- Chromium 157.0.8103.38 → 157.0.8103.50 on Helium 0.21.2 / helium-macos 0.21.2.1 (`7839a9ae`). A patch release;
  Helium added two local omnibox prefs (history and bookmark suggestions) and their Settings section, which Ray's
  `tools/trim-settings-pak.py` may need to account for at the bump. Chrome stable is 157.0.8103.78/.79 (83 security
  fixes, 5 Critical, 2026-11-11): neither Ardia nor Ray has them. Ray is still on 156.0.8078.47.
- `chromium-pref-hash-safe-storage-key-change.patch` (`004fcffc`): extensions kept across a Safe Storage key change
  (item 1d, MISSING 59). Security-neutral: an encrypted hash that fails falls back to the HMAC Chrome already trusts;
  `kDisallowLegacyPrefMacFallback` still disables it.
- `chromium-drag-always-ends.patch` (`268de16f` and a dozen follow-ups): a page-started drag that never got its end
  (mostly Ardia's CLI over DevTools `Input.dispatchDragEvent`) left the page ignoring clicks and keys; now every drag
  ends, late DevTools replies can't crash. Mostly matters to automation; Ray gets it with item 1.
- `chromium-memory-saver-pinned-tabs.patch` (`48504051`): Memory Saver's timer sleeps Chrome pinned tabs like any
  tab (whether Ray's pinned rows and favorites are Chrome pinned tabs is unchecked); only urgent discards spared them before. Weigh with
  item 3: Arc never sleeps favorites' state away visibly; Ray's unloaded rows already fade.
- `ac_video_upscaler_job.mm` async VideoToolbox (`0998bfa6`): item 1e, MISSING 60.
- `ac_search_suggest.cc` (`7c854a06`): suggestions fetched by Chromium, none in private windows (MISSING 62).
- `ac_host_visibility.mm` grows window-server occlusion checks (`a8646275`, `45a67052`) for Auto PiP; Ray's
  window sight already reads `occlusionState`.
- `chromium-device-emulation-size-reset.patch`, `ac_cli_*`: Ardia's `ardia browse` CLI only.

**App features Ray lacks:**
- Tab switch on mouse down (item 23). Clicking the address edits it in place with a dropdown (⌘T stays centred);
  Ray's sidebar address opens the command bar, as Arc's does: keep Arc's.
- ⌥⌘← / ⌥⌘→ switch profiles; ⌥↩ in the command bar opens Split View; borderless page frame; collapsed group keeps
  tabs opened from it; pinch a Little Ardia window; `ardia tabs --usage` per-tab CPU and memory (Ray has Task
  Manager); three-step onboarding with Redo Setup… (Ray's onboarding has Show Welcome Again).
- Unread counts now off by default in Ardia, with a pill and the title's "(3)" dropped: if Ray builds item 17, start
  off by default the same way.
- Ray already has: ⌘W closes every selected tab (Ray's multi-select), the "New tab opened" pill (Ray's note), Auto
  PiP only when out of sight, the location permission asking macOS (not tried in Ray: check a site asking for
  location gets an answer).

**Fixes to behaviour Ray shares:**
- Safe Storage key change (1d), upscaler crash (1e), loading tab address (24), ⌃Tab order (25), extensions in
  private windows (22).
- One click after a right-click menu: Ardia's lost mouse-up ate the next click (`048b8052`); Ray's row menus are
  AppKit menus, likely fine (not tried).
- A light custom colour keeps sidebar text readable in dark mode: Ray's `ProfileColor.foreground(on:)` covers fills;
  Ray's sidebar isn't tinted by the colour, so nothing to take.

**Competitive notes:** Ardia ahead: a newer Chromium (still behind Chrome's .79), profiles, split view, Peek on by
default, mouse-down switches, per-tab usage CLI. Ray ahead: Settings › Search and Tab to Search, a share picker and
⌃Tab switcher of its own, no CLI or telemetry surface. Ardia is shipping a stable roughly weekly with ~200 commits;
Ray's biggest gap remains the engine rebuild (item 1), now also carrying two user-visible bug fixes (1d, 1e).

## v0.2.46-nightly.3 to .5 (2026-11-11 to 11-12), engine a840abea → 054c7f68

Range `v0.2.46-nightly.2..v0.2.46-nightly.5`: 92 commits, one engine patch (+56). Chromium unchanged
(157.0.8103.38); no new security fixes.

**Engine** (engine-054c7f68642e, in nightly.3):
- `chromium-webstore-icon-optional.patch` (`246e5e77`, Ardia #1135): Chrome's `WebstoreInstallHelper` ended a
  Web Store install with "Image decode failed" when the listing's icon (lh3.googleusercontent.com) couldn't be
  fetched or decoded (DNS, a VPN or filter, Local Network Access, an HTTP error). Now it logs and installs with the
  default icon. Ray has the same Chrome code: MISSING 55, comes with item 1 or as a small `engine-ray` fixup.

**App features Ray lacks:**
- Auto PiP on app switch (item 21); a Dock click restores a minimised window while a video is in PiP (check Ray's
  `applicationShouldHandleReopen` with PiP up, not tried).
- Collapsed tab group keeps the tabs opened from it under its header (Arc's), and keeps the current tab in view.
  Ray's Today folders take tabs opened from them; what a collapsed folder shows then is not tried.
- Peek on by default (item 9); ⌥⌘← / ⌥⌘→ switch profiles (Ray has one profile, MISSING Arc 2); split view ⌘W
  closes one pane, Arc import keeps splits (Ray has no split view); pinch a Little Ardia window open; a compact ⌘T
  plugin (`commandBarStart`); unread count at the row's end, a PiP icon on a tab in PiP.
- Ray already has: the "New tab opened" pill (Ray's "Opened in Background Tab" note), a link preview that moves out
  of the way (Ray's goes bottom right near the pointer; Ardia's goes to the top), the screen-share permission line and
  sharing its own windows (Ray's `SharePicker`, MISSING 51).

**Fixes to behaviour Ray shares:**
- Extensions in private windows (item 22).
- Web Store icon failure (above).
- Korean IME composing in the command bar (Ardia's was a React field; Ray's is an `NSTextField`, likely fine, not
  tried); content-blocker toggles, sync uploads, Auto-Hide Tabs, Discord toolbar bounce, translation: Ardia-only.

**Competitive notes:** Ardia ahead: auto PiP on app switch, collapsed-group behaviour, Peek, split view, profiles.
Ray ahead: Settings › Search and Tab to Search, ⌃Tab switcher, a share picker that already lists its own windows.

## v0.2.46-nightly.2 (2026-11-10), engine bc84a70b → a840abea

Range `v0.2.46-nightly.1..v0.2.46-nightly.2`: 32 commits, 32 engine files (+82/−1,244). Chromium unchanged
(157.0.8103.38); no new security fixes.

**Engine** (engine-a840abead94e):
- **Window close no longer waits 4 s** (`cba28a9c`, `ac_web_contents_delegate.mm`): the unload-done reply goes to
  Chrome while it's closing the window, so ⇧⌘T right after keeps Back/Forward and a private session ends with
  its window. Ray has the same code: item 1c.
- **Frame-rate patches out** (`0f289583`): `chromium-begin-frame-warm-up`, `-main-frame-throttle-after-show`,
  `-main-frame-full-rate-on-input`, `-battery-saver-full-rate-on-input` and `ac_input_frame_rate.mm` removed;
  `thaw-live-connections` becomes `freeze-spares-live-connections` without the 600 s unfreeze. Also gone:
  `ac_engine_abi_version`, an unreachable password-save fallback, `ArdiaCore.h` loses 5 lines. The prebuilt
  engine's key now hashes the offline game too (`engine/engine-key.sh`). Ray: item 19.

**App features Ray lacks:** nothing new for Ray. `ardia browse` (Ardia's agent CLI: actions answer with the
opened text, `read --scroll`, spreadsheet `fill`, stale refs follow a redrawn element) has no Ray counterpart and
isn't on Ray's roadmap.

**Fixes to behaviour Ray shares:**
- Window-close timing (above).
- Sync's Keychain key save updates before deleting (`1cf6efe8`); import temp copies (which can hold a logins
  database) named per process and stale ones removed at start. Ray's `ImportWriter` reads the source in place
  through Ardia's import core: check it leaves no copies behind (not tried).
- Live folders saved at quit, split/peek ordering (`fd0f6294`): Ardia-only features.

**Competitive notes:** Ardia ahead: window close/reopen (until 1c), a measured Dia divider. Ray ahead: Settings
› Search and Tab to Search, the ⌃Tab switcher, its own screen-share picker (MISSING 51) where Ardia only refuses
unclicked capture.

## v0.2.45 (2026-11-10, stable) and v0.2.46-nightly.1 (2026-11-10), engines f16f5620 → bc84a70b

Stable of nightlies 1–4 (2026-11-06 to 11-08) plus Chromium 157; nightly.1 of 0.2.46 has app fixes only (same
engine). Range `v0.2.44..v0.2.46-nightly.1`: 338 commits, 61 engine files (+1,828/−371), 12 new patches.

**Engine** (engine-f16f5620, 213c584a, 6b163791, e2b3e5ce, 44666813, bc84a70b; tree `bc84a70b` ships in v0.2.45):
- **Chromium 157.0.8103.38 on Helium 0.21.1 / helium-macos 0.21.1.1** (`f8aaa24c`), with Chrome 157's security
  fixes (213, 7 Critical). Helium dropped `wasm-interpreter-fixes`, ungoogled's `disable-tos-dialog` and
  `prefer-https-by-default` (157 turns on HTTPS-First balanced itself) and added
  `disable-actions-for-browser-commands` (keeps `chrome::ExecuteCommand`, which Ray's page commands use). Memory
  25 % lower at 1–20 tabs (Ardia's table: 20 tabs 1,257 → 918 MB). Ray: item 1.
- **Display capture needs a click** (`b18165de`, `38096782`, `ac_desktop_capture.mm`,
  `pagesPickDisplayMedia`): security-relevant for Ray; item 1a.
- **glic off** (`0365b06a`): item 1b.
- `chromium-widevine-without-cdm.patch` (`fcdb61d9`): Widevine reports supported before the CDM component is
  installed, so Apple's and the Education Store's guest checkout stop on "Page Not Found" no more. Ray likely
  shares this (not tried).
- `chromium-keep-old-frame-on-swap.patch` (`1b0554d7`, `ac96727d`, `3ccc9688`): a same-site link swapping
  RenderViewHost hid the old view and dropped its compositor, a ~60 ms blank before the new page's first frame
  (each hosted page view has its own `BrowserCompositorMac`, Ray's gotcha too). The patch keeps a hidden view's
  compositor suspended with a clone of its last CALayerParams and hands it over. Ray has the same hosting, so likely
  the same flash; `switch-no-blank` covers tab switches only. Comes with item 1.
- `chromium-pip-user-agent-ignores-page-opt-out.patch` (`f3286b4a`): Ardia's PiP button and auto-PiP work where the
  page sets `disablePictureInPicture` (YouTube TV). Ray has no PiP control yet (MISSING Arc 9).
- Crash fixes: `chromium-action-open-popup-without-active-tab`, `-active-web-contents-without-active-tab`
  (extension badge in a tabless window, `71c27323`), `-remoting-dialog-without-browser-view` (Cast),
  `-extension-tab-move-closing-window` and ArdiaCore's closing-window guards (`3e4317c5`, `bfae8f43`, `bf0f55dd`:
  `adoptTab:` can refuse). All apply to Ray's engine shape; come with item 1.
- `chromium-capture-wake-lock-awake-only`, `chromium-tpm-metrics-off` (a startup TPM benchmark of hardware crypto on
  Mac), `chromium-media-access-hook` (Ardia answers media requests from any delegate), video upscaler fixes (Ray
  leaves upscaling out), the `ardia browse` drag patches (`chromium-drag-start-event-id`,
  `-global-trace-id-64bit`, `devtools-control-token`: Ray drops the token patch, check whether the drag patches
  depend on it), passwords: a re-save matches any stored copy and a login saves under Chrome's canonical origin
  (`d6a9bb82`, `13ff3d86`; Ray's new save prompt should check "re-save the same password" by hand).

**App features Ray lacks:**
- Unread counts on tabs (item 17).
- ~~Command bar arrowing fills the field (item 2).~~ Done 2026-11-10.
- Links from pinned tabs and Top Apps open in a Peek, redirect wrappers unwrapped (Gmail, Slack, Outlook); "Open
  new-tab links in" New tab / Peek / Little Ardia. Peek is an open decision (item 9).
- Profiles load on first use (8 profiles: 1.5 GB → 390 MB). Ray has one profile (MISSING Arc 2); design input.
- Page frame slider down to edge to edge; files, links and text dropped on the New Tab page open there; bookmarks can
  hide entirely (Copy URL takes the star's place); the command bar pulses in the site's colour on a site-search Tab.
- A pinned tab away from its address shows "/ title"; a tab with a Peek open shows the Peek's icon; the audio
  indicator holds 2 s after sound stops (Ray: with the sound icon, item 5).
- Report a Problem sheet, anonymous ID, `ardia tabs`/`groups`/`apply` CLI: left out on purpose (MISSING).

**Fixes to behaviour Ray shares or should check:**
- Full screen: the window buttons hide until the pointer reaches the top, then come down with macOS's title bar, no
  flicker or gap in the sidebar (`ca40a46a`). Ray keeps its lights in the sidebar in full screen
  (`fullScreenRowCenter`); look at it by hand against Arc.
- A window dragged to another display on macOS 27 slid down or shrank after the drop and didn't tile at screen
  edges. The owner is on macOS 27: try with Ray (not tried).
- Extension sign-in windows (Stylus's cloud sync, `chrome.identity`-style flows) opened among the tabs and closed
  the user's window when done. Try Stylus sync in Ray.
- The hidden sidebar's peek opened while holding a button near the window edge, and flickered at the window's corner.
  Ray's `peek-zones` covers the edge; a held mouse button isn't tried.
- A click that drifts a few points still counts on a tab (Ray: check the sidebar's drag threshold).
- ⌃Tab switcher lists only open tabs (Ray's recent order: check unloaded tabs).
- Back to Pinned URL stuck after leaving the pinned page again; a camera dot stayed on a slept tab.
- A light profile colour in dark mode: titles turn dark on it, selected tab white highlight (0.2.46-nightly.1,
  "Adjust text to the colour"). Ray's `ProfileColor.foreground(on:)` already picks by contrast for accent fills.

**Competitive:** Ardia is ahead on the engine (M157 vs Ray's M156.47), memory, Peek, unread badges and an agent
CLI. It now matches what Ray already did: closing the last window keeps it (item 18) and site panels closing on a
click elsewhere or Escape (Ray's `Panels` always did). Ray is still ahead on a native AppKit hot path and Arc's
⌃Tab switcher with pictures.

## v0.2.44 (2026-11-04, stable), engine-38b319abda74

Stable release of nightlies 1–6 plus a nightly.7 range (`v0.2.44-nightly.6..v0.2.44`, 40 commits, most of them
release films, the perf ratchet and Ardia's dashboard). Already covered above: sidebar on the right (item 15),
share from the page menu (13), swipe-and-hold history (16), shared Top Apps, hooks and config files, background
peek (8), muted tabs' silent notifications (5).

**Engine** (tree `38b319ab`, from `2da3ca19`; no Chromium bump, still 156.0.8078.79 on Helium 0.20.3; no Chrome
security fixes): one patch, `chromium-storage-pressure-bubble-without-browser-view.patch` (`9e5b115b`, Ardia #835):
when the disk runs low Chrome's storage pressure bubble dereferenced `BrowserView::GetBrowserViewForBrowser`, which
an embedder's browsers don't have, and crashed. Ray's engine has the same browsers and no such patch: it should
crash the same way (not tried). Comes with item 2, or as a one-file `engine-ray` fixup on its own.

**App, new since nightly.6:** each profile picks whether its Top Apps join the shared set (`d3f81640`); PiP thrown
into a corner nests its curve inside the window's corner (`c1409aa8`); the top tab strip clips at its start, a close
keeps the next × under the pointer, split tabs click anywhere (`1b4eb4ac`); faster new tabs (first paint 80 → 69 ms,
the page's first frame 55 → 45 ms) from memoizing React rows (`a59a0060`, `d50d6df3`, `01f6dbf1`).

**Fixes Ray shares or should check** (`9e5b115b`):
- macOS 27's green-button submenus throw (`submenuAction:` gone from NSMenu): Ray is AppKit too, item 8a.
- Omnibox fixup regex backtracked exponentially on `my-blog-post.another-post.x:` (Hermes, stack depth). Ray's
  `AddressInput` uses no regular expressions; nothing to take.
- Acting on an extension the engine already removed: Ardia now logs and reloads its list. Ray's Settings ›
  Extensions follows the engine's list; worth one try (remove from chrome://extensions with the pane open).
- Names save on click away (a profile name needed Return), tabs moved to another window land per "New tabs open at",
  never in a group. Ray has no profile names or move-to-window yet; keep both in mind when they land.

**Competitive:** Ardia publishes a perf table per release (new tab first paint 69 ms). Ray has `switch-no-blank` but
no published timings; a measured new-tab and window first paint would let Ray answer it. Ardia is ahead on sidebar
side, sharing and scripting; Ray stays ahead on a native AppKit hot path (no React re-render cost to tune away) and
Arc's ⌃Tab switcher.

## v0.2.44-nightly.6 (2026-11-04), engine-2da3ca19a224

**Engine** (tree `2da3ca19`, from `b2c15dac`; no Chromium bump, still 156.0.8078.79 on Helium 0.20.3; no Chrome
security fixes):
- `chromium-devtools-control-token.patch` + `ac_cli_token_policy_*.cc` (`fd6880c1`): with an `ardia browse` session
  on, any service worker starting crashed the browser (a `GetForId` temporary ref freed a half-built agent host).
  Not Ray's: Ray drops that patch (`engine-ray/fixups/0002-drop-devtools-control-token.patch`) and its files.

**App:** profiles sharing browsing data share their Top Apps, one live page across profiles (`9237009b`, PR #136;
Arc's spaces sharing Favorites); a pull-request live folder can hide repos (`fb5b3846`); swipe back and hold opens
Dia's upward history list (`a97d6db7`; Ray: item 16); Top Apps tiles share one glass pass, so pages scroll smoothly
with the sidebar open (`ec32cab4`: each separate `NSGlassEffectView` costs WindowServer a pass every composited
frame while a page scrolls; grouped in an `NSGlassEffectContainerView`); the right-hand peek stays open
(`d47b7dee`); PiP's Back to Tab from a split view stays on the video (`497d66d5`).

**Fixes Ray shares or should check:** the glass cost. Ray's Glass surfaces are `NSVisualEffectView`s (not
`NSGlassEffectView`) and only over the page while a note or panel shows; the sidebar has none per row. Nothing to
take, but never give sidebar rows or tiles their own glass view each: group them.

**Competitive:** shared Top Apps is the Spaces-sharing-Favorites behaviour Ray will need once Spaces and Profiles
land (MISSING Arc #1, #2). Ray's favorites are one set today, so it already behaves this way with one profile.

## v0.2.44-nightly.5 (2026-11-03), engine-b2c15dac6771

**Engine** (tree `b2c15dac`, from `7ad5405d`; no Chromium bump, no security fixes):
- `ac_downloads.cc` (`4d9a3713`): a completed download carries the engine's own SHA-256 (`DownloadItem::GetHash`)
  as `sha256`. Ardia's download mover checks it after claiming the file into a 0700 staging folder, so a same-user
  process can't swap the file before a hook moves it. Ray has no mover; comes with item 2.
- `TabBridge` counts main-frame document commits and keeps the last HTTP status (`committedHTTPStatus`,
  `committedDocumentCount`), and `navigationEntries` marks the committed entry (`8ed4ec56`, for Ardia's hooks).
  Ray: the `committed` flag helps item 16's list.

**App:** hooks (`~/.config/ardia/hooks.json`: rewrite or block links, route links from an app to a profile, file
downloads, deny camera/mic, run commands on launch, idle or wake; anything reaching outside the page waits for
approval in Settings › Advanced › Automation); address bar rows from config (fixed lists, URL templates, suggest
endpoints, behind a keyword or mixed in; endpoints off until approved); Picture in Picture in WebKit tabs; with the
sidebar on the right, the window buttons ride it and it sits 9 pt from the window edge (`1544dabc`); uBlock Origin
1.75.4.

**Not for Ray:** hooks and config-file address rows sit on the `ardia` config file and CLI, left out on purpose
(MISSING). Their link rules are Air Traffic Control by another name (MISSING Arc #12); Ray's version, if built, is a
Settings UI, not a dotfile. WebKit tabs: Ray has no WebKit (decided).

**Competitive:** Ardia is turning into a scriptable browser (hooks, CLI, agent control). Ray answers with Arc's feel
and a native Settings window; its Site searches (keyword + Tab) already cover the keyword half of config rows.

## v0.2.44-nightly.4 (2026-11-03)

Read first from Ardia's `main` on 2026-11-03 (`6cb71745`), before the release; the tag is that commit. No change
under `engine/` (still engine-7ad5405dbe6d), so nothing for Ray's engine. Range
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
