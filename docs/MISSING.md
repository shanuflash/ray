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

**Already working through Chrome's defaults:** right-click menus, spell check, `chrome://` pages.

## Done

| What | When |
|---|---|
| Ray's own engine (Phase B) and "Ray Safe Storage" | 2026-10-28, 0.2.0 |
| Print (⌘P), Print Using System Dialog (⌥⌘P), Save Page As, Show Full History (⌘Y), Zoom In/Out/Actual Size, View Source (⌥⌘U), Task Manager, Clear Browsing Data (⇧⌘⌫) | 2026-10-29, `9c27c31` |
| Arc's zoom level note; print preview centred with rounded corners | 2026-10-29, `17dabae` |
| Import from Arc and other browsers (pinned, favorites, open tabs, history, bookmarks, passwords, cookies, autofill) and first-run onboarding | 2026-10-29, `0154dab` … `58611e6` |
| Command bar actions (Ray's menu commands by name, with shortcuts) | 2026-10-29, `893280a` |
| Address bar loading glow: one Dia sweep per navigation | 2026-10-29, `6b2f1e1` |
