// Which checks in checks.mjs a change can affect. `scripts/test.sh --changed` runs only those (boot, quit and
// restore always run). Keys are a path, a folder ending in "/", or "path#Section" for one `// MARK: Section` of a
// big file (`# MARK:` in a script; the lines from that mark to the next). Values are check names, "all", or [] (nothing beyond the unit
// tests, which always run).
//
// Anything without an entry runs the whole suite, so a missing entry costs time, never coverage. When you add a
// file, a MARK section or a check, add it here in the same change.

const pages = ["page-channel", "navigate", "target-blank", "window-open", "background-tab", "create-target",
  "activate-target", "page-closes-itself", "close-target"];
const permissions = ["permission", "permission-allow"];
const commandBar = ["address-new-tab", "address-cancel", "bar-lists-tabs", "bar-switch-to-tab", "bar-history",
  "address-navigate", "address-javascript", "bar-one-row", "bar-search-suggestions", "bar-search-google", "bar-actions",
  "bar-ranking", "settings-bar",
  "search-engine", "search-suggestions-off", "site-search"];
const drag = ["drag-click-selects", "drag-reorder", "drag-to-pin", "drag-to-favorite", "drag-pin-hint-gone",
  "drag-out-cancels", "drag-favorite-to-today"];
const sidebarMotion = ["sidebar-toggle", "peek-zones", "window-lights", "toggle-keeps-page-still"];
const pageSurface = ["switch-back-latency", "switch-no-blank", "top-strip-click", "toggle-keeps-page-still", "activate-target",
  "devtools-docked", "background-tab"];

const otherApps = ["open-from-other-apps", "open-from-other-apps-launch"];
// Tabs and sidebar, Appearance and Shortcuts rows with features of their own.
const settingFeatures = ["settings-appearance-mode", "settings-scroll-bars", "settings-page-address-bar",
  "settings-sidebar-button", "settings-fade-unloaded", "settings-reorder-haptics", "settings-undo-reopens"];
const settings = ["settings-window", "settings-catalog", "settings-minimal-url", "settings-loading-progress", "settings-theme",
  "settings-zoom", "settings-private-zoom", "settings-new-tab-position", "settings-recent-tab-cycling",
  "settings-shortcuts", "settings-routes", "settings-trimmed", "settings-persist", "settings-panes", "settings-search",
  "settings-bar", "settings-colours", ...settingFeatures,
  "search-engine", "search-suggestions-off", "site-search", "jumpcloud-relay"];
// Settings › General (SettingsGeneral.swift, CloseWarnings.swift): its pane, the two warnings and Start fresh.
settings.push("settings-general", "warn-before-quitting", "warn-before-closing-window");
settings.push("settings-privacy", "settings-extensions");
settings.push("settings-passwords", "settings-autofill");
// What a setting's value or its change notice reaches: the settings checks, the welcome (theme, keys), and the
// features they drive (address bar, loading, site controls' zoom reset, ⇧⌘C, ⌘S, menu keys in the command bar).
const settingReaders = [...settings, "onboarding", "page-toolbar", "page-loading", "load-sweep-once", "address-fragment",
  "site-controls", "copy-url", "sidebar-toggle", "page-commands", "bar-actions"];

