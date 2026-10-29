import AppKit

// Settings › Shortcuts' editor (the `shortcuts` setting's control): every command of Ray's menu by menu, its key in a
// key-cap field, a search field over their names and Reset All Shortcuts (Ardia's Shortcuts pane, without its
// filters). Click a field and press the keys: ⌘ or ⌃ with a key, or a function key. Escape cancels, Delete or Forward
// Delete leave the command with no key. A key another command has asks, in the list (no sheet or popover), whether to
// take it from that one (Crest's Replace / Cancel); a key macOS or a locked command keeps is refused there and the
// field keeps listening. What the keys do is MenuShortcuts.swift.

// MARK: Pane

final class ShortcutsPaneContent: SettingsPaneContent {
  private(set) weak var editor: ShortcutEditor?

  func control(named name: String, for key: AnySettingKey) -> NSView? {
    guard name == "shortcuts" else { return nil }
    let editor = ShortcutEditor()
    self.editor = editor
    return editor
  }

  // MARK: Tests

  /// `shortcuts state|search <text>|record <id>|type <key> [cmd shift opt ctrl]|replace|cancel|reset <id>|resetall|scroll
  /// [id]`: the editor's own controls, pressed as a click or a key press would (open the pane first: `settings open
  /// shortcuts`). `type` hands the recorder a key press made by `makeEvent`, as its key monitor would. `state` is one
  /// line of JSON.
  static func testCommand(_ argument: String, makeEvent: (String, NSWindow?) -> NSEvent?) -> String {
    let words = argument.split(separator: " ", maxSplits: 1).map(String.init)
    guard let content = SettingsPanes.content(for: .shortcuts) as? ShortcutsPaneContent, let editor = content.editor else {
      return "no pane"
    }
    let rest = words.count == 2 ? words[1] : ""
    switch words.first {
    case "state": return editor.debugJSON
    case "search": editor.search(rest)
    case "record": return editor.pressField(rest) ? "ok" : "no such command"
    case "type":
      guard editor.recordingID != nil else { return "not recording" }
      guard let event = makeEvent(rest, editor.window) else { return "usage: shortcuts type <key> [cmd shift opt ctrl]" }
      editor.receive(event)
    case "replace": return editor.pressReplace() ? "ok" : "no conflict"
    case "cancel": return editor.pressCancel() ? "ok" : "no conflict"
    case "reset": return editor.pressReset(rest) ? "ok" : "not customized"
    case "resetall": return editor.pressResetAll() ? "ok" : "nothing to reset"
    case "scroll": editor.scrollIntoView(rest.isEmpty ? nil : rest)
    default:
      return "usage: shortcuts state|search <text>|record <id>|type <key> [mods]|replace|cancel|reset <id>|resetall|scroll [id]"
    }
    return "ok"
  }
}

/// Tells the pane its height changed (a notice came or went, a search hid rows): it lays out again.
private func relayoutPane(from view: NSView) {
  var current: NSView? = view
  while let each = current {
    each.needsLayout = true
    if let pane = each as? SettingsPaneView {
      pane.onResize?()
      return
    }
    current = each.superview
  }
}

// MARK: Editor

final class ShortcutEditor: NSView, SettingsWideControl, NSTextFieldDelegate {
  /// What the list says under a command's row.
  enum Notice: Equatable {
    /// A key that can't be the command's, and why (the field keeps listening).
    case problem(id: String, text: String)
    /// A key another command has: Replace takes it from that one.
    case conflict(id: String, combo: KeyCombo, holder: String)

    var id: String {
      switch self {
      case .problem(let id, _), .conflict(let id, _, _): return id
      }
    }
  }

  private enum Entry {
    case header(NSTextField)
    case row(ShortcutRow)
    case notice(ShortcutNotice)
    case empty(NSTextField)
  }

  private static let toolbarHeight: CGFloat = 28
  private static let rowHeight: CGFloat = 36

  private let searchBox = ShortcutSearchBox()
  private let resetAll = LinkButton(title: "Reset All Shortcuts")
  private var entries: [Entry] = []
  private var lines: [Hairline] = []
  private(set) var query = ""
  private(set) var recordingID: String?
  private(set) var notice: Notice?
  private var monitor: Any?
  private var applied: NSObjectProtocol?

