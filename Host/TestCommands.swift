import AppKit

enum TestCommands {
  private static var buffer = ""

  static func start() {
    guard TestEnvironment["RAY_TEST_COMMANDS"] == "1" else { return }
    FileHandle.standardInput.readabilityHandler = { handle in
      guard let text = String(data: handle.availableData, encoding: .utf8), !text.isEmpty else {
        handle.readabilityHandler = nil
        return
      }
      DispatchQueue.main.async { receive(text) }
    }
  }

  private static func receive(_ text: String) {
    buffer += text
    while let newline = buffer.firstIndex(of: "\n") {
      let line = String(buffer[..<newline])
      buffer.removeSubrange(...newline)
      run(line)
    }
  }

  private static func key(_ argument: String, in window: NSWindow?) -> String {
    let parts = argument.split(separator: " ").map(String.init)
    guard let window, let character = parts.first, let code = keyCodes[character] else { return "usage: key <char> [cmd shift opt ctrl]" }
    var flags: NSEvent.ModifierFlags = []
    if parts.contains("cmd") { flags.insert(.command) }
    if parts.contains("shift") { flags.insert(.shift) }
    if parts.contains("opt") { flags.insert(.option) }
    if parts.contains("ctrl") { flags.insert(.control) }
    // `keywin`: make the window key first (without ordering it front), so the press takes AppKit's real key path.
    if parts.contains("keywin") { window.makeKey() }
    // A real keyboard reports the shifted character (⇧⌘C arrives as "C"), even ignoring modifiers.
    let typed = character == "tab" ? "\t" : character
    let shown = flags.contains(.shift) ? typed.uppercased() : typed
    for type in [NSEvent.EventType.keyDown, .keyUp] {
      guard let event = NSEvent.keyEvent(
        with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber, context: nil, characters: shown, charactersIgnoringModifiers: shown,
        isARepeat: false, keyCode: code) else { return "no event" }
      // keywin presses go through the event queue, as real keystrokes do (local event monitors see them there).
      if parts.contains("keywin") { NSApp.postEvent(event, atStart: false) } else { NSApp.sendEvent(event) }
    }
    return "ok"
  }

  private static let keyCodes: [String: UInt16] = ["s": 1, "t": 17, "w": 13, "l": 37, "r": 15, "d": 2, "c": 8, "f": 3, "g": 5, "n": 45, "esc": 53, "tab": 48, ",": 43, "=": 24, "-": 27,
                                                     "0": 29, "p": 35, "u": 32, "y": 16]

  /// `key ctrlup`: Control let go, as a real keyboard reports it (through the event queue, where local monitors see it).
  private static func releaseControl(in window: NSWindow?) -> String {
    guard let window, let event = NSEvent.keyEvent(
      with: .flagsChanged, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
      windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
      isARepeat: false, keyCode: 59) else { return "no event" }
    NSApp.postEvent(event, atStart: false)
    return "ok"
  }

  /// `setting <name> <value>`: a setting changed through `RaySettings.apply`, the call the Settings window's own
  /// controls make. `settings open|close|link|snap <path>` drive the window itself.
  private static func setting(_ argument: String) -> String {
    let words = argument.split(separator: " ", maxSplits: 1).map(String.init)
    guard words.count == 2, let key = RaySetting(rawValue: words[0]), RaySettings.shared.apply(key, words[1]) else {
      return "usage: setting <\(RaySetting.allCases.map(\.rawValue).joined(separator: "|"))> <value>"
    }
    return "ok"
  }

  private static func settingsWindow(_ argument: String) -> String {
    let words = argument.split(separator: " ", maxSplits: 1).map(String.init)
    switch words.first {
    case "open": SettingsWindowController.shared.show()
    case "close": SettingsWindowController.shared.close()
    case "link": if !SettingsWindowController.shared.pressAllSettings() { return "no window" }
    case "press":
      guard words.count == 2, SettingsWindowController.shared.press(words[1].split(separator: " ").map(String.init)) else {
        return "no such control"
      }
    case "snap":
      guard words.count == 2, SettingsWindowController.shared.snapshot(to: words[1]) else { return "no window" }
    default: return "usage: settings open|close|link|snap <path>"
    }
    return "ok"
  }

  /// `press x y`, `move x y`, `release x y`: one mouse drag in steps, so checks can look at it mid-way.
  private static func mouse(_ type: NSEvent.EventType, _ argument: String, in window: NSWindow?) -> String {
    let numbers = argument.split(separator: " ").compactMap { Double($0) }
    guard let window, let content = window.contentView, numbers.count == 2 || numbers.count == 3 else {
      return "usage: press|move|release x y [clickCount]"
    }
    guard let event = NSEvent.mouseEvent(
      with: type, location: NSPoint(x: numbers[0], y: content.bounds.height - numbers[1]), modifierFlags: [],
      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
      eventNumber: 0, clickCount: numbers.count == 3 ? Int(numbers[2]) : 1, pressure: 1) else { return "no event" }
    NSApp.sendEvent(event)
    return "ok"
  }

