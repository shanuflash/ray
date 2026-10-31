# What Ray still lacks

The gap list against Arc and against Chrome, kept current. The owner picks the order; PLAN.md's roadmap says what
comes first overall. When something lands, move it to "Done" with the date and the commit or release.

Built from Ray's code and the engine's API (`engine/raycore/src/ray/core/public/RayCore.h`, the `ac_*` calls): what
Arc has that Ray doesn't, and what Chromium offers that Ray never wired up. Items marked (?) depend on what the
engine does when Ray has no UI of its own for them, and haven't been tried by hand.

## Top priority (owner)

1. **Tab groups for extensions** (owner, 2026-10-29): the Claude browser extension (and others) put the tabs they
   drive into a Chrome tab group (`chrome.tabGroups`); Arc has no tab groups, so Claude's browser use fails there.
   Check whether Ray's engine (Chrome's tab strip underneath, Ardia's layer) supports groups end to end, make the
   API work, and show a group in Ray's sidebar (its colour and name over its tabs). Test with the Claude extension.
2. **Select several tabs** (owner, 2026-10-29): ⌘-click adds or removes a tab, ⇧-click selects a range, as in Arc.
   On a selection: ⇧⌘C copies all their links (one per line), right-click › Duplicate (needs Duplicate tab, item
   10 below), New Folder with them, drag them together; Split View with them once it exists. Waiting for the owner's
   go (other sessions first).

## Arc features Ray doesn't have

**Big**
1. **Spaces**: separate sidebars per context, two-finger swipe between them, a colour or gradient per Space.
   Roadmap item 2. Cra (`third_party/cra`) has a model worth copying; its views are SwiftUI, so Ray's are rebuilt in
   AppKit.
2. **Profiles**: several logins (Arc ties a profile to a Space). Ray has one profile; the engine has
   `loadProfile`/`offTheRecordProfileFor`.
3. **Split View**: two or more pages side by side in one window.
4. **Little Arc**: the small window for links opened from other apps (⌥⌘N). Links from other apps would open there;
   today they open as a Today tab in the normal window (`Host/LinksFromApps.swift`).
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
8. Media controls in the sidebar (now playing, play/pause), and a sound icon and mute on tabs. Mute the tab only
   (Chrome's per-tab mute, kept across navigation); Mute Site as its own choice behind ⌥ (Ardia 0.2.43-nightly.4
   moved to this after a site-wide mute surprised users; `docs/ARDIA-WATCH.md`).
