import AppKit

// Building blocks for the Settings panes that show the user's own data (Passwords, Autofill): a stack whose rows come
// and go, list rows, headers, inline forms and detail lines, small buttons, a pasteboard that
// forgets secrets, and the test hooks' fixtures. Nothing here logs what it shows.

/// Tells the pane that holds `view` its height changed (rows came or went): it lays out again and the scroll view's
/// document follows.
func settingsContentDidResize(_ view: NSView) {
  view.needsLayout = true
  var next = view.superview
  while let current = next {
    current.needsLayout = true
    if let pane = current as? SettingsPaneView {
      pane.onResize?()
      return
    }
    next = current.superview
  }
}

/// A one-line label's width as drawn, with room to spare (`intrinsicContentSize` comes out a point or two short for
/// some of these and the text truncates).
func settingsLabelWidth(_ label: NSTextField) -> CGFloat {
  ceil(label.attributedStringValue.size().width) + 6
}

/// Scrolls the Settings pane so `view` (an item's details or a form just opened) shows, once the pane has laid out.
func settingsScrollIntoView(_ view: NSView) {
  DispatchQueue.main.async {
    guard view.window != nil else { return }
    view.enclosingScrollView?.documentView?.layoutSubtreeIfNeeded()
    view.scrollToVisible(view.bounds.insetBy(dx: 0, dy: -56))
  }
}

// MARK: Stack

/// Views one under another, each with the gap above it and, optionally, a hairline above it. `set` replaces them
/// (views it keeps stay where they are in the tree). With `cards` on (a data pane's own list), each run of items
/// between headers (`SettingsDataHeader`) sits on a card, 14 pt in, as a group's rows do; headers stay outside, 4 pt in.
final class SettingsStack: NSView, SettingsSizing {
  struct Item {
    let view: NSView
    var gap: CGFloat = 0
    var line = false
    /// Spans the card it's on edge to edge (a picture band), past the card's inset.
    var bleeds = false
  }

  private(set) var items: [Item] = []
  private var lines: [Hairline] = []
  var cards = false { didSet { needsLayout = true } }
  private var backs: [SettingsCardBackground] = []

  override var isFlipped: Bool { true }

  func set(_ items: [Item]) {
    let kept = Set(items.map { ObjectIdentifier($0.view) })
    for old in self.items where !kept.contains(ObjectIdentifier(old.view)) { old.view.removeFromSuperview() }
    lines.forEach { $0.removeFromSuperview() }
    lines = []
    self.items = items
    for item in items {
      if item.view.superview !== self { addSubview(item.view) }
      if item.line {
        let line = Hairline()
        lines.append(line)
        addSubview(line)
      }
    }
    needsLayout = true
  }

  private func isHeader(_ item: Item) -> Bool { cards && item.view is SettingsDataHeader }

  /// Each item's frame (x, width) at `width`: on a card 14 pt in, a header 4 pt in, else the full width.
  private func span(_ item: Item, _ width: CGFloat) -> (x: CGFloat, width: CGFloat) {
    guard cards else { return item.bleeds ? (-SettingsCardBox.inset, width + SettingsCardBox.inset * 2) : (0, width) }
    if isHeader(item) { return (SettingsPaneView.headerInset, width - SettingsPaneView.headerInset) }
    return item.bleeds ? (0, width) : (SettingsCardBox.inset, width - SettingsCardBox.inset * 2)
  }

  func height(forWidth width: CGFloat) -> CGFloat {
    items.reduce(0) { $0 + $1.gap + sizedHeight($1.view, width: span($1, width).width) }
  }

  override func layout() {
    super.layout()
    var y: CGFloat = 0
    var line = 0
    // Card runs: where each starts and ends.
    var runs: [(top: CGFloat, bottom: CGFloat)] = []
    var runTop: CGFloat?
    for item in items {
      if isHeader(item) {
        if let top = runTop { runs.append((top, y)) }
        runTop = nil
      } else if cards, runTop == nil {
        runTop = y + item.gap
      }
      y += item.gap
      let (x, width) = span(item, bounds.width)
      if item.line, line < lines.count {
        lines[line].frame = NSRect(x: x, y: y, width: width, height: 1)
        line += 1
      }
      let height = sizedHeight(item.view, width: width)
      item.view.frame = NSRect(x: x, y: y, width: width, height: height)
      y += height
    }
    if let top = runTop { runs.append((top, y)) }
    while backs.count < runs.count {
      let back = SettingsCardBackground()
      backs.append(back)
      addSubview(back, positioned: .below, relativeTo: nil)
    }
    while backs.count > runs.count { backs.removeLast().removeFromSuperview() }
    for (back, run) in zip(backs, runs) {
      back.frame = NSRect(x: 0, y: run.top, width: bounds.width, height: run.bottom - run.top)
    }
  }
}

