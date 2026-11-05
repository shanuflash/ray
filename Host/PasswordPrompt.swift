import AppKit

// Chrome's "Save password?" and "Update password?" as a panel at the page's top right (Ardia's spot; Chrome hangs its
// bubble from the key icon at the omnibox's right end, which Ray doesn't have). The engine decides when to ask (a
// sign-in that worked, a changed password) and saves; Ray only asks. The fill dropdown and "Suggest strong password"
// are Chrome's own popups, drawn by the engine (`tab(_:didShowAutofillSuggestions:)` only says one showed).
// Following the security checklist: only over its own tab, the full origin from the engine, buttons dead for 0.5 s each
// time it appears, nothing by default (Return is the focused control's, Escape or a click outside is "not now").

final class PasswordPrompts {
  struct Prompt {
    /// "save" or "update".
    let state: String
    let origin: String
    let username: String
    let passwordLength: Int
    let federation: String
    let usernames: [String]
    weak var tab: RayCoreTab?
  }

  private weak var controller: BrowserWindowController?
  /// One per tab, kept while another tab is shown, until it's answered.
  private var waiting: [Prompt] = []
  private var shown: (prompt: Prompt, view: PasswordPromptView, handle: PanelHandle)?
  /// For tests: what the last prompt came to (a fixed word) and how many were offered.
  private(set) var last: String?
  private(set) var offered = 0
  var onChange: (() -> Void)?

  init(controller: BrowserWindowController) {
    self.controller = controller
  }

  private static var observation: SettingsObservation?

  /// Settings › Passwords › Offer to save passwords is Chrome's own switch for it, so the engine stops asking (and
  /// still fills what's saved). From the first window on; later calls do nothing.
  static func followSetting() {
    guard observation == nil else { return }
    let apply = { (on: Bool) in
      RayCoreEngine.shared?.defaultProfile.setBoolPreference("credentials_enable_service", value: on)
    }
    apply(RaySettings.shared[.offerToSavePasswords])
    observation = RaySettings.shared.observe(.offerToSavePasswords) { apply($0) }
  }

  /// The engine's `passwordPrompt` for a tab of this window.
  func add(_ info: [String: Any], tab: RayCoreTab) {
    guard let state = info["state"] as? String, let origin = info["origin"] as? String else { return }
    if state == "saved" {
      // Saved without asking (a password Chrome suggested): say so, as Chrome's confirmation does.
      if tab === controller?.activeTab {
        controller?.notes.show(Note("Password saved", icon: .symbol("key.fill"), key: "passwordSaved"))
      }
      last = "savedNote"
      onChange?()
      return
    }
    guard state == "save" || state == "update" else { return }
    // Settings › Passwords › Offer to save passwords off: the engine shouldn't ask (`credentials_enable_service`), and
    // if it does, the answer is "not now".
    guard RaySettings.shared[.offerToSavePasswords] else {
      tab.resolvePasswordPrompt("dismiss", username: nil, password: nil)
      last = "off"
      onChange?()
      return
    }
    let prompt = Prompt(
      state: state, origin: origin, username: info["username"] as? String ?? "",
      passwordLength: (info["passwordLength"] as? NSNumber)?.intValue ?? 0, federation: info["federation"] as? String ?? "",
      usernames: info["usernames"] as? [String] ?? [], tab: tab)
    if shown?.prompt.tab === tab { shown?.handle.close() }
    waiting.removeAll { $0.tab === tab || $0.tab == nil }
    waiting.append(prompt)
    offered += 1
    update()
  }

  /// Shows the active tab's prompt, if it has one and no other panel is open; call when tabs switch.
  func update() {
    waiting.removeAll { $0.tab == nil || $0.tab?.closed == true }
    guard let controller, shown == nil, !controller.panels.isOpen,
          let prompt = waiting.first(where: { $0.tab === controller.activeTab && $0.tab != nil }) else {
      onChange?()
      return
    }
    let view = PasswordPromptView(prompt: prompt)
    var handle: PanelHandle?
    view.onAnswer = { [weak self] action in self?.answer(action, from: view, handle: handle) }
    handle = controller.panels.open(PanelSpec(
      name: "passwordPrompt", content: view, anchor: anchor(in: controller),
      closesOn: [.outsideClick, .escape, .tabSwitch], origin: prompt.origin,
      onClose: { [weak self, weak view] in
        guard let self, let view, self.shown?.view === view else { return }
        self.shown = nil
        // A tab switch or another panel puts it away for later; Escape or a click elsewhere is "not now".
        if let reason = controller.panels.lastClosedBy, reason == "tabSwitch" || reason == "another" {
          self.onChange?()
        } else {
          self.resolve(prompt, "dismiss")
        }
      }))
    shown = (prompt, view, handle!)
    onChange?()
  }

  /// The page's top right, under the address bar: where Ardia (and Arc) put it.
  private func anchor(in controller: BrowserWindowController) -> PanelAnchor {
    PanelAnchor(rect: { [weak controller] in
      guard let pages = controller?.pageFrame else { return .zero }
      return NSRect(x: pages.maxX - 10, y: pages.maxY - 10 + Panels.gap, width: 0, height: 0)
    }, below: true, align: .trailing)
  }

