// Which checks in checks.mjs a change can affect. `scripts/test.sh --changed` runs only those (boot, quit and
// restore always run). Keys are a path, a folder ending in "/", or "path#Section" for one `// MARK: Section` of a
// big file (the lines from that mark to the next). Values are check names, "all", or [] (nothing beyond the unit
// tests, which always run).
//
// Anything without an entry runs the whole suite, so a missing entry costs time, never coverage. When you add a
// file, a MARK section or a check, add it here in the same change.

const pages = ["page-channel", "navigate", "target-blank", "window-open", "background-tab", "create-target",
  "activate-target", "page-closes-itself", "close-target"];
const permissions = ["permission", "permission-allow"];
const commandBar = ["address-new-tab", "address-cancel", "bar-lists-tabs", "bar-switch-to-tab", "bar-history",
  "address-navigate", "address-javascript", "bar-one-row", "bar-search-suggestions", "bar-search-google", "bar-actions"];
const drag = ["drag-click-selects", "drag-reorder", "drag-to-pin", "drag-to-favorite", "drag-pin-hint-gone",
  "drag-out-cancels", "drag-favorite-to-today"];
const sidebarMotion = ["sidebar-toggle", "peek-zones", "window-lights", "toggle-keeps-page-still"];
const pageSurface = ["switch-back-latency", "top-strip-click", "toggle-keeps-page-still", "activate-target",
  "devtools-docked", "background-tab"];