  init() {
    super.init(frame: .zero)
    searchBox.field.delegate = self
    resetAll.setAccessibilityLabel("Reset all shortcuts to Ray's defaults")
    resetAll.onClick = { [weak self] in _ = self?.pressResetAll() }
    addSubview(searchBox)
    addSubview(resetAll)
    applied = NotificationCenter.default.addObserver(forName: MenuShortcuts.didApply, object: nil, queue: .main) { [weak self] _ in
      self?.rebuild()
    }
    rebuild()
  }

  required init?(coder: NSCoder) { fatalError() }

  deinit {
    if let monitor { NSEvent.removeMonitor(monitor) }
    if let applied { NotificationCenter.default.removeObserver(applied) }
  }

  override var isFlipped: Bool { true }

  override func viewWillMove(toWindow newWindow: NSWindow?) {
    super.viewWillMove(toWindow: newWindow)
    if newWindow == nil { stopRecording() }
  }

  // MARK: Rows

  /// The commands the search leaves, in menu order. Every typed word starts a word of the title or the menu's name.
  private var shown: [MenuCommand] {
    let typed = BarActions.words(query)
    return MenuShortcuts.commands.filter { command in
      let names = BarActions.words(command.title) + BarActions.words(command.menu)
      return typed.allSatisfy { word in names.contains { $0.hasPrefix(word) } }
    }
  }

  private func rebuild() {
    for entry in entries {
      switch entry {
      case .header(let view), .empty(let view): view.removeFromSuperview()
      case .row(let view): view.removeFromSuperview()
      case .notice(let view): view.removeFromSuperview()
      }
    }
    entries = []
    let commands = shown
    var menu: String?
    for command in commands {
      if command.menu != menu {
        menu = command.menu
        let header = settingsLabel(command.menu, size: 12, weight: .semibold, color: .secondaryLabelColor)
        entries.append(.header(header))
        addSubview(header)
      }
      let row = ShortcutRow(command: command, recording: recordingID == command.id,
                            customized: MenuShortcuts.isCustomized(command))
      row.field.onPress = { [weak self] in self?.startRecording(command.id) }
      row.onReset = { [weak self] in _ = self?.pressReset(command.id) }
      entries.append(.row(row))
      addSubview(row)
      if let notice, notice.id == command.id {
        let view = ShortcutNotice(notice, onReplace: { [weak self] in _ = self?.pressReplace() },
                                  onCancel: { [weak self] in _ = self?.pressCancel() })
        entries.append(.notice(view))
        addSubview(view)
      }
    }
    if commands.isEmpty {
      let empty = settingsLabel("No commands match “\(query)”", size: 13, color: .secondaryLabelColor)
      entries.append(.empty(empty))
      addSubview(empty)
    }
    let customized = !MenuShortcuts.overrides.isEmpty
    resetAll.isEnabled = customized
    resetAll.alphaValue = customized ? 1 : 0.4
    relayoutPane(from: self)
  }

  // MARK: Layout

  private func height(of entry: Entry, width: CGFloat) -> CGFloat {
    switch entry {
    case .header(let label): return ceil(label.intrinsicContentSize.height)
    case .row: return Self.rowHeight
    case .notice(let view): return view.height(forWidth: width)
    case .empty: return 40
    }
  }

  /// Space above an entry: a group's header sits apart from the group before it.
  private func gap(before index: Int) -> CGFloat {
    guard index > 0 else { return 0 }
    switch entries[index] {
    case .header: return 18
    default:
      if case .header = entries[index - 1] { return 4 }
      return 0
    }
  }

  func height(forWidth width: CGFloat) -> CGFloat {
    var y = Self.toolbarHeight + 14
    for (index, entry) in entries.enumerated() { y += gap(before: index) + height(of: entry, width: width) }
    return y
  }

  override func layout() {
    super.layout()
    let width = bounds.width
    let resetSize = resetAll.intrinsicContentSize
    resetAll.frame = NSRect(x: width - resetSize.width, y: ((Self.toolbarHeight - resetSize.height) / 2).rounded(),
                            width: resetSize.width, height: resetSize.height)
    searchBox.frame = NSRect(x: 0, y: 0, width: max(120, resetAll.frame.minX - 16), height: Self.toolbarHeight)
    lines.forEach { $0.isHidden = true }
    var lineIndex = 0
    var y = Self.toolbarHeight + 14
    for (index, entry) in entries.enumerated() {
      y += gap(before: index)
      let height = height(of: entry, width: width)
      let frame = NSRect(x: 0, y: y, width: width, height: height)
      switch entry {
      case .header(let view), .empty(let view): view.frame = frame
      case .notice(let view): view.frame = frame
      case .row(let view):
        view.frame = frame
        // A hairline between two rows of a group.
        if index > 0, case .row = entries[index - 1] {
          if lineIndex == lines.count {
            let line = Hairline()
            lines.append(line)
            addSubview(line)
          }
          lines[lineIndex].isHidden = false
          lines[lineIndex].frame = NSRect(x: 0, y: y, width: width, height: 1)
          lineIndex += 1
        }
      }
      y += height
    }
  }

