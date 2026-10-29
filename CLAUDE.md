# Ray

A macOS (14+, Apple Silicon) Chromium browser with Arc's sidebar, pinned tabs and pinned tiles. Native AppKit +
Core Animation UI on Ardia's engine. `PLAN.md` is the plan and the source of truth for decisions.

**Before any work, read PLAN.md's "Goal and roadmap" and "Open decisions (owner)" and keep them in mind:** the most
Arc-feeling browser on real, de-Googled Chromium for Mac, launching into Arc's shutdown on 2026-12-22.
`docs/MISSING.md` is the gap list against Arc and Chrome, plus "Known limitations and follow-ups" (smaller gaps found
while building). When a feature lands, move it to its "Done" table; when you find a limitation, add it there. When the
owner asks what's pending or missing, answer from this file. Weigh every
choice against Arc's feel, real Chromium with working extensions, and painless switching from Arc. Never post
publicly or create accounts.

## Layout
- `Host/`: the native app in Swift + AppKit. `Bridging.h` exposes the engine API. `BrowserWindowController` owns a
  window's tabs; `SidebarView` is the address field and tab list; `PageContainerView` shows one page at a time
  (others stay attached but hidden, with `noteShown(byHost:)`); `MainMenu` + `Shortcuts` do key routing.
  A tab switch never shows a blank frame: the page left stays on screen until the new one's first frame
  (`PageFrameWatch`: Chrome adds a new content layer under the render view when the page's new compositor delivers
  one). The new page goes on top (`sortSubviews`) at alpha 0 and turns opaque in that same commit; the old one is
  hidden a display frame later. A 0.3 s deadline if no frame comes; no hold when the window isn't on screen.
