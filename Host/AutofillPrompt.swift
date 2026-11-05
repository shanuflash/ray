import AppKit

// Chrome's "Save address?", "Update address?" and "Save card?" as the password prompt's card, in the same spot (the
// page's top right). The engine decides when to ask (a form sent with a new address or card) and saves; Ray only asks,
// with Chrome's own title and accept label (they differ by case: "Update address?", "Add to address?"). Only cards
// saved on this Mac are asked about: the engine skips Google Payments' upload, IBAN and offer bubbles. No card number
// ever reaches Ray: the card line is Chrome's own "Visa ••1234 • 08/31". Chrome closes a prompt when its tab is hidden
// (`closed`) and asks again when it shows, so unlike passwords a tab switch ends it rather than putting it away (and
// needs no `update()`). The fill dropdown is Chrome's own popup, drawn by the engine
// (`tab(_:didShowAutofillSuggestions:)` only says one showed).
// Following the security checklist: only over its own tab, the full origin from the engine, buttons dead for 0.5 s each
// time it appears, nothing by default (Escape or a click outside is "not now").

final class AutofillPrompts {
  struct Prompt {
    let id: Int
    /// "saveAddress", "updateAddress" or "saveCard".
    let kind: String
    let title: String
    let message: String
    let accept: String
    let footer: String
    /// What's saved, as sections of lines (an update's new and old values, each under its label).
    let sections: [(label: String, lines: [String])]
    let origin: String
    weak var tab: RayCoreTab?

    var isCard: Bool { kind == "saveCard" }
  }

  private weak var controller: BrowserWindowController?
  /// One per tab, until it's answered or Chrome closes it.
  private var waiting: [Prompt] = []
  private var shown: (prompt: Prompt, view: AutofillPromptView, handle: PanelHandle)?
  /// Set while Ray closes the panel because Chrome closed the prompt: nothing to answer.
  private var closingForEngine = false
  /// For tests: what the last prompt came to (a fixed word) and how many were offered.
  private(set) var last: String?
  private(set) var offered = 0
  var onChange: (() -> Void)?

  init(controller: BrowserWindowController) {
    self.controller = controller
  }

  private static var observations: [SettingsObservation] = []

  /// Settings › Autofill › Save and fill addresses / cards are Chrome's own switches, so the engine stops asking and
  /// filling. From the first window on; later calls do nothing.
  static func followSettings() {
    guard observations.isEmpty else { return }
    for (key, preference) in [(AnySettingKey.autofillAddresses, "autofill.profile_enabled"),
                              (AnySettingKey.autofillCards, "autofill.credit_card_enabled")] {
      let apply = { (on: Bool) in RayCoreEngine.shared?.defaultProfile.setBoolPreference(preference, value: on) }
      apply(RaySettings.shared[key])
      observations.append(RaySettings.shared.observe(key) { apply($0) })
    }
  }

  /// The engine's `autofillPrompt` for a tab of this window: a new prompt, or `closed` for one Chrome closed.
  func add(_ info: [String: Any], tab: RayCoreTab) {
    guard let id = (info["id"] as? NSNumber)?.intValue else { return }
    if info["closed"] as? Bool == true {
      waiting.removeAll { $0.id == id }
      if let shown, shown.prompt.id == id {
        closingForEngine = true
        shown.handle.close()
        closingForEngine = false
        last = "closed"
      }
      onChange?()
      return
    }
    guard let kind = info["kind"] as? String, ["saveAddress", "updateAddress", "saveCard"].contains(kind),
          let origin = info["origin"] as? String, !origin.isEmpty else { return }
    // The switch off: the engine shouldn't ask (Chrome's pref), and if it does, the answer is "not now".
    guard RaySettings.shared[kind == "saveCard" ? .autofillCards : .autofillAddresses] else {
      tab.resolveAutofillPrompt(id, action: "dismiss")
      last = "off"
      onChange?()
      return
    }
    let text = { (key: String) in info[key] as? String ?? "" }
    var sections: [(label: String, lines: [String])] = []
    if kind == "updateAddress" {
      let changes = info["changes"] as? [[String: String]] ?? []
      let values = { (key: String) in changes.compactMap { $0[key] }.filter { !$0.isEmpty } }
      sections.append((text("newLabel"), values("to")))
      if !text("newLabel").isEmpty { sections.append((text("oldLabel"), values("from"))) }
    } else {
      sections.append(("", info["lines"] as? [String] ?? []))
    }
    let prompt = Prompt(
      id: id, kind: kind, title: text("title").isEmpty ? Self.title(kind) : text("title"),
      // A card's explanation ("To pay faster next time…") is left out, as Arc keeps prompts short; an address's line
      // says which saved address an update changes.
      message: kind == "saveCard" ? "" : text("message"), accept: text("accept").isEmpty ? "Save" : text("accept"),
      footer: text("footer"), sections: sections.filter { !$0.lines.isEmpty }, origin: origin, tab: tab)
    if shown?.prompt.tab === tab {
      closingForEngine = true
      shown?.handle.close()
      closingForEngine = false
    }
    waiting.removeAll { $0.tab === tab || $0.tab == nil }
    waiting.append(prompt)
    offered += 1
    update()
  }

  private static func title(_ kind: String) -> String {
    switch kind {
    case "saveCard": return "Save card?"
    case "updateAddress": return "Update address?"
    default: return "Save address?"
    }
  }

