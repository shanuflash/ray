import AppKit

// Asking to be the default browser outside Settings › General (Chrome's infobar, Arc's and Dia's onboarding step): a
// note at launch in the bottom right corner, rarely. Only in the first normal window, a few seconds after it's up;
// never over the onboarding, never once Ray is (or was) the default; at least 14 days after the last ask (the
// onboarding's step counts) and 3 times at most. "Never" ends it; ignoring it is "not now". Make Default is Settings ›
// General's call (`GeneralSystem`, macOS's own confirmation), so test builds go through its fakes. Test builds never
// ask by themselves unless RAY_DEFAULT_BROWSER_ASK=1; `defaultask run` asks now through the same rules.

final class DefaultBrowserAsk {
  static let shared = DefaultBrowserAsk()

  static let gap: TimeInterval = 14 * 24 * 60 * 60
  static let maxAsks = 3
  static let delay: TimeInterval = 3
  static let noteKey = "defaultBrowser"

  /// Test builds: time added to the clock, so a check can step past the gap.
  private var clockOffset: TimeInterval = 0
  /// Why the last launch didn't ask, or "asked".
  private(set) var lastDecision = "none"
  private var now: Date { Date().addingTimeInterval(clockOffset) }

  // MARK: Asking

  /// The launch's first normal window is up: ask a few seconds later, if the rules allow.
  func launched(in controller: BrowserWindowController) {
    guard !TestEnvironment.isTestBuild || TestEnvironment["RAY_DEFAULT_BROWSER_ASK"] == "1" else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.delay) { [weak self, weak controller] in
      guard let self, let controller else { return }
      self.consider(in: controller)
    }
  }

  /// Why not to ask now, or nil to ask.
  private func reason(in controller: BrowserWindowController) -> String? {
    let settings = RaySettings.shared
    if controller.isPrivate { return "private" }
    if controller.onboarding != nil { return "onboarding" }
    if settings.defaultBrowserNever { return "never" }
    if GeneralSystem.shared.isDefaultBrowser {
      // Ray was the default: someone who later picked another browser isn't asked again.
      settings.neverAskDefaultBrowser()
      return "default"
    }
    if settings.defaultBrowserAsks >= Self.maxAsks { return "enough" }
    if let at = settings.defaultBrowserAskedAt, now.timeIntervalSince1970 - at < Self.gap { return "recent" }
    return nil
  }

  /// Asks now if the rules allow; returns what was decided.
  @discardableResult
  func consider(in controller: BrowserWindowController) -> String {
    let why = reason(in: controller)
    lastDecision = why ?? "asked"
    if why == nil { ask(in: controller) }
    controller.logState("defaultBrowserAsk")
    return lastDecision
  }

  private func ask(in controller: BrowserWindowController) {
    RaySettings.shared.recordDefaultBrowserAsk(at: now, counts: true)
    controller.notes.show(Note(
      "Ray isn't your default browser", detail: "Links from other apps open elsewhere", icon: .symbol("globe"),
      actions: [
        NoteAction("Never") { RaySettings.shared.neverAskDefaultBrowser() },
        NoteAction("Make Default") { GeneralSystem.shared.makeDefaultBrowser() },
      ],
      spot: .bottomTrailing, lasts: .seconds(10), key: Self.noteKey, asks: true))
  }

  /// The onboarding showed its step: the note waits its gap from now.
  func askedInOnboarding() { RaySettings.shared.recordDefaultBrowserAsk(at: now, counts: false) }

  // MARK: Tests

  /// `defaultask run|reset|days <n>`: ask now through the rules, forget every ask, or move the clock n days on.
  func command(_ argument: String) -> String {
    let words = argument.split(separator: " ").map(String.init)
    switch (words.first, words.count) {
    case ("run", 1):
      guard let controller = AppController.shared.current else { return "no window" }
      return consider(in: controller)
    case ("reset", 1):
      RaySettings.shared.resetDefaultBrowserAsk()
      clockOffset = 0
      lastDecision = "none"
    case ("days", 2):
      guard let days = Double(words[1]) else { return "usage: defaultask days <n>" }
      clockOffset += days * 24 * 60 * 60
    default:
      return "usage: defaultask run|reset|days <n>"
    }
    return "ok"
  }

  var debug: [String: Any] {
    let settings = RaySettings.shared
    return [
      "asks": settings.defaultBrowserAsks, "never": settings.defaultBrowserNever, "lastDecision": lastDecision,
      "daysSinceAsked": settings.defaultBrowserAskedAt.map { ((now.timeIntervalSince1970 - $0) / 86400 * 10).rounded() / 10 } ?? NSNull(),
    ]
  }
}
