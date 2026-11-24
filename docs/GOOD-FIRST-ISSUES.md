# Good first issues

Small, well-scoped tasks from [MISSING.md](MISSING.md)'s "Known limitations" (the number in brackets). Each is a
few files in `Host/` or `tests/`, needs no engine build beyond the one you build Ray with, and ends with a check.
Read [CONTRIBUTING.md](../CONTRIBUTING.md) first. When one lands, move it to MISSING.md's "Done" table and take it
off this list.

## Tests

### 1. Test logging survives a closed pipe [25]
`FileHandle.standardError.write(_:)` raises when the reader has gone, which crashed a hidden test instance in
`logState`. Switch to the non-throwing `write(contentsOf:)` (`try?`).
- `Host/main.swift`, `Host/TestEnvironment.swift`, `Host/TestCommands.swift`, `Host/SettingsDataViews.swift`,
  `Host/BrowserWindowController.swift` (`logState`)
- Done when: `grep -rn "standardError.write(" Host` finds none; `scripts/test.sh --changed` passes.

### 2. Check: ⌘W on the last Today tab keeps the window [28]
The code already keeps the window when only pinned tabs or favorites are left (`activateNeighbor` → `showNothing`);
a second ⌘W closes it. Nothing checks it.
- `tests/checks.mjs` (a new check), `tests/affected.mjs` (its entry)
- Done when: the check fails if the first ⌘W closes the window.

### 3. Check: a press alone switches tabs [61]
`SidebarRowView.mouseDown` and the favorite tile switch on the press, as Chrome and Arc do. Nothing checks that a
press without a release switches.
- `tests/checks.mjs`, `tests/affected.mjs`, maybe a `rowpress <id>` test command in `Host/TestCommands.swift`
- Done when: the check fails if switching moves to `mouseUp`.

## Sidebar and tabs

### 4. ⇧⌘T puts a Today tab back in its folder [30]
`ClosedTab` keeps `parentID`, but `reopen` uses it only for pinned tabs, so a Today tab comes back outside its
folder. Put it back in the folder if the folder still exists.
- `Host/BrowserWindowController.swift` (`reopen(_:shows:)`), `Host/ClosedTabs.swift`
- Done when: `reopen-closed-tab` (or a new check) covers a tab closed from a Today folder.

### 5. Middle-click a favorite unloads it [73]
A middle click on a row closes a Today tab or unloads a pinned one; `FavoriteTileView` has no `otherMouseDown`, so a
favorite ignores it. Do what a pinned row does.
- `Host/SidebarView.swift` (`FavoriteTileView`, the row's middle-click code to reuse)
- Done when: a check middle-clicks a loaded favorite and it unloads but stays a favorite.

### 6. "Double-click to rename" hint [16]
Arc's row tip says "Double-click to rename" once; Ray's tooltip is only the title. Show the hint the first time,
then never again (a Settings.json state field, as `onboarded`).
- `Host/SidebarView.swift` (the row's `toolTip`), `Host/RaySettings.swift`
- Done when: the state log shows the hint on the first row and not after; Settings.json remembers it.

### 7. Clear Today keeps the whole batch for ⇧⌘T [73]
`ClosedTabs.limit` is 25, so clearing 40 Today tabs loses the oldest 15 for ⇧⌘T and ⌘Z. A single batch should be
kept whole (or counted as one).
- `Host/ClosedTabs.swift` (`limit`, the trim in `record`, `takeNext(inBatch:)`)
- Done when: `clear-today-keeps-current` (or a new check) clears 30 tabs and ⇧⌘T brings all 30 back.

### 8. Peek only while Ray is in front [33]
With the sidebar hidden, hovering the window's left edge while another app is in front likely slides the sidebar
out. Peek only while Ray is active; a hover from the background opens when Ray comes forward with the pointer still
there (Ardia's fix, its issue #698).
- `Host/BrowserWindowController.swift` (`pointer(at:appActive:)`, the peek code)
- Done when: `peek-zones` covers `appActive` false.

## Copy and keys

### 9. ⇧⌘C strips trackers [73]
Arc and Ardia copy the URL without tracking parameters (`utm_*`, `fbclid`, `gclid`…). Ray copies it raw. Add a
pure function in `AddressInput` and use it for Copy URL, Copy Links and Copy URL as Markdown.
- `Host/AddressInput.swift`, `Host/BrowserWindowController.swift` (`copyURL`, `copyLinks`, `copyURLAsMarkdown`),
  `tests/AddressInputTests.swift`
- Done when: unit tests cover which parameters go, which stay, and a URL with nothing to strip is unchanged.

### 10. Developer Tools is a reserved key [14]
A page that cancels keydown can keep ⌥⌘I from Ray. Add Developer Tools to the reserved commands, as Helium does.
- `Host/MenuShortcuts.swift` (`reservedIDs`)
- Done when: the state log's `shortcuts.reserved` lists ⌥⌘I and a check confirms it.

## Engine-facing, app-side

### 11. Pages and extensions in your Mac's language [12]
Chrome takes its UI language from the app bundle's localizations, and Ray declares none, so chrome:// pages and
extensions' `chrome.i18n` likely run in English. Declare Chromium's 55 desktop locales in `CFBundleLocalizations`.
Ray's own UI stays English.
- `scripts/build-app.sh` (Info.plist)
- Done when: `build/Ray.app`'s Info.plist lists them; tried by hand with another macOS language.

### 12. No "Cancelled" row after a cancelled Save As [13]
`Downloads` lists Chrome's item before the save panel gives it a path, so cancelling the panel leaves a
"Cancelled" row (Ardia fixed the same). List a download once it has a path; drop one cancelled before it had one.
- `Host/Downloads.swift`
- Done when: tried by hand (File › Save Page As…, Cancel) and covered by the downloads checks' state.

### 13. Video upscaling off while sharing a tab [67]
Ray's engine upscales video by default; in Ardia, upscaling in a shared tab turned Meet's preview black. Turn it off
with `RayCoreEngine.setVideoUpscaling(false)` while `ScreenShares` has a share, back on after.
- `Host/ScreenShare.swift` (`ScreenShares`), `engine/raycore/src/ray/core/public/RayCore.h` (read only)
- Done when: `screen-share` checks the state log says upscaling is off during a share and on after.

### 14. macOS 27: the green button's menu doesn't crash [39]
macOS 27's NSMenu no longer implements `submenuAction:`, which a submenu's parent item targets (Move & Resize, Fill &
Arrange). At launch, add an empty `submenuAction:` to NSMenu when it's missing (Ardia `9e5b115b`).
- `Host/AppController.swift` (launch), or `Host/main.swift`
- Done when: a check confirms `NSMenu` responds to `submenuAction:`; tried by hand on macOS 27.
