import AppKit

// What a page asks Ray through the engine, beside permissions and passwords (docs/mocks/page-prompts.html, look A):
// - `PageQuestions`: "Open “App”?" for a link to another app (`externalAppRequest`; Chrome's own dialog showed before)
//   and "Page not responding" (`tabBecameUnresponsive`), each a question from the page's top centre over its own tab.
// - `BlockedPopups`: "Pop-up blocked" as a note with Open and Always Allow (`didBlockPopup`, `openBlockedPopup`).
// Following the security checklist: only over their own tab, the full origin from the engine (never the page's words),
// buttons dead for 0.5 s each time they appear, nothing allowed by default.

final class PageQuestions {
  enum Kind: String {
    case app, hang
  }

  struct Question {
    let kind: Kind
    /// The engine's request id (an app link); "" for a hang.
    let id: String
    /// The page that asks, from the engine; nil for a page with no real origin (a file).
    let origin: String?
    let app: String
    let appPath: String?
    let scheme: String
    /// The engine lets this one be remembered: an https (or localhost) page in a normal window.
    let canRemember: Bool
    /// The tab's committed origin when it asked: another site cancels an app link.
    let site: String?
    weak var tab: RayCoreTab?
  }

  private weak var controller: BrowserWindowController?
  private var waiting: [Question] = []
  private var shown: (question: Question, view: PanelQuestion, handle: PanelHandle)?
  /// A hang that ended by itself: its question closes without an answer.
  private var closingQuietly = false
  /// For tests: the last question's kind and how it was answered.
  private(set) var last: [String: Any]?
  var onChange: (() -> Void)?

  init(controller: BrowserWindowController) {
    self.controller = controller
  }

  // MARK: Asking

  /// The engine's `externalAppRequest`: a link to another app, or to a kind of link no app on this Mac opens.
  func appLink(_ request: [String: Any], tab: RayCoreTab) {
    guard let id = request["id"] as? String, let reported = request["scheme"] as? String else { return }
    let scheme = String(reported.prefix(40))
    guard let app = request["app"] as? String, !app.isEmpty else {
      // Nothing to ask: no app opens it (the engine keeps no request).
      if tab === controller?.activeTab {
        controller?.notes.show(Note("No app opens “\(scheme):” links", icon: .warning, key: "noApp"))
      }
      last = ["kind": "noApp", "scheme": scheme]
      onChange?()
      return
    }
    // One per tab: a second link while one waits replaces it (the first is cancelled).
    for old in waiting where old.tab === tab && old.kind == .app { RayCoreEngine.resolveExternalApp(old.id, open: false, remember: false) }
    waiting.removeAll { $0.tab === tab && $0.kind == .app }
    if let shown, shown.question.tab === tab, shown.question.kind == .app {
      RayCoreEngine.resolveExternalApp(shown.question.id, open: false, remember: false)
      self.shown = nil
      closingQuietly = true
      shown.handle.close()
      closingQuietly = false
    }
    let origin = request["origin"] as? String
    waiting.append(Question(
      kind: .app, id: id, origin: origin, app: String(app.prefix(80)), appPath: request["appPath"] as? String,
      scheme: scheme, canRemember: origin != nil && request["remember"] is String, site: tab.committedOrigin, tab: tab))
    update()
  }

  /// The engine's hang monitor fired for this tab (15 s without an answer from its page).
  func unresponsive(_ tab: RayCoreTab) {
    guard !waiting.contains(where: { $0.tab === tab && $0.kind == .hang }),
          !(shown?.question.tab === tab && shown?.question.kind == .hang) else { return }
    waiting.append(Question(kind: .hang, id: "", origin: tab.committedOrigin, app: "", appPath: nil, scheme: "",
                            canRemember: false, site: tab.committedOrigin, tab: tab))
    update()
  }

  /// The page answers again: its question goes, unanswered.
  func responsive(_ tab: RayCoreTab) {
    waiting.removeAll { $0.tab === tab && $0.kind == .hang }
    if let shown, shown.question.tab === tab, shown.question.kind == .hang {
      self.shown = nil
      closingQuietly = true
      shown.handle.close()
      closingQuietly = false
      last = ["kind": "hang", "answer": "recovered"]
    }
    update()
  }

  /// Shows the active tab's question (a hang first) if no other panel is open; call when tabs switch.
  func update() {
    for question in waiting where question.kind == .app && (question.tab == nil || question.tab?.closed == true
      || question.tab?.committedOrigin != question.site) {
      RayCoreEngine.resolveExternalApp(question.id, open: false, remember: false)
    }
    waiting.removeAll { $0.tab == nil || $0.tab?.closed == true || ($0.kind == .app && $0.tab?.committedOrigin != $0.site) }
    guard let controller, shown == nil, !controller.panels.isOpen else {
      onChange?()
      return
    }
    let mine = waiting.filter { $0.tab === controller.activeTab && $0.tab != nil }
    guard let question = mine.first(where: { $0.kind == .hang }) ?? mine.first else {
      onChange?()
      return
    }
    show(question, in: controller)
  }