- `CommandBarView` + `Suggestions`: the Arc-style command bar (⌘T new tab, ⌘L / clicking the sidebar address =
  current tab). Rows: autocompleted host match, typed URL or search, open tabs ("Switch to Tab"), history, and
  `BarActions`: menu commands read from the main menu (Ray's own items, validated as the menu does), matched by word
  starts of their title or synonyms, with the live key equivalent; an exact name leads unless a host autocompletes.
  Then "Settings: …" rows (`SettingsSearch.barMatches`, matched the same way: each shown setting, section and pane,
  at most 2), which open the Settings window at that row and flash it; one leads only when named in full after
  "settings" with no host, command or page matching (check `settings-bar`). Ranking is Arc's: when nothing else leads, a page you go to leads over the typed search (Enter opens it): only for a
  search, from 3 characters, every word at a word start of its title or address, frecency ≥ 1.5 (Chromium's
  HistoryQuick: last 10 visits, each worth its recency; an open tab adds 1), never a search results page. Then the
  typed row, actions, settings, the other pages by match + frecency, and search suggestions last, only to fill the 5 shown rows
  (2 at most). The bar shows 5 rows and scrolls to 10 (overlay scroller). This window's active tab is never offered
  (nor its page as history); another tab on the same address is. Page rows: title, then `Suggestions.shortAddress`
  (host, "…", the path's last ~16 characters; a long host loses its start instead). Check `bar-ranking`.
- `PageToolbar`: Dia's address bar above the page (View › Show Address Bar on Page). Geometry is Ardia's
  (`third_party/ardia/apps/browser/src/components/ui/theme.ts` `layout`, `components/toolbar/Toolbar.tsx`): 41 pt,
  buttons centred at 21/56/92/127, address from 145; the host in medium weight, then path and query in grey
  (View › Show Full Address, the same setting as Settings › Minimal URL, inverted; minimal shows them on hover). The sidebar/back/forward/reload
  buttons ride the sidebar's dock spring in while the sidebar is hidden. Its sliders button opens `SiteControls`:
  quick actions, extension tiles, the site's permissions (`ac_site_settings_*`, keyed by the tab's
  `committedOrigin`) and the connection state.
- `ConnectionLook` (in `AddressInput.swift`): the security icon for both address fields and the panel's footer.
- `ProfileColor`: the profile's colour, which every accent in Ray's UI uses (loading wash, progress, drop targets,
  selection, "on" states, Settings' switches). Default: Dia's lavender; Settings › Theme sets it (`apply(hex:)`,
  posts `didChange`, and each window redraws its views and re-tints the wash, page line and downloads ring).
  `foreground(on:)` is the white or black with the higher WCAG contrast on a fill: use it for any text or icon on an
  accent fill. `legible(color, on:)` moves any (tint of the) colour just far enough to read on a background, and
  `mix(a, over: b, light, dark:)` is a solid wash; both resolve when drawn, so they follow the setting and the
  appearance. Never use `NSColor.controlAccentColor` (`scripts/test.sh` fails on it).
- `SettingsCatalog`: every setting as one typed entry, `SettingKey<Value>` (a `static let` on `AnySettingKey`, named
  in its `all` list): id (also its Settings.json key and the test command's name; a rename goes through `aliases`),
  default, `validate` (clamp or refuse), scope (app; profile and Space later), `built` (an unbuilt one's row shows only
  in test builds), and its UI: pane, group, title, detail, search keywords, control (toggle, choice as a pop-up,
  `segmented` for 2–3 options, `picture` options drawn by a view builder, colour, custom) and `rare` (under its group's
  "More" line). Values are `SettingValue`s: Bool, Double, Int, String, String?. The window's rows, its search, the
  command bar's "Settings: …" rows, `setting <id> <value>`, `settings catalog` and the state log's `settings` dump
  are generated from it. `SettingPane` (same file) lists the panes in sidebar order with title, subtitle, SF Symbol
  and sidebar section (top, "Your data", "More"); `isShown` hides a pane with no shown row and no content of its own,
  in Ray.app only. **Adding a setting:** one entry plus its name in `all`, then the feature reads
  `RaySettings.shared[.id]` (and `observe(.id)` if it follows changes); `settings-catalog` covers it with no check
  code. `appearanceMode` and `scrollBars` are unbuilt (test builds only) and exercise the picture and segmented
  controls.
- `RaySettings`: the settings' values. `shared[.key]` reads, `set(.key, value)` writes, `apply(key, text)` (`default`
  resets any setting) is the one call the window's controls and the test command `setting` both make, and
  `observe(.key) { value in … }` / `observe([keys]) { … }` follow changes (main thread, once per run-loop turn, for as
  long as the returned `SettingsObservation` is kept). `Settings.json` in the data dir next to `Sidebar.json` is a
  dictionary (saved 0.2 s after a change and on quit, sorted keys): a missing or invalid value loads as its default,
  and keys this build doesn't know are written back as they were. Also holds Ray's own state there as typed fields,
  not settings: the hosts the user zoomed (see Page zoom below), `zoomAdopted`, the Settings window's frame and
  `onboarded`. Private windows read it, never write to it (their zoomed hosts stay in memory).
- `SettingsWindow`: Ray's own Settings window, direction G (PLAN.md §13): ⌘, (the pane last shown, else General),
  `ray://settings/<pane>`, or a command bar row. 780×560, full-size content, the traffic lights over a 210 pt
  sidebar in Ray's sidebar colour: a search field, the panes as 34 pt rows (icon and name; the selected one in
  `SettingsColors.selectedFill`/`selectedInk`, a wash and a legible tint of the profile's colour), and "All Chrome
  Settings…" (chrome://settings) at the bottom. Searching (`SettingsSearch`, after Ardia's `searchMatch.ts`: titles,
  details, keywords, groups and pane names) replaces the pane list; ↑ ↓ ⏎ and Escape work, and choosing a result
  opens its pane, scrolls to its row and flashes it (`SettingsFlash`: 120 ms in, 900 ms held, 700 ms out, on a
  layer). `SettingsPaneView` is one pane: title (22 pt), a grey subtitle, an optional call-to-action strip, then
  groups (13 pt semibold headers with room for one trailing control, 44 pt rows split by hairlines, no boxes, rare
  rows under "More") in a column of at most 600 pt with 24 pt sides, scrolling with an overlay scroller.
  `SettingsControls`: `RaySwitch`, `RaySegmentedControl`, `PictureChoiceControl` (2.5 pt ring and a check, in the
  profile's colour), `SwatchRow`, `SettingsCallToAction` (General's Make Default; a hidden one takes no room), `AccentButton`, `LinkButton`.
  `MiniRayWindow`: a tiny layer-drawn Ray window (sidebar rows, one active or new, the page with or without its
  address bar, light or dark) for live pictures (`SettingsLivePicture`, beside the minimal URL and new-tab rows) and
  picture choices. **Pane content:** `SettingsPanes.swift` defines `SettingsPaneContent` (sections placed top, after
  a group or bottom, with search entries; a call to action; header controls; `.custom` controls; row pictures) and
  the registry `SettingsPanes.make(_:)`. **Adding a pane's own UI:** one new file (`Host/SettingsPrivacy.swift`,
  a class conforming to `SettingsPaneContent`) plus its line in the registry, and its `ray://settings/<pane>` line
  in `AddressInput.nativeSettingsPaths` once it replaces Chrome's page; the window's layout code doesn't change
  (example: `SettingsAbout.swift`). `AddressInput.nativeSettingsPane(for:)` recognises the Appearance address (and
  Profiles) plus General, Tabs, Shortcuts and About: typed or chosen ones open the window and never load; Chrome's
  page navigating itself there goes back. Privacy, Extensions and Search stay Chrome's pages until their panes
  land; Passwords and Autofill are Ray's (below).
  Settings that act elsewhere: minimal URL and loading progress (`PageToolbar`, `PageContainerView.showsProgress`),
  new tab position (`insertToday`), ⌃Tab in recent order (`cycleTabWithControl`, settled by a `flagsChanged` monitor
  when Control is released), ⇧⌘C and ⌘S (`MainMenu.applyShortcutSettings` removes their key equivalents so the page
  gets the keys), and page zoom.
- `SettingsGeneral` (Settings › General): the "Make Ray your default browser" strip (`NSWorkspace.setDefaultApplication`
  for http then https, macOS's own confirmation; hidden while Ray is the default), Open Ray at login
  (`SMAppService.mainApp`, its real status, "approval" included), the catalog's quitting group (`warnBeforeQuitting`
  off, `warnBeforeClosingWindow` on, `onQuit` keep/fresh), Downloads (`ac_downloads_settings`/`_set_settings`: folder
  with Change…, ask where to save), Updates (Sparkle's `SPUUpdater` switches and Check Now via `Updater.updater`;
  without an updater only the version; `SUAutomaticallyUpdate` in Info.plist makes install-automatically default on)
  and Import… (File › Import from Browser…). `GeneralSystem` re-reads on activation; in test builds the default
  browser, login item and updater are fakes (`general …` test commands; checks never touch the real ones).
  `CloseWarnings`: ⌘Q's "Quit Ray?" sheet (⌘Q again quits; menu Quit only, never Dock/logout/update quits) and the
  close sheet for a window that would lose 2+ tabs (only private windows: the normal one keeps its tabs for ⌘N), each
  with "Don't ask again"; test command `warning confirm|suppress|cancel`. Start fresh: the launch's first normal
  window drops last time's Today tabs into Recently Closed (`startFresh`, `restore(fresh:)`). Checks
  `settings-general`, `warn-before-quitting` (own instances; also Start fresh), `warn-before-closing-window`.
