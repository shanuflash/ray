import AppKit

// Pieces the data panes share (Settings › Privacy, Settings › Extensions): a list whose rows come and go with the
// engine's data, a row with an icon that can open to show more under it, buttons, a confirmation sheet that ignores
// clicks for its first half second, and opening a page in the normal window. They look like the generated rows
// (`SettingsRowView`): 13 pt titles over 12 pt grey lines, at least 44 pt, hairlines between.

// MARK: List

/// Rows with hairlines between them, replaced as the data behind them changes. A pane's own section, or the inside
/// of an opened row.
final class SettingsDynamicList: NSView, SettingsSizing {
  private(set) var rows: [NSView] = []
  private var lines: [Hairline] = []
  /// When the list lands in a window (its pane is shown): the time to load what it shows.
  var onShow: (() -> Void)?
  /// When the window it's in becomes key again (back from the browser, say).
  var onWindowKey: (() -> Void)?
  private var keyObserver: NSObjectProtocol?

  override var isFlipped: Bool { true }

  func setRows(_ new: [NSView]) {
    rows.forEach { $0.removeFromSuperview() }
    lines.forEach { $0.removeFromSuperview() }
    rows = new
    lines = []
    for (index, row) in new.enumerated() {
      addSubview(row)
      if index > 0 {
        let line = Hairline()
        lines.append(line)
        addSubview(line)
      }
    }
    settingsSectionResized()
  }

  func height(forWidth width: CGFloat) -> CGFloat { rows.reduce(0) { $0 + sizedHeight($1, width: width) } }

  override func layout() {
    super.layout()
    var y: CGFloat = 0
    for (index, row) in rows.enumerated() {
      let height = sizedHeight(row, width: bounds.width)
      row.frame = NSRect(x: 0, y: y, width: bounds.width, height: height)
      if index > 0 { lines[index - 1].frame = NSRect(x: 0, y: y, width: bounds.width, height: 1) }
      y += height
    }
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
    keyObserver = nil
    guard let window else { return }
    onShow?()
    keyObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in self?.onWindowKey?() }
  }
}

extension NSView {
  /// A section's height changed (rows came or went, one opened): its pane lays out again and the window fits it.
  func settingsSectionResized() {
    var view: NSView? = self
    while let current = view, !(current is SettingsPaneView) {
      current.needsLayout = true
      view = current.superview
    }
    guard let pane = view as? SettingsPaneView else { return }
    pane.needsLayout = true
    pane.onResize?()
  }
}

// MARK: Rows

/// One item of a data list: an icon, a title (a host elides from its start, so the end of the name stays), a grey
/// line, controls on the right, and, opened, more under it (`body`). A click on the top part opens or closes it.
final class SettingsItemRow: NSView, SettingsSizing {
  static let iconSize: CGFloat = 22
  private static let indent: CGFloat = 34

  /// What tests and links know the row by (an origin, a host, an extension's id).
  let key: String
  private let iconView = NSImageView()
  private let titleLabel: NSTextField
  private let detailLabel: NSTextField
  private let controls: [NSView]
  private let chevron = NSImageView()
  /// Shown under the row while it's open.
  let body: NSView?
  var onToggle: ((Bool) -> Void)?
  private(set) var isOpen = false
  private let hasIcon: Bool

  init(key: String, icon: NSImage?, title: String, detail: String, controls: [NSView] = [], body: NSView? = nil,
       open: Bool = false, titleElidesHead: Bool = false, showsIcon: Bool = true) {
    self.key = key
    titleLabel = settingsLabel(title, size: 13)
    detailLabel = NSTextField(wrappingLabelWithString: detail)
    self.controls = controls
    self.body = body
    hasIcon = showsIcon
    super.init(frame: .zero)
    titleLabel.lineBreakMode = titleElidesHead ? .byTruncatingHead : .byTruncatingTail
    detailLabel.font = .systemFont(ofSize: 12)
    detailLabel.textColor = .secondaryLabelColor
    detailLabel.isSelectable = false
    detailLabel.maximumNumberOfLines = 3
    detailLabel.cell?.truncatesLastVisibleLine = true
    iconView.image = icon
    iconView.imageScaling = .scaleProportionallyUpOrDown
    iconView.symbolConfiguration = .init(pointSize: 14, weight: .regular)
    iconView.contentTintColor = .secondaryLabelColor
    if showsIcon { addSubview(iconView) }
    addSubview(titleLabel)
    addSubview(detailLabel)
    controls.forEach { addSubview($0) }
    if let body {
      chevron.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
      chevron.contentTintColor = .tertiaryLabelColor
      addSubview(chevron)
      addSubview(body)
    }
    setOpen(open, animated: false)
    setAccessibilityElement(false)
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }
  override var mouseDownCanMoveWindow: Bool { false }

