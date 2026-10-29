import AppKit

/// Settings › General's two warnings, each a sheet with "Don't ask again" (which turns its setting off):
/// - ⌘Q, when "Warn before quitting with ⌘Q" is on: "Quit Ray?" over the window you're in. Pressing ⌘Q again quits.
///   Only Ray › Quit Ray asks; quitting from the Dock, logging out or an update's relaunch never does (as in Chrome and
///   Ardia, whose warnings are for ⌘Q only).
/// - Closing a window, when "Warn before closing a window with several tabs" is on and the close would lose two or
///   more tabs. Only a private window loses its tabs; the normal window's stay in Sidebar.json and ⌘N brings them back
///   (as Arc keeps a closed window's tabs in its Space), so it never asks.
enum CloseWarnings {
  /// Two or more, as Ardia counts (`windowClose.ts`, MIN_TABS).
  static let severalTabs = 2

  private enum Kind: String {
    case quit, close
  }

  /// The warning showing now.
  private static var showing: (kind: Kind, alert: NSAlert, window: NSWindow)?
  /// What was asked last and how it was answered, for the state log.
  private static var last: [String: Any]?
  /// Set by the warning's Quit: the quit it started goes through.
  private static var quitConfirmed = false
  /// Windows whose close the warning confirmed: their next close goes through.
  private static var closeConfirmed: [ObjectIdentifier] = []

  // MARK: Quitting

  /// ⌘Q: true to quit now. With the warning on, the first ⌘Q shows it (false); its Quit button, or ⌘Q again while it
  /// shows, calls `quit`.
  static func allowsQuit(then quit: @escaping () -> Void) -> Bool {
    if quitConfirmed { return true }
    guard RaySettings.shared[.warnBeforeQuitting] else { return true }
    if let showing {
      // ⌘Q again quits, as the warning says.
      guard showing.kind == .quit else { return false }
      answer(.alertFirstButtonReturn)
      return false
    }
    let alert = NSAlert()
    alert.messageText = "Quit Ray?"
    alert.informativeText = (RaySettings.shared[.onQuit] == "fresh"
      ? "Today's tabs close. Pinned tabs and favorites stay." : "Your tabs will be here when you open Ray again.")
      + " Press ⌘Q again to quit."
    alert.addButton(withTitle: "Quit")
    alert.addButton(withTitle: "Cancel")
    alert.showsSuppressionButton = true
    alert.suppressionButton?.title = "Don't ask again"
    // Over the window you're in; with none open there's nothing to lose by asking app-wide.
    let window = NSApp.keyWindow.flatMap { $0.attachedSheet == nil && !($0 is NSPanel) ? $0 : nil }
      ?? AppController.shared.current?.window
    guard let window, window.isVisible, window.attachedSheet == nil else {
      // No window to sit on: an app-wide alert (never in a test instance, which must not come forward).
      TestEnvironment.log("quit warning: no window to show it on (\(window == nil ? "none" : "hidden or busy"))")
      if TestEnvironment.isTestBuild { return true }
      last = ["kind": Kind.quit.rawValue, "title": alert.messageText, "message": alert.informativeText, "answer": NSNull()]
      quitConfirmed = finish(.quit, alert, alert.runModal())
      return quitConfirmed
    }
    show(.quit, alert, on: window) { confirmed in
      guard confirmed else { return }
      quitConfirmed = true
      DispatchQueue.main.async { quit() }
    }
    return false
  }

  /// The quit was cancelled after the warning let it through (a page's "leave site?", say): the next ⌘Q asks again.
  static func quitCancelled() { quitConfirmed = false }

  // MARK: Closing a window

  /// The window's close button, or ⌘W with no tab: true to close now. With the warning on and two or more tabs
  /// to lose, shows it (false); its Close button closes the window.
  static func allowsClose(_ controller: BrowserWindowController) -> Bool {
    let id = ObjectIdentifier(controller.window)
    if let at = closeConfirmed.firstIndex(of: id) {
      closeConfirmed.remove(at: at)
      return true
    }
    let tabs = tabsLost(closing: controller)
    guard RaySettings.shared[.warnBeforeClosingWindow], !AppController.shared.quitting, tabs >= severalTabs else { return true }
    // One warning at a time; a second close while it shows does nothing.
    guard showing == nil else { return false }
    let alert = NSAlert()
    alert.messageText = "Close \(tabs) tabs?"
    alert.informativeText = "This private window's tabs, and everything they keep, are gone once it closes."
    alert.addButton(withTitle: "Close Window")
    alert.addButton(withTitle: "Cancel")
    alert.showsSuppressionButton = true
    alert.suppressionButton?.title = "Don't ask again"
    let window = controller.window
    guard window.attachedSheet == nil else { return false }
    show(.close, alert, on: window) { confirmed in
      guard confirmed else { return }
      closeConfirmed.append(id)
      // Once the sheet is off the window: a window with a sheet on it doesn't close.
      DispatchQueue.main.async { window.performClose(nil) }
    }
    return false
  }

  /// The tabs a window's close throws away: a private window's, all of them; the normal window keeps its own.
  static func tabsLost(closing controller: BrowserWindowController) -> Int {
    controller.isPrivate ? controller.state.allEntries.filter { !$0.isFolder }.count : 0
  }

  // MARK: The sheet

  private static func show(_ kind: Kind, _ alert: NSAlert, on window: NSWindow, done: @escaping (Bool) -> Void) {
    showing = (kind, alert, window)
    last = ["kind": kind.rawValue, "title": alert.messageText, "message": alert.informativeText, "answer": NSNull()]
    log()
    alert.beginSheetModal(for: window) { response in
      showing = nil
      done(finish(kind, alert, response))
    }
  }

  /// Records the answer, turns the setting off on "Don't ask again" (with Quit or Close), and says whether to go on.
  private static func finish(_ kind: Kind, _ alert: NSAlert, _ response: NSApplication.ModalResponse) -> Bool {
    let confirmed = response == .alertFirstButtonReturn
    let suppressed = confirmed && alert.suppressionButton?.state == .on
    if suppressed {
      RaySettings.shared.set(kind == .quit ? AnySettingKey.warnBeforeQuitting : AnySettingKey.warnBeforeClosingWindow, false)
    }
    last?["answer"] = confirmed ? (suppressed ? "suppressed" : "confirmed") : "cancelled"
    log()
    return confirmed
  }

  /// Answers the warning as its buttons do.
  private static func answer(_ response: NSApplication.ModalResponse) {
    guard let showing else { return }
    showing.window.endSheet(showing.alert.window, returnCode: response)
  }

  private static func log() {
    DispatchQueue.main.async { AppController.shared.current?.logState("warning") }
  }

  // MARK: Tests

  /// `warning confirm|suppress|cancel`: the warning showing now answered as its buttons would (`suppress`: with
  /// "Don't ask again" ticked).
  static func command(_ word: String) -> String {
    guard let showing else { return "no warning" }
    switch word {
    case "confirm": answer(.alertFirstButtonReturn)
    case "suppress":
      showing.alert.suppressionButton?.state = .on
      answer(.alertFirstButtonReturn)
    case "cancel": answer(.alertSecondButtonReturn)
    default: return "usage: warning confirm|suppress|cancel"
    }
    return "ok"
  }

  static var debug: [String: Any] {
    ["showing": showing?.kind.rawValue ?? NSNull(), "last": last ?? NSNull()]
  }
}