  /// Shows the active tab's prompt, if it has one and no other panel is open; call when a panel closes.
  func update() {
    waiting.removeAll { $0.tab == nil || $0.tab?.closed == true }
    guard let controller, shown == nil, !controller.panels.isOpen,
          let prompt = waiting.first(where: { $0.tab === controller.activeTab && $0.tab != nil }) else {
      onChange?()
      return
    }
    let view = AutofillPromptView(prompt: prompt)
    var handle: PanelHandle?
    view.onAnswer = { [weak self] action in self?.answer(action, from: view, handle: handle) }
    handle = controller.panels.open(PanelSpec(
      name: "autofillPrompt", content: view, anchor: PasswordPrompts.anchor(in: controller),
      closesOn: [.outsideClick, .escape, .tabSwitch], origin: prompt.origin,
      onClose: { [weak self, weak view] in
        guard let self, let view, self.shown?.view === view else { return }
        self.shown = nil
        // Chrome closed it, or a tab switch or another panel put it away; Escape or a click elsewhere is "not now".
        if self.closingForEngine {
          self.onChange?()
        } else if let reason = controller.panels.lastClosedBy, reason == "tabSwitch" || reason == "another" {
          self.onChange?()
        } else {
          self.resolve(prompt, "dismiss")
        }
      }))
    shown = (prompt, view, handle!)
    onChange?()
  }

  private func answer(_ action: String, from view: AutofillPromptView, handle: PanelHandle?) {
    guard let shown, shown.view === view else { return }
    self.shown = nil
    resolve(shown.prompt, action)
    handle?.close()
  }

  private func resolve(_ prompt: Prompt, _ action: String) {
    waiting.removeAll { $0.id == prompt.id || $0.tab == nil }
    prompt.tab?.resolveAutofillPrompt(prompt.id, action: action)
    last = action
    onChange?()
    controller?.showPagePrompts()
  }

  // MARK: Autofill prompt tests

  /// For the state log: the shape of what's asked, never an address, a card's digits or the site.
  var state: [String: Any] {
    var open: Any = NSNull()
    if let shown, let tab = shown.prompt.tab {
      open = [
        "kind": shown.prompt.kind, "ready": shown.view.ready, "buttons": shown.view.buttonTitles,
        "originShown": shown.view.originText == PermissionPromptView.display(shown.prompt.origin),
        "sameOrigin": tab.committedOrigin.map { PermissionPromptView.display($0) == PermissionPromptView.display(shown.prompt.origin) } ?? false,
        "activeTab": tab === controller?.activeTab, "lines": shown.view.lineCounts,
        "message": !shown.prompt.message.isEmpty, "footer": !shown.prompt.footer.isEmpty,
      ] as [String: Any]
    }
    return ["open": open, "waiting": waiting.count, "offered": offered, "last": last ?? NSNull()]
  }

  /// `afprompt press accept|decline|close`, `afprompt has <text>` (whether the shown card's lines include it, so a
  /// check can tell the right address showed without the text reaching the log).
  func test(_ argument: String) -> String {
    let words = argument.split(separator: " ", maxSplits: 1).map(String.init)
    guard let shown else { return "no prompt" }
    switch words.first {
    case "press":
      guard words.count == 2 else { return "usage: afprompt press <button>" }
      if words[1] == "close" { shown.handle.close(); return "ok" }
      return shown.view.press(words[1]) ? "ok" : "not ready"
    case "has":
      guard words.count == 2 else { return "usage: afprompt has <text>" }
      return shown.prompt.sections.contains { $0.lines.contains { $0.contains(words[1]) } } ? "yes" : "no"
    default:
      return "usage: afprompt press <button>|has <text>"
    }
  }
}

// MARK: Autofill prompt view

/// The prompt's content: a pin or a card, Chrome's title and the site, then what's saved (an update's new values over
/// the old ones, each under its label), the footnote and the answers.
final class AutofillPromptView: PromptCardView {
  private var labels: [NSTextField] = []
  private var rows: [(label: NSTextField?, lines: [NSTextField])] = []

  init(prompt: AutofillPrompts.Prompt) {
    super.init(symbol: prompt.isCard ? "creditcard.fill" : "mappin.and.ellipse", title: prompt.title,
               origin: prompt.origin, message: prompt.message, footnote: prompt.footer,
               answers: [("decline", PanelButton(title: "Not Now")), ("accept", PanelButton(title: prompt.accept, primary: true))])
    for section in prompt.sections {
      var label: NSTextField?
      if !section.label.isEmpty {
        let text = NSTextField(labelWithString: section.label)
        text.font = .systemFont(ofSize: 11)
        text.textColor = .secondaryLabelColor
        addSubview(text)
        label = text
      }
      let lines = section.lines.prefix(8).enumerated().map { index, line -> NSTextField in
        let text = NSTextField(labelWithString: line)
        // The first line of a summary (the name, or the card) leads.
        let leads = index == 0 && section.label.isEmpty
        text.font = .systemFont(ofSize: 12.5, weight: leads ? .medium : .regular)
        text.textColor = leads || !section.label.isEmpty ? .labelColor : .secondaryLabelColor
        text.lineBreakMode = .byTruncatingTail
        addSubview(text)
        return text
      }
      rows.append((label, lines))
    }
    sizeToContent()
  }

  required init?(coder: NSCoder) { fatalError() }

  override func layoutWell(x: CGFloat, y: CGFloat, width: CGFloat, apply: Bool) -> CGFloat {
    var top = y + 9
    for (index, row) in rows.enumerated() {
      if index > 0 { top += 8 }
      if let label = row.label {
        let height = ceil(label.intrinsicContentSize.height)
        if apply { label.frame = NSRect(x: x + 10, y: top, width: width - 20, height: height) }
        top += height + 2
      }
      for line in row.lines {
        let height = ceil(line.intrinsicContentSize.height)
        if apply { line.frame = NSRect(x: x + 10, y: top, width: width - 20, height: height) }
        top += height + 1
      }
    }
    return top + 8 - y
  }

  /// How many lines each section shows, for the state log (never their text).
  var lineCounts: [Int] { rows.map { $0.lines.count } }
}