  private func show(_ question: Question, in controller: BrowserWindowController) {
    let site = question.origin.map(PermissionPromptView.display)
    var view: PanelQuestion!
    switch question.kind {
    case .app:
      let icon = question.appPath.flatMap { FileManager.default.fileExists(atPath: $0) ? NSWorkspace.shared.icon(forFile: $0) : nil }
      view = PanelQuestion(
        title: "Open “\(question.app)”?",
        message: site.map { "\($0) wants to open this app." } ?? "This page wants to open this app.",
        icon: icon, check: question.canRemember ? site.map { "Always allow \($0)" } : nil,
        answers: [("Cancel", false, false), ("Open", true, false)], wait: 0.5) { [weak self] index in
          self?.answer(question, open: index == 1)
        }
    case .hang:
      let icon = NSImage(systemSymbolName: "clock", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 22, weight: .regular))
      view = PanelQuestion(
        title: "Page not responding",
        message: "\(site ?? "This page") stopped responding. Wait for it, or close the page.",
        icon: icon, answers: [("Exit Page", false, false), ("Wait", true, false)], wait: 0.5) { [weak self] index in
          self?.answer(question, open: index == 1)
        }
    }
    let handle = controller.panels.open(PanelSpec(
      name: question.kind == .app ? "appLink" : "notResponding", content: view, anchor: controller.questionAnchor,
      closesOn: question.kind == .app ? [.escape, .tabSwitch, .otherSite] : [.escape, .tabSwitch],
      origin: question.site, asks: true,
      // A link's question has no default; a stuck page's is Wait, as Chrome's.
      onReturn: question.kind == .hang ? { [weak self] in self?.answer(question, open: true) } : nil,
      onClose: { [weak self, weak view] in
        guard let self, let view, self.shown?.view === view else { return }
        self.shown = nil
        if self.closingQuietly { return }
        // A tab switch or another panel puts it away for later; Escape or another site is Cancel (Wait for a hang).
        if let reason = controller.panels.lastClosedBy, reason == "tabSwitch" || reason == "another" {
          self.onChange?()
        } else {
          self.resolve(question, open: question.kind == .hang, remember: false, how: "closed")
        }
      }))
    shown = (question, view, handle)
    onChange?()
  }

  /// A button: Open or Cancel (an app link), Wait or Exit Page (a hang).
  private func answer(_ question: Question, open: Bool) {
    guard let shown, shown.question.tab === question.tab, shown.question.id == question.id,
          shown.question.kind == question.kind else { return }
    let remember = open && question.canRemember && shown.view.check?.state == .on
    self.shown = nil
    closingQuietly = true
    shown.handle.close()
    closingQuietly = false
    resolve(question, open: open, remember: remember, how: "button")
    update()
  }

  private func resolve(_ question: Question, open: Bool, remember: Bool, how: String) {
    waiting.removeAll { $0.tab === question.tab && $0.kind == question.kind }
    switch question.kind {
    case .app:
      RayCoreEngine.resolveExternalApp(question.id, open: open, remember: remember)
      last = ["kind": "app", "answer": open ? "open" : "cancel", "remember": remember, "how": how]
    case .hang:
      question.tab?.resolveUnresponsive(!open)
      last = ["kind": "hang", "answer": open ? "wait" : "exit", "how": how]
    }
    onChange?()
  }

  // MARK: Page question tests

  /// For the state log: what's asked, never the page's address.
  var state: [String: Any] {
    var open: Any = NSNull()
    if let shown, let tab = shown.question.tab {
      let buttons = shown.view.buttons
      open = [
        "kind": shown.question.kind.rawValue, "app": shown.question.app, "scheme": shown.question.scheme,
        "origin": shown.question.origin ?? NSNull(), "check": shown.view.check?.title ?? NSNull(),
        "ready": buttons.allSatisfy(\.isEnabled), "buttons": buttons.map { $0.accessibilityLabel() ?? "" },
        "activeTab": tab === controller?.activeTab, "hasIcon": shown.question.kind == .hang || shown.question.appPath != nil,
      ] as [String: Any]
    }
    var state: [String: Any] = ["open": open, "waiting": waiting.count, "last": last ?? NSNull()]
    #if RAY_TEST_HOOKS
    // The engine's would-be launches (test builds never open another app).
    state["launches"] = RayCoreEngine.testExternalLaunches
    #endif
    return state
  }

  /// `pagequestion press <n>|check|escape`: as a click, the tick box or Escape would.
  func test(_ argument: String) -> String {
    let words = argument.split(separator: " ").map(String.init)
    guard let shown else { return "no question" }
    switch words.first {
    case "press":
      guard words.count == 2, let index = Int(words[1]), shown.view.buttons.indices.contains(index) else {
        return "usage: pagequestion press <n>"
      }
      let button = shown.view.buttons[index]
      guard button.isEnabled else { return "not ready" }
      button.performClick(nil)
    case "check":
      guard let check = shown.view.check else { return "no tick box" }
      check.state = check.state == .on ? .off : .on
    case "escape":
      shown.handle.close()
    default:
      return "usage: pagequestion press <n>|check|escape"
    }
    return "ok"
  }
}