  // MARK: Search

  func controlTextDidChange(_ notification: Notification) { search(searchBox.field.stringValue) }

  func search(_ text: String) {
    if searchBox.field.stringValue != text { searchBox.field.stringValue = text }
    query = text
    rebuild()
  }

  // MARK: Recording

  /// Clicking a field: it listens for the next key press (another field stops listening).
  private func startRecording(_ id: String) {
    guard let command = MenuShortcuts.command(id), command.rebindable else { return }
    stopRecording()
    notice = nil
    recordingID = id
    // The search field gives up the keys.
    if window?.firstResponder is NSText { window?.makeFirstResponder(nil) }
    monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
      guard let self else { return event }
      return self.intercept(event) ? nil : event
    }
    rebuild()
  }

  private func stopRecording() {
    if let monitor { NSEvent.removeMonitor(monitor) }
    monitor = nil
    recordingID = nil
  }

  /// The key monitor: a key press in this window is the shortcut (nothing else sees it); a click anywhere, or a key in
  /// another window, stops listening and goes on as usual.
  private func intercept(_ event: NSEvent) -> Bool {
    guard let id = recordingID else { return false }
    if event.type != .keyDown {
      // After the click lands, on the rows it was aimed at (a click on another field starts that one instead).
      DispatchQueue.main.async { [weak self] in
        if self?.recordingID == id { self?.cancelRecording() }
      }
      return false
    }
    guard event.window === window, window != nil else {
      cancelRecording()
      return false
    }
    receive(event)
    return true
  }

  private func cancelRecording() {
    guard recordingID != nil else { return }
    stopRecording()
    if case .problem = notice { notice = nil }
    rebuild()
  }

  /// A key press while listening.
  func receive(_ event: NSEvent) {
    guard let id = recordingID else { return }
    let modifiers = event.modifierFlags.intersection(KeyCombo.relevant)
    if modifiers.isEmpty, event.keyCode == 53 {
      notice = nil
      cancelRecording()
      return
    }
    if modifiers.isEmpty, event.keyCode == 51 || event.keyCode == 117 {
      stopRecording()
      notice = nil
      clear(id)
      rebuild()
      return
    }
    guard let combo = KeyCombo(event: event) else {
      show(.problem(id: id, text: "That key can't be a shortcut. Try a letter, number or function key."))
      return
    }
    record(combo, for: id)
  }

  private func record(_ combo: KeyCombo, for id: String) {
    guard let command = MenuShortcuts.command(id) else { return }
    if combo == command.current {
      stopRecording()
      notice = nil
      rebuild()
      return
    }
    if let refusal = ShortcutOverrides.refusal(combo, for: id) {
      show(.problem(id: id, text: refusal))
      return
    }
    if let holder = MenuShortcuts.holder(of: combo, except: id) {
      stopRecording()
      show(.conflict(id: id, combo: combo, holder: holder.id))
      return
    }
    stopRecording()
    notice = nil
    assign(combo, to: id, replacing: nil)
  }

  private func show(_ notice: Notice) {
    self.notice = notice
    rebuild()
    if let row = row(for: notice.id) { row.superview?.layoutSubtreeIfNeeded() }
  }

  // MARK: Changing the setting

  private var current: [String: KeyCombo?] { MenuShortcuts.overrides }

  private func save(_ entries: [String: KeyCombo?]) {
    guard RaySettings.shared.set(.shortcuts, ShortcutOverrides(entries)) else {
      if let id = recordingID ?? notice?.id { show(.problem(id: id, text: "Ray couldn't keep that shortcut.")) }
      return
    }
    rebuild()
  }

  /// `combo` becomes `id`'s key; `holder` (Replace) gives its own up. A command whose key is a default needs nothing:
  /// a default yields to a key the user chose.
  private func assign(_ combo: KeyCombo, to id: String, replacing holder: String?) {
    guard let command = MenuShortcuts.command(id) else { return }
    var entries = current
    if combo == MenuShortcuts.defaultKey(of: command) { entries.removeValue(forKey: id) } else { entries[id] = .some(combo) }
    if let holder, let held = entries[holder], held == combo { entries[holder] = .some(nil) }
    save(entries)
  }

  /// Delete while listening: the command keeps no key.
  private func clear(_ id: String) {
    guard let command = MenuShortcuts.command(id) else { return }
    var entries = current
    if MenuShortcuts.defaultKey(of: command) == nil { entries.removeValue(forKey: id) } else { entries[id] = .some(nil) }
    save(entries)
  }

  // MARK: Presses (the views' and the test command's)

  func pressField(_ id: String) -> Bool {
    guard let command = MenuShortcuts.command(id), command.rebindable else { return false }
    startRecording(id)
    scrollIntoView(id)
    return true
  }

  func pressReplace() -> Bool {
    guard case .conflict(let id, let combo, let holder) = notice else { return false }
    notice = nil
    assign(combo, to: id, replacing: holder)
    return true
  }

  func pressCancel() -> Bool {
    guard case .conflict = notice else { return false }
    notice = nil
    rebuild()
    return true
  }

  func pressReset(_ id: String) -> Bool {
    var entries = current
    guard entries.removeValue(forKey: id) != nil else { return false }
    if notice?.id == id { notice = nil }
    save(entries)
    return true
  }

  func pressResetAll() -> Bool {
    guard !current.isEmpty else { return false }
    stopRecording()
    notice = nil
    RaySettings.shared.apply(AnySettingKey.shortcuts, "default")
    rebuild()
    return true
  }

  private func row(for id: String) -> ShortcutRow? {
    for case .row(let row) in entries where row.command.id == id { return row }
    return nil
  }

  /// Brings the editor's top (or a command's row, with what's under it) into view.
  func scrollIntoView(_ id: String?) {
    window?.contentView?.layoutSubtreeIfNeeded()
    guard let scroll = enclosingScrollView, let document = scroll.documentView else { return }
    var target = convert(bounds, to: document)
    if let id, let row = row(for: id) { target = row.convert(row.bounds, to: document) }
    let top = max(0, min(target.minY - 90, document.frame.height - scroll.contentView.bounds.height))
    scroll.contentView.scroll(to: NSPoint(x: 0, y: top))
    scroll.reflectScrolledClipView(scroll.contentView)
  }

  // MARK: Tests

  var debugJSON: String {
    var groups: [String] = []
    var rows: [[String: Any]] = []
    for case .header(let label) in entries { groups.append(label.stringValue) }
    for case .row(let row) in entries {
      rows.append([
        "id": row.command.id, "title": row.command.title, "menu": row.command.menu, "key": row.command.current?.display ?? "",
        "field": row.field.text, "locked": !row.command.rebindable, "customized": row.customized,
      ])
    }
    var noticeOut: Any = NSNull()
    switch notice {
    case .problem(let id, let text): noticeOut = ["kind": "problem", "id": id, "text": text]
    case .conflict(let id, let combo, let holder):
      noticeOut = ["kind": "conflict", "id": id, "combo": combo.display, "holder": holder,
                   "holderTitle": MenuShortcuts.command(holder)?.title ?? ""]
    case nil: break
    }
    let out: [String: Any] = [
      "query": query, "groups": groups, "rows": rows, "recording": recordingID ?? NSNull(), "notice": noticeOut,
      "resetAllEnabled": resetAll.isEnabled, "empty": entries.contains { if case .empty = $0 { return true } else { return false } },
      "height": height(forWidth: max(bounds.width, 400)),
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys]),
          let text = String(data: data, encoding: .utf8) else { return "{}" }
    return text
  }
}

