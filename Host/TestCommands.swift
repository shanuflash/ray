import AppKit

enum TestCommands {
  private static var buffer = ""

  static func start() {
    guard environment["LUMEN_TEST_COMMANDS"] == "1" else { return }
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
    default:
      result = "unknown"
    }
    FileHandle.standardError.write("[lumen-test] \(line) -> \(result)\n".data(using: .utf8)!)
  }
}