// MARK: Header

/// A data section's header: its title (13 pt semibold, as a group's), a grey count after it, and controls on the right
/// (a search field, Add…).
final class SettingsDataHeader: NSView, SettingsSizing {
  private let titleLabel: NSTextField
  private let countLabel = settingsLabel("", size: 13, color: .secondaryLabelColor)
  private var trailing: [NSView] = []

  init(title: String) {
    titleLabel = settingsLabel(title, size: 13, weight: .semibold)
    super.init(frame: .zero)
    addSubview(titleLabel)
    addSubview(countLabel)
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }

  var count: String {
    get { countLabel.stringValue }
    set { countLabel.stringValue = newValue }
  }

  func setTrailing(_ views: [NSView]) {
    trailing.forEach { $0.removeFromSuperview() }
    trailing = views
    views.forEach { addSubview($0) }
    needsLayout = true
  }

  func height(forWidth width: CGFloat) -> CGFloat {
    max(24, trailing.map { $0.fittingSize.height }.max() ?? 0) + 8
  }

  override func layout() {
    super.layout()
    let room = bounds.height - 8
    var right = bounds.width
    for view in trailing.reversed() {
      let size = view.fittingSize
      let width = view is NSSearchField ? min(200, max(120, bounds.width * 0.32)) : size.width
      view.frame = NSRect(x: right - width, y: ((room - size.height) / 2).rounded(), width: width, height: size.height)
      right -= width + 8
    }
    let titleHeight = ceil(titleLabel.intrinsicContentSize.height)
    titleLabel.frame = NSRect(x: 0, y: ((room - titleHeight) / 2).rounded(), width: min(settingsLabelWidth(titleLabel), right), height: titleHeight)
    let countX = titleLabel.frame.maxX + 2
    countLabel.frame = NSRect(x: countX, y: titleLabel.frame.minY, width: max(0, right - countX - 8), height: titleHeight)
  }
}

// MARK: Rows

/// A line of grey text that wraps (an empty list, a status after an export).
final class SettingsNote: NSView, SettingsSizing {
  /// An empty list's note on its card: one line as tall as a row (44 pt).
  static let rowInset: CGFloat = 14
  private let label: NSTextField
  private let inset: CGFloat

  init(_ text: String, color: NSColor = .secondaryLabelColor, inset: CGFloat = 8) {
    label = NSTextField(wrappingLabelWithString: text)
    self.inset = inset
    super.init(frame: .zero)
    label.font = .systemFont(ofSize: 12)
    label.textColor = color
    label.isSelectable = false
    addSubview(label)
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }

  var text: String {
    get { label.stringValue }
    set { label.stringValue = newValue }
  }

  func height(forWidth width: CGFloat) -> CGFloat { textHeight(label, width: width) + inset * 2 }

  override func layout() {
    super.layout()
    label.frame = NSRect(x: 0, y: inset, width: bounds.width, height: textHeight(label, width: bounds.width))
  }
}

// MARK: Card

/// An open item's details, or a form: inset on a soft fill with rounded corners, under its row.
final class SettingsCard: NSView, SettingsSizing {
  let content: NSView
  private static let padding: CGFloat = 14

  init(_ content: NSView) {
    self.content = content
    super.init(frame: .zero)
    wantsLayer = true
    layer?.cornerRadius = 10
    layer?.cornerCurve = .continuous
    addSubview(content)
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }
  override var wantsUpdateLayer: Bool { true }
  override func updateLayer() { layer?.backgroundColor = SettingsColors.track.cgColor }

  func height(forWidth width: CGFloat) -> CGFloat {
    sizedHeight(content, width: width - Self.padding * 2) + Self.padding * 2 + 8
  }

  override func layout() {
    super.layout()
    let height = sizedHeight(content, width: bounds.width - Self.padding * 2)
    content.frame = NSRect(x: Self.padding, y: Self.padding, width: bounds.width - Self.padding * 2, height: height)
  }
}

/// One line of an open item: a grey name on the left, the value, and small buttons after it.
final class SettingsDetailLine: NSView, SettingsSizing {
  static let nameWidth: CGFloat = 96
  private let nameLabel: NSTextField
  let valueLabel: NSTextField
  private let buttons: [NSView]

