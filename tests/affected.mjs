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
  "address-navigate", "address-javascript", "bar-one-row", "bar-search-suggestions"];
const drag = ["drag-click-selects", "drag-reorder", "drag-to-pin", "drag-to-favorite", "drag-pin-hint-gone",
  "drag-out-cancels", "drag-favorite-to-today"];
const sidebarMotion = ["sidebar-toggle", "peek-zones", "window-lights", "toggle-keeps-page-still"];
const pageSurface = ["switch-back-latency", "top-strip-click", "toggle-keeps-page-still", "activate-target",
  "devtools-docked", "background-tab"];

export const areas = {
  // Central: windows, menus, key routing, saved state, the engine bridge.
  "Host/AppController.swift": "all",
  "Host/MainMenu.swift": "all",
  "Host/Shortcuts.swift": "all",
  "Host/SidebarModel.swift": "all",
  "Host/EngineCalls.swift": "all",
  "Host/TestEnvironment.swift": "all",
  "Host/ProfileColor.swift": "all",
  "Host/main.swift": "all",
  "Host/Bridging.h": "all",
  "Resources/": "all",
  "vendor/": "all",
  "engine.lock": "all",
  "scripts/build-app.sh": "all",
  "tools/": "all",
  "Branding/": ["about-panel"],

  // BrowserWindowController: by section. Lines outside them (properties, init) run everything.
  "Host/BrowserWindowController.swift#Layout": [...sidebarMotion, ...pageSurface, "page-toolbar", "site-controls",
    "find-in-page", "copy-url"],
  "Host/BrowserWindowController.swift#Extensions and downloads": ["extensions", "extension-prompt", "downloads",
    "download-insecure-blocked", "site-controls"],
  "Host/BrowserWindowController.swift#Test snapshots": ["folder-rename", "tile-hover"],
  "Host/BrowserWindowController.swift#Arc import": ["arc-import"],
  "Host/BrowserWindowController.swift#Permission prompts": permissions,
  "Host/BrowserWindowController.swift#Toast": ["copy-url"],
  "Host/BrowserWindowController.swift#Find in page": ["find-in-page", "copy-url"],
  "Host/BrowserWindowController.swift#Site controls": ["site-controls", "extensions", "copy-url", "find-in-page"],
  "Host/BrowserWindowController.swift#Entries": "all",
  "Host/BrowserWindowController.swift#Page toolbar": ["page-toolbar", "page-loading", "site-controls", "sidebar-toggle"],
  "Host/BrowserWindowController.swift#Sidebar visibility": [...sidebarMotion, "page-toolbar", "downloads"],
  "Host/BrowserWindowController.swift#Command bar": [...commandBar, "copy-url"],
  "Host/BrowserWindowController.swift#Pages": pageSurface,
  "Host/BrowserWindowController.swift#SidebarViewDelegate": "all",
  "Host/BrowserWindowController.swift#ArdiaCoreWindowDelegate": [...pages, "private-window", "close-last-window"],
  "Host/BrowserWindowController.swift#ArdiaCoreTabDelegate": [...pages, ...permissions, "page-toolbar", "page-loading",
    "site-controls", "find-in-page"],
  "Host/BrowserWindowController.swift#State log": [],

  "Host/SidebarView.swift#Folder fold": ["folder-animation", "folder-toggle", "folder-rename", ...drag],
  "Host/SidebarView.swift#Drag and drop": [...drag, "folder-drag-in", "folder-drag-folder"],
  "Host/SidebarView.swift#Downloads panel": ["downloads"],

  "Host/AddressInput.swift": [...commandBar, "page-toolbar", "site-controls"],
  "Host/ArcImport.swift": ["arc-import"],
  "Host/CommandBarView.swift": commandBar,
  "Host/Suggestions.swift": commandBar,
  "Host/Downloads.swift": ["downloads", "download-insecure-blocked"],
  "Host/Extensions.swift": ["extensions", "extension-prompt", "site-controls"],
  "Host/FindBar.swift": ["find-in-page"],
  "Host/PageContainerView.swift": pageSurface,
  "Host/PageToolbar.swift": ["page-toolbar", "page-loading", "site-controls", "sidebar-toggle", "top-strip-click"],
  "Host/PermissionPrompt.swift": permissions,
  "Host/SiteControls.swift": ["site-controls", "extensions"],
  "Host/Spring.swift": [...sidebarMotion, "drag-reorder"],
  "Host/Toast.swift": ["copy-url"],
  "Host/WindowDragArea.swift": ["top-strip-click", "window-lights", "drag-click-selects"],
  // Test hooks: the feature's own files bring in its checks.
  "Host/TestCommands.swift": ["folder-rename", "tile-hover"],

  // Nothing to run beyond the unit tests.
  "tests/AddressInputTests.swift": [],
  "tests/affected.mjs": [],
  "tests/changed.mjs": [],
  "scripts/test.sh": [],
  "scripts/relaunch.sh": [],
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