// MARK: Row

/// A command: its title on the left; on the right its key-cap field, with a reset arrow before it when the user chose
/// its key.
private final class ShortcutRow: NSView {
  let command: MenuCommand
  let customized: Bool
  let field: KeyCapField
  var onReset: (() -> Void)?
  private let titleLabel: NSTextField
  private var reset: NSButton?

  init(command: MenuCommand, recording: Bool, customized: Bool) {
    self.command = command
    self.customized = customized
    titleLabel = settingsLabel(command.title, size: 13, color: command.rebindable ? .labelColor : .secondaryLabelColor)
    field = KeyCapField()
    super.init(frame: .zero)
    field.setAccessibilityLabel("Shortcut for \(command.title)")
    if command.rebindable {
      field.style = recording ? .recording : .normal
      field.text = recording ? "Type Shortcut" : command.current?.display ?? "None"
      field.toolTip = "Click, then press the new shortcut. Escape cancels; Delete removes it."
    } else {
      field.style = .locked
      field.text = command.current?.display ?? "None"
      field.toolTip = command.lockedReason.map { "\($0)." }
    }
    addSubview(titleLabel)
    addSubview(field)
    if customized {
      let button = NSButton()
      button.isBordered = false
      button.bezelStyle = .regularSquare
      button.imagePosition = .imageOnly
      button.image = NSImage(systemSymbolName: "arrow.uturn.backward", accessibilityDescription: "Reset")
      button.symbolConfiguration = .init(pointSize: 11, weight: .medium)
      button.contentTintColor = .secondaryLabelColor
      let original = MenuShortcuts.defaultKey(of: command)?.display ?? "none"
      button.toolTip = "Back to Ray's shortcut (\(original))"
      button.setAccessibilityLabel("Reset \(command.title) to Ray's shortcut")
      button.target = self
      button.action = #selector(resetPressed)
      reset = button
      addSubview(button)
    }
    setAccessibilityElement(false)
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }

  @objc private func resetPressed() { onReset?() }

  override func layout() {
    super.layout()
    let mid = bounds.height / 2
    let size = field.intrinsicContentSize
    field.frame = NSRect(x: bounds.width - size.width, y: (mid - size.height / 2).rounded(), width: size.width, height: size.height)
    var right = field.frame.minX - 8
    if let reset {
      reset.frame = NSRect(x: right - 20, y: (mid - 10).rounded(), width: 20, height: 20)
      right = reset.frame.minX - 8
    }
    let height = ceil(titleLabel.intrinsicContentSize.height)
    titleLabel.frame = NSRect(x: 0, y: (mid - height / 2).rounded(), width: max(0, right - 8), height: height)
  }
}

// MARK: Key cap

/// A command's key in a rounded field, as macOS's Keyboard Shortcuts draws them. Listening, it says "Type Shortcut" in
/// the profile's colour with a ring of it; a command that can't change shows its key as plain grey text.
final class KeyCapField: NSControl {
  enum Style { case normal, recording, locked }

  var onPress: (() -> Void)?
  var style: Style = .normal { didSet { update() } }
  var text = "" { didSet { update() } }
  private let label = settingsLabel("", size: 12, weight: .medium)

  init() {
    super.init(frame: .zero)
    wantsLayer = true
    layer?.cornerRadius = 6
    layer?.cornerCurve = .continuous
    label.alignment = .center
    addSubview(label)
    setAccessibilityElement(true)
    setAccessibilityRole(.button)
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }
  override var wantsUpdateLayer: Bool { true }
  override var mouseDownCanMoveWindow: Bool { false }

  override var intrinsicContentSize: NSSize {
    NSSize(width: max(104, ceil(label.attributedStringValue.size().width) + 24), height: 24)
  }

  private func update() {
    label.stringValue = text
    setAccessibilityValue(text)
    invalidateIntrinsicContentSize()
    needsDisplay = true
    needsLayout = true
    superview?.needsLayout = true
  }

  override func updateLayer() {
    switch style {
    case .normal:
      layer?.backgroundColor = SettingsColors.track.cgColor
      layer?.borderWidth = 0
      label.textColor = text == "None" ? .tertiaryLabelColor : .labelColor
    case .recording:
      layer?.backgroundColor = SettingsColors.strip.cgColor
      layer?.borderWidth = 1.5
      layer?.borderColor = SettingsColors.mark.cgColor
      label.textColor = ProfileColor.legible(NSColor(name: nil) { _ in ProfileColor.accent }, on: SettingsColors.strip, minimum: 4.5)
    case .locked:
      layer?.backgroundColor = NSColor.clear.cgColor
      layer?.borderWidth = 0
      label.textColor = .secondaryLabelColor
    }
  }

  override func layout() {
    super.layout()
    let height = ceil(label.intrinsicContentSize.height)
    label.frame = NSRect(x: 0, y: ((bounds.height - height) / 2).rounded(), width: bounds.width, height: height)
  }

  override func resetCursorRects() { if style != .locked { addCursorRect(bounds, cursor: .pointingHand) } }

  override func mouseDown(with event: NSEvent) { if style != .locked { onPress?() } }

  override func accessibilityPerformPress() -> Bool {
    guard style != .locked else { return false }
    onPress?()
    return true
  }
}

// MARK: Notice