// MARK: Blocked pop-ups

/// Pop-ups a page opened without a click, which Chrome blocked: a note at the top right with Open (opens them all) and
/// Always Allow (allows pop-ups for the site, which Settings › Privacy then lists, and opens them). One note per page;
/// once it's gone (answered, timed out, closed) the page's later pop-ups stay blocked without another.
final class BlockedPopups {
  private struct Page {
    weak var tab: RayCoreTab?
    var ids: [String] = []
    var origin: String
    /// Its note was shown and is over: no other for this page.
    var done = false
    /// Its note was put away by a tab switch: it shows again on return.
    var putAway = false
  }

  private weak var controller: BrowserWindowController?
  private var pages: [Page] = []
  private var note: (tab: RayCoreTab, handle: NoteHandle)?
  private(set) var last: [String: Any]?
  var onChange: (() -> Void)?
  static let noteKey = "popupBlocked"

  init(controller: BrowserWindowController) {
    self.controller = controller
  }

  /// The engine's `didBlockPopup`: `id` and the blocking page's origin.
  func blocked(_ popup: [String: String], tab: RayCoreTab) {
    guard let id = popup["id"], !id.isEmpty else { return }
    settle()
    if let at = pages.firstIndex(where: { $0.tab === tab }) {
      // Chrome keeps 25 a page; so does Ray.
      if !pages[at].ids.contains(id) { pages[at].ids = Array((pages[at].ids + [id]).suffix(25)) }
    } else {
      pages.append(Page(tab: tab, ids: [id], origin: popup["origin"] ?? tab.committedOrigin ?? ""))
    }
    show(tab)
  }

  /// The tab's page changed (a new document): what it blocked is gone with it.
  func committed(_ tab: RayCoreTab) {
    pages.removeAll { $0.tab === tab || $0.tab == nil }
    if note?.tab === tab { dismiss() }
  }

  /// Tabs switched: the note belongs to its own tab.
  func tabSwitched() {
    settle()
    if let note, note.handle.isShown, let at = pages.firstIndex(where: { $0.tab === note.tab }) {
      pages[at].putAway = true
      note.handle.dismiss()
      self.note = nil
    }
    if let tab = controller?.activeTab, let page = pages.first(where: { $0.tab === tab }), page.putAway { show(tab) }
  }

  /// A note that went away by itself (timed out, closed) ends its page's notes.
  private func settle() {
    pages.removeAll { $0.tab == nil || $0.tab?.closed == true }
    guard let note, !note.handle.isShown else { return }
    if let at = pages.firstIndex(where: { $0.tab === note.tab }) { pages[at].done = true }
    self.note = nil
  }

  private func show(_ tab: RayCoreTab) {
    guard let controller, tab === controller.activeTab, let at = pages.firstIndex(where: { $0.tab === tab }),
          !pages[at].done else {
      onChange?()
      return
    }
    pages[at].putAway = false
    let count = pages[at].ids.count
    let text = count == 1 ? "Pop-up blocked" : "\(count) pop-ups blocked"
    let site = PermissionPromptView.display(pages[at].origin)
    let actions = [
      NoteAction("Open") { [weak self, weak tab] in self?.open(tab, always: false) },
      NoteAction("Always Allow") { [weak self, weak tab] in self?.open(tab, always: true) },
    ]
    // The same key: a note already showing changes in place ("2 pop-ups blocked").
    let handle = controller.notes.show(Note(text, detail: site, icon: .symbol("macwindow.badge.plus"), actions: actions,
                                            key: Self.noteKey, asks: true))
    note = (tab, handle)
    last = ["shown": count]
    onChange?()
  }

  private func dismiss() {
    note?.handle.dismiss()
    note = nil
  }

  /// Open, or Always Allow: the engine opens each one still blocked; Always Allow saves the site's choice first.
  private func open(_ tab: RayCoreTab?, always: Bool) {
    guard let tab, let at = pages.firstIndex(where: { $0.tab === tab }) else { return }
    let ids = pages[at].ids
    pages[at].ids = []
    pages[at].done = true
    note = nil
    for (index, id) in ids.enumerated() { tab.openBlockedPopup(id, always: always && index == 0) }
    last = ["answer": always ? "always" : "open", "count": ids.count]
    onChange?()
  }

  var state: [String: Any] {
    let active = controller?.activeTab
    let page = pages.first { $0.tab === active && active != nil }
    return ["blocked": page?.ids.count ?? 0, "done": page?.done ?? false, "noteShown": note?.handle.isShown ?? false,
            "last": last ?? NSNull(),
            "pages": pages.compactMap { page in page.tab.map { ["tab": Int($0.tabId), "blocked": page.ids.count, "done": page.done] } }]
  }
}
