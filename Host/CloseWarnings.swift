import AppKit

/// Settings › General's two warnings, each a panel that asks (dropping from the page's top centre, the panels' look)
/// with "Don't ask again" (which turns its setting off); Return confirms, Escape or closing it cancels:
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

  /// The warning showing now: its question, and how to answer it (confirmed, "Don't ask again" ticked).
  private static var showing: (kind: Kind, question: PanelQuestion, answer: (Bool, Bool) -> Void)?
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
      showing.answer(true, showing.question.check?.state == .on)
      return false
    }
    let title = "Quit Ray?"
    let message = (RaySettings.shared[.onQuit] == "fresh"
      ? "Today's tabs close. Pinned tabs and favorites stay." : "Your tabs will be here when you open Ray again.")
      + " Press ⌘Q again to quit."
    // Over the window you're in; with none open there's nothing to lose by asking app-wide.
    let controller = AppController.shared.current
    guard let controller, controller.window.isVisible, controller.window.attachedSheet == nil else {
      // No window to sit on: an app-wide alert (never in a test instance, which must not come forward).
      TestEnvironment.log("quit warning: no window to show it on (\(controller == nil ? "none" : "hidden or busy"))")
      if TestEnvironment.isTestBuild { return true }
      let alert = NSAlert()
      alert.messageText = title
      alert.informativeText = message
      alert.addButton(withTitle: "Quit")
      alert.addButton(withTitle: "Cancel")
      alert.showsSuppressionButton = true
      alert.suppressionButton?.title = "Don't ask again"
      last = ["kind": Kind.quit.rawValue, "title": title, "message": message, "answer": NSNull()]
      let confirmed = alert.runModal() == .alertFirstButtonReturn
      quitConfirmed = finish(.quit, confirmed: confirmed, suppressed: confirmed && alert.suppressionButton?.state == .on)
      return quitConfirmed
    }
    show(.quit, title: title, message: message, confirm: "Quit", on: controller) { confirmed in
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
    let window = controller.window
    guard window.attachedSheet == nil else { return false }
    show(.close, title: "Close \(tabs) tabs?",
         message: "This private window's tabs, and everything they keep, are gone once it closes.",
         confirm: "Close Window", on: controller) { confirmed in
      guard confirmed else { return }
      closeConfirmed.append(id)
      DispatchQueue.main.async { window.performClose(nil) }
    }
    return false
  }

  /// The tabs a window's close throws away: a private window's, all of them; the normal window keeps its own.
  static func tabsLost(closing controller: BrowserWindowController) -> Int {
    controller.isPrivate ? controller.state.allEntries.filter { !$0.isFolder }.count : 0
  }

  // MARK: The panel

  /// The question as a panel that asks, over `controller`'s page: Cancel and the confirming answer (primary), "Don't
  /// ask again". Its answer comes once, whichever way it's given (a button, Return, ⌘Q again, Escape, closing it).
  private static func show(_ kind: Kind, title: String, message: String, confirm: String,
                           on controller: BrowserWindowController, done: @escaping (Bool) -> Void) {
    var answered = false
    var close: (() -> Void)?
    let answer = { (confirmed: Bool, suppressed: Bool) in
      guard !answered else { return }
      answered = true
      showing = nil
      close?()
      done(finish(kind, confirmed: confirmed, suppressed: confirmed && suppressed))
    }
    var question: PanelQuestion!
    question = PanelQuestion(title: title, message: message, check: "Don't ask again",
                             answers: [("Cancel", false, false), (confirm, true, false)]) { index in
      answer(index == 1, question.check?.state == .on)
    }
    showing = (kind, question, answer)
    last = ["kind": kind.rawValue, "title": title, "message": message, "answer": NSNull()]
    log()
    let handle = controller.panels.open(PanelSpec(
      name: kind == .quit ? "quitWarning" : "closeWarning", content: question, anchor: controller.questionAnchor,
      closesOn: [.escape, .windowInactive], asks: true,
      onReturn: { answer(true, question.check?.state == .on) }, onClose: { answer(false, false) }))
    close = { handle.close() }
  }

  /// Records the answer, turns the setting off on "Don't ask again" (with Quit or Close), and says whether to go on.
  private static func finish(_ kind: Kind, confirmed: Bool, suppressed: Bool) -> Bool {
    if suppressed {
      RaySettings.shared.set(kind == .quit ? AnySettingKey.warnBeforeQuitting : AnySettingKey.warnBeforeClosingWindow, false)
    }
    last?["answer"] = confirmed ? (suppressed ? "suppressed" : "confirmed") : "cancelled"
    log()
    return confirmed
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
    case "confirm": showing.question.buttons[1].performClick(nil)
    case "suppress":
      showing.question.check?.state = .on
      showing.question.buttons[1].performClick(nil)
    case "cancel": showing.question.buttons[0].performClick(nil)
    default: return "usage: warning confirm|suppress|cancel"
    }
    return "ok"
  }

  static var debug: [String: Any] {
    ["showing": showing?.kind.rawValue ?? NSNull(), "last": last ?? NSNull()]
  }
}
