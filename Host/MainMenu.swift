import AppKit

enum MainMenu {
  static func install(target: AppController) {
    let main = NSMenu()

    main.addItem(submenu("Ray", [
      item("About Ray", #selector(AppController.showAbout(_:)), nil, target: target),
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
      item("Import from Arc…", #selector(AppController.importFromArc(_:)), nil, target: target),
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
      item("Downloads", #selector(AppController.showDownloads(_:)), "l", [.command, .option], target: target),
      item("Developer Tools", #selector(AppController.toggleDevTools(_:)), "i", [.command, .option], target: target),
      .separator(),
      item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
    ]))

    main.addItem(submenu("History", [
      item("Back", #selector(AppController.goBack(_:)), "[", target: target),
      item("Forward", #selector(AppController.goForward(_:)), "]", target: target),
    ]))

    var tabItems: [NSMenuItem] = [
      item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
      item("Zoom", #selector(NSWindow.performZoom(_:)), nil),
      .separator(),
      item("Show Next Tab", #selector(AppController.nextTab(_:)), "]", [.command, .shift], target: target),
      item("Show Previous Tab", #selector(AppController.previousTab(_:)), "[", [.command, .shift], target: target),
      item("Show Next Tab", #selector(AppController.nextTab(_:)), "\t", [.control], target: target, alternate: true),
      item("Show Previous Tab", #selector(AppController.previousTab(_:)), "\t", [.control, .shift], target: target, alternate: true),
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
  }

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
