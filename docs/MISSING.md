# What Ray still lacks

The gap list against Arc and against Chrome, kept current. The owner picks the order; PLAN.md's roadmap says what
comes first overall. When something lands, move it to "Done" with the date and the commit or release.

Built from Ray's code and the engine's API (`engine/raycore/src/ray/core/public/RayCore.h`, the `ac_*` calls): what
Arc has that Ray doesn't, and what Chromium offers that Ray never wired up. Items marked (?) depend on what the
engine does when Ray has no UI of its own for them, and haven't been tried by hand.

## Top priority (owner)

1. **Select several tabs: what's left** (owner, 2026-10-29). ⌘/⇧-click, the selection's menu, ⇧⌘C and dragging
   them together landed 2026-10-31, Duplicate and Move to on a selection 2026-11-03. Left: Split View with them once
   it exists, Escape to end a selection (the sidebar doesn't take keys), a count on the dragged row.

## Arc features Ray doesn't have

**Big**
1. **Spaces**: separate sidebars per context, two-finger swipe between them, a colour or gradient per Space.
   Roadmap item 2. Cra (`third_party/cra`) has a model worth copying; its views are SwiftUI, so Ray's are rebuilt in
   AppKit.
2. **Profiles**: several logins (Arc ties a profile to a Space). Ray has one profile; the engine has
   `loadProfile`/`offTheRecordProfileFor`.
3. **Split View**: two or more pages side by side in one window.
4. **Little Arc**: the small window for links opened from other apps (⌥⌘N). Links from other apps would open there;
   today they open as a Today tab in the normal window (`Host/LinksFromApps.swift`). Ardia's design notes for its
   Little Ardia (new-tab links kept inside it, a tab moved mid-load): `docs/ARDIA-WATCH.md`, "v0.2.44-nightly.4".
5. **Archive view**: Ray archives stale Today tabs but has no way to browse or restore them.

6. **Peek**: Arc's preview of a link in a floating card over the page (open it fully or dismiss). Ray dropped the
   engine hook Ardia used (`chromium-temporary-tab-restore-hook.patch`, in `engine-ray/drop-patches.txt`): bringing
   Peek back means restoring that patch, or building it on ordinary tabs. Open decision in PLAN.md.
7. **Built-in content blocker**: ad and tracker blocking without installing an extension. The engine still has
   Ardia's navigation hold for one (`holdNavigationsUntilRulesetsOf:`, idle; Ardia ran its own uBlock Origin,
   `fajbdaomknpkicfjcpipdmcpoamdmilh`), and Helium's bundled uBlock Origin is compiled out
   (`chromium-helium-ublock-off.patch`). Today the user installs uBlock Origin Lite from the Web Store. Open
   decision in PLAN.md.

**Smaller**
8. Media controls in the sidebar (now playing, play/pause; the sound icon on tabs is done). Mute Site as its own
   choice behind ⌥ (Ardia 0.2.43-nightly.4 moved to this after a site-wide mute surprised users;
   `docs/ARDIA-WATCH.md`).
9. *(Done: automatic picture in picture, see Done. The number stays for references elsewhere.)*
10. Arc's row-menu items that wait on other features: Add Split View (tabs) and Turn "<folder>" into Space (folders)
    once Split View and Spaces exist; Share Folder… as Arc's shared-folder link (Ray shares the folder's links).
11. Boosts: per-site CSS/JS, zapping elements.
12. Air Traffic Control: rules for which Space a link opens in (Cra's `LinkRouting`).
13. Capture (Arc's screenshot tool).
14. Easels, Notes, Library.
15. Sidebar on the right. Ardia shipped it in 0.2.44-nightly.4–6 (traffic lights ride the sidebar, the peek comes
    from the right edge); its list of what mirrors is in `docs/ARDIA-WATCH.md`, "v0.2.44-nightly.4" and ".5".
16. Sync between Macs.
17. Collapse the pinned section: a "Pinned" toggle on the divider above Today; collapsed, only the entry holding
    the active tab shows (Ardia 0.2.43-nightly.4, its most-asked issue).
18. Unread counts on tabs: a web app's count on its pinned tab, favorite or row, from the page title, the Badging
    API or a favicon dot (Ardia 0.2.45; Arc showed favicons' own dots only).

**Left out on purpose:** Arc Max's AI features.

## Chrome features not wired in Ray

**Menus**
1. ~~Bookmarks UI~~ (Done: the Bookmarks panel, menu and command bar rows). Leftovers: Known limitations 48.

**Prompts the engine asks Ray to show (delegate hooks Ray doesn't implement)**
2. ~~Passwords: the "save password?" prompt~~ (Done). The fill dropdown and "Suggest strong password" are Chrome's own
   popups (the engine draws them); see Known limitations 40.
3. ~~Autofill for addresses and cards: the save prompts~~ (Done). The fill dropdown is Chrome's own popup (the engine
   draws it); see Known limitations 45.
4. ~~Links that open other apps: `mailto:`, Zoom, Slack… (`externalAppRequest`)~~ (Done).
5. Device pickers: WebUSB, Bluetooth, HID, Serial (`deviceChooser`); requests get nothing.
6. ~~Screen-share picker (`allowDesktopCapture`, "share this tab instead")~~ (Done). See Known limitations 51.
7. Cast (`castDialog`, `castRoutes`).
8. ~~A note when a popup is blocked, with "always allow" (`didBlockPopup`, `openBlockedPopup`)~~ (Done).
9. ~~Crashed tab page and the "page unresponsive" dialog (`rendererGone`, `tabBecameUnresponsive`)~~ (Done).
10. ~~Warning on quit while downloads run (`confirmCloseWithDownloads`)~~ (Done). See Known limitations 46.

**Page and tab details**
11. ~~Link preview at the bottom corner on hover~~ (Done).
12. Tab state: put to sleep (`tabDidChangeDiscarded`), the site's theme colour. (The sound icon is done.)
13. Extension side panels and extension keyboard shortcuts (`extensionSidePanel`, `extensionActionShortcut`).
14. Installing imported extensions: the engine's `ac_extensions_install` takes a folder or a .crx, not a Web Store id.
15. Web notifications: from the engine's alerts helper, not checked (?).
16. Install an extension by dropping a .crx on the window, "Allow User Scripts" per extension (Tampermonkey and
    other userscript managers), and Export Bookmarks as HTML. The engine calls come with Ardia's
    engine-2f172eb50b89 (`ac_extension_drop.mm` and the `engine:extensionInstallFailed:tab:` delegate,
    `ac_extensions_configure` `userScripts`, `ac_bookmarks_export_html`); Ray needs the sync and the UI.
18. Share from the page's right-click menu: selected text, an image, a link (trackers removed), a video/audio
    source or the page, through macOS's share sheet; File › Share › Share… on ⌥⌘S. Engine part comes with Ardia's
    engine-7ad5405dbe6d (`ac_context_menu_share`); Ray implements `tab:shareFromContextMenu:` (Ardia
    0.2.44-nightly.3, `docs/ARDIA-WATCH.md`).

19. Back and Forward history lists: the buttons' lists are done; left is Dia's two-finger swipe-and-hold list (it
    opens upward under the fingers; Ardia 0.2.44-nightly.6, `docs/ARDIA-WATCH.md` "Ray should" 16). The swipe's chip
    is Ray's (Dia's look) but Chrome still recognises the gesture, and Chrome's swiper cancels on vertical motion, so
    the list needs Ray's own swipe code (Ardia's `ArdiaSwipe`).

**Already working through Chrome's defaults:** right-click menus, spell check, `chrome://` pages.

## From Ardia's settings

Gone through Ardia 0.2.42's Settings window pane by pane (2026-10-29); what it offers that Ray doesn't, beyond the
items above. The revamp that gives these a home is PLAN.md section 13.

**Big**
1. **Live Folders** (Arc had them): folders that refresh on their own, GitHub/Bitbucket pull requests,
   Notion/Confluence/Google Drive documents. A pull-request folder's menu can hide repos (Arc's Repositories
   submenu; Ardia 0.2.44-nightly.6).
