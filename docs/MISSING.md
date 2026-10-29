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
4. **Little Arc**: the small window for links opened from other apps (⌥⌘N).
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
8. Media controls in the sidebar (now playing, play/pause), and a sound icon and mute on tabs.
9. Automatic picture-in-picture when you switch away from a playing video (`setAutoPictureInPicture`).
10. Duplicate tab (`duplicateTab:profile:foreground:`).
11. Boosts: per-site CSS/JS, zapping elements.
12. Air Traffic Control: rules for which Space a link opens in (Cra's `LinkRouting`).
13. Capture (Arc's screenshot tool).
14. Easels, Notes, Library.
15. Sidebar on the right.
16. Sync between Macs.

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

**Default browser**
16. **Make Ray the default browser** from Ray: a "Default browser" row with a Make Default button in Settings, a step
    in the onboarding (after the import, "Open links from other apps in Ray?"), and a gentle note when Ray isn't the
    default (Chrome's infobar, Arc's prompt). Uses `NSWorkspace.setDefaultApplication(at:toOpenURLsWithScheme:)`,
    which shows macOS's own confirmation. Needs Ray to declare http/https and HTML first (in progress 2026-10-29).

**Already working through Chrome's defaults:** right-click menus, spell check, `chrome://` pages.

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
   test window lands on the visible desktop (also on older commits).
9. **Accent contrast elsewhere.** `ProfileColor.visible(on:)` keeps a black or white profile colour visible in the
   onboarding only; the sidebar selection and hover, loading glow, downloads ring, Settings' switches, command bar
   selection and site controls' "on" states would benefit too (owner to decide).

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