  private func answer(_ action: String, from view: PasswordPromptView, handle: PanelHandle?) {
    guard let shown, shown.view === view else { return }
    self.shown = nil
    var username: String?
    if action == "save" || action == "update" {
      let typed = view.username.trimmingCharacters(in: .whitespacesAndNewlines)
      if !typed.isEmpty, typed != shown.prompt.username { username = typed }
    }
    resolve(shown.prompt, action, username: username)
    handle?.close()
  }

  private func resolve(_ prompt: Prompt, _ action: String, username: String? = nil) {
    waiting.removeAll { $0.tab === prompt.tab || $0.tab == nil }
    prompt.tab?.resolvePasswordPrompt(action, username: username, password: nil)
    last = action
    onChange?()
  }

  // MARK: Password prompt tests

  /// For the state log: the shape of what's asked, never a username, password or site.
  var state: [String: Any] {
    var open: Any = NSNull()
    if let shown, let tab = shown.prompt.tab {
      open = [
        "state": shown.prompt.state, "ready": shown.view.ready, "buttons": shown.view.buttonTitles,
        "originShown": shown.view.originText == PermissionPromptView.display(shown.prompt.origin),
        "sameOrigin": tab.committedOrigin.map { PermissionPromptView.display($0) == PermissionPromptView.display(shown.prompt.origin) } ?? false,
        "activeTab": tab === controller?.activeTab, "hasUsername": !shown.view.username.isEmpty,
        "dots": shown.view.dots, "choices": shown.prompt.usernames.count,
      ] as [String: Any]
    }
    return ["open": open, "waiting": waiting.count, "offered": offered, "last": last ?? NSNull()]
  }

  /// `pwprompt press save|update|never|nope|notnow|close`, `pwprompt username <fixture>`: as clicks and typing would.
  func test(_ argument: String) -> String {
    let words = argument.split(separator: " ", maxSplits: 1).map(String.init)
    guard let shown else { return "no prompt" }
    switch words.first {
    case "press":
      guard words.count == 2 else { return "usage: pwprompt press <button>" }
      if words[1] == "close" { shown.handle.close(); return "ok" }
      return shown.view.press(words[1]) ? "ok" : "not ready"
    case "username":
      guard words.count == 2, let login = SettingsFixtures.item("logins", words[1]) else { return "no fixture" }
      shown.view.username = SettingsFixtures.text(login, "username")
      return "ok"
    default:
      return "usage: pwprompt press <button>|username <fixture>"
    }
  }
}

// MARK: Password prompt view

/// The prompt's content: a key, "Save password?" and the site, the username (editable, or a choice of the saved ones
/// when updating) over the password's dots, then the answers.
final class PasswordPromptView: NSView {
  static let width: CGFloat = 320
  var onAnswer: ((String) -> Void)?
  private let prompt: PasswordPrompts.Prompt
  private let icon = NSImageView()
  private let title: NSTextField
  private let origin: NSTextField
  private let well = NSView()
  private let field = NSTextField()
  private let secret = NSTextField(labelWithString: "")
  private var choices: [NSView] = []
  private var chosen: String?
  private let buttons: [(action: String, button: PanelButton)]
  private(set) var ready = false