  /// The icon fades for something switched off (a disabled extension).
  var dimmed = false { didSet { iconView.alphaValue = dimmed ? 0.45 : 1 } }

  var title: String { titleLabel.stringValue }
  var detail: String { detailLabel.stringValue }

  func setOpen(_ open: Bool, animated: Bool = true) {
    isOpen = open && body != nil
    body?.isHidden = !isOpen
    chevron.image = NSImage(systemSymbolName: isOpen ? "chevron.up" : "chevron.down", accessibilityDescription: nil)
    chevron.setAccessibilityLabel(isOpen ? "Hide details" : "Show details")
    needsLayout = true
    if animated { settingsSectionResized() }
  }

  /// A click on the row's top part, or a test's.
  func toggle() {
    guard body != nil else { return }
    setOpen(!isOpen)
    onToggle?(isOpen)
  }

  override func mouseDown(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    if point.y <= topHeight(bounds.width) { toggle() }
  }

  override func resetCursorRects() {
    if body != nil { addCursorRect(NSRect(x: 0, y: 0, width: bounds.width, height: topHeight(bounds.width)), cursor: .pointingHand) }
  }

  private var textLeft: CGFloat { hasIcon ? Self.indent : 0 }

  private var controlsWidth: CGFloat {
    var width = controls.reduce(0) { $0 + $1.fittingSize.width + 8 }
    if body != nil { width += 22 }
    return width
  }

  private func textWidth(_ width: CGFloat) -> CGFloat { max(80, width - textLeft - controlsWidth - 12) }

  private func topHeight(_ width: CGFloat) -> CGFloat {
    let text = textWidth(width)
    let title = ceil(titleLabel.intrinsicContentSize.height)
    let detail = textHeight(detailLabel, width: text)
    let tallest = controls.map { $0.fittingSize.height }.max() ?? 0
    return max(SettingsRowView.minHeight, 11 + max(title + (detail > 0 ? 2 + detail : 0), tallest, Self.iconSize) + 11)
  }

  func height(forWidth width: CGFloat) -> CGFloat {
    var height = topHeight(width)
    if isOpen, let body { height += sizedHeight(body, width: width - textLeft) + 10 }
    return height
  }

  override func layout() {
    super.layout()
    let top = topHeight(bounds.width)
    let middle = top / 2
    let text = textWidth(bounds.width)
    let title = ceil(titleLabel.intrinsicContentSize.height)
    let detail = textHeight(detailLabel, width: text)
    let block = title + (detail > 0 ? 2 + detail : 0)
    iconView.frame = NSRect(x: 2, y: (middle - Self.iconSize / 2).rounded(), width: Self.iconSize, height: Self.iconSize)
    titleLabel.frame = NSRect(x: textLeft, y: (middle - block / 2).rounded(), width: text, height: title)
    detailLabel.frame = NSRect(x: textLeft, y: (middle - block / 2 + title + 2).rounded(), width: text, height: detail)
    var right = bounds.width
    if body != nil {
      chevron.frame = NSRect(x: right - 14, y: (middle - 7).rounded(), width: 14, height: 14)
      right -= 22
    }
    for control in controls.reversed() {
      let size = control.fittingSize
      control.frame = NSRect(x: right - size.width, y: (middle - size.height / 2).rounded(), width: size.width, height: size.height)
      right -= size.width + 8
    }
    if let body, isOpen {
      body.frame = NSRect(x: textLeft, y: top, width: bounds.width - textLeft, height: sizedHeight(body, width: bounds.width - textLeft))
    }
  }
}

/// A row inside an opened item: a title (and an optional grey line) on the left, one control on the right.
final class SettingsDetailRow: NSView, SettingsSizing {
  private let titleLabel: NSTextField
  private let detailLabel: NSTextField
  let control: NSView?
  private let iconView: NSImageView?