export const areas = {
  // Central: windows, menus, key routing, saved state, the engine bridge.
  "Host/AppController.swift": "all",
  "Host/AppController.swift#Welcome again": ["onboarding"],
  // Which menu commands are enabled: the menu's keys and the command bar's action rows.
  "Host/AppController.swift#Menu validation": [...commandBar, "page-commands", "copy-url", "find-in-page", "site-controls",
    "settings-shortcuts", "clear", "folder-create", "pin-unload-restore"],
  "Host/MainMenu.swift": "all",
  "Host/Shortcuts.swift": "all",
  "Host/SidebarModel.swift": "all",
  // What Sidebar.json keeps of an entry, its name and titles, and what the sidebar shows of it.
  "Host/SidebarModel.swift#Names and saved fields": [...pages, ...drag, ...commandBar, "tab-rename", "folder-create",
    "folder-rename", "favorites", "pin-unload-restore", "tile-hover", "clear", "reopen-closed-tab", "arc-import",
    "import-browser", "private-window", "close-last-window"],
  // When a pinned tab or favorite counts as away from its page.
  "Host/SidebarModel.swift#Pinned page": ["pin-unload-restore", "reopen-closed-tab", "favorites"],
  "Host/EngineCalls.swift": "all",
  "Host/TestEnvironment.swift": "all",
  // Colours only: the checks that read a colour or draw with it.
  "Host/ProfileColor.swift": ["page-loading", "site-controls", "tile-hover", "drag-to-favorite", "settings-theme", "settings-window",
    "settings-colours", "onboarding"],
  "Host/main.swift": "all",
  "Host/Bridging.h": "all",
  "Resources/": "all",
  "engine/": "all",
  // Tab-modal dialogs (print preview): where they sit and their corners.
  "engine/raycore/src/ray/core/ac_modal_dialog_host.mm": ["page-commands"],
  // A series line changes with its patch file, which has its own entry (or falls under engine/: all).
  "engine/patches/series": [],
  "engine/patches/chromium-web-dialog-rounded-corners.patch": ["page-commands"],
  "engine-ray/fixups/0004-dialogs-centred-and-rounded.patch": ["page-commands"],
  "engine-ray/": "all",
  "engine.lock": "all",
  "scripts/build-app.sh": "all",
  // Which certificate signs the apps (the checks run on the mock keychain; only updater-config reads the signature).
  "scripts/build-app.sh#Signing": ["updater-config"],
  "tools/": "all",
  // The pak tools only touch the engine's own pages: the rebranded About page, and the trimmed settings page.
  "tools/rebrand-pak.py": ["about-panel", "settings-trimmed"],
  "tools/trim-settings-pak.py": ["about-panel", "settings-trimmed"],
  "Branding/": ["about-panel"],
  // Self-update (Sparkle): the build's Info.plist keys, the embedded framework, and the updater staying off in tests.
  "Branding/sparkle-public-key.txt": ["updater-config"],
  "VERSION": ["updater-config", "about-panel"],
  "sparkle.lock": ["updater-config"],
  "scripts/fetch-sparkle.sh": ["updater-config"],

  // BrowserWindowController: by section. Lines outside them (properties, init) run everything.
  "Host/BrowserWindowController.swift#Layout": [...sidebarMotion, ...pageSurface, "page-toolbar", "site-controls",
    "find-in-page", "copy-url"],
  "Host/BrowserWindowController.swift#Extensions and downloads": ["extensions", "extension-prompt", "downloads",
    "download-insecure-blocked", "site-controls"],
  "Host/BrowserWindowController.swift#Test snapshots": ["folder-rename", "tile-hover", "bar-actions", "load-sweep-once"],
  "Host/BrowserWindowController.swift#Arc import": ["arc-import", "import-browser"],
  "Host/BrowserWindowController.swift#Browser import": ["import-browser", "arc-import", "onboarding", "tab-rename"],
  "Host/BrowserWindowController.swift#Onboarding": ["onboarding"],
  "Host/BrowserWindowController.swift#Permission prompts": permissions,
  "Host/BrowserWindowController.swift#Toast": ["copy-url", "page-commands"],
  "Host/BrowserWindowController.swift#Find in page": ["find-in-page", "copy-url"],
  "Host/BrowserWindowController.swift#Site controls": ["site-controls", "extensions", "copy-url", "find-in-page", "settings-privacy"],
  "Host/BrowserWindowController.swift#Entries": "all",
  "Host/BrowserWindowController.swift#Recently closed": ["reopen-closed-tab", "tab-rename", "warn-before-quitting"],
  // A tab's own name: Rename…, the double click, the test command's `rename` (folders too).
  "Host/BrowserWindowController.swift#Tab names": ["tab-rename", "folder-rename"],
  "Host/BrowserWindowController.swift#Page toolbar": ["page-toolbar", "address-fragment", "page-loading", "load-sweep-once", "site-controls",
    "sidebar-toggle", "settings-page-address-bar"],
  "Host/BrowserWindowController.swift#Sidebar visibility": [...sidebarMotion, "page-toolbar", "downloads"],
  "Host/BrowserWindowController.swift#Command bar": [...commandBar, "copy-url", "onboarding", "tab-rename"],
  "Host/BrowserWindowController.swift#Pages": pageSurface,
  "Host/BrowserWindowController.swift#SidebarViewDelegate": "all",
  "Host/BrowserWindowController.swift#RayCoreWindowDelegate": [...pages, "private-window", "close-last-window", "warn-before-closing-window"],
  "Host/BrowserWindowController.swift#RayCoreTabDelegate": [...pages, ...permissions, "page-toolbar", "page-loading",
    "load-sweep-once", "site-controls", "find-in-page", "settings-zoom", "settings-routes", "settings-trimmed",
    "address-fragment", "jumpcloud-relay"],
  "Host/BrowserWindowController.swift#Settings": [...settings, "page-toolbar", "page-loading"],
  "Host/BrowserWindowController.swift#Page commands": ["page-commands"],
  "Host/BrowserWindowController.swift#Page zoom": ["settings-zoom", "settings-private-zoom", "settings-window", "site-controls",
    "page-commands"],
  "Host/BrowserWindowController.swift#State log": [],

  // The rest of SidebarView (rows, tiles, the address field, the top row): the sidebar's own checks.
  "Host/SidebarView.swift": [...drag, "folder-create", "folder-toggle", "folder-rename", "folder-animation",
    "folder-drag-in", "folder-drag-folder", "folder-out-and-delete", "tile-hover", "favorites", "pin-unload-restore",
    "sidebar-toggle", "peek-zones", "window-lights", "page-toolbar", "clear", "downloads", "address-fragment", "tab-rename",
    "settings-sidebar-button", "settings-fade-unloaded"],
  "Host/SidebarView.swift#Folder fold": ["folder-animation", "folder-toggle", "folder-rename", ...drag],
  // Also the rows' menus and the test hooks for renaming (the field, its Done button).
  "Host/SidebarView.swift#Drag and drop": [...drag, "folder-drag-in", "folder-drag-folder", "folder-rename", "tab-rename",
    "settings-reorder-haptics"],
  "Host/SidebarView.swift#Downloads panel": ["downloads"],

  "Host/AddressInput.swift": [...commandBar, "page-toolbar", "site-controls", "settings-routes", "settings-trimmed",
    "address-fragment", "settings-privacy", "settings-extensions"],
  // How the page address bar splits an address (lead, host, rest), and which URL a view-source: one is about.
  "Host/AddressInput.swift#Address display": ["address-fragment", "page-toolbar", "settings-minimal-url", "site-controls",
    "page-commands"],
  // The helpers that read what was typed: the command bar's.
  "Host/AddressInput.swift#Typed addresses": [...commandBar, "settings-routes"],
  // Which links and files from other apps Ray takes.
  "Host/AddressInput.swift#Opens from other apps": otherApps,
  // Which site search addresses Ray takes, and how a query goes into one.
  "Host/AddressInput.swift#Search templates": ["site-search", "search-engine", "bar-search-suggestions", "bar-search-google"],
  // Links and files from other apps (and the one that launched Ray), and where they open.
  "Host/LinksFromApps.swift": otherApps,
  "Host/BrowserWindowController.swift#Links from other apps": otherApps,
  // The settings: storage and observers, and the catalog of what they are (each entry's window row and test command).
  "Host/RaySettings.swift": settingReaders,
  "Host/SettingsCatalog.swift": settingReaders,
  // The Settings window: its frame and sidebar, the panes' layout, the pane-content registry and each pane's own
  // content, the controls (RaySwitch and the swatches are also the welcome's), the live pictures and search (whose
  // matches are also the command bar's "Settings: …" rows).
  "Host/SettingsWindow.swift": settings,
  "Host/SettingsPaneView.swift": settings,
  "Host/SettingsPanes.swift": settings,
  "Host/SettingsAppearance.swift": ["settings-panes", "settings-window", "settings-page-address-bar"],
  "Host/SettingsTabs.swift": ["settings-panes", "settings-window"],
  "Host/SettingsAbout.swift": ["settings-panes", "settings-search"],
  "Host/SettingsGeneral.swift": ["settings-general", "settings-panes", "settings-search", "warn-before-quitting", "updater-config"],
  "Host/CloseWarnings.swift": ["warn-before-quitting", "warn-before-closing-window", "close-last-window", "private-window"],
  // Settings › Privacy and Settings › Extensions, over the engine's data calls, and the pieces they share.
  "Host/SettingsPrivacy.swift": ["settings-privacy", "settings-panes", "settings-search", "site-controls"],
  "Host/SettingsExtensions.swift": ["settings-extensions", "settings-panes", "settings-search", "extensions"],
  "Host/SettingsDataRows.swift": ["settings-privacy", "settings-extensions"],
  // Settings › Passwords and › Autofill (on the engine's ac_passwords_* and ac_autofill_*), and their shared pieces.
  "Host/SettingsPasswords.swift": ["settings-passwords", "settings-panes", "settings-search", "jumpcloud-relay"],
  "Host/SettingsAutofill.swift": ["settings-autofill", "settings-panes", "settings-search"],
  "Host/SettingsDataViews.swift": ["settings-passwords", "settings-autofill"],
  // Settings › Search: its rows and controls, and the engines and site searches the command bar searches with.
  "Host/SettingsSearchPane.swift": ["search-engine", "search-suggestions-off", "site-search", "settings-catalog", "settings-panes",
    "settings-window", "settings-search", "settings-bar", "settings-persist"],
  "Host/SearchEngines.swift": [...commandBar, "settings-catalog", "private-window"],
  // JumpCloud Go through Chrome: the login pages, Chrome's pipe, the cookies (tests/ has its Chrome stand-in), and
  // Passwords' setup row.
  "Host/JumpCloudRelay.swift": ["jumpcloud-relay"],
  "Host/SettingsJumpCloud.swift": ["settings-panes", "settings-search", "jumpcloud-relay"],
  "tests/jumpcloud-chrome-standin.mjs": ["jumpcloud-relay"],
  "Host/TestCommands.swift#JumpCloud relay": ["jumpcloud-relay"],
  "Host/SettingsControls.swift": [...settings, "onboarding"],
  "Host/MiniRayWindow.swift": ["settings-panes", "settings-window"],
  "Host/SettingsSearch.swift": [...settings, ...commandBar],
  "Host/ArcImport.swift": ["arc-import", "import-browser"],
  // The first run's welcome and File › Import from Browser… (on the fake importer).
  "Host/Onboarding.swift": ["onboarding"],
  "Host/RaySettings.swift#Onboarding": ["onboarding"],
  // The settings in the state log: the checks that compare them (the restore check reads them after settings-persist).
  "Host/RaySettings.swift#State log": [...settings, "onboarding"],
  "Host/CommandBarView.swift": commandBar,
  "Host/Suggestions.swift": [...commandBar, "tab-rename"],
  // The command bar's action rows: menu commands by name (they run through the menu's own validation and selectors).
  "Host/BarActions.swift": [...commandBar, "page-commands", "copy-url"],
  "Host/Downloads.swift": ["downloads", "download-insecure-blocked"],
  "Host/Extensions.swift": ["extensions", "extension-prompt", "site-controls"],
  "Host/FindBar.swift": ["find-in-page"],
  "Host/PageContainerView.swift": pageSurface,
  // When a page that was just shown has drawn (the tab switch holds the page left until then).
  "Host/PageFrameWatch.swift": pageSurface,
  "Host/PageToolbar.swift": ["page-toolbar", "address-fragment", "settings-minimal-url", "page-loading", "load-sweep-once", "site-controls", "sidebar-toggle",
    "top-strip-click", "settings-sidebar-button"],
  // Which loads the address field sweeps for.
  "Host/LoadSweep.swift": ["page-loading", "load-sweep-once", "settings-loading-progress", "page-toolbar"],
  "Host/PermissionPrompt.swift": permissions,
  "Host/SiteControls.swift": ["site-controls", "extensions", "settings-privacy"],
  "Host/Spring.swift": [...sidebarMotion, "drag-reorder"],
  "Host/Toast.swift": ["copy-url", "page-commands"],
  "Host/Updater.swift": ["updater-config", "settings-general"],
  // ⇧⌘T and History › Recently Closed.
  "Host/ClosedTabs.swift": ["reopen-closed-tab", "tab-rename"],
  // ⌘Z: Edit › Undo, or reopening a closed tab outside text.
  "Host/ClosedTabs.swift#Undo close tab": ["settings-undo-reopens", "reopen-closed-tab", "settings-shortcuts"],
  // Light or dark for Ray's windows, and the scroll bars pages are told to draw.
  "Host/AppLook.swift": ["settings-appearance-mode", "settings-scroll-bars", "settings-panes", "settings-window"],
  "Host/SafeStorage.swift": ["safe-storage-migration"],
  "Host/WindowDragArea.swift": ["top-strip-click", "window-lights", "drag-click-selects"],
  // Test hooks: the feature's own files bring in its checks.
  "Host/TestCommands.swift#Settings": [...settings, "onboarding"],
  "Host/TestCommands.swift": ["site-search", "search-engine", "folder-rename", "tile-hover", "import-browser", "onboarding", "bar-actions", "load-sweep-once",
    "reopen-closed-tab", "close-last-window", ...otherApps, "switch-no-blank", "tab-rename", "settings-general",
    "warn-before-quitting", "warn-before-closing-window", "settings-undo-reopens"],

  // Nothing to run beyond the unit tests.
  "tests/AddressInputTests.swift": [],
  "tests/SafeStorageTests.swift": [],
  // The importer's own tests (swift test) cover its readers; import-browser runs it end to end in the app, and
  // onboarding drives its screens on the importer's fixtures.
  "Importer/": ["import-browser", "onboarding", "jumpcloud-relay"],
  "Importer/Tests/": [],
  "Host/ImportSession.swift": ["import-browser", "onboarding"],
  "Host/ImportWriter.swift": ["import-browser", "onboarding"],
  "tests/affected.mjs": [],
  "tests/changed.mjs": [],
  "scripts/test.sh": [],
  "scripts/relaunch.sh": [],
  "scripts/release.sh": [],
  "scripts/run-hidden.sh": [],
  "scripts/fetch-engine.sh": [],
  "CLAUDE.md": [],
  "PLAN.md": [],
  "README.md": [],
  "docs/": [],
  "NOTICE": [],
  "LICENSE": [],
  "LICENSE.Apache-2.0": [],
  ".gitignore": [],
  // tests/checks.mjs is handled in changed.mjs: the checks whose bodies changed, or all if shared code changed.
};

// Checks that build on what an earlier check left (the folder checks use the folder folder-create makes): selecting
// one also runs these, in suite order.
export const needs = {
  "folder-toggle": ["folder-create"],
  // Its double click starts on an open folder, as folder-toggle leaves it.
  "folder-rename": ["folder-create", "folder-toggle"],
  "folder-animation": ["folder-create"],
  "folder-drag-in": ["folder-create"],
  "folder-drag-folder": ["folder-create"],
  "folder-out-and-delete": ["folder-create"],
  "drag-to-favorite": ["drag-click-selects", "drag-reorder", "drag-to-pin"],
};
