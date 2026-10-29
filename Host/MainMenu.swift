import AppKit

enum MainMenu {
  static func install(target: AppController) {
    let main = NSMenu()

    main.addItem(submenu("Ray", [
      item("About Ray", #selector(AppController.showAbout(_:)), nil, target: target),
      item("Check for Updates…", #selector(AppController.checkForUpdates(_:)), nil, target: target),
      .separator(),
      item("Settings…", #selector(AppController.showSettings(_:)), ",", target: target),
      // Held ⌥ turns Settings… into this (an alternate shares the key, so ⌥⌘, opens it too).
      optionAlternate(item("Show Welcome Again", #selector(AppController.showWelcomeAgain(_:)), ",", [.command, .option], target: target)),
      item("Clear Browsing Data…", #selector(AppController.clearBrowsingData(_:)), backspace, [.command, .shift], target: target),
      .separator(),
      item("Hide Ray", #selector(NSApplication.hide(_:)), "h", target: NSApp),
      item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option], target: NSApp),
      item("Show All", #selector(NSApplication.unhideAllApplications(_:)), nil, target: NSApp),
      .separator(),
      item("Quit Ray", #selector(AppController.quit(_:)), "q", target: target),
    ]))

    main.addItem(submenu("File", [
      item("New Tab", #selector(AppController.newTab(_:)), "t", target: target),
      item("New Window", #selector(AppController.newWindow(_:)), "n", target: target),
      item("New Private Window", #selector(AppController.newPrivateWindow(_:)), "n", [.command, .shift], target: target),
      item("Open Location…", #selector(AppController.focusAddress(_:)), "l", target: target),
      .separator(),
      item("Close Tab", #selector(AppController.closeTab(_:)), "w", target: target),
      .separator(),
      item("Pin Tab", #selector(AppController.togglePin(_:)), "d", target: target),
      item("New Folder", #selector(AppController.newFolder(_:)), "n", [.command, .option], target: target),
      item("Back to Pinned URL", #selector(AppController.backToPinned(_:)), nil, target: target),
      item("Clear Today's Tabs", #selector(AppController.clearToday(_:)), nil, target: target),
      .separator(),
      item("Import from Browser…", #selector(AppController.importFromBrowser(_:)), nil, target: target),
      .separator(),
      // ⌘S is Toggle Sidebar unless Settings frees it; then it's Save Page As, as in Chrome (applyShortcutSettings).
      item("Save Page As…", #selector(AppController.savePage(_:)), nil, target: target),
      item("Print…", #selector(AppController.printPage(_:)), "p", target: target),
      item("Print Using System Dialog…", #selector(AppController.printWithSystemDialog(_:)), "p", [.command, .option], target: target),
    ]))

    main.addItem(submenu("Edit", [
      item("Undo", Selector(("undo:")), "z"),
      item("Redo", Selector(("redo:")), "z", [.command, .shift]),
      .separator(),
      item("Cut", #selector(NSText.cut(_:)), "x"),
      item("Copy", #selector(NSText.copy(_:)), "c"),
      item("Paste", #selector(NSText.paste(_:)), "v"),
      item("Paste and Match Style", #selector(NSTextView.pasteAsPlainText(_:)), "v", [.command, .option, .shift]),
      item("Select All", #selector(NSText.selectAll(_:)), "a"),
      .separator(),
      item("Copy URL", #selector(AppController.copyURL(_:)), "c", [.command, .shift], target: target),
      .separator(),
      item("Find…", #selector(AppController.find(_:)), "f", target: target),
      item("Find Next", #selector(AppController.findNext(_:)), "g", target: target),
      item("Find Previous", #selector(AppController.findPrevious(_:)), "g", [.command, .shift], target: target),
    ]))

    main.addItem(submenu("View", [
      item("Toggle Sidebar", #selector(AppController.toggleSidebar(_:)), "s", target: target),
      item("Show Address Bar on Page", #selector(AppController.toggleToolbar(_:)), nil, target: target),
      item("Show Full Address", #selector(AppController.toggleFullAddress(_:)), nil, target: target),
      item("Site Controls", #selector(AppController.toggleSiteControls(_:)), nil, target: target),
      .separator(),
      item("Reload Page", #selector(AppController.reload(_:)), "r", target: target),
      item("Force Reload Page", #selector(AppController.reloadIgnoringCache(_:)), "r", [.command, .shift], target: target),
      .separator(),
      item("Actual Size", #selector(AppController.actualSize(_:)), "0", target: target),
      item("Zoom In", #selector(AppController.zoomIn(_:)), "+", target: target),
      // ⌘= is the unshifted ⌘+ on most keyboards, as Chrome takes it.
      item("Zoom In", #selector(AppController.zoomIn(_:)), "=", target: target, alternate: true),
      item("Zoom Out", #selector(AppController.zoomOut(_:)), "-", target: target),
      .separator(),
      item("Downloads", #selector(AppController.showDownloads(_:)), "l", [.command, .option], target: target),
      item("Developer Tools", #selector(AppController.toggleDevTools(_:)), "i", [.command, .option], target: target),
      item("View Source", #selector(AppController.viewSource(_:)), "u", [.command, .option], target: target),
      .separator(),
      item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
    ]))

    main.addItem(submenu("History", [
      item("Back", #selector(AppController.goBack(_:)), "[", target: target),
      item("Forward", #selector(AppController.goForward(_:)), "]", target: target),
      .separator(),
      item("Show Full History", #selector(AppController.showHistory(_:)), "y", target: target),
    ]))

    var tabItems: [NSMenuItem] = [
      item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
      item("Zoom", #selector(NSWindow.performZoom(_:)), nil),
      .separator(),
      item("Task Manager", #selector(AppController.taskManager(_:)), nil, target: target),
      .separator(),
      item("Show Next Tab", #selector(AppController.nextTab(_:)), "]", [.command, .shift], target: target),
      item("Show Previous Tab", #selector(AppController.previousTab(_:)), "[", [.command, .shift], target: target),
      // ⌃Tab: most recently used order when Settings says so (and the sidebar's order when it doesn't).
      item("Show Next Tab", #selector(AppController.nextTabWithControl(_:)), "\t", [.control], target: target, alternate: true),
      item("Show Previous Tab", #selector(AppController.previousTabWithControl(_:)), "\t", [.control, .shift], target: target, alternate: true),
      .separator(),
    ]
    for number in 1...9 {
      let entry = item(number == 9 ? "Last Tab" : "Tab \(number)", #selector(AppController.selectTab(_:)), "\(number)", target: target)
      entry.tag = number
      tabItems.append(entry)
    }
    let window = submenu("Window", tabItems)
    main.addItem(window)

    NSApp.mainMenu = main
    NSApp.windowsMenu = window.submenu
    applyShortcutSettings()
  }

  /// Settings can take ⇧⌘C and ⌘S away from the menu, so the page gets those keys. Run at launch and on every change.
  static func applyShortcutSettings() {
    let values = RaySettings.shared.values
    setKey(#selector(AppController.copyURL(_:)), on: values.copyLinkShortcut, key: "C", modifiers: [.command, .shift])
    setKey(#selector(AppController.toggleSidebar(_:)), on: values.sidebarShortcut, key: "s", modifiers: [.command])
    setKey(#selector(AppController.savePage(_:)), on: !values.sidebarShortcut, key: "s", modifiers: [.command])
  }

  private static func setKey(_ action: Selector, on: Bool, key: String, modifiers: NSEvent.ModifierFlags) {
    guard let menu = NSApp.mainMenu, let entry = find(action, in: menu) else { return }
    entry.keyEquivalent = on ? key : ""
    entry.keyEquivalentModifierMask = on ? modifiers : []
  }

  private static func find(_ action: Selector, in menu: NSMenu) -> NSMenuItem? {
    for item in menu.items {
      if item.action == action { return item }
      if let found = item.submenu.flatMap({ find(action, in: $0) }) { return found }
    }
    return nil
  }

  /// For tests: the key a menu item answers to now ("" for none).
  static func keyEquivalent(of action: Selector) -> String? {
    NSApp.mainMenu.flatMap { find(action, in: $0) }?.keyEquivalent
  }

  /// For tests: an item's key, whether it shows only while ⌥ is held, and the item it stands in for.
  static func alternateInfo(of action: Selector) -> [String: Any]? {
    guard let main = NSApp.mainMenu, let item = find(action, in: main), let menu = item.menu else { return nil }
    let at = menu.index(of: item)
    let before = at > 0 ? menu.items[at - 1] : nil
    return ["title": item.title, "key": item.keyEquivalent, "option": item.keyEquivalentModifierMask.contains(.option),
            "alternate": item.isAlternate, "after": before?.title ?? NSNull()]
  }

  /// An item that replaces the one before it while ⌥ is held (same key, ⌥ added).
  private static func optionAlternate(_ entry: NSMenuItem) -> NSMenuItem {
    entry.isAlternate = true
    return entry
  }

  /// ⌫ as a key equivalent (Clear Browsing Data is ⇧⌘⌫ in Chrome).
  private static let backspace = String(UnicodeScalar(UInt8(NSBackspaceCharacter)))

  private static func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
    let menu = NSMenu(title: title)
    items.forEach(menu.addItem)
    let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    holder.submenu = menu
    return holder
  }

  private static func item(
    _ title: String,
    _ action: Selector,
    _ key: String?,
    _ modifiers: NSEvent.ModifierFlags = [.command],
    target: AnyObject? = nil,
    alternate: Bool = false
  ) -> NSMenuItem {
    // A shifted letter must be written uppercase: ⇧⌘C arrives as "C", which an item keyed "c" + Shift never matches.
    let shifted = modifiers.contains(.shift) && key?.count == 1 && key?.first?.isLetter == true
    let entry = NSMenuItem(title: title, action: action, keyEquivalent: shifted ? key!.uppercased() : key ?? "")
    entry.keyEquivalentModifierMask = key == nil ? [] : modifiers
    entry.target = target
    entry.isHidden = alternate
    entry.allowsKeyEquivalentWhenHidden = alternate
    return entry
  }
}
