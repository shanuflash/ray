import AppKit

enum Shortcuts {
  private static let tabKey: UInt16 = 48

  static func isReserved(_ event: NSEvent) -> Bool {
    guard event.type == .keyDown else { return false }
    let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
    let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
    switch modifiers {
    case [.command]:
      // ⌘, is Chrome's too (it opens chrome://settings): Ray's Settings window takes it first.
      return ["t", "w", "n", "q", ","].contains(key)
    case [.command, .shift]:
      return ["t", "w", "n", "[", "]", "{", "}"].contains(key)
    case [.control], [.control, .shift]:
      return event.keyCode == tabKey
    default:
      return false
    }
  }
}
