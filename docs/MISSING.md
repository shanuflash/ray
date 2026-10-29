# What Ray still lacks

The gap list against Arc and against Chrome, kept current. The owner picks the order; PLAN.md's roadmap says what
comes first overall. When something lands, move it to "Done" with the date and the commit or release.

Built from Ray's code and the engine's API (`engine/raycore/src/ray/core/public/RayCore.h`, the `ac_*` calls): what
Arc has that Ray doesn't, and what Chromium offers that Ray never wired up. Items marked (?) depend on what the
engine does when Ray has no UI of its own for them, and haven't been tried by hand.

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
17. **Make Ray the default browser** from Ray: a "Default browser" row with a Make Default button in Settings, a step
    in the onboarding (after the import, "Open links from other apps in Ray?"), and a gentle note when Ray isn't the
    default (Chrome's infobar, Arc's prompt). Uses `NSWorkspace.setDefaultApplication(at:toOpenURLsWithScheme:)`,
    which shows macOS's own confirmation. Ray already declares http/https and HTML and opens their links, so it
    can be picked in System Settings meanwhile.

**Already working through Chrome's defaults:** right-click menus, spell check, `chrome://` pages.

## From Ardia's settings

Gone through Ardia 0.2.42's Settings window pane by pane (2026-10-29); what it offers that Ray doesn't, beyond the
items above. The revamp that gives these a home is PLAN.md section 13.

**Big**
1. **Choosing a search engine**: Ray searches a fixed Google. Missing the engine list with Make Default, custom site
   searches (type a keyword, press Tab in the command bar) and a search suggestions switch. The engine has
   `ac_search_engines`; `/search` is trimmed from Chrome's settings today.
2. **Live Folders** (Arc had them): folders that refresh on their own, GitHub/Bitbucket pull requests,
   Notion/Confluence/Google Drive documents.
3. **Live Calendar** (Arc's calendar preview): hover a pinned calendar tab to see the day, a badge counting down to
   the next meeting, an alert with a Join button.
4. **Shortcut editor**: change any menu shortcut, search actions, Reset All.
5. **Theme as a gradient** (Arc's Space themes): several colours, intensity, grain, direction. Ray has one accent
   colour. Belongs with Spaces.
6. **Native data screens**: every site's permissions, zoom levels and "apps allowed to open links" in one list with
   Clear Site Data (Ray has only the per-site panel); passwords behind Touch ID with CSV import/export; addresses and
   cards; an Extensions screen (toggles, details, site access, add from a store link, load unpacked). The engine
   has `ac_site_settings`, `ac_passwords`, `ac_reauth`, `ac_autofill_edit`, `ac_extensions`, `ac_browsing_data`.

**Smaller**
7. Where new tabs go (top, bottom, next to current) and where the New Tab button sits (Ray has one switch).
8. Open at login.
9. Warn before quitting with ⌘Q, and before closing a window with several tabs.
10. On quit: keep tabs and windows, or start fresh.
11. Light, Dark or Automatic for Ray's own chrome (Ray follows macOS only).
12. Alternate app icons: a few need designing first.
13. Hide the address bar above the page (View › Show Address Bar on Page) while scrolling down: it tucks into a
    thin strip with the site's name; scrolling up or clicking the strip brings it back.
14. Show or hide the sidebar button, and Arc's "Clear" button between pinned tabs and Today (Ray has no such
    button yet; Clear Today's Tabs is only in the File menu and the command bar).
15. ⌘Z reopens a closed tab outside text fields, as in Arc.
16. Fade the icons of unloaded tabs.
17. Haptic bump when reordering tabs.
18. Thin scroll bars.
19. Updates as Settings rows: check automatically, install automatically, Stable or Nightly, version, Check Now
    (Ray has the menu item only).
20. Downloads folder and "ask where to save" in Ray's Settings (only on Chrome's page today).
21. Battery saver.
22. Memory Saver rows: on/off, Moderate / Balanced / Maximum, "Always keep these sites active" (Ardia's Settings ›
    Advanced › Performance, through the engine's `ac_memory_saver` from engine-2f172eb50b89). Today only on
    chrome://settings/performance, and off by default (see Known limitations).
23. Compact toolbar: the address bar above the page at 28 pt instead of 41, so a 16:9 video in web full screen
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

## Done

| What | When |
|---|---|
| Ray's own engine (Phase B) and "Ray Safe Storage" | 2026-10-28, 0.2.0 |
| Print (⌘P), Print Using System Dialog (⌥⌘P), Save Page As, Show Full History (⌘Y), Zoom In/Out/Actual Size, View Source (⌥⌘U), Task Manager, Clear Browsing Data (⇧⌘⌫) | 2026-10-29, `9c27c31` |
| Arc's zoom level note; print preview centred with rounded corners | 2026-10-29, `17dabae` |
| Import from Arc and other browsers (pinned, favorites, open tabs, history, bookmarks, passwords, cookies, autofill) and first-run onboarding | 2026-10-29, `0154dab` … `58611e6` |
| Command bar actions (Ray's menu commands by name, with shortcuts) | 2026-10-29, `893280a` |
| Address bar loading glow: one Dia sweep per navigation | 2026-10-29, `6b2f1e1` |
| One signing identity ("Ray Code Signing"): no keychain prompt on every build | 2026-10-29, `ec95fc8` |
| Reopen closed tab (⇧⌘T) back in its sidebar place, History › Recently Closed, and in the command bar | 2026-10-29, `609d4b2`, `8850dd4` |
| Address shows `#fragment` and `view-source:` URLs; IDN hosts as punycode (no spoof checker yet) | 2026-10-29, `2512bed` |
| Command bar ranks your pages first like Arc, 5 rows, scroll to 10, never the active tab | 2026-10-29, `feat: command bar ranks pages like arc` |
| Ray as a web browser to macOS (pickable as the default browser): links and HTML/PDF files from other apps open as Today tabs, also when they launch Ray | 2026-10-29, `feat: ray can be the default browser` |
| Tab switch never flashes a blank page: the page left stays until the new one has drawn | 2026-10-29, `fix: no blank frame on tab switch` |
