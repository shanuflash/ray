import AppKit

enum TestCommands {
  private static var buffer = ""

  static func start() {
    guard TestEnvironment["LUMEN_TEST_COMMANDS"] == "1" else { return }
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
      "back": .backToPinned, "close": .close, "unload": .unload,
    ]
    guard parts.count == 2, let action = actions[parts[0]], let id = UUID(uuidString: parts[1]),
          let controller = AppController.shared.current, let entry = controller.state.entry(id: id) else {
      return "usage: rowaction <action> <id>"
    }
    controller.perform(action, on: entry)
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
    case "drag":
      result = drag(argument, in: window)
    default:
      result = "unknown"
    }
    FileHandle.standardError.write("[lumen-test] \(line) -> \(result)\n".data(using: .utf8)!)
  }
}