  init(name: String, value: String, monospaced: Bool = false, buttons: [NSView] = []) {
    nameLabel = settingsLabel(name, size: 12, color: .secondaryLabelColor)
    valueLabel = settingsLabel(value, size: 13)
    self.buttons = buttons
    super.init(frame: .zero)
    valueLabel.lineBreakMode = .byTruncatingMiddle
    if monospaced { valueLabel.font = .monospacedSystemFont(ofSize: 13, weight: .regular) }
    addSubview(nameLabel)
    addSubview(valueLabel)
    buttons.forEach { addSubview($0) }
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }

  func height(forWidth width: CGFloat) -> CGFloat { 28 }

  override func layout() {
    super.layout()
    let nameHeight = ceil(nameLabel.intrinsicContentSize.height)
    nameLabel.frame = NSRect(x: 0, y: ((bounds.height - nameHeight) / 2).rounded(), width: Self.nameWidth - 8, height: nameHeight)
    let valueHeight = ceil(valueLabel.intrinsicContentSize.height)
    let valueWidth = min(settingsLabelWidth(valueLabel),
                         bounds.width - Self.nameWidth - CGFloat(buttons.count) * 28 - 8)
    valueLabel.frame = NSRect(x: Self.nameWidth, y: ((bounds.height - valueHeight) / 2).rounded(), width: max(0, valueWidth), height: valueHeight)
    var x = valueLabel.frame.maxX + 6
    for button in buttons {
      button.frame = NSRect(x: x, y: ((bounds.height - 24) / 2).rounded(), width: 24, height: 24)
      x += 26
    }
  }
}

/// The buttons at the bottom of a card: one on the left (Delete…), the rest on the right.
final class SettingsButtonBar: NSView, SettingsSizing {
  private let leading: [NSView]
  private let trailing: [NSView]

  init(leading: [NSView] = [], trailing: [NSView]) {
    self.leading = leading
    self.trailing = trailing
    super.init(frame: .zero)
    (leading + trailing).forEach { addSubview($0) }
    // It sits on a card's fill.
    (leading + trailing).forEach { ($0 as? SettingsButton)?.onCard = true }
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }

  func height(forWidth width: CGFloat) -> CGFloat { 38 }

  override func layout() {
    super.layout()
    let top: CGFloat = 10
    var x: CGFloat = 0
    for view in leading {
      let size = view.fittingSize
      view.frame = NSRect(x: x, y: top + ((28 - size.height) / 2).rounded(), width: size.width, height: size.height)
      x += size.width + 8
    }
    var right = bounds.width
    for view in trailing.reversed() {
      let size = view.fittingSize
      view.frame = NSRect(x: right - size.width, y: top + ((28 - size.height) / 2).rounded(), width: size.width, height: size.height)
      right -= size.width + 8
    }
  }
}

// MARK: Form

/// Labelled text fields, one per line, for adding or editing an item. Secure fields never show what they hold.
final class SettingsForm: NSView, SettingsSizing {
  struct Field {
    let key: String
    let label: String
    let box: EditorField
    var field: NSTextField { box.field }
  }

  private(set) var fields: [Field] = []
  private var labels: [NSTextField] = []
  private let error = NSTextField(wrappingLabelWithString: "")
  /// Fields narrower than the column (an expiry month).
  private var widths: [String: CGFloat] = [:]

  override var isFlipped: Bool { true }

  init() {
    super.init(frame: .zero)
    error.font = .systemFont(ofSize: 12)
    error.textColor = .systemRed
    error.isSelectable = false
    addSubview(error)
  }

  required init?(coder: NSCoder) { fatalError() }

  @discardableResult
  func add(_ key: String, _ label: String, value: String = "", placeholder: String = "", secure: Bool = false,
           width: CGFloat? = nil) -> NSTextField {
    // On the card's fill: the content's colour.
    let box = EditorField(placeholder: placeholder, secure: secure)
    box.fill = SettingsColors.card
    let field = box.field
    field.stringValue = value
    field.setAccessibilityLabel(label)
    if secure { field.contentType = .password }
    let name = settingsLabel(label, size: 12, color: .secondaryLabelColor)
    fields.append(Field(key: key, label: label, box: box))
    labels.append(name)
    if let width { widths[key] = width }
    addSubview(name)
    addSubview(box)
    // Tab goes from field to field, in order.
    if fields.count > 1 { fields[fields.count - 2].field.nextKeyView = field }
    return field
  }

  subscript(key: String) -> NSTextField? { fields.first { $0.key == key }?.field }