  private static func drag(_ argument: String, in window: NSWindow?) -> String {
    let numbers = argument.split(separator: " ").compactMap { Double($0) }
    guard let window, let content = window.contentView, numbers.count == 4 else { return "usage: drag x y dx dy" }
    let start = NSPoint(x: numbers[0], y: content.bounds.height - numbers[1])
    func post(_ type: NSEvent.EventType, _ point: NSPoint) {
      guard let event = NSEvent.mouseEvent(
        with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { return }
      NSApp.sendEvent(event)
    }
    post(.leftMouseDown, start)
    for step in 1...5 {
      let t = Double(step) / 5
      post(.leftMouseDragged, NSPoint(x: start.x + numbers[2] * t, y: start.y - numbers[3] * t))
    }
    post(.leftMouseUp, NSPoint(x: start.x + numbers[2], y: start.y - numbers[3]))
    return "ok"
  }

  private static func rowAction(_ argument: String) -> String {
    let parts = argument.split(separator: " ").map(String.init)
    let actions: [String: SidebarRowAction] = [
      "pin": .pin, "unpin": .unpin, "favorite": .addToFavorites, "unfavorite": .removeFromFavorites,
      "back": .backToPinned, "close": .close, "unload": .unload, "newfolder": .newFolder,
      "nestfolder": .newNestedFolder, "togglefolder": .toggleFolder, "outfolder": .removeFromFolder,
      "deletefolder": .deleteFolder, "renamefolder": .renameFolder,
    ]
    guard parts.count >= 2, let id = UUID(uuidString: parts[1]),
          let controller = AppController.shared.current, let entry = controller.state.entry(id: id) else {
      return "usage: rowaction <action> <id> [folder id]"
    }
    if parts[0] == "infolder", parts.count == 3, let folder = UUID(uuidString: parts[2]) {
      controller.perform(.moveToFolder(folder), on: entry)
    } else if let action = actions[parts[0]], parts.count == 2 {
      controller.perform(action, on: entry)
    } else {
      return "usage: rowaction <action> <id> [folder id]"
    }
    return "ok"
  }

  /// `extprompt fake <name>` shows an install prompt as the engine would; `extprompt accept|cancel` clicks it.
  private static func extensionPrompt(_ argument: String) -> String {
    guard let controller = AppController.shared.current else { return "no window" }
    let parts = argument.split(separator: " ", maxSplits: 1).map(String.init)
    switch parts.first {
    case "fake":
      controller.extensions.showInstallPrompt([
        "requestId": "test-install", "id": "abcdefghijklmnopabcdefghijklmnop", "name": parts.count > 1 ? parts[1] : "Test",
        "version": "1.0", "permissions": ["Read and change all your data on all websites"],
      ], in: controller.window)
      return "ok"
    case "accept": return controller.extensions.answerPrompt(accept: true) ? "ok" : "not ready"
    case "cancel": return controller.extensions.answerPrompt(accept: false) ? "ok" : "no prompt"
    default: return "usage: extprompt fake <name> | accept | cancel"
    }
  }

  /// `rename <id> <title…>`: what the inline editor commits.
  private static func rename(_ argument: String) -> String {
    let parts = argument.split(separator: " ", maxSplits: 1).map(String.init)
    guard parts.count == 2, let id = UUID(uuidString: parts[0]), let controller = AppController.shared.current,
          let entry = controller.state.entry(id: id) else { return "usage: rename <id> <title>" }
    controller.rename(entry, to: parts[1])
    return "ok"
  }

  private static func run(_ line: String) {
    let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
    guard let command = parts.first else { return }
    let argument = parts.count > 1 ? parts[1] : ""
    let window = AppController.shared.current?.window
    let editor = window?.firstResponder as? NSTextView
    var result = "ok"
    switch command {
    case "menu":
      if !NSApp.sendAction(Selector(argument + ":"), to: AppController.shared, from: nil) { result = "no action" }
    case "type":
      if let editor { editor.insertText(argument, replacementRange: editor.selectedRange()) } else { result = "no editor" }
    case "enter":
      if let editor { editor.doCommand(by: #selector(NSResponder.insertNewline(_:))) } else { result = "no editor" }
    case "escape":
      if let editor { editor.doCommand(by: #selector(NSResponder.cancelOperation(_:))) } else { result = "no editor" }
    case "down":
      if let editor { editor.doCommand(by: #selector(NSResponder.moveDown(_:))) } else { result = "no editor" }
    case "up":
      if let editor { editor.doCommand(by: #selector(NSResponder.moveUp(_:))) } else { result = "no editor" }
    case "row":
      if let id = UUID(uuidString: argument), AppController.shared.current?.selectEntry(id: id) == true {} else {
        result = "no entry"
      }
    case "rowaction":
      result = rowAction(argument)
    case "rename":
      result = rename(argument)
    case "extinstall":
      AppController.shared.current?.extensions.installUnpacked(argument) { id in
        FileHandle.standardError.write("[ray-test] installed \(id ?? "nothing")\n".data(using: .utf8)!)
      }
    case "extrun":
      if let controller = AppController.shared.current, let tab = controller.activeTab {
        controller.extensions.run(argument, on: tab, anchor: controller.extensionsAnchor)
      } else {
        result = "no tab"
      }
    case "extprompt":
      result = extensionPrompt(argument)
    case "extclose":
      AppController.shared.current?.extensions.closePopup()
    case "arcimport":
      if AppController.shared.current?.answerArcImport(argument == "accept") != true { result = "no prompt" }
    case "closewindow":
      AppController.shared.current?.window.performClose(nil)
    case "reopen":
      _ = AppController.shared.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
    case "perm":
      if AppController.shared.current?.permissions.press(argument) != true { result = "not ready" }
    case "aboutsnap":
      AppController.shared.showAbout(nil)
      result = "no panel"
      if let panel = NSApp.windows.first(where: { $0.isVisible && $0 is NSPanel }), let view = panel.contentView,
         let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
        view.cacheDisplay(in: view.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]),
           (try? png.write(to: URL(fileURLWithPath: argument))) != nil { result = "ok" }
        panel.close()
      }
    case "site":
      if AppController.shared.current?.siteControlsCommand(argument.split(separator: " ").map(String.init)) != true {
        result = "no panel"
      }
    case "sitesnap":
      if AppController.shared.current?.snapshotSiteControls(to: argument) != true { result = "no panel" }
    case "toolbarsnap":
      if AppController.shared.current?.snapshotToolbar(to: argument) != true { result = "no toolbar" }
    case "toolbarreload":
      // The toolbar's reload button, which is a stop button while the page loads.
      AppController.shared.current?.pressToolbarReload()
    case "dlsnap":
      if AppController.shared.current?.snapshotDownloads(to: argument) != true { result = "no list" }
    case "dlopen":
      AppController.shared.current?.showDownloads()
    case "dl":
      let parts = argument.split(separator: " ").map(String.init)
      if parts.count == 2, ["keep", "discard"].contains(parts[0]), let controller = AppController.shared.current {
        if !controller.pressDownload(parts[1], keep: parts[0] == "keep") { result = "not ready" }
      } else {
        result = "usage: dl keep|discard <id>"
      }
    case "hover":
      let numbers = argument.split(separator: " ").compactMap { Double($0) }
      if numbers.count == 2 { AppController.shared.current?.hoverSidebar(at: NSPoint(x: numbers[0], y: numbers[1])) } else {
        result = "usage: hover x y"
      }
    case "renamedone":
      if AppController.shared.current?.pressRenameDone() != true { result = "not renaming" }
    case "pointer":
      let numbers = argument.split(separator: " ").compactMap { Double($0) }
      if numbers.count == 2 {
        AppController.shared.current?.pointer(at: NSPoint(x: numbers[0], y: numbers[1]), appActive: true)
      } else {
        result = "usage: pointer x y"
      }
    case "peek":
      if argument == "on" { AppController.shared.current?.beginPeek() } else { AppController.shared.current?.endPeek(animated: true) }
    case "terminate":
      NSApp.terminate(nil)
    case "state":
      AppController.shared.current?.logState("probe")
    case "hit":
      let numbers = argument.split(separator: " ").compactMap { Double($0) }
      if let window, let frameView = window.contentView?.superview, numbers.count == 2 {
        let point = NSPoint(x: numbers[0], y: frameView.bounds.height - numbers[1])
        var chain: [String] = []
        var view = frameView.hitTest(point)
        while let current = view, chain.count < 6 {
          chain.append(String(describing: type(of: current)))
          view = current.superview
        }
        result = chain.joined(separator: " < ")
      }
    case "key":
      result = argument == "ctrlup" ? releaseControl(in: window) : key(argument, in: window)
    case "setting":
      result = setting(argument)
    case "settings":
      result = settingsWindow(argument)
    case "zoom":
      if AppController.shared.current?.zoomCommand(argument) != true { result = "usage: zoom in|out|reset (a page open)" }
    case "drag":
      result = drag(argument, in: window)
    case "press":
      result = mouse(.leftMouseDown, argument, in: window)
    case "move":
      result = mouse(.leftMouseDragged, argument, in: window)
    case "release":
      result = mouse(.leftMouseUp, argument, in: window)
    default:
      result = "unknown"
    }
    FileHandle.standardError.write("[ray-test] \(line) -> \(result)\n".data(using: .utf8)!)
  }
}