- `SettingsPrivacy` (Settings › Privacy, the normal profile's only, never a private window's): sites with a permission
  of their own (`ac_site_settings_origins` + `_get`, sorted by registrable domain; a row opens to each permission's
  pop-up, Reset Permissions and Clear Site Data…), the sites you zoomed (`RaySettings.zoomedHosts` with
  `ac_zoom_list` levels; Reset un-marks the host and sets the default with `ac_zoom_set`, as Site controls' does),
  apps sites may open (`ac_external_apps_*`), Clear browsing data (Chrome's dialog) and, under More, Chrome's
  per-category defaults. Follows `siteSettings.changed` / `zoom.changed`. Chrome's Site settings pages
  (`/content`, `/content/all`, `/content/siteDetails`, `/content/zoomLevels`) and `ray://settings/privacy`
  (`AddressInput.raySettingsAliases`: Chrome's `/privacy` page stays Chrome's) open it; Site controls' Site
  Settings… opens it at the site. `SettingsExtensions` (Settings › Extensions): `ac_extensions_list` rows (manifest
  icon, version, description, switch) that open to site access, private windows, Options, Reload (unpacked),
  Remove…; the Web Store; Load unpacked under More; Add from a link unbuilt (test builds only).
  `ray://settings/extensions` opens it; chrome://extensions stays Chrome's. `SettingsDataRows`: what both share
  (`SettingsDynamicList`, `SettingsItemRow`, `SettingsConfirm`: Cancel by default, the action dead for 0.5 s, the
  full origin or the extension's ID; `SettingsPages.open` uses the normal window). Test commands `privacy …` and
  `extpane …` answer with the pane's lists as JSON and press its controls (checks `settings-privacy`,
  `settings-extensions`).
- Settings › Passwords (`SettingsPasswords.swift`) and › Autofill (`SettingsAutofill.swift`), on the engine's
  `ac_passwords_*` and `ac_autofill_*` calls; `SettingsDataViews.swift` holds their pieces (`SettingsStack`, item rows,
  inline cards and forms, `SettingsConfirm` sheets, `SettingsPasteboard`, `SecretJSON`, `SettingsDataGuard`).
  Passwords: locked until Unlock (`ac_passwords_unlock`, the engine's Touch ID or login password, `ac_reauth.cc`);
  `SettingsDataGuard` locks it (and hides a shown card number) when the Settings window closes, after 5 min without a
  click or key in it (Chrome's `kPasswordManagerAuthValidity`), on sleep or a user switch. Unlocked: search, a row
  opens its details (show/copy through `ac_passwords_reveal`, edit through `ac_passwords_update`, both re-authing per
  the engine; delete after a sheet), Add…, Never saved; under More, CSV import (the importer's `PasswordsCSV` +
  `ac_passwords_add`) and Export… (a warning, a save panel, `ac_passwords_export`, which always re-auths). A copied
  password or card number is concealed (`org.nspasteboard.ConcealedType`) and cleared after 120 s if unchanged
  (Chrome's `kClipboardClearDelay`). Autofill: addresses (edit inline, country by name or code) and cards (number
  shown only through `ac_autofill_card_number`'s re-auth, Luhn-checked on add). Secrets go to the engine only as
  `SecretJSON` through `EngineCalls.callWithSecret`; the state log (`passwordsPane`, `autofillPane`) has counts and
  ids, and its `pasteboard` says `<concealed>` for them. "Offer to save passwords" and "Save and fill
  addresses/cards" are unbuilt (no prompts yet). Routes: chrome://settings/passwords, /autofill, /addresses,
  /payments and chrome://password-manager (any path; `AddressInput.nativePages`). Checks `settings-passwords`,
  `settings-autofill`.
- Page zoom: the engine keeps zoom per host and `tab.zoomFactor = x` writes that host's level, so Ray applies the
  default zoom itself: on a committed navigation (next run-loop turn, after the engine's own zoom) to a host the user
  hasn't zoomed, and on every tab when the default changes. `tabDidChangeZoom` on a settled host that isn't the
  default marks the host as user-zoomed (⌘+ / ⌘−); levels already in the engine's host map at first launch are
  adopted as the user's (`ac_zoom_list`, once). Site controls' Reset un-marks the host. `LoadingTint` uses Dia's measured lilac-to-lavender
  ramp for the default and builds the same shape around any other colour.
- `EngineCalls`: calls the engine's exported `ac_*` C functions (`dlsym`, JSON in, JSON reply), e.g.
  `ac_history_query`. Their arguments are in `third_party/ardia/engine/chromium/src/chrome/browser/ardia/ac_*.cc`.
  `EngineEvents` is the one engine event sink (`downloads.changed`, …), handed out by topic.
- Pinned folders are `SidebarEntry`s of kind `.folder` inside `state.pinned`, kept in tree order with `parentID`
  links; `SidebarState.normalizePinned()` rebuilds a valid tree after every change and on load.
- Tab names (Arc's Rename): `SidebarEntry.customTitle` (Sidebar.json `customTitle`, optional; `name(from:)` makes
  it one plain line of at most 200 characters), which `displayTitle` prefers over `pageTitle`; page title updates
  only ever write `title`. Rows' menus (tiles too) have Rename… (the `.renameFolder` action, for tabs as well) and,
  once named, Use Page Title; a double click on a tab's title renames it; a favorite's field sits in a lifted row
  under its tile (`SidebarView.beginRename`). `BrowserWindowController.setName` (MARK Tab names) commits: empty or
  the page's own title clears it. The command bar (shown, and found by it or the page's title), Recently Closed and
  ⇧⌘T use it; imports keep Arc's and Zen's names as names (`ArcImport.Node.tab`'s `name`). Never logged in normal
  runs. Test commands `rowaction rename <id>`, `rename <id> [text]`, `rowmenu <id>`; state log `customTitle` and
  `pageTitle` per entry; check `tab-rename` (restore compares every name after the relaunch).
- `Extensions` (puzzle button in the sidebar address field, action popups in an NSPopover, install prompt),
  `Downloads` (button in the sidebar footer, ⌥⌘L; the list slides up as a panel inside the sidebar), `FindBar` (⌘F),
  `PermissionPrompt` (site permissions, only over their own tab), `ArcImport` (the old Import from Arc…, sidebar
  only; its action still exists without a menu item), `Toast` (Arc's top-right note, "Copied Current URL"; a
  `figure` style is the zoom level note, "110%", shown after ⌘+ ⌘− ⌘0 but never when Ray applies the default zoom).
- `LinksFromApps`: Ray as a web browser to macOS. Info.plist (`build-app.sh`) declares http/https and HTML, XHTML,
  PDF (`AddressInput.documentTypes`; no `file` scheme), so Ray can be picked as the default browser. Ray installs its
  own GetURL and Open Documents Apple Event handlers on willFinishLaunching (AppKit's never reached the delegate);
  links go through `AddressInput.link(fromOtherApp:)` (http(s) only), files only from Open Documents through
  `document(fromOtherApp:)` (real local files of those types). Each opens as a Today tab in the normal window, the
  last one active. A launch by a link waits for AppKit's launch to finish (its event comes after the engine starts)
  and opens the links in place of the start page. Test command `appopen link|files|direct`; checks
  `open-from-other-apps` and `open-from-other-apps-launch` (a cold start through `open -g -n`, its own data dir).
- Import: `Importer/` is Ardia's import core (Apache-2.0, `swift test --package-path Importer`, fixtures only, never a
  real profile), compiled into the app. `ImportSession` (the contract the screens use: `ImportItem`, `ImportSource`,
  `sources()`/`preview`/`run`) and `ImportWriter` (reading off the main thread, one Keychain prompt for the source's
  "<Name> Safe Storage" only when passwords/cookies/autofill are chosen, writing the sidebar through
  `addImported`, history through `ac_history_import` in 1,000-row batches, passwords/cookies/autofill through
  `EngineCalls.callWithSecret`, which wipes the bytes as soon as the engine has parsed them, bookmarks into one
  "Imported from <Browser>" folder with `ac_bookmarks_apply`). Never another browser's settings. Test builds read
  only `RAY_IMPORT_SOURCE_DIR` (fixtures) and `RAY_IMPORT_SECRET`, never the Keychain (checks `import-browser`).
- `Onboarding`: the first-run overlay (welcome, where you're coming from, what to bring, moving in, your colour,
  three keys), shown until "Start browsing" sets `onboarded` in Settings.json: on a new data dir and, once, on every
  profile from Ray 0.2.0 and earlier (no key),
  File › Import from Browser… (import steps only) and Ray › Show Welcome Again (⌥, also ⌥⌘,). Test builds show it
  only with `RAY_ONBOARDING=1` (check `onboarding`). `ProfileColor.visible(on:)` keeps accent marks at 3:1 against
  their background (a black profile colour on a dark card).
- Page commands (`BrowserWindowController` `// MARK: Page commands`): Print, Save Page As and Task Manager run
  Chrome's own commands (`executeChromeCommand`, ids from chrome_command_ids.h); View Source opens a `view-source:`
  tab; History and Clear Browsing Data open (or switch to) Chrome's pages. Check `page-commands`.
- `ClosedTabs`: ⇧⌘T and History › Recently Closed (`ClosedTabsMenu.shared` is their menu target, which `BarActions`
  also accepts). Records ⌘W / row Close / Clear Today, tags normal tabs with `ac_tab_restore_tag` so Chrome's tab
  restore keeps their history (`ac_tab_restore_take` + `coreWindow.restoreTab` put them back in their sidebar place);
  private windows keep their own in-memory list. Check `reopen-closed-tab`.
- Address display: `AddressInput.addressParts(for:)` (lead / host / trail, fragment kept, percent-encoded),
  `unwrapped`/`innerURL(of:)` for `view-source:`, `blob:`, `filesystem:` (one level, like Chrome; the security icon
  judges the inner URL); hosts shown as punycode until Ray has an IDN spoof checker (Ardia's `idn.ts`). Check
  `address-fragment`.
- `LoadSweep` + `LoadingWash` (PageToolbar): the address field's loading glow, Dia's measured shape, one sweep per
  main-frame navigation the user started or the page committed (Chrome's frame-level loading/progress would
  restart it); check `load-sweep-once`.
- Tab-modal dialogs (print preview…) are centred on the page with rounded corners: `engine-ray/fixups/0004`
  (raycore's `DialogPositionInHostView`, and `chromium-web-dialog-rounded-corners.patch`).
- `Spring`: a CADisplayLink spring. `dockSpring` (⌘S) and `peekSpring` drive `layout()` every frame.
- `Branding/Ray.icon` (Icon Composer; `actool` builds Assets.car + Ray.icns) and `tools/rebrand-pak.py` (renames
  "Ardia" to "Ray" and swaps Ardia's logos in the engine's .pak files at build time) and
  `tools/trim-settings-pak.py` (takes Profiles, Appearance and behavior and Search engine out of the engine's chrome://settings page in
  `resources.pak`, also at build time; Ray's own Settings window has the first two, and `AddressInput.nativeSettingsPane`
  sends those addresses there. Search is a fixed Google, so `/search` and `/searchEngines` have no pane:
  `AddressInput.isRemovedSettingsPage` sends them to plain chrome://settings/).
- `Resources/page_script.js`: runs in every frame; iframes return on its first line. Only `hello` today.
- `tests/`: `checks.mjs` (DevTools + `[ray-state]` log checks on a hidden instance), `AddressInputTests.swift`,
  `affected.mjs` (which checks each file or `// MARK:` section can affect) and `changed.mjs` (diff → checks).
- `Host/TestCommands.swift`: with `RAY_TEST_COMMANDS=1`, stdin lines drive the real UI (`menu <action>`,
  `type <text>`, `enter`, `escape`) through the same code paths as the keyboard. DevTools can't reach native UI, so
  checks for the sidebar and address field go through this. Settings: `setting <id> <value>` (any catalog id, parsed
  by its type; same call as the window's controls), `settings open [pane]|close|link|press <id> [n]|snap <path>|catalog`
  (the window's controls are named by setting id in `settingsWindow.controls`), `settings search <text>`,
  `settings choose <n>`, `settings key up|down|enter|escape` (the sidebar's search), `settings asapp on|off` (list
  panes and rows as Ray.app does: unbuilt rows and empty panes hidden), `zoom in|out|reset`, and
  `key tab ctrl keywin` / `key ctrlup` for ⌃Tab walks. `onscreen on|off` puts the hidden window on the shown Space
  (accessory policy, nearly transparent, click-through, not activated) for checks of what pages draw. The state log
  has `settings`, `settingsWindow` (pane, panes listed, rows per pane by id, search results, `flashing` /
  `lastFlash` / `flashVisible`, the selected row's colours and contrast, live pictures, open "More" lines),
  `menuKeys`, `recentOrder`, `tabCycle`, each tab's `zoom` and `pages.switches`
  (per display frame of each tab switch: `o` old page, `n` new page drawn, `b` both, `-` blank; check
  `switch-no-blank`).
- `engine/`: Ray's engine source (Phase B), generated: `tools/engine/sync-engine.sh` renames Ardia's `engine/`
  (`rename-ardia.py`: ArdiaCore→RayCore, bundle id, "Ray Safe Storage", links) and applies `engine-ray/` (dropped
  patches, removed files, fixups). Never edit `engine/` by hand. Its public API is
  `engine/raycore/src/ray/core/public/RayCore.h`. Built in `~/chromium-build` (steps 1, 3, 4, 2, 5 of
  `engine/patches/build/`, under `scripts/locked chromium`; never clean that build cache).
- `engine.lock`: `source=local` builds against `~/chromium-build/…/out/Release_GN_arm64/Chromium Framework.framework`
  (`RAY_ENGINE_FRAMEWORK` overrides); `ardia_tag` is the Ardia source `engine/` was made from.
  `scripts/fetch-engine.sh` resolves it.
- `SafeStorage` (`Host/SafeStorage.swift`): before the engine starts, moves a Ray 0.1 data dir from the mock
  keychain's key to "Ray Safe Storage" in the login keychain (once; marker `Chromium/Ray Safe Storage`, originals a
  week in `Safe Storage Migration/backup`), and decides `--use-mock-keychain`: only test builds and a launch whose
  move couldn't start keep it. State log `safeStorage`; test builds use the engine's file keychain with
  `RAY_KEYCHAIN=file` (check `safe-storage-migration`), never the login keychain.
- `sparkle.lock`: the pinned Sparkle 2 release (version, URL, sha256); `scripts/fetch-sparkle.sh` downloads, checks
  and unpacks it into `build/sparkle/<version>` (tarball cached in `~/Library/Caches/Ray/sparkle`). Never committed.
  `VERSION` (`version=`, `build=`) is the one place the app's version comes from; `Branding/sparkle-public-key.txt`
  is the EdDSA public key `build-app.sh` writes into `SUPublicEDKey`.
- `Host/Updater.swift`: Ray › Check for Updates… (`SPUStandardUpdaterController`). It starts only in the real app and
  only with a real `SUPublicEDKey`; the test app never creates it (state log `updater`, check `updater-config`).
- `scripts/release.sh <version> [--notes file]`: builds, zips, signs and writes the appcast under `build/release/`.
- `third_party/ardia/`: read-only reference clone of Ardia at `ardia_tag` (gitignored). Read it for behaviour; don't
  build from it.
- `third_party/crest/`: read-only reference clone of Crest (gitignored), another native-Mac Chromium browser.
- Upstream watch: `docs/ARDIA-WATCH.md` (Ardia's releases reviewed, newest first, "Last reviewed" line, a "Ray
  should" list) and `docs/CHROMIUM-WATCH.md` (Chrome stable and Helium releases vs `engine.lock`'s Chromium, security
  fixes first). Two daily scheduled tasks in the owner's Claude app (`ardia-watch-daily` 10:00,
  `chromium-watch-daily` 10:15) append to them and commit only that file; they never touch engine files or builds.
- `third_party/cra/`: read-only reference clone of Cra (gitignored; github.com/VictorKildahl/cra, MIT), an Arc
  replacement on CEF with SwiftUI UI. Its importers (`Sources/Cra/Services/Import`) and models are plain Swift and
  may be copied: keep its copyright line in the file header and in `NOTICE`. Its SwiftUI views are references only
  for Ray's hot paths (sidebar, tab rows, window chrome stay AppKit + Core Animation); skip its content blocker.

## Build and run
- `scripts/build-app.sh` → `build/Ray.app` (the user's app) and `build/RayTests.app` (same code compiled with
  `-D RAY_TEST_HOOKS`, bundle id `….tests`). Test hooks, `RAY_*` overrides, URL logs and the DevTools port exist
  only in the test app; checks and `run-hidden.sh` use it, `relaunch.sh` opens the real one.
- Quit the user's Ray before building: macOS App Management blocks rewriting a running bundle (EPERM, a half-built
  app, a broken icon). `osascript -e 'tell application id "<CFBundleIdentifier of build/Ray.app>" to quit'`.
- While the user is trying a build, don't quit their Ray to test the next change: build and test in a temporary
  worktree (`git worktree add --detach .claude/worktrees/<name> HEAD`, `git diff | git -C <wt> apply`), commit in
  the main checkout, and relaunch only when they're ready.
- `scripts/run-hidden.sh <throwaway data dir> [port] [url]` launches hidden and prints DevTools' page list.
- `scripts/test.sh [check …]`: unit tests (address parsing, the keychain move, the importer's XCTest suite against
  `Importer/fixtures`), then `tests/checks.mjs` (hidden instance, own data dir, local fixture pages). Add a check for
  every behaviour you add or fix.
- Engine delegate methods are `@optional`: a Swift name that's slightly off compiles with only a "nearly matches"
  warning and is never called. Treat those warnings as errors.

## Shipping to friends
Ray updates itself with Sparkle 2: the feed is `https://github.com/shanuflash/ray/releases/latest/download/appcast.xml`
(each release carries its own `appcast.xml` next to `Ray-<version>.zip`, and GitHub's `latest` redirect serves the
newest release's). The app is ad-hoc signed (no Developer ID), so trust comes from Sparkle's EdDSA signature: the
archive must verify against the `SUPublicEDKey` baked into the *installed* Ray (Sparkle's `SUUpdateValidator`; an
ad-hoc code signature changes every build and isn't what's trusted, it only has to be valid and not removed).
- **One-time key setup:** run `build/sparkle/<version>/bin/generate_keys` (after any build). The private key goes into
  your login keychain (item "Private key for signing Sparkle updates"); it prints the public key, which you put in
  `Branding/sparkle-public-key.txt`. The private key never leaves the keychain: not in the repo, not in logs, not in
  CI; back it up only with `generate_keys -x` into a password manager, never a commit. If it's lost, installed copies
  can't be updated and friends must reinstall by hand. Until the real public key is in, builds warn and the updater
  stays off.
- **Cut a release:** commit everything, then `scripts/release.sh 0.2.0 --notes notes.md`. It bumps `VERSION`, builds
  `build/Ray.app`, zips it with `ditto` (a zip serves both first installs and Sparkle), signs it from the keychain,
  writes and checks `build/release/0.2.0/appcast.xml` and prints the `git commit` and `gh release create …` commands.
  It publishes nothing; run those yourself after trying the zip.
- **First install is not notarized:** friends unzip, drag Ray to Applications (not run from Downloads: macOS runs
  unmoved apps translocated, read-only, and Sparkle can't replace them), then right-click › Open (macOS 14), or on
  macOS 15+ try to open it once and use System Settings › Privacy & Security › Open Anyway. Updates after that
  install without the prompt. Each update changes the ad-hoc signature, so macOS may ask again for camera, microphone
  and location.
- From the Phase B engine on, cookies and passwords are under "Ray Safe Storage" in the login keychain.
- **Signing identity:** builds are signed with "Ray Code Signing", a self-signed code-signing certificate (10 years,
  created 2026-10-29) whose private key is in the owner's login keychain, usable by `/usr/bin/codesign` only.
  `build-app.sh` picks it when present (else ad-hoc, `RAY_SIGN_IDENTITY` overrides); `release.sh` refuses a build
  without it; `updater-config` checks it. Its stable designated requirement (`certificate root =
  H"57dd31c307844623c2a646a24fb7f19c27327a4f"`) is what lets macOS keep "Always Allow" for "Ray Safe Storage" and
  privacy permissions across builds and updates. Sparkle accepts the change from ad-hoc because the EdDSA key is
  unchanged. Never export the key into the repo; back it up only into a password manager (Keychain Access ›
  "Ray Code Signing" › Export). If it's lost, a new certificate costs friends one more keychain prompt.

## Testing
- Per change: `scripts/build-app.sh && scripts/test.sh --changed`. It runs the unit tests, then only the checks the
  working tree's diff (plus untracked files) can affect, printing the reason per file. `--changed <base>` diffs
  against another commit. The whole suite (`scripts/test.sh`) runs only before a push, never per change: the user
  asked for this and gets annoyed by repeated full runs. If `--changed` says "all" for a small edit, the map is too
  coarse: give the file or section its own entry instead of running everything. Running checks by name skips their
  setup: `needs` in `tests/affected.mjs` lists them (`--changed` adds them itself).
- Keep `tests/affected.mjs` honest: a new Host file, a new `// MARK:` section in a big file, or a new check gets its
  entry in the same change. Unmapped files run everything (safe, slow). A section runs from its MARK to the next
  MARK or top-level declaration. Changes inside a check in `checks.mjs` run that check; changes to shared helpers
  run everything.
- Animations: record what happened app-side (e.g. `navigationSteps` in the state log) instead of polling; a command
  round trip is slower than a 0.26 s spring.
- OS re-auth (Touch ID or the login password) in tests: `RAY_REAUTH=granted|denied` on a hidden instance makes
  main.swift pass `--ray-background` and `--ray-test=reauth=…` (compiled only into the test app), and the engine
  answers at once with no prompt. A test instance without it never makes a re-auth call (`settingsReauthAllowed`).
  Secrets for the panes' test commands come from `RAY_TEST_SECRETS` (JSON, by index), never a command line, which
  stderr echoes. `ownInstance(name, env)` in checks.mjs starts such an instance on its own data dir.
- Multi-window checks: `state()` is whichever window logged last; poll `command("state")`, which logs the current one.
- Known environment noise. Spring checks skip while the display sleeps (`needsFrames`). Some checks only run when the
  hidden test window happens to land on the visible desktop: `switch-back-latency` then fails (on older commits
  too) and leaves state that breaks `private-window`, `arc-import` and `close-last-window` after it. A subset run
  can also fail from what earlier checks left behind: `pin-unload-restore` leaves its tab pinned, so `favorites` and
  `reopen-closed-tab` fail right after it (on main too); run those alone. Before blaming a change, run the same command on the
  previous commit (`git stash -u`, build, run, `git stash pop`) and compare.

## Gotchas (learnt the hard way)
- A page view hidden in Ray is hidden to Chrome: `BrowserCompositorMac` drops its compositor at once (the GPU
  clears its content, possibly before Ray's own commit lands) and makes a new one on show, so the page shows only
  its background colour until a new CALayerHost arrives. Never hide the page on screen before its replacement has
  drawn, and never move a page view out of the tree to reorder it (Chrome sees hide + show): use `sortSubviews`.
- A test window on another app's full-screen Space isn't on screen: Chrome draws nothing and display links don't
  tick. Checks of frames use `onscreen on` (only an accessory app's window can join that Space); `isOnActiveSpace`
  stays false for a window on all Spaces, so go by `occlusionState`.
- Setting observers run on the next turn of the run loop, not inside `set`: code that changes a setting and needs the
  result at once reads `RaySettings.shared[.key]` itself. An `observe` whose `SettingsObservation` isn't kept stops at
  once.
- The settings-page trim (`tools/trim-settings-pak.py`) edits minified code of one engine version, matched by exact
  patterns, and the build stops with a message naming the pattern when one moves. On an engine bump, run the build, and
  if it stops, re-read `shared.rollup.js` (the resource that holds `function createPageVisibility()`; decompress it
  from resources.pak) and fix the patterns, then run `settings-trimmed`. The bare `/` route's top-level page must be one
  that draws on `/` (Performance); Privacy draws nothing there.
- Shifted menu key equivalents must be uppercase ("C" for ⇧⌘C); real and synthetic ⇧-keys arrive uppercase.
- Chrome's window swallows reserved shortcuts (⌘W with no tab) before the menu sees them: `AppController` routes
  `Shortcuts.isReserved` keys to the main menu from an app-local keyDown monitor. A menu item that
  `validateMenuItem` disables never fires its shortcut either.
- Info.plist needs the privacy usage strings (camera, microphone, location, Bluetooth, audio capture): without them
  TCC kills Ray the moment a site asks.
- The launch's open event (a link or file that started Ray) is dispatched after `engineDidStart` (the engine's start
  runs on the main loop before AppKit's launch finishes), and AppKit's own handlers never reached
  `application(_:open:)` in Ray, even with the delegate set on willFinishLaunching: `LinksFromApps` installs Ray's
  handlers there and holds the first window until didFinishLaunching (13 ms on a link launch, none otherwise).
- The engine silently cancels insecure downloads (HTTPS page → HTTP file); Keep/Discard only shows for files Chrome
  holds as dangerous. Ardia 0.2.42's "insecure download waits for Keep" is its app UI over the same engine tree
  (`ac_downloads_keep` already handles insecure ones), so on this engine nothing changes.
- NSPopover is Liquid Glass on macOS 26+, so content without its own background shows the glass. Extension popups
  get Chrome's white base (`contentsBackgroundColor`). The user dislikes popovers for Ray's own UI: build in-window
  panels (downloads, site controls) that close on an outside click, Escape and tab switches.
- Extension action icons can be empty (they load late, or only the background page sets one): fall back to the
  manifest icon from `ac_extensions_list`, as Chrome's toolbar does.
- `NSTextField` labels draw from the top of their frame: make the frame exactly one line tall
  (`intrinsicContentSize.height`) and centre that, or text rides 1–2 pt high.
- Chrome's content layer follows the page by CALayer autoresizing, which rounds each step: keep page frames on whole
  points or the page creeps a little on every ⌘S.
- Chrome that moves with the sidebar takes `dockSpring.value` in `layout()`; never switch it on
  `state.sidebarHidden`, which flips before the animation starts.
- Subview order in the window's root: pages < toolbar < sidebar / floating peek < panels and toast. New UI over the
  page goes below `floating`, so a peeking sidebar covers it.
- Security icon (`ConnectionLook`): nothing on dev hosts (localhost, 127/8, ::1, `*.localhost`, `*.test`), a grey
  open lock for plain http, red only for a certificate error on a real site. The user hated Dia's red lock on dev.
- Scripted edits: assert the old text matches exactly once before replacing; an empty-string replace once corrupted
  `checks.mjs`.

## Security checklist (every change)
Web pages are hostile; Chromium sandboxes them, but Ray's chrome must not hand them anything back.
- **Identity comes from the engine, never the page.** Use the verified `origin` the engine passes with page messages
  and the tab's `committedOrigin`; ignore any URL or origin a page reports about itself.
- **Page channel:** `Resources/page_script.js` runs in every frame; iframes return on its first line unless a feature
  needs them. Treat every message as untrusted: check kind, types and sizes; never act on it across tabs.
- **URLs from anywhere** (address field, command bar, history, suggestions, drag and drop, `Sidebar.json`, popups,
  other apps) go through `AddressInput`. Never load `javascript:`. Load `data:`/`file:` only when the user typed it,
  or (`file:` only) opened that file with Ray from Finder; another app's links are http(s) only.
- **Address display:** the host leads and stands out (any path after it is grey and is what gets cut when long),
  long hosts elided from the start, `user:pass@` hidden, port shown, paths kept percent-encoded; never show
  page-controlled text where the address goes.
- **Prompts** (permissions, external apps, downloads, extension installs, password save): deny or close by default,
  show the full origin, ignore clicks for the first 0.5 s, never auto-accept, never show over another tab's page.
- **No string-built code:** JSON through `JSONSerialization` only (`EngineCalls`); never build JS for
  `evaluate`/`executeJavaScript` from untrusted text.
- **Test and debug hooks** (`TestCommands`, `[ray-state]` logs, DevTools port, `RAY_*` overrides) work only when
  their `RAY_*` variable is set, and are never reachable from a page or a normal launch.
- **Logs:** no URLs, titles, page messages, cookies or credentials in `NSLog` in normal runs.
- **Secrets:** never in `Sidebar.json`, logs or tests. Test builds run on the mock keychain (or the engine's file
  keychain); never let a test instance read or write the login keychain.
- **Monitors:** global event monitors watch pointer position only, never keys; none in test instances.
- **Engine:** on every Chromium bump (`engine.lock`'s `chromium`), note it against current Chrome stable.
- **Every security-relevant behaviour gets a check** in `tests/checks.mjs`.

## Key routing
- `preHandleKeyEvent` runs only Chrome's reserved set (`Shortcuts.isReserved`: ⌘T ⌘W ⌘N ⌘Q ⌘, ⇧⌘T ⇧⌘W ⇧⌘N ⇧⌘[ ⇧⌘]
  ⌃Tab) before the page. Everything else reaches the page first; `handleKeyEvent` (page didn't use it) sends it to
  the main menu.

## Rules
- **Docs stay current, in the same commit as the change** (the owner's rule for this repo): a new Host file, MARK
  section, engine fixup, setting, test hook or check gets its line in CLAUDE.md's Layout (and Testing/Gotchas when
  it teaches something); a feature that lands moves to `docs/MISSING.md`'s "Done" table with date and commit; a
  roadmap step or decision that changes is updated in PLAN.md; anything a user would notice updates README's "What
  works", "Not yet" or "Security". Subagents do this for their own change; when merging, check it was done.
- Don't push until the user has tried the build and says so: commit locally, relaunch, wait. Commit only when the
  checks you ran pass (look for FAIL in the output first).
- Match Arc and Dia from the user's screenshots and recordings. For exact sizes and spacing read Ardia's source
  (same design lineage) instead of measuring pixels.
- Commit messages: caveman style, one short line like `feat: arc like sidebar` or `fix: sidebar opening too quickly`
  (conventional prefix, lowercase, no body unless the why is non-obvious). No Co-Authored-By or other attribution.
- Before any design or behaviour decision, check all four references and say what each does: Chromium's source
  (Chrome's behaviour), Ardia (`third_party/ardia`, same engine), Crest (`third_party/crest`) and Cra
  (`third_party/cra`, closest to Ray's goal). None is
  automatically right; weigh them, and where they disagree pick on evidence. Don't narrate the checking.
- Never steal focus with test instances: test only through `scripts/run-hidden.sh` / `tests/checks.mjs`
  (`RAY_BACKGROUND=1`, own data dir).
- After a build the user should look at, run `scripts/relaunch.sh` once checks pass: it quits their running Ray with
  a normal macOS quit, installs build/Ray.app as /Applications/Ray.app (their one copy, the one in the Dock) and
  opens it in front on their default data dir. The user asked for both; they can't easily run commands themselves.
  Never run build/Ray.app directly for them: two copies on one profile make the Dock icon hand off and quit.
- Every test instance gets its own throwaway `RAY_DATA_DIR`; never the default data dir, never a real browser profile.
- Quit the instances you start (`kill -TERM <pid>`), and only those.
- Every wait has a deadline.
- Verify before calling something done: build, run hidden, check over DevTools (port) and the stderr log; say what
  still needs a visual check.
- UI hot paths (sidebar, tab rows, window chrome) and Settings are AppKit + Core Animation, never SwiftUI. Animations run on
  layers, not main-thread timers. A tab switch shows the page before any store update.
- No WebKit, no Ardia performance messages in the page script. Peek and a built-in content blocker are open
  decisions (PLAN.md, "Open decisions"): don't build either until the owner decides.
- Ray's keychain item is "Ray Safe Storage" (account "Ray"). Never let Ray read "Ardia Safe Storage" (the user's real
  Ardia) or any other browser's item, except as an explicit import the user asks for. Test builds stay on
  `--use-mock-keychain`.