/// Under a row: why a key can't be its shortcut (red text), or that another command has it, with Cancel and Replace.
private final class ShortcutNotice: NSView, SettingsSizing {
  private let label: NSTextField
  private let isConflict: Bool
  private var replace: AccentButton?
  private var cancel: LinkButton?

  init(_ notice: ShortcutEditor.Notice, onReplace: @escaping () -> Void, onCancel: @escaping () -> Void) {
    switch notice {
    case .problem(_, let text):
      label = NSTextField(wrappingLabelWithString: text)
      isConflict = false
    case .conflict(_, let combo, let holder):
      let other = MenuShortcuts.command(holder)
      let name = other.map { "\($0.title) (\($0.menu) menu)" } ?? "another command"
      label = NSTextField(wrappingLabelWithString: "\(combo.display) is already the shortcut for \(name). Replace it? "
        + "\(other?.title ?? "That command") will have none.")
      isConflict = true
    }
    super.init(frame: .zero)
    label.font = .systemFont(ofSize: 12)
    label.isSelectable = false
    label.textColor = isConflict ? .labelColor : .systemRed
    addSubview(label)
    if isConflict {
      wantsLayer = true
      layer?.cornerRadius = 8
      layer?.cornerCurve = .continuous
      let replace = AccentButton(title: "Replace")
      replace.onClick = onReplace
      let cancel = LinkButton(title: "Cancel")
      cancel.background = SettingsColors.strip
      cancel.onClick = onCancel
      self.replace = replace
      self.cancel = cancel
      addSubview(replace)
      addSubview(cancel)
    }
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }
  override var wantsUpdateLayer: Bool { true }
  override func updateLayer() { if isConflict { layer?.backgroundColor = SettingsColors.strip.cgColor } }

  private var buttonsWidth: CGFloat {
    guard let replace, let cancel else { return 0 }
    return replace.intrinsicContentSize.width + 16 + cancel.intrinsicContentSize.width + 16
  }

  private func textWidth(_ width: CGFloat) -> CGFloat { max(80, width - (isConflict ? 24 + buttonsWidth : 0)) }

  func height(forWidth width: CGFloat) -> CGFloat {
    let text = textHeight(label, width: textWidth(width))
    return isConflict ? max(48, text + 24) : text + 10
  }

  override func layout() {
    super.layout()
    let width = textWidth(bounds.width)
    let height = textHeight(label, width: width)
    if let replace, let cancel {
      label.frame = NSRect(x: 12, y: ((bounds.height - height) / 2).rounded(), width: width, height: height)
      let size = replace.intrinsicContentSize
      replace.frame = NSRect(x: bounds.width - 12 - size.width, y: ((bounds.height - size.height) / 2).rounded(),
                             width: size.width, height: size.height)
      let cancelSize = cancel.intrinsicContentSize
      cancel.frame = NSRect(x: replace.frame.minX - 16 - cancelSize.width, y: ((bounds.height - cancelSize.height) / 2).rounded(),
                            width: cancelSize.width, height: cancelSize.height)
    } else {
      label.frame = NSRect(x: 0, y: 0, width: width, height: height)
    }
  }
}

// MARK: Search field

/// The editor's search: a rounded field with a magnifying glass, as Settings' own sidebar search.
private final class ShortcutSearchBox: NSView {
  let field = NSTextField()
  private let icon = NSImageView()

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.cornerRadius = 7
    layer?.cornerCurve = .continuous
    icon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
    icon.symbolConfiguration = .init(pointSize: 11, weight: .medium)
    icon.contentTintColor = .secondaryLabelColor
    field.isBezeled = false
    field.isBordered = false
    field.drawsBackground = false
    field.focusRingType = .none
    field.font = .systemFont(ofSize: 13)
    field.placeholderString = "Search commands"
    field.setAccessibilityLabel("Search menu commands")
    field.cell?.isScrollable = true
    field.cell?.wraps = false
    field.cell?.usesSingleLineMode = true
    addSubview(icon)
    addSubview(field)
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }
  override var wantsUpdateLayer: Bool { true }
  override var mouseDownCanMoveWindow: Bool { false }
  override func updateLayer() { layer?.backgroundColor = SettingsColors.track.cgColor }
  override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(field) }

  override func layout() {
    super.layout()
    icon.frame = NSRect(x: 8, y: ((bounds.height - 14) / 2).rounded(), width: 14, height: 14)
    let height = ceil(field.intrinsicContentSize.height)
    field.frame = NSRect(x: 28, y: ((bounds.height - height) / 2).rounded(), width: bounds.width - 36, height: height)
  }
}