  var errorText: String {
    get { error.stringValue }
    set {
      error.stringValue = newValue
      settingsContentDidResize(self)
    }
  }

  /// Empties every field (secure ones especially), so nothing typed stays in a view that is gone.
  func wipe() {
    for item in fields {
      item.field.stringValue = ""
      item.field.abortEditing()
    }
  }

  func height(forWidth width: CGFloat) -> CGFloat {
    let errorHeight = error.stringValue.isEmpty ? 0 : textHeight(error, width: width) + 6
    return CGFloat(fields.count) * 32 + errorHeight
  }

  override func layout() {
    super.layout()
    let nameWidth = SettingsDetailLine.nameWidth
    let fieldWidth = min(340, bounds.width - nameWidth)
    var y: CGFloat = 0
    for (index, item) in fields.enumerated() {
      let label = labels[index]
      let labelHeight = ceil(label.intrinsicContentSize.height)
      label.frame = NSRect(x: 0, y: y + ((32 - labelHeight) / 2).rounded(), width: nameWidth - 8, height: labelHeight)
      item.box.frame = NSRect(x: nameWidth, y: y + 2, width: widths[item.key] ?? fieldWidth, height: 28)
      y += 32
    }
    if !error.stringValue.isEmpty {
      error.frame = NSRect(x: nameWidth, y: y + 2, width: bounds.width - nameWidth, height: textHeight(error, width: bounds.width - nameWidth))
    } else {
      error.frame = .zero
    }
  }
}

// MARK: Buttons

/// A borderless SF Symbol button (Copy, Show), its name in its tooltip and for VoiceOver.
final class SettingsIconButton: NSButton {
  var onClick: (() -> Void)?

  init(symbol: String, label: String, action: (() -> Void)? = nil) {
    super.init(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
    setSymbol(symbol, label: label)
    isBordered = false
    bezelStyle = .regularSquare
    imagePosition = .imageOnly
    contentTintColor = .secondaryLabelColor
    target = self
    self.action = #selector(clicked)
    onClick = action
  }

  required init?(coder: NSCoder) { fatalError() }

  func setSymbol(_ symbol: String, label: String) {
    image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
      .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
    toolTip = label
    setAccessibilityLabel(label)
  }

  override var intrinsicContentSize: NSSize { NSSize(width: 24, height: 24) }
  override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

  @objc private func clicked() { onClick?() }
}

// MARK: Pasteboard

/// Copies for the data panes. A password or card number is marked concealed (nspasteboard.org's
/// `org.nspasteboard.ConcealedType`, which clipboard managers skip) and cleared after two minutes if it is still
/// what the pasteboard holds, as Chrome does (`kClipboardClearDelay`, passwords_private_delegate_impl.cc).
enum SettingsPasteboard {
  static let clearDelay: TimeInterval = 120
  private static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
  private static var clearing: DispatchWorkItem?

  static var board: NSPasteboard { BrowserWindowController.pasteboard }
  /// A secret is on the pasteboard and will be cleared.
  static var clearPending: Bool { clearing != nil }

  static func copy(_ text: String, secret: Bool) {
    let board = self.board
    board.clearContents()
    board.setString(text, forType: .string)
    clearing?.cancel()
    clearing = nil
    guard secret else { return }
    board.setData(Data(), forType: concealed)
    let count = board.changeCount
    let work = DispatchWorkItem {
      clearing = nil
      // Only if nothing was copied since.
      if board.changeCount == count { board.clearContents() }
    }
    clearing = work
    DispatchQueue.main.asyncAfter(deadline: .now() + clearDelay, execute: work)
  }

  /// For tests: what the timer would do, now.
  static func clearNow() -> Bool {
    guard let work = clearing else { return false }
    work.perform()
    work.cancel()
    return true
  }

  static var isConcealed: Bool { board.types?.contains(concealed) ?? false }
}

// MARK: Tests

/// Test builds only: fixture logins, cards and addresses from `RAY_TEST_SECRETS` (JSON), so the test commands that
/// type them name them by index and no secret is ever in a command line (which the test log echoes).
enum SettingsFixtures {
  private static let all: [String: Any] = {
    guard let text = TestEnvironment["RAY_TEST_SECRETS"], let data = text.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
    return object
  }()

  static func item(_ kind: String, _ index: String) -> [String: Any]? {
    guard let list = all[kind] as? [[String: Any]], let i = Int(index), list.indices.contains(i) else { return nil }
    return list[i]
  }