  init(prompt: PasswordPrompts.Prompt) {
    self.prompt = prompt
    let update = prompt.state == "update"
    title = NSTextField(labelWithString: update ? "Update password?" : "Save password?")
    origin = NSTextField(wrappingLabelWithString: PermissionPromptView.display(prompt.origin))
    var answers: [(String, PanelButton)] = []
    if !update { answers.append(("never", PanelButton(title: "Never"))) }
    answers.append((update ? "nope" : "dismiss", PanelButton(title: "Not Now")))
    answers.append((update ? "update" : "save", PanelButton(title: update ? "Update" : "Save", primary: true)))
    buttons = answers.map { (action: $0.0, button: $0.1) }
    super.init(frame: .zero)

    icon.image = NSImage(systemSymbolName: "key.fill", accessibilityDescription: nil)
    icon.symbolConfiguration = .init(pointSize: 14, weight: .semibold)
    icon.contentTintColor = .secondaryLabelColor
    icon.wantsLayer = true
    icon.layer?.cornerRadius = 8
    icon.layer?.cornerCurve = .continuous
    addSubview(icon)
    title.font = .systemFont(ofSize: 13.5, weight: .semibold)
    origin.font = .systemFont(ofSize: 12)
    origin.textColor = .secondaryLabelColor
    origin.lineBreakMode = .byCharWrapping
    origin.isSelectable = false
    addSubview(title)
    addSubview(origin)

    well.wantsLayer = true
    well.layer?.cornerRadius = 8
    well.layer?.cornerCurve = .continuous
    addSubview(well)
    if update && prompt.usernames.count > 1 {
      choose(prompt.username)
    } else {
      field.stringValue = prompt.username
      field.placeholderString = prompt.federation.isEmpty
        ? "Username" : "Signed in with \(URL(string: prompt.federation)?.host ?? prompt.federation)"
      field.font = .systemFont(ofSize: 12.5, weight: .medium)
      field.isBordered = false
      field.drawsBackground = false
      field.focusRingType = .none
      field.isEditable = !update
      field.isSelectable = !update
      field.lineBreakMode = .byTruncatingTail
      field.cell?.isScrollable = true
      field.setAccessibilityLabel("Username")
      addSubview(field)
      secret.stringValue = String(repeating: "•", count: min(prompt.passwordLength, 16))
      secret.font = .systemFont(ofSize: 12)
      secret.textColor = .secondaryLabelColor
      secret.isHidden = prompt.passwordLength == 0
      secret.setAccessibilityLabel("Password, hidden")
      addSubview(secret)
    }
    for (action, button) in buttons {
      button.isEnabled = false
      button.onClick = { [weak self] in self?.onAnswer?(action) }
      addSubview(button)
    }
    frame = NSRect(x: 0, y: 0, width: Self.width, height: layoutContent(apply: false))
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }
  override var mouseDownCanMoveWindow: Bool { false }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guard window != nil else { return }
    // Each time it appears its buttons wait half a second, so a click meant for the page can't land on one.
    ready = false
    buttons.forEach { $0.button.isEnabled = false }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
      guard let self, self.window != nil else { return }
      self.ready = true
      self.buttons.forEach { $0.button.isEnabled = true }
    }
  }

  override func updateLayer() {
    super.updateLayer()
    icon.layer?.backgroundColor = PanelColors.tile.cgColor
    well.layer?.backgroundColor = PanelColors.tile.cgColor
  }

  override var wantsUpdateLayer: Bool { true }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    needsDisplay = true
  }

  override func layout() {
    super.layout()
    _ = layoutContent(apply: true)
  }

  private func layoutContent(apply: Bool) -> CGFloat {
    let pad: CGFloat = 16
    let left = pad + 44
    let textWidth = Self.width - left - pad
    var y = pad
    let titleHeight = ceil(title.intrinsicContentSize.height)
    origin.preferredMaxLayoutWidth = textWidth
    let originHeight = ceil(origin.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: textWidth, height: 1000)).height ?? 16)
    if apply {
      icon.frame = NSRect(x: pad, y: pad, width: 32, height: 32)
      title.frame = NSRect(x: left - 2, y: y, width: textWidth + 4, height: titleHeight)
      origin.frame = NSRect(x: left - 2, y: y + titleHeight + 2, width: textWidth + 4, height: originHeight)
    }
    y = max(y + titleHeight + 2 + originHeight, pad + 32) + 12
    let wellWidth = Self.width - pad * 2
    var wellHeight: CGFloat
    if choices.isEmpty {
      let fieldHeight = ceil(field.intrinsicContentSize.height)
      wellHeight = 10 + fieldHeight + (secret.isHidden ? 0 : 2 + 15) + 10
      if apply {
        field.frame = NSRect(x: pad + 10, y: y + 10, width: wellWidth - 20, height: fieldHeight)
        secret.frame = NSRect(x: pad + 12, y: y + 10 + fieldHeight + 2, width: wellWidth - 24, height: 15)
      }
    } else {
      wellHeight = 6 + CGFloat(choices.count) * 36 + 6
      for (index, row) in choices.enumerated() where apply {
        row.frame = NSRect(x: pad + 4, y: y + 6 + CGFloat(index) * 36, width: wellWidth - 8, height: 36)
      }
    }
    if apply { well.frame = NSRect(x: pad, y: y, width: wellWidth, height: wellHeight) }
    y += wellHeight + 14
    var right = Self.width - pad
    for (_, button) in buttons.reversed() {
      let width = button.intrinsicContentSize.width
      right -= width
      if apply { button.frame = NSRect(x: right, y: y, width: width, height: 28) }
      right -= 6
    }
    return y + 28 + pad
  }

  /// The saved username to update: its row ticked (the rows are made again, as site controls' choices are).
  private func choose(_ name: String) {
    chosen = name
    choices.forEach { $0.removeFromSuperview() }
    choices = prompt.usernames.map { each in
      PanelKit.choice(each, chosen: each == name) { [weak self] in self?.choose(each) }
    }
    choices.forEach { addSubview($0) }
    needsLayout = true
  }

  /// What's typed (or chosen) for the username.
  var username: String {
    get { chosen ?? field.stringValue }
    set { if chosen != nil { choose(newValue) } else { field.stringValue = newValue } }
  }

  var originText: String { origin.stringValue }
  var dots: Int { secret.isHidden ? 0 : secret.stringValue.count }
  var buttonTitles: [String] { buttons.map { $0.button.accessibilityLabel() ?? "" } }

  /// A click on an answer, as the mouse would make it: nothing while its buttons wait.
  func press(_ action: String) -> Bool {
    let wanted = action == "notnow" ? (prompt.state == "update" ? "nope" : "dismiss") : action
    guard let button = buttons.first(where: { $0.action == wanted })?.button, button.isEnabled else { return false }
    button.performClick(nil)
    return true
  }
}