2. **Live Calendar** (Arc's calendar preview): hover a pinned calendar tab to see the day, a badge counting down to
   the next meeting, an alert with a Join button.
3. **Theme as a gradient** (Arc's Space themes): several colours, intensity, grain, direction. Ray has one accent
   colour. Belongs with Spaces.

**Smaller**
5. New tabs at the bottom of Today (Ray offers the top or below the current tab) and where the New Tab button sits.
7. Alternate app icons: a few need designing first.
8. Hide the address bar above the page (View › Show Address Bar on Page) while scrolling down: it tucks into a
   thin strip with the site's name; scrolling up or clicking the strip brings it back.
9. Arc's "Clear" button between pinned tabs and Today (Ray has no such button yet; Clear Today's Tabs is only in
   the File menu and the command bar). Its Settings row exists, unbuilt.
14. Battery saver.
15. Memory Saver rows: on/off, Moderate / Balanced / Maximum, "Always keep these sites active" (Ardia's Settings ›
    Advanced › Performance, through the engine's `ac_memory_saver` from engine-2f172eb50b89). Today only on
    chrome://settings/performance, and off by default (see Known limitations).
16. Compact toolbar: the address bar above the page at 28 pt instead of 41, so a 16:9 video in web full screen
    fills a maximized window (Ardia 0.2.43-nightly.1).

**Left out on purpose:** WebKit engine and website rules (decided no), setup codes, the `ardia` command-line tool,
meeting groups (Arc has none; tab groups are Today folders now, owner 2026-10-31), video upscaling, crash reports and usage stats; a choice of when
Today tabs archive (Ray keeps Arc's 12 h, owner 2026-10-29); sharing tabs across windows (for now).

## Known limitations and follow-ups

Smaller gaps found while building the items above. Each says where the fix goes.

1. **Command bar can't weigh typed pages.** `ac_history_query` only exports visit times, not typed counts or visit
   types, so the bar's frecency counts visits only (Chrome weighs a typed visit 1.5×). Fix: export `typed_count` and
   the visit transition from the engine (`engine-ray` fixup on `ac_history.cc`). Found 2026-10-29.
2. **No IDN spoof checker.** Addresses show internationalised hosts as punycode (`xn--bcher-kva.example`), so real
   non-English domains look raw. Fix: port Ardia's `idn.ts` checks (or Chrome's IDN spoof checker) and show Unicode
   when safe. The command bar's "Switch to Tab" detail still decodes to Unicode (`AddressInput.host(of:)`).
3. **View Source drops the fragment.** The engine reports a `view-source:` tab's URL without its `#fragment`, though
   Ray asks for it. Engine-side.
4. **Imported extensions aren't installed.** `ac_extensions_install` takes a folder or .crx, not a Web Store id.
   Fix: an engine call that installs by Web Store id (Chrome's webstore installer).
5. **History can be imported twice.** Re-running an import adds history visits again (sidebar items, passwords and
   cookies are de-duplicated). Fix: skip URLs already in history, or import only visits newer than the newest one.
6. **Print preview and Escape.** Unconfirmed whether Escape closes it when the owner's window is key (the hidden
   test window can't tell).
7. **Command bar: "Switch to Tab" text clipped by about a letter next to the arrow button** (seen in a snapshot,
   2026-10-29).
8. **Test hygiene.** `settings-shortcuts` leaves a Save Page As sheet open (it presses ⌘S with that setting off);
   `close-last-window` now cancels it, but the check itself should close it. `folder-rename` fails when the hidden
   test window lands on the visible desktop (also on older commits). `switch-back-latency` hit-tests (400, 14), which is
   the page toolbar now that it shows by default, so it never sees the page (it passes at (400, 200) with `onscreen
   on`); `background-tab` fails right after boot on main too (its `#plain` lookup returns nothing). Found 2026-10-29.
9. **Accent contrast elsewhere.** `ProfileColor.visible(on:)` keeps a black or white profile colour visible in the
   onboarding only; the sidebar selection and hover, loading glow, downloads ring, Settings' switches, command bar
   selection and site controls' "on" states would benefit too (owner to decide).
10. **Engine behind Chrome stable.** Chromium 156.0.8078.47; Chrome stable for Mac is 156.0.8078.75 and 157
    (chromiumdash, 2026-10-29), and Ardia hasn't bumped. Fix: the next engine rebuild bumps 156's patch level and
    takes Ardia's engine-2f172eb50b89 together (`docs/ARDIA-WATCH.md`, `docs/CHROMIUM-WATCH.md`). Found 2026-10-29.
11. **No tab sleeping at all.** Ray's engine skips Helium's `memory-saving-by-default.patch` "because it would fight
    Ray's own tab sleeping", but Ray has none (that was Ardia's app), so background tabs never sleep unless the user
    turns Memory Saver on in chrome://settings/performance. Fix: take Ardia's engine-2f172eb50b89 (drops the skip,
    Memory Saver on by default, as Helium and now Ardia). Found 2026-10-29.
12. **Engine and extensions likely always in English.** Chrome takes its UI locale from the app bundle's
    localizations, and Ray's Info.plist (`scripts/build-app.sh`) declares none, so chrome:// pages and every
    extension's `chrome.i18n` probably run in en-US whatever the Mac's language (Ardia found and fixed this in
    `b13d9f79`). Not tried in Ray. Fix: declare Chromium's 55 desktop locales in `CFBundleLocalizations`; Ray's own
    UI stays English. Found 2026-10-29.
13. **A cancelled Save As may leave a "Cancelled" row** in the downloads panel: `Downloads` lists Chrome's item
    before the save panel gives it a path (Ardia's bug, fixed in 0.2.43-nightly.3). Not tried in Ray. Fix: list a
    download once it has a path, drop one cancelled before it had one. Found 2026-10-29.
14. **Reserved keys short of Helium's set.** `Shortcuts.isReserved` lacks Developer Tools (⌥⌘I), F12 and Search Tabs
    (⇧⌘A), so a page that cancels keydown can keep them (Ardia `dd242aac`). Found 2026-10-29.
15. **JumpCloud Go can't sign in from Ray itself (relayed through Chrome since 2026-10-29).** Its extension (`jdoahkhfkeipblhbhppmcbdgapeoaopa`, same 3.3.5 in Arc
    and Ray) asks JumpCloud's native host for the sign-in token (`runtime.sendNativeMessage`, host
    `com.jumpcloud.jumpcloudgo`). Ray finds the host: its manifest is in `/Library/Google/Chrome/NativeMessagingHosts`,
    which Helium's `scan-chrome-native-messaging-hosts` reads. But the host (`/opt/jc_user_ro/JumpCloudGo-Chrome`,
    agent 2.200.0) checks who launched it: `proc_pidpath` of its parent (Chrome's browser process), then
    `/usr/bin/codesign` on that app against a fixed list of identifier + Developer ID team: Chrome
    (`com.google.Chrome`, EQHXZ8M8AV), Arc, Island, Brave, Firefox, Edge, Amazon WorkSpaces. Anything else gets
    "Cannot validate parent process" for the token (its `info` call still answers). Ray is `dev.shanus.ray`, signed
    "Ray Code Signing" with no team, so it can never match; Chrome Dev/Beta/Canary (`com.google.Chrome.dev`…) fail
    the same way (the owner's Chrome is Chrome Dev 158). Stable Chrome passes. Not Local Network Access: the login
    page's `http://localhost:1028` path is Android-only; on a Mac it talks only to the extension
    (`externally_connectable`). Ray can't pass the check honestly (passing as another browser would defeat the
    company's device check). **Workaround in Ray:** Settings › Passwords › "Sign in with JumpCloud Go through Chrome"
    (`jumpCloudRelay`, off by default, `Host/JumpCloudRelay.swift`): on JumpCloud's /login page, Ray starts real
    Google Chrome (signature checked: `com.google.Chrome`, team EQHXZ8M8AV) on its own profile
    (`<data>/JumpCloud Relay`, 0700) over `--remote-debugging-pipe`, loads the console's own login page there
    headless (`--headless=new`, ordinary Chrome's user agent and client hints, no window, no Dock icon, never
    activated, so a full-screen Ray stays on its Space), and on reaching /userconsole copies only jumpcloud.com
    cookies into Ray and reloads the tab (an app's sign-in, `context=sso` such as a SAML app, goes on to the app's
    `https://sso.jumpcloud.com/` + `redirectTo` instead, since the login page doesn't forward an existing session; an
    app whose policy asks for JumpCloud Go again sends a signed-in user to `/login/stepup?…mfaType=durt`, which relays
    too since 2026-11-11 (Argo CD; whether Chrome's fresh check satisfies the app still needs the owner's real try)). If headless doesn't sign in within 10 s it starts again in a small visible
    Chrome window (in full screen, Ray shows "Finish signing in to JumpCloud in Chrome" with a button instead of
    switching Spaces). Set Up… installs the extension into that profile once. The owner's company sign-in worked
    end to end on 2026-10-29 with the visible window (JumpCloud Go finishes by itself, no Touch ID); the headless
    run still needs its real try (the native host's parent check should see the same signed Chrome executable).
    Follow-ups: the relay clears all of jumpcloud.com's site data in Ray before importing (the engine's
    `ac_cookies_import` keeps cookies Ray already has, and `ac_site_data_clear` is the only delete); the visible
    fallback still shows a second Google Chrome in the Dock while it runs; a Chrome policy that turns off remote
    debugging (`RemoteDebuggingAllowed`) makes it say Chrome didn't answer, and one that turns off headless mode
    (`HeadlessMode`) costs a fallback. Real fix: settle the bundle id, then ask JumpCloud to add Ray's identifier and
    team to the host's list (Ray's team is the free Apple Development one, 96AWMN4CQ6: no Developer ID, owner
    2026-11-03, so they may refuse; the relay stays). Found 2026-10-29.
16. **Tab rename details.** Arc's row tip says "Double-click to rename" once (Cra copies it); Ray shows no hint. A
    favorite's name is typed in a lifted row under its tile (Ardia and Crest use a sheet): worth a look by hand. A
    double click on an unloaded tab loads it and keeps the field focused in the hidden test window; not yet tried in
    a key window, where the page could take focus as it loads. Fix where needed in `SidebarView.beginRename`. Found
    2026-10-29.
17. **Extension popup details.** The popup window has no arrow (a system arrow would be filled with a colour Ray
    can't know the page paints; Crest leaves it out too) and is centred under its button rather than following
    Chrome's edge alignment. Escape is taken by the popup window before the page sees it (Ray's render view doesn't
    hand an unused Escape back), so a popup's own Escape handling (closing its menu) closes the whole popup. Fix:
    route the extension view's unhandled keys back to `ExtensionsController`. Found 2026-10-29.
18. **Keychain prompt on every new build or update.** "Ray Safe Storage" asks for the login password once per build
    (and per Sparkle update for friends), "Always Allow" included: the item's partition list keys apps without a
    Team ID by cdhash, and "Ray Code Signing" is self-signed, so it has none. Fix: an Apple-issued certificate
    (the owner's Apple Development certificate, since 2026-10-29; no Developer ID, owner 2026-11-03), then one last
    prompt. Found 2026-10-29.

19. **Search pane gaps.** Only a built-in engine can be the default (Chrome and Ardia allow a custom one); no
    suggestions inside a scoped site search; letter marks instead of engine icons (no icon fetching); pages that
    search through Chrome itself ("Search Google for …" in the right-click menu) still use Google, because Ray keeps
    its own engine list rather than Chrome's TemplateURLService (`ac_search_engines_list` can't set a default).
20. **Privacy pane gaps.** It lists only permissions that already differ from the default (Site controls sets the
    rest); origins with wildcard patterns don't show (the engine leaves them out); an extension's "On specific
    sites" can't add sites (`ac_extensions_configure` has no host list); Chrome's Site settings pages aren't trimmed
    from `resources.pak`, only routed to the pane.
21. **Passwords pane gaps.** "Never saved" can't gain entries from Settings (no engine call to add an exception); the
    real Touch ID prompt, save and open panels and 1Password's "Add browser" with the signed Ray aren't tried by
    hand.
22. **Two sets of Settings data rows.** `SettingsDataRows` (Privacy, Extensions) and `SettingsDataViews` (Passwords,
    Autofill) were built in parallel and overlap (item rows, confirm sheets; the latter's are `SettingsRecordRow` and
    `SettingsRecordConfirm`). Fold into one.
23. **A page's "Leave site?" doesn't cancel a window close cleanly.** `windowDidCancelClose` isn't implemented, so
    the window keeps its closing flag after the page cancels.

24. **Unloaded tabs no longer fade by default.** Ray used to dim every Today tab whose page wasn't loaded; that is
    now Settings › Tabs and sidebar › Fade icons of unloaded tabs, off by default (Arc's look, Ardia's default).
25. **Test instances can die on a closed pipe.** Test-only logging uses `FileHandle.standardError.write(_:)`, which
    raises when the test runner has already closed its end; a hidden instance then crashes (seen 2026-10-29 in
    `logState`). Fix: the non-throwing `write(contentsOf:)` in the six places that log.
26. **Settings › Tabs/Appearance/Shortcuts not felt by hand.** The reorder haptic, forced light/dark across the app,
    and "Always" scroll bars in Ray's own sidebar and Settings were checked by state and snapshots only.

27. **Shortcut editor gaps.** The "Copy the page's link with ⇧⌘C" switch keeps its title after Copy URL is rebound (it
    only sets the default now); no "Changed" or "Conflicts" filter (Ardia has them); the Settings search doesn't find
    single commands; moving Close Tab off ⌘W also stops ⌘W closing the Settings window, without a warning; recording
    by real keyboard and non-US layouts aren't tried by hand.
28. **⌘W on the last Today tab with only pinned tabs or favorites left: not tried.** Ardia closed the whole window
    there (unloaded pinned tiles counted as asleep) and fixed it to keep the window, as Arc does (0.2.43-nightly.5,
    `d8e1098b`). Ray's `close-last-window` check covers closing the window, not this. Fix if it closes: keep the
    window while anything is pinned; add a check. Found 2026-10-30.
29. **Private-window guard lives in Host only.** Ray's engine (Ardia 0.2.42) lets most `ac_*` calls run with
    `offTheRecord` unchecked and relies on Host to refuse; Ardia's engine-4d8c64033b08 refuses every call for a
    private profile unless it is marked `kAllow`, rejects empty args for sensitive calls, and zeroes decrypted
    passwords (two new patches). Fix: take that engine (`docs/ARDIA-WATCH.md` item 1). Found 2026-10-30.

30. **Folders: what's left.** (Found building Today folders, 2026-10-31.)
   - A Today tab reopened with ⇧⌘T comes back outside its folder: `ClosedTab` keeps `parentID` but `reopen` only
     uses it for pinned tabs. Fix in `BrowserWindowController.reopen` (Today: back into the folder if it's still there).
   - File › New Folder and the command bar still make a pinned folder only; a Today folder comes from a tab's menu
     (Add to Folder › New Folder) or an extension. Grouping several tabs at once waits for Select several tabs.
   - An extension that groups a pinned tab or favorite sees it taken out again (Chrome never groups a pinned tab;
     Ray's pinned tabs aren't Chrome-pinned underneath, `placeTab` is unused, so `tab.pinned` reads false for them).
   - Chrome's saved tab groups service (`TabGroupSyncService`) still runs: a moment after launch it writes back the
     look it saved when a group was made. `TabGroupSync` pushes Ray's look over it for 5 s after making a group; turning
     the service off in the engine would remove the race.
   - Close Tabs has no undo note yet (⇧⌘T and History › Recently Closed bring tabs back): `notes.show(Note(…, spot: .bottom))` with an Undo button.
   - The folder icon has no accessibility label; Change Icon's grid has no arrow-key navigation, and an emoji icon
     (kept from before 2026-10-31) can't be picked again (Arc's set is symbols only).
   - Not yet tried with the real Claude extension (needs the owner's sign-in in their own Ray).

31. **`settings-page-address-bar` is flaky** (2026-10-31/11-01): it failed twice in a row on one run and passed in
    the full suite and alone right after. Its own instance reads the setting a moment after launch; if it fails
    again, look at the timing of the one-time `pageToolbar` move.
32. **Not yet on the panels' look:** extension popups (their own window; could take the panels' corners, shadow and
    motion), and the dead Import from Arc confirm (`importFromArc`, no menu item reaches it).
33. **Peek from a background window: not tried.** With the sidebar hidden, hovering the left edge of Ray's window
    while another app is in front likely slides the sidebar out (`pointer(at:appActive:)` only narrows the reach to
    the window's own edge strip). Ardia stopped this (0.2.44-nightly.2, its issue #698): peek only while the app is
    active; a hover from the background opens when Ray comes forward with the pointer still there. Fix in
    `BrowserWindowController`'s peek code.
34. **Row menus (2026-11-03), what's left:** a folder's Delete moves its tabs up a level (Ray's old Delete Folder;
    Arc's may take them with it, not checked against Arc); Move to ▸ has no Favorites (Add to Favorites does that)
    and no other windows or Spaces; a tab's own icon shows in the sidebar only (the command bar, Recently Closed and
    the page toolbar keep the favicon); Edit Pinned Page › Edit… pins only http(s), chrome and about addresses, and
    a typed phrase pins its search page; Duplicate of an unloaded tab or a folder makes unloaded copies (no history).
35. **Engine calls a page with no certificate yet a certificate error.** `SecurityInfoFor` (`ac_tab_info.mm`) reads
    the visible entry, and a pending https navigation has no certificate, which it reports as `certificateError`
    (Chrome's `SecurityStateTabHelper` says none). Ray reads levels through `ConnectionLook.level`, which treats one
    with no errors as none. Fix in the engine (`engine-ray` fixup), then drop the workaround. Found 2026-11-03.
36. **No preconnect: a site's first visit pays DNS, connect and TLS after Enter.** Measured on a hidden instance
    (2026-11-03): navigation starts 2–30 ms after Enter (Ray adds nothing), then 50–90 ms of DNS and 100–800 ms of
    connect and TLS per new host before the request. Chrome and Arc start that while you type (the omnibox
    preconnects its top match through `LoadingPredictor::PrepareForPageLoad`, and pages' links are DNS-prefetched),
    so the page seems to start at once. Ray has neither: its command bar isn't Chrome's omnibox and the engine has no
    preconnect call, and Helium's `inox-patchset/modify-default-prefs.patch` defaults network prediction to off
    (Chrome: standard), which also blocks link prefetch and Chrome's own preconnects. Fix: an engine call
    (`ac_preconnect(url)`, `engine-ray` fixup) that the bar calls for its top row's host as you type, and network
    prediction on by default (an owner decision: Helium turned it off for privacy).
37. **Full-screen Ray once hid some menu bar items** (2026-11-04): with Ray full screen, Stats' RAM and CPU, Maccy and
    one more status item were gone while Ray was in front (Chrome and Arc full screen showed them), though the menu bar
    had room. Leaving and re-entering full screen fixed it. Not reproduced. Lead: a window restored into full screen at
    launch (a relaunch or update) before AppKit's launch finished; check Ray's window restoration and full-screen entry
    against Chrome's next time it happens.
38. **Low disk space likely crashes Ray** (not tried): Chrome's storage pressure bubble dereferences a `BrowserView`
    the engine's browsers don't have. Ardia fixed it in engine-38b319abda74
    (`chromium-storage-pressure-bubble-without-browser-view.patch`, 0.2.44); take it with Ardia's engine or as an
    `engine-ray` fixup. Found 2026-11-05.
39. **macOS 27: the green button's Move & Resize / Fill & Arrange may crash** (not tried): a submenu's parent item
    targets NSMenu with `submenuAction:`, which macOS 27's NSMenu no longer implements (Ardia 0.2.44, `9e5b115b`).
    Fix: add an empty `submenuAction:` to NSMenu at launch when it's missing. Found 2026-11-05.
40. **Password prompt gaps** (2026-11-05). The fill dropdown and "Suggest strong password" are Chrome's popups,
    drawn by the engine; no hidden test instance ever got one (`didShowAutofillSuggestions` never fired, by manual
    fallback, a click or with the window key and on screen), so whether they show in Ray is untried by hand. The
    prompt can't show the password (the engine gives only its length) and there's no key icon to bring a dismissed
    prompt back (Chrome's omnibox has one). No "Passwords" manual fallback (Ardia's `autofill passwords` command).
41. **Any page can open Chrome's screen-share picker without a click** (security, not tried). Ray has no picker of
    its own (Chrome 6) and no `getDisplayMedia` shim, so a page calling it while loading, or from an about:blank
    iframe, gets Chrome's picker, whose live ScreenCaptureKit thumbnails can flood replayd/tccd with permission
    checks (it froze input on the owner's Mac in Ardia's test). Ardia's engine now refuses native display capture
    unless the host's picker asked (`b18165de`, v0.2.45). Fix: that engine (`docs/ARDIA-WATCH.md` item 1a) or an
    `engine-ray` fixup, then a picker behind a click; add a check. Found 2026-11-10.
42. ~~**Command bar: arrowing moves only the highlight.**~~ (Done 2026-11-10: ↑ ↓ and Tab put the row in the field,
    Escape restores what you typed.)
43. **Engine leaves Gemini in Chrome (glic) on.** Helium keeps `kGlic`, so every tab carries glic's tab features
    (an Ardia crash, #954, was in one's destructor). Fix: disable the glic features in `ac_main_delegate.cc`
    (Ardia `0365b06a`). Found 2026-11-10.
44. **Same-site link clicks may flash blank for ~60 ms** (not tried): the RenderViewHost swap hides the old page view,
    which drops its compositor before the new one draws. Ardia's `chromium-keep-old-frame-on-swap.patch` (v0.2.45)
    keeps the old frame. Also likely shared, not tried: Apple Store guest checkout ending on "Page Not Found"
    (`chromium-widevine-without-cdm.patch`), and on macOS 27 a window dragged to another display sliding or shrinking
    after the drop. Found 2026-11-10.
45. **Autofill prompt gaps** (2026-11-05). The address and card fill dropdown is Chrome's popup, drawn by the engine,
    untried by hand (as 40). Only cards saved on this Mac are asked about: the engine drops Google Payments' upload,
    IBAN and offer bubbles, so IBANs are never saved. No icon brings a dismissed prompt back, the address prompt can't
    be edited before saving (Chrome's has Edit), and a card's explanation ("To pay faster…") is left out.
46. **Page prompt gaps** (2026-11-05). Quitting from the Dock, at logout or for an update goes through
    `applicationShouldTerminate`, which answers "now": whether the engine still asks about running downloads there is
    untried. A dismissed "Pop-up blocked" note can't be brought back for that page (Chrome keeps an omnibox icon; Ray
    has none). "Exit Page" and "Quit" are filled red (`PanelButton`'s destructive look), not the mock's red text. The
    hang check waits for the engine's real 15 s monitor (no shorter test switch).
47. **Tab details gaps** (2026-11-05). The sound mark's playing state is untested: test instances run with
    `--mute-audio`, under which no page ever counts as audible, so `tab-sound` covers muting and the mark's click
    only. The mark goes at once when sound stops (2 s after, the engine's hold) rather than fading over Chrome's 1 s,
    and the title slides over without animation. The link preview moves to the other corner as Arc's does, not
    down off the page as Chrome's, and grows to the page's width at once (Chrome animates it over up to 150 ms); it hasn't been tried with a right-to-left address. The history list has no Chrome "chapter stops" (other sites further back) or favicons for pages the
    favicon store doesn't hold (private windows: none).

48. **Bookmarks panel gaps** (2026-11-05). No drag: rows can't be reordered or moved between folders in the panel,
    nor dragged into the sidebar to pin (the sidebar takes no drops from outside it; Add to Pinned does it from the
    menu); moving is Bookmark Manager's (Chrome's page). Bookmark This Tab… puts new ones at the end of the bookmarks
    bar with no folder choice (Chrome remembers the last folder). No bookmarks bar, on purpose. No Export Bookmarks
    (engine call `ac_bookmarks_export_html` comes with the next engine, Chrome 16 above). Fix: a drag source on
    `BookmarkRowView` and `ac_bookmarks_apply`'s `move`, plus outside drops on `SidebarView`.
49. **Automatic picture in picture gaps** (2026-11-10). Chrome's rules decide: a video pops out only while it plays
    with sound (a muted video never does), on https or a file, and Chrome's safe-URL check comes first; a call
    (camera or microphone) pops out only on sites that ask for it (Meet does); never in a private window (Chrome's
    incognito rule). Leaving the window counts only when it's covered, minimised or on another Space (its
    occlusion), not when another app is merely in front; Arc's exact rule there is unconfirmed. Coming back closes only a PiP Chrome opened by itself: one opened by hand stays (Ardia
    and Crest close it too). The video route is untested in checks (test instances run with `--mute-audio`, so no
    page is audible); `auto-picture-in-picture` covers the call route on Chrome's fake camera. No "back to tab" or
    sidebar control for the PiP window beyond Chrome's own.
50. **Tab to Search gaps** (2026-11-10). Arc's built-in site searches aren't listed in Settings › Search, so they
    can't be turned off or edited (a site search of your own with the same keyword replaces one). A site search of
    your own takes its icon's colour only once that icon is cached (its front page visited), else the profile's.
    The unscoped field keeps the magnifier; Arc shows the default engine's icon there. Fix: list the built-ins in
    `SettingsSearchPane` with a switch each; fetch the icon by host.
51. **Screen sharing gaps** (2026-11-10). Chrome's floating share bar is hidden by Ray after it appears (found by its
    shape: a borderless views widget at the status level on every Space); an engine fixup that skips it when Ray's
    grant applies would be cleaner (next engine rebuild). Windows and screens need macOS Screen Recording permission;
    Crest's way (macOS's own content-sharing picker, no permission) needs engine work (a `DesktopMediaPicker` that
    opens `SCContentSharingPicker`). Capturing Ray's own window goes through macOS (`window:<id>:0`): unverified in
    tests (no permission there), check on a real Mac. Extensions' `chrome.desktopCapture` still gets Chrome's
    picker. Shares started without Ray's picker show as "Sharing your screen" (Ray can't tell the kind). The note
    shows only in windows of the sharing tab's profile; Chrome's tab-sharing infobar stays undrawn.
52. **Closing a window frees its tabs 4 s late** (engine, not tried; from Ardia `cba28a9c`, 2026-11-11). Ray's
    `ac_web_contents_delegate.mm` `CloseContents` drops a page's unload-done reply while Chrome closes the window,
    so the close waits on two 2 s fallback timers: the tabs are saved as lone closed tabs (reopening right after
    loses Back/Forward) and a private window's session outlives it by 4 s. Fix: an `engine-ray` fixup calling
    `BrowserWebContentsDelegate::CloseContents(source)` when `CanCloseContents` is false (next engine rebuild).
53. **Auto Picture in Picture ignores switching apps** (not tried; from Ardia `48498759`, 2026-11-12). Ray's window
    sight (`PageContainerView` `// MARK: Window sight`) counts a page unseen only when covered, minimised, on another
    Space or locked, so going to another app with Ray's window still visible leaves a playing video in the page;
    Arc and Ardia pop it out and put it back on return. Fix: observe `NSApplication.didResignActive`/`didBecomeActive`
    and note the active tab's page unseen while inactive (only a playing tab not already in PiP).
54. **Extensions allowed in Incognito may not show in private windows** (not tried; from Ardia `df9b9c0e`,
    2026-11-12). Ardia listed only `"incognito": "split"` extensions there. Check that Ray's private window shows a
    spanning extension allowed in Incognito (tile and popup) and that its Options opens in the normal window.
55. **Web Store install fails when its icon can't be fetched** (engine; from Ardia `246e5e77`, 2026-11-12). Chrome's
    `WebstoreInstallHelper` ends the install with "Image decode failed" if lh3.googleusercontent.com is blocked or the
    icon won't decode. Fix: Ardia's `chromium-webstore-icon-optional.patch` (install with the default icon) at the
    next engine rebuild.
56. **Sidebar resize leftovers** (2026-11-12). No keyboard or VoiceOver way to resize (Crest: an adjustable handle,
    20 pt steps; Chrome's side panel: arrow keys).
    Dragging far past the minimum doesn't hide the sidebar (Arc may; not measured). With scroll bars set to Always,
    the strip covers the outer 6 pt of the sidebar's scroller. The real cursor over the strip's 2 pt on the page
    hasn't been seen by eye (Chrome sets its own there). Hidden pages are resized with every drag step, as on ⌘S
    (the performance review's fix for that covers both).

## Done

| What | When |
|---|---|
| Resizable sidebar: drag its edge (240–480 pt, a rubber band at the limits as Ardia's, nothing drawn as Arc's), double-click for the standard width; one width for every window, remembered | 2026-11-12, `feat: resizable sidebar` |
| A peeking sidebar's edge drags too, and ⌘S on a peeking sidebar docks it in place (no slide out and in again) | 2026-11-12, `fix: peeking sidebar resizes and docks in place` |
| Screen sharing in Ray's own look: a picker over the asking tab (Tabs / Windows / Screen with pictures, deny by default, full origin, 0.5 s guard), a held note at the top centre (Stop Sharing, Share This Tab), share marks on the rows, a ring round the shared page; Chrome's picker and floating bar gone; Ray's own window shares through macOS | 2026-11-10, `feat: own screen share picker and indicators` |
| Back/forward swipe shows Dia's frosted chip with a chevron (grows and ticks once letting go navigates) instead of Chrome's dark half-circle | 2026-11-10, `feat: dia swipe chip` |
| Arc's Tab to Search: the start of a site's name offers "Search YouTube  Tab" at the field's end; Tab scopes with a pill in the site's colour, a pulse of it and the row filled with it; Arc's built-in site searches (YouTube, Wikipedia, GitHub, Google Maps…) | 2026-11-10, `feat: arc tab to search` |
| Command bar: ↑ ↓ and Tab put the chosen row in the field (a search's query, a page's address; menu commands and settings keep what you typed), Escape brings back what you typed, typing goes on from the field (Known limitation 42) | 2026-11-10, `feat: bar arrows fill field` |
| Automatic picture in picture (Settings › Tabs, on by default): a playing video or a call pops out when you switch tabs or leave the window, and goes back when you return | 2026-11-10, `feat: auto picture in picture` |
| Settings' new look: rows on rounded cards (Dia's, Ardia's), a group's live picture across the top of its card instead of beside a row, a calmer segmented control and sidebar; Check Now beside the version in About Ray | 2026-11-10, `feat: settings cards look` |
| Asks to be the default browser: an onboarding step after the import ("Open links in Ray?") and a rare note at launch (bottom right, 14 days apart, 3 times at most, Never for good) | 2026-11-05, `feat: ask to be default browser` |
| Bookmarks: a panel from the sidebar's footer (⌥⌘B: search, folders in place, open, ⌘-click behind, Rename…, Delete with Undo, Add to Pinned, Open All), the menu bar's Bookmarks menu (Bookmark This Tab…, Bookmark All Tabs…, the bookmarks as menus), "Bookmark" rows in the command bar | 2026-11-05, `feat: bookmarks panel` |
| Link address on hover at the page's bottom left (above a download's note, aside from the pointer); a sound icon on tabs and favorites (click to mute); back/forward history lists on right-click or hold | 2026-11-05, `feat: link preview, tab sound, history lists` |
| Page prompts: Ray's own "Open “App”?" for links to other apps (replacing Chrome's dialog; Always allow syncs with Settings › Privacy), "Pop-up blocked" note with Open and Always Allow, a crashed page view with Reload (out of memory, keeps crashing; a tab killed while hidden reloads when shown), "Page not responding" (Wait / Exit Page), "Quit and cancel N downloads?"; fixed two tabs opened in front at once flipping forever (out of memory) | 2026-11-05, `feat: page prompts` |
| "Save address?", "Update address?" and "Save card?" after a form is sent (Not Now, Save); Settings › Autofill › Save and fill addresses / cards | 2026-11-05, `feat: autofill save prompts` |
| "Save password?" and "Update password?" after a sign-in (Never, Not Now, Save; username editable), "Password Saved" for a suggested one; Settings › Passwords › Offer to save passwords | 2026-11-05, `feat: save password prompt` |
| Arc's ⌃Tab switcher: recent tabs as cards with page pictures, switching on Control's release, Tab/⇧Tab/arrows/pointer, Escape cancels, a quick tap just switches | 2026-11-04, `feat: arc ctrl-tab switcher` |
| Ray's own engine (Phase B) and "Ray Safe Storage" | 2026-10-28, 0.2.0 |
| First installs without notarization: a DMG whose window shows the drag and the first open (Open Anyway), and a cask for the owner's tap (`brew install shanuflash/tap/ray`), both from `scripts/release.sh` | 2026-11-03, `feat: dmg and homebrew tap` |
| Notes: six spots on the page, one each, glass or solid (Settings › Appearance), the sidebar's spring; downloads note with progress | 2026-10-31, `cb92326` |
| Panels: one framework for site controls (with a "…" page), the notes' glass or solid look on prompts and downloads, Settings › Appearance › Panels and notes | 2026-10-31, `6a326c5` |
| Panels everywhere: sidebar sliders button (no puzzle menu), permission choices and Clear Site Data as pages, extension install and quit/close warnings as panel questions, folder icon picker on Panels, find bar on the shared surface; tab group push off Chrome's notification (crash) | 2026-10-31, `cd08553` |
| Command bar on the panels' surface and spring; downloads list as a panel from its button; Settings' Remove/Export confirms as panel questions | 2026-11-01, `3807f53` |
| Print (⌘P), Print Using System Dialog (⌥⌘P), Save Page As, Show Full History (⌘Y), Zoom In/Out/Actual Size, View Source (⌥⌘U), Task Manager, Clear Browsing Data (⇧⌘⌫) | 2026-10-29, `9c27c31` |
| Arc's zoom level note; print preview centred with rounded corners | 2026-10-29, `17dabae` |
| Import from Arc and other browsers (pinned, favorites, open tabs, history, bookmarks, passwords, cookies, autofill) and first-run onboarding | 2026-10-29, `0154dab` … `58611e6` |
| Command bar actions (Ray's menu commands by name, with shortcuts) | 2026-10-29, `893280a` |
| Address bar loading glow: one Dia sweep per navigation | 2026-10-29, `6b2f1e1` |
| One signing identity ("Ray Code Signing"): permissions kept across builds (the keychain still asks per build, Known limitations 18) | 2026-10-29, `ec95fc8` |
| Reopen closed tab (⇧⌘T) back in its sidebar place, History › Recently Closed, and in the command bar | 2026-10-29, `609d4b2`, `8850dd4` |
| Address shows `#fragment` and `view-source:` URLs; IDN hosts as punycode (no spoof checker yet) | 2026-10-29, `2512bed` |
| Command bar ranks your pages first like Arc, 5 rows, scroll to 10, never the active tab | 2026-10-29, `feat: command bar ranks pages like arc` |
| Ray as a web browser to macOS (pickable as the default browser): links and HTML/PDF files from other apps open as Today tabs, also when they launch Ray | 2026-10-29, `feat: ray can be the default browser` |
| Tab switch never flashes a blank page: the page left stays until the new one has drawn | 2026-10-29, `fix: no blank frame on tab switch` |
| Rename tabs (Rename… or a double click; kept over navigations and relaunches; Arc's names kept on import) | 2026-10-29, `feat: rename tabs` |
| Settings: one typed catalog for every setting (storage, observers, test command, check generated from it) | 2026-10-29, `414495a` |
| New Settings window (direction G): text sidebar with lavender wash, search with row flash, `ray://settings/<pane>`, "Settings: …" in the command bar, live pictures | 2026-10-29, `d88e0e3` |
| Extension popups draw on macOS 27 (a borderless window, not an NSPopover, which showed them plain white) | 2026-10-29, `fdc09cd` |
| Settings › General: Make Default strip, open at login, warn before ⌘Q and before closing a private window with tabs, start fresh, downloads folder, update switches, import | 2026-10-29, `25f0e1e` |
| Settings › Privacy (every site's permissions, zoom levels, apps sites may open, clear data) and › Extensions (switches, site access, private windows, options, reload, remove, load unpacked); Site controls in a private window no longer write to the normal profile | 2026-10-29, `0eaf904` |
| Settings › Passwords (locked behind Touch ID, search, show, copy, edit, add, delete, CSV import and export) and › Autofill (addresses, cards) | 2026-10-29, `d34b5c4` |
| Settings › Search: default engine, suggestions switch, site searches with a keyword and Tab in the command bar | 2026-10-29, `7d54ba9` |
| JumpCloud Go sign-in relayed through Google Chrome (Settings › Passwords; known limitation #15) | 2026-10-29, `0b6fb3f` |
| Settings: Light, Dark or Automatic (pages follow); scroll bars Automatic / When scrolling / Always (pages follow live); one address-bar-on-page setting for every window; show or hide the sidebar button; fade unloaded tabs; reorder haptic; ⌘Z reopens a closed tab outside text | 2026-10-29, `d2c6ed0` |
| Settings › Shortcuts: an editor for every menu command (record, conflicts with Replace, none, reset; macOS's keys refused; Quit and Settings locked); the command bar and reserved keys follow | 2026-10-29, `7f3b29d` |
| Folders in Today as Chrome tab groups (extensions like Claude's drive them; ungrouping, renaming, colours, collapse both ways), colours, Change Icon (Arc's panel), an animated folder icon, sliding moves, spring-loaded closed folders, Pin / Unpin Folder, Close Tabs; kept over relaunch | 2026-10-31, `e18f3c8` |
| Select several tabs (⌘-click, ⇧-click): New Folder with them, Add to Folder, Pin/Unpin, Copy Links (⇧⌘C), Close, drag together | 2026-10-31, `4e94dc3` |
| Arc's tab, favorite and folder menus: Copy Link, Share, Change Icon on tabs, Mute, Edit Pinned Page (Replace with Current, Edit…), Duplicate (tabs and folders), Move to, Remove Pin, Share Folder…, Copy All Links; Duplicate and Move to on a selection | 2026-11-03, `feat: arc row menus` |