  static func text(_ item: [String: Any], _ key: String) -> String {
    if let text = item[key] as? String { return text }
    if let number = item[key] as? NSNumber { return number.stringValue }
    return ""
  }
}

/// A test command's answer, written when it is ready (an engine reply), in TestCommands' format.
func settingsTestReply(_ line: String, _ result: String) {
  FileHandle.standardError.write("[ray-test] \(line) -> \(result)\n".data(using: .utf8)!)
}

/// Whether this instance may make the engine calls that ask for Touch ID or the login password. Ray.app: always. A test
/// build: only a hidden instance started with RAY_REAUTH=granted|denied, whose engine answers at once with no prompt
/// (main.swift); any other test instance never makes them, so no test shows a real prompt.
var settingsReauthAllowed: Bool {
  guard TestEnvironment.isTestBuild else { return true }
  return launchedInBackground && ["granted", "denied"].contains(TestEnvironment["RAY_REAUTH"] ?? "")
}

/// The engine's default profile, where saved passwords and autofill live (never a private window's).
var settingsDataProfile: RayCoreProfile? { RayCoreEngine.shared?.defaultProfile }

/// After a change worth checking: every window's state log (test builds) shows it.
func settingsDataChanged(_ event: String) {
  DispatchQueue.main.async { AppController.shared.current?.logState(event) }
}

// MARK: Secrets to the engine

/// A JSON object for `EngineCalls.callWithSecret`, written straight into `SecretBytes` (never a Swift String holding
/// the whole thing): what the engine reads with `SensitiveArgs`. The bytes are wiped once the engine has parsed them.
enum SecretJSON {
  enum Value {
    case text(String)
    case number(Int)
    case object([(String, Value)])
  }

  static func object(_ fields: [(String, Value)]) -> SecretBytes {
    let writer = SecretWriter(capacity: 256)
    write(fields, to: writer)
    writer.append(0)
    return writer.finish()
  }

  private static func write(_ fields: [(String, Value)], to writer: SecretWriter) {
    writer.append(UInt8(ascii: "{"))
    for (index, (key, value)) in fields.enumerated() {
      if index > 0 { writer.append(UInt8(ascii: ",")) }
      JSON.string(key, to: writer)
      writer.append(UInt8(ascii: ":"))
      switch value {
      case .text(let text): JSON.string(text, to: writer)
      case .number(let number): writer.append(String(number))
      case .object(let inner): write(inner, to: writer)
      }
    }
    writer.append(UInt8(ascii: "}"))
  }
}

// MARK: Locking

/// When what the data panes unlocked or revealed goes away: the Settings window closing, five minutes without a click,
/// key or scroll in it (Chrome's `kPasswordManagerAuthValidity`, restarted by activity as its
/// `PasswordAccessAuthTimeoutHandler` is), the screens going to sleep, or the user switching to another account.
/// Panes register what to forget; `arm()` starts the clock when something is unlocked.
final class SettingsDataGuard {
  static let shared = SettingsDataGuard()
  static let idle: TimeInterval = 5 * 60

  private var handlers: [() -> Void] = []
  private var timer: DispatchWorkItem?
  private var monitor: Any?
  private var observing = false

  var armed: Bool { timer != nil }

  /// `forget` runs on every lock (twice is harmless).
  func register(_ forget: @escaping () -> Void) {
    handlers.append(forget)
    observe()
  }

  /// Something is unlocked or showing: lock after the idle time, sooner on the window closing or sleep.
  func arm() {
    if monitor == nil {
      // Activity in the Settings window keeps it open; only which window an event is for is looked at, and only to
      // restart the clock (never what was typed).
      monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown, .scrollWheel]) { [weak self] event in
        if event.window?.delegate === SettingsWindowController.shared { self?.touch() }
        return event
      }
    }
    touch()
  }

  /// Restarts the clock (an action in a pane).
  func touch() {
    timer?.cancel()
    let work = DispatchWorkItem { [weak self] in self?.lock() }
    timer = work
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.idle, execute: work)
  }

  /// Forgets everything now.
  func lock() {
    timer?.cancel()
    timer = nil
    if let monitor { NSEvent.removeMonitor(monitor) }
    monitor = nil
    handlers.forEach { $0() }
  }

  private func observe() {
    guard !observing else { return }
    observing = true
    NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] note in
      guard (note.object as? NSWindow)?.delegate === SettingsWindowController.shared else { return }
      SettingsConfirm.dismiss()
      self?.lock()
    }
    let workspace = NSWorkspace.shared.notificationCenter
    for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
      workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.lock() }
    }
  }
}