  init(title: String, detail: String = "", symbol: String? = nil, control: NSView?) {
    titleLabel = NSTextField(wrappingLabelWithString: title)
    detailLabel = NSTextField(wrappingLabelWithString: detail)
    self.control = control
    iconView = symbol.map { NSImageView(image: NSImage(systemSymbolName: $0, accessibilityDescription: nil) ?? NSImage()) }
    super.init(frame: .zero)
    titleLabel.font = .systemFont(ofSize: 13)
    titleLabel.isSelectable = false
    detailLabel.font = .systemFont(ofSize: 12)
    detailLabel.textColor = .secondaryLabelColor
    detailLabel.isSelectable = false
    addSubview(titleLabel)
    addSubview(detailLabel)
    if let iconView {
      iconView.symbolConfiguration = .init(pointSize: 12, weight: .regular)
      iconView.contentTintColor = .secondaryLabelColor
      addSubview(iconView)
    }
    if let control { addSubview(control) }
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }

  private var left: CGFloat { iconView == nil ? 0 : 24 }
  private func textWidth(_ width: CGFloat) -> CGFloat { max(80, width - left - (control.map { $0.fittingSize.width + 16 } ?? 0)) }

  func height(forWidth width: CGFloat) -> CGFloat {
    let text = textWidth(width)
    let detail = textHeight(detailLabel, width: text)
    let block = textHeight(titleLabel, width: text) + (detail > 0 ? 2 + detail : 0)
    return max(36, 8 + max(block, control?.fittingSize.height ?? 0) + 8)
  }

  override func layout() {
    super.layout()
    let text = textWidth(bounds.width)
    let title = textHeight(titleLabel, width: text), detail = textHeight(detailLabel, width: text)
    let block = title + (detail > 0 ? 2 + detail : 0)
    let middle = bounds.height / 2
    iconView?.frame = NSRect(x: 0, y: (middle - 8).rounded(), width: 16, height: 16)
    titleLabel.frame = NSRect(x: left, y: (middle - block / 2).rounded(), width: text, height: title)
    detailLabel.frame = NSRect(x: left, y: (middle - block / 2 + title + 2).rounded(), width: text, height: detail)
    if let control {
      let size = control.fittingSize
      control.frame = NSRect(x: bounds.width - size.width, y: (middle - size.height / 2).rounded(), width: size.width, height: size.height)
    }
  }
}

/// Buttons side by side, left-aligned, under an opened item.
final class SettingsButtonRow: NSView, SettingsSizing {
  let buttons: [NSView]

  init(_ buttons: [NSView]) {
    self.buttons = buttons
    super.init(frame: .zero)
    buttons.forEach { addSubview($0) }
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }

  func height(forWidth width: CGFloat) -> CGFloat { 44 }

  override func layout() {
    super.layout()
    var x: CGFloat = 0
    for button in buttons {
      let size = button.fittingSize
      button.frame = NSRect(x: x, y: ((bounds.height - size.height) / 2).rounded(), width: size.width, height: size.height)
      x += size.width + 8
    }
  }
}

/// A plain push button that runs a closure (grey, never the system accent).
final class SettingsButton: NSButton {
  var onClick: (() -> Void)?

  init(_ title: String, destructive: Bool = false, action: (() -> Void)? = nil) {
    super.init(frame: .zero)
    self.title = title
    bezelStyle = .push
    controlSize = .regular
    font = .systemFont(ofSize: 13)
    hasDestructiveAction = destructive
    target = self
    self.action = #selector(clicked)
    onClick = action
  }

  required init?(coder: NSCoder) { fatalError() }

  override var fittingSize: NSSize { intrinsicContentSize }

  @objc private func clicked() { onClick?() }

  /// A test's click, only when a person could click it.
  func press() -> Bool {
    guard isEnabled, !isHidden else { return false }
    onClick?()
    return true
  }
}

/// A pop-up of named values whose choice runs a closure.
final class SettingsPopUp: NSPopUpButton {
  var onChoose: ((String) -> Void)?
  private(set) var values: [String] = []

  init(_ options: [(title: String, value: String)], selected: String?, pullsDown: Bool = false, title: String? = nil) {
    super.init(frame: .zero, pullsDown: pullsDown)
    font = .systemFont(ofSize: 13)
    if pullsDown { addItem(withTitle: title ?? "") }
    for option in options {
      if option.value == "-" {
        menu?.addItem(.separator())
      } else {
        addItem(withTitle: option.title)
        lastItem?.representedObject = option.value
      }
    }
    values = options.map(\.value).filter { $0 != "-" }
    if !pullsDown, let selected, let index = itemArray.firstIndex(where: { $0.representedObject as? String == selected }) {
      selectItem(at: index)
    }
    target = self
    action = #selector(chosen)
  }

  required init?(coder: NSCoder) { fatalError() }

  override var fittingSize: NSSize { intrinsicContentSize }