const settings = ["settings-window", "settings-minimal-url", "settings-loading-progress", "settings-theme",
  "settings-zoom", "settings-private-zoom", "settings-new-tab-position", "settings-recent-tab-cycling",
  "settings-shortcuts", "settings-routes", "settings-trimmed", "settings-persist"];

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
  "Host/EngineCalls.swift": "all",
  "Host/TestEnvironment.swift": "all",
  // Colours only: the checks that read a colour or draw with it.
  "Host/ProfileColor.swift": ["page-loading", "site-controls", "tile-hover", "drag-to-favorite", "settings-theme", "settings-window"],
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
  "Host/BrowserWindowController.swift#Browser import": ["import-browser", "arc-import", "onboarding"],
  "Host/BrowserWindowController.swift#Onboarding": ["onboarding"],
  "Host/BrowserWindowController.swift#Permission prompts": permissions,
  "Host/BrowserWindowController.swift#Toast": ["copy-url", "page-commands"],
  "Host/BrowserWindowController.swift#Find in page": ["find-in-page", "copy-url"],
  "Host/BrowserWindowController.swift#Site controls": ["site-controls", "extensions", "copy-url", "find-in-page"],
  "Host/BrowserWindowController.swift#Entries": "all",
  "Host/BrowserWindowController.swift#Page toolbar": ["page-toolbar", "page-loading", "load-sweep-once", "site-controls",
    "sidebar-toggle"],
  "Host/BrowserWindowController.swift#Sidebar visibility": [...sidebarMotion, "page-toolbar", "downloads"],
  "Host/BrowserWindowController.swift#Command bar": [...commandBar, "copy-url", "onboarding"],
  "Host/BrowserWindowController.swift#Pages": pageSurface,
  "Host/BrowserWindowController.swift#SidebarViewDelegate": "all",
  "Host/BrowserWindowController.swift#RayCoreWindowDelegate": [...pages, "private-window", "close-last-window"],
  "Host/BrowserWindowController.swift#RayCoreTabDelegate": [...pages, ...permissions, "page-toolbar", "page-loading",
    "load-sweep-once", "site-controls", "find-in-page", "settings-zoom", "settings-routes", "settings-trimmed"],
  "Host/BrowserWindowController.swift#Settings": [...settings, "page-toolbar", "page-loading"],
  "Host/BrowserWindowController.swift#Page commands": ["page-commands"],
  "Host/BrowserWindowController.swift#Page zoom": ["settings-zoom", "settings-private-zoom", "settings-window", "site-controls",
    "page-commands"],
  "Host/BrowserWindowController.swift#State log": [],

  // The rest of SidebarView (rows, tiles, the address field, the top row): the sidebar's own checks.
  "Host/SidebarView.swift": [...drag, "folder-create", "folder-toggle", "folder-rename", "folder-animation",
    "folder-drag-in", "folder-drag-folder", "folder-out-and-delete", "tile-hover", "favorites", "pin-unload-restore",
    "sidebar-toggle", "peek-zones", "window-lights", "page-toolbar", "clear", "downloads"],
  "Host/SidebarView.swift#Folder fold": ["folder-animation", "folder-toggle", "folder-rename", ...drag],
  "Host/SidebarView.swift#Drag and drop": [...drag, "folder-drag-in", "folder-drag-folder"],
  "Host/SidebarView.swift#Downloads panel": ["downloads"],

  "Host/AddressInput.swift": [...commandBar, "page-toolbar", "site-controls", "settings-routes", "settings-trimmed"],
  "Host/RaySettings.swift": "all",
  "Host/SettingsWindow.swift": [...settings, "onboarding"],
  "Host/ArcImport.swift": ["arc-import"],
  // The first run's welcome and File › Import from Browser… (on the fake importer).
  "Host/Onboarding.swift": ["onboarding"],
  "Host/RaySettings.swift#Onboarding": ["onboarding"],
  // The settings in the state log: the checks that compare them (the restore check reads them after settings-persist).
  "Host/RaySettings.swift#State log": [...settings, "onboarding"],
  "Host/CommandBarView.swift": commandBar,
  "Host/Suggestions.swift": commandBar,
  // The command bar's action rows: menu commands by name (they run through the menu's own validation and selectors).
  "Host/BarActions.swift": [...commandBar, "page-commands", "copy-url"],
  "Host/Downloads.swift": ["downloads", "download-insecure-blocked"],
  "Host/Extensions.swift": ["extensions", "extension-prompt", "site-controls"],
  "Host/FindBar.swift": ["find-in-page"],
  "Host/PageContainerView.swift": pageSurface,
  "Host/PageToolbar.swift": ["page-toolbar", "page-loading", "load-sweep-once", "site-controls", "sidebar-toggle",
    "top-strip-click"],
  // Which loads the address field sweeps for.
  "Host/LoadSweep.swift": ["page-loading", "load-sweep-once", "settings-loading-progress", "page-toolbar"],
  "Host/PermissionPrompt.swift": permissions,
  "Host/SiteControls.swift": ["site-controls", "extensions"],
  "Host/Spring.swift": [...sidebarMotion, "drag-reorder"],
  "Host/Toast.swift": ["copy-url", "page-commands"],
  "Host/Updater.swift": ["updater-config"],
  "Host/SafeStorage.swift": ["safe-storage-migration"],
  "Host/WindowDragArea.swift": ["top-strip-click", "window-lights", "drag-click-selects"],
  // Test hooks: the feature's own files bring in its checks.
  "Host/TestCommands.swift": ["folder-rename", "tile-hover", "import-browser", "onboarding", "bar-actions", "load-sweep-once"],

  // Nothing to run beyond the unit tests.
  "tests/AddressInputTests.swift": [],
  "tests/SafeStorageTests.swift": [],
  // The importer's own tests (swift test) cover its readers; import-browser runs it end to end in the app, and
  // onboarding drives its screens on the importer's fixtures.
  "Importer/": ["import-browser", "onboarding"],
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
  "folder-rename": ["folder-create"],
  "folder-animation": ["folder-create"],
  "folder-drag-in": ["folder-create"],
  "folder-drag-folder": ["folder-create"],
  "folder-out-and-delete": ["folder-create"],
  "drag-to-favorite": ["drag-click-selects", "drag-reorder", "drag-to-pin"],
};