9. Automatic picture-in-picture when you switch away from a playing video (`setAutoPictureInPicture`).
10. Duplicate tab (`duplicateTab:profile:foreground:`).
11. Boosts: per-site CSS/JS, zapping elements.
12. Air Traffic Control: rules for which Space a link opens in (Cra's `LinkRouting`).
13. Capture (Arc's screenshot tool).
14. Easels, Notes, Library.
15. Sidebar on the right.
16. Sync between Macs.
17. Collapse the pinned section: a "Pinned" toggle on the divider above Today; collapsed, only the entry holding
    the active tab shows (Ardia 0.2.43-nightly.4, its most-asked issue).

**Left out on purpose:** Arc Max's AI features.

## Chrome features not wired in Ray

**Menus**
1. Bookmarks UI: ⌘D pins; imported bookmarks live in Chrome's model (`chrome://bookmarks`), with no Ray view.

**Prompts the engine asks Ray to show (delegate hooks Ray doesn't implement)**
2. Passwords: the "save password?" prompt, the fill dropdown, password generation (`passwordSavePromptForTab`,
   `passwordPrompt`, `didShowAutofillSuggestions`).
3. Autofill for addresses and cards (`autofillPrompt`, `showAutofillSuggestions`).
4. Links that open other apps: `mailto:`, Zoom, Slack… (`externalAppRequest`) (?).
5. Device pickers: WebUSB, Bluetooth, HID, Serial (`deviceChooser`); requests get nothing.
6. Screen-share picker (`allowDesktopCapture`, "share this tab instead").
7. Cast (`castDialog`, `castRoutes`).
8. A note when a popup is blocked, with "always allow" (`didBlockPopup`, `openBlockedPopup`).
9. Crashed tab page and the "page unresponsive" dialog (`rendererGone`, `tabBecameUnresponsive`).
10. Warning on quit while downloads run (`confirmCloseWithDownloads`).

**Page and tab details**
11. Link preview at the bottom corner on hover (`didChangeStatusText`).
12. Tab state: sound/mute (`tabDidChangeAudio`), put to sleep (`tabDidChangeDiscarded`), the site's theme colour.
13. Extension side panels and extension keyboard shortcuts (`extensionSidePanel`, `extensionActionShortcut`).
14. Installing imported extensions: the engine's `ac_extensions_install` takes a folder or a .crx, not a Web Store id.
15. Web notifications: from the engine's alerts helper, not checked (?).
16. Install an extension by dropping a .crx on the window, "Allow User Scripts" per extension (Tampermonkey and
    other userscript managers), and Export Bookmarks as HTML. The engine calls come with Ardia's
    engine-2f172eb50b89 (`ac_extension_drop.mm` and the `engine:extensionInstallFailed:tab:` delegate,
    `ac_extensions_configure` `userScripts`, `ac_bookmarks_export_html`); Ray needs the sync and the UI.

**Default browser**
17. **Ask to be the default browser** outside Settings: a step in the onboarding (after the import, "Open links from
    other apps in Ray?") and a gentle note when Ray isn't the default (Chrome's infobar, Arc's prompt). Settings ›
    General's Make Default strip is done (`NSWorkspace.setDefaultApplication`, macOS's own confirmation).

**Already working through Chrome's defaults:** right-click menus, spell check, `chrome://` pages.

## From Ardia's settings

Gone through Ardia 0.2.42's Settings window pane by pane (2026-10-29); what it offers that Ray doesn't, beyond the
items above. The revamp that gives these a home is PLAN.md section 13.

**Big**
1. **Live Folders** (Arc had them): folders that refresh on their own, GitHub/Bitbucket pull requests,
   Notion/Confluence/Google Drive documents.
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
tab groups and meeting groups (Arc has none), video upscaling, crash reports and usage stats; a choice of when
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
    `https://sso.jumpcloud.com/` + `redirectTo` instead, since the login page doesn't forward an existing session). If headless doesn't sign in within 10 s it starts again in a small visible
    Chrome window (in full screen, Ray shows "Finish signing in to JumpCloud in Chrome" with a button instead of
    switching Spaces). Set Up… installs the extension into that profile once. The owner's company sign-in worked
    end to end on 2026-10-29 with the visible window (JumpCloud Go finishes by itself, no Touch ID); the headless
    run still needs its real try (the native host's parent check should see the same signed Chrome executable).
    Follow-ups: the relay clears all of jumpcloud.com's site data in Ray before importing (the engine's
    `ac_cookies_import` keeps cookies Ray already has, and `ac_site_data_clear` is the only delete); the visible
    fallback still shows a second Google Chrome in the Dock while it runs; a Chrome policy that turns off remote
    debugging (`RemoteDebuggingAllowed`) makes it say Chrome didn't answer, and one that turns off headless mode
    (`HeadlessMode`) costs a fallback. Real fix: Developer ID signing (roadmap step 4),
    settle the bundle id, then ask JumpCloud to add Ray's identifier and team to the host's list. Found 2026-10-29.
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
    (Developer ID, roadmap step 4; or the owner's Apple Development certificate for their own builds), then one last
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
    hand; "Offer to save passwords" and "Save and fill addresses/cards" stay unbuilt until Ray has the prompts
    (Chrome features #2, #3).
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
    passwords (two new patches). Fix: take that engine (`docs/ARDIA-WATCH.md` item 2). Found 2026-10-30.

## Done

| What | When |
|---|---|
| Ray's own engine (Phase B) and "Ray Safe Storage" | 2026-10-28, 0.2.0 |
| Notes: six spots on the page, one each, glass or solid (Settings › Appearance), the sidebar's spring; downloads note with progress | 2026-10-31, toast-revamp |
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
