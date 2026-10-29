import AppKit

enum Shortcuts {
  /// Whether a key press is one of Chrome's reserved commands' (New Tab, Close Tab, New Window, New Private Window,
  /// Quit, Settings, Reopen Closed Tab, Show Next and Previous Tab, ⌃Tab), as their keys are now: Ray's menu takes it
  /// before the page. The keys follow the commands when Settings › Shortcuts changes them (`MenuShortcuts.isReserved`).
  static func isReserved(_ event: NSEvent) -> Bool {
    guard event.type == .keyDown else { return false }
    return MenuShortcuts.isReserved(event)
  }
}