  var selectedValue: String? { selectedItem?.representedObject as? String }

  @objc private func chosen() {
    guard let value = selectedValue else { return }
    onChoose?(value)
  }

  /// A test's choice, as a person would pick it.
  func choose(_ value: String) -> Bool {
    guard isEnabled, let index = itemArray.firstIndex(where: { $0.representedObject as? String == value }) else { return false }
    selectItem(at: index)
    chosen()
    return true
  }
}

// MARK: Confirm

/// The question before a destructive action (Remove an extension, Clear Site Data), as a sheet on the Settings
/// window. Following the security checklist: Cancel is the default (Return and Escape cancel), the action's button
/// ignores clicks for its first half second, and the message names exactly what goes (the full origin, the
/// extension and its ID).
enum SettingsConfirm {
  private static var open: (alert: NSAlert, confirm: NSButton, window: NSWindow?)?

  static func ask(_ message: String, detail: String, action: String, in window: NSWindow?, then: @escaping () -> Void) {
    guard open == nil else { return }
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = message
    alert.informativeText = detail
    alert.addButton(withTitle: "Cancel")
    let confirm = alert.addButton(withTitle: action)
    confirm.hasDestructiveAction = true
    confirm.keyEquivalent = ""
    confirm.isEnabled = false
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { confirm.isEnabled = true }
    open = (alert, confirm, window)
    let done: (NSApplication.ModalResponse) -> Void = { response in
      open = nil
      if response == .alertSecondButtonReturn { then() }
    }
    if let window {
      alert.beginSheetModal(for: window, completionHandler: done)
    } else {
      done(alert.runModal())
    }
  }

  /// For tests: the question showing, if any.
  static var debug: [String: Any]? {
    open.map { ["message": $0.alert.messageText, "detail": $0.alert.informativeText, "ready": $0.confirm.isEnabled] }
  }

  /// For tests: answers as a click would; a click on the action in its first half second does nothing.
  static func answer(accept: Bool) -> String {
    guard let open else { return "no question" }
    let button = accept ? open.confirm : open.alert.buttons[0]
    guard button.isEnabled else { return "not ready" }
    button.performClick(nil)
    return "ok"
  }
}

// MARK: Pages

enum SettingsPages {
  /// The profile the data panes show and change: the normal one, never a private window's.
  static var profile: RayCoreProfile? { RayCoreEngine.shared?.defaultProfile }

  /// Whether an engine event is about the normal profile (private windows' changes aren't the panes' business).
  static func isNormalProfile(_ payload: [String: Any]) -> Bool {
    guard payload["offTheRecord"] as? Bool != true, let profile else { return false }
    guard let path = payload["profile"] as? String else { return true }
    return URL(fileURLWithPath: path).standardizedFileURL.path == URL(fileURLWithPath: profile.path).standardizedFileURL.path
  }

  /// Opens a page in a tab of the normal window (opened again if it was closed), never a private one: the panes act
  /// on the normal profile.
  static func open(_ url: String) {
    guard let controller = AppController.shared.openMainWindow() else { return }
    controller.openToday(url, after: controller.activeEntry, foreground: true)
    if !launchedInBackground { controller.window.makeKeyAndOrderFront(nil) }
  }

  /// One of the engine's pages (Clear Browsing Data), switched to when it's already open in the normal window.
  static func show(_ address: String) {
    guard let controller = AppController.shared.openMainWindow(), let url = AddressInput.url(for: address) else { return }
    controller.showPage(url)
    if !launchedInBackground { controller.window.makeKeyAndOrderFront(nil) }
  }

  /// A site's icon from the engine's favicon store, as the command bar's rows get theirs.
  static func favicons(for pages: [String], then done: @escaping ([String: NSImage]) -> Void) {
    guard let profile, !pages.isEmpty else { return done([:]) }
    EngineCalls.call("ac_favicons_get", profile: profile, args: ["pages": Array(pages.prefix(200)), "size": 32]) { reply in
      var out: [String: NSImage] = [:]
      for (page, info) in reply?["pages"] as? [String: [String: Any]] ?? [:] {
        if let png = info["png"] as? String, let data = Data(base64Encoded: png), let image = NSImage(data: data) { out[page] = image }
      }
      done(out)
    }
  }

  /// JSON text for a test command's answer.
  static func json(_ value: Any) -> String {
    guard JSONSerialization.isValidJSONObject(value),
          let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
          let text = String(data: data, encoding: .utf8) else { return "{}" }
    return text
  }
}
