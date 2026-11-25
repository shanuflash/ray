import AppKit

/// What New Space and Edit Space… change, before it's saved.
struct SpaceDraft: Equatable {
  var name: String
  var icon: String?
  var color: String?
  var accent: String?
  /// nil: the default profile; "new": a new one made on Create; else a profile directory another Space uses.
  var profile: String?
  var mode: String? = nil
  var strength: Double? = nil
}

/// A profile the editor offers: its directory and the Spaces on it.
struct SpaceProfileChoice {
  let directory: String?
  let title: String
}

/// New Space and Edit Space… (owner's pick 4B of `docs/mocks/spaces.html`, 2026-11-25): a panel that grows out of the
/// footer's + (or the Space's icon). Name, icon, a full theme (the Window colour the browser takes and the Accent Ray's
/// selection, loading and "on" states take) and its profile, as Arc offers one. Every change shows at once on the
/// window behind; Cancel, Escape or a click outside puts it back, Create Space (or Done, Return) keeps it.
final class SpaceEditorView: NSView, NSTextFieldDelegate {
  static let newProfile = "new"
  private(set) var draft: SpaceDraft
  let isNew: Bool
  var onChange: ((SpaceDraft) -> Void)?
  var onFinish: ((Bool) -> Void)?

  private let title = NSTextField(labelWithString: "")
  private let nameField = EditorField(placeholder: "Space name")
  private let labels = ["Icon", "Window", "Accent", "Profile"].map { NSTextField(labelWithString: $0) }
  private var iconCells: [SpaceChoiceCell] = []
  private var windowCells: [SpaceChoiceCell] = []
  private var accentCells: [SpaceChoiceCell] = []
  private let profileButton = NSPopUpButton(frame: .zero, pullsDown: false)
  private let profiles: [SpaceProfileChoice]
  let cancelButton = PanelButton(title: "Cancel")
  let confirmButton: PanelButton
  /// Settings › Spaces' editor: no title, Cancel or Done (every change applies at once), and Delete Space….
  let inSettings: Bool
  let deleteButton = SettingsButton("Delete Space…", destructive: true)
  var onDelete: (() -> Void)?
  private var pickingColor: WritableKeyPath<SpaceDraft, String?>?

  init(draft: SpaceDraft, isNew: Bool, profiles: [SpaceProfileChoice], inSettings: Bool = false) {
    self.draft = draft
    self.isNew = isNew
    self.profiles = profiles
    self.inSettings = inSettings
    confirmButton = PanelButton(title: isNew ? "Create Space" : "Done", primary: true)
    super.init(frame: .zero)
    wantsLayer = true
    title.stringValue = isNew ? "New Space" : "Edit Space"
    title.font = .systemFont(ofSize: 13.5, weight: .semibold)
    addSubview(title)
    nameField.fill = SidebarColors.fill
    nameField.field.stringValue = draft.name
    nameField.field.delegate = self
    nameField.field.setAccessibilityLabel("Space name")
    addSubview(nameField)
    for label in labels {
      label.font = .systemFont(ofSize: 11, weight: .semibold)
      label.textColor = .secondaryLabelColor
      addSubview(label)
    }
    iconCells = SpaceTheme.icons.map { icon in
      let cell = SpaceChoiceCell(kind: .icon(icon))
      cell.onClick = { [weak self] in self?.choose(icon: icon) }
      addSubview(cell)
      return cell
    }
    windowCells = ([nil] + SpaceTheme.windows.map(Optional.some)).map { hex in
      let cell = SpaceChoiceCell(kind: .colour(hex))
      cell.onClick = { [weak self] in self?.choose(\.color, hex) }
      addSubview(cell)
      return cell
    } + [customCell(\.color)]
    accentCells = ([nil] + SpaceTheme.accents.map(Optional.some)).map { hex in
      let cell = SpaceChoiceCell(kind: .colour(hex))
      cell.onClick = { [weak self] in self?.choose(\.accent, hex) }
      addSubview(cell)
      return cell
    } + [customCell(\.accent)]
    for choice in profiles { profileButton.addItem(withTitle: choice.title) }
    profileButton.addItem(withTitle: "New Profile")
    profileButton.font = .systemFont(ofSize: 12)
    profileButton.controlSize = .small
    profileButton.target = self
    profileButton.action = #selector(profileChosen)
    selectProfileItem()
    addSubview(profileButton)
    cancelButton.onClick = { [weak self] in self?.onFinish?(false) }
    confirmButton.onClick = { [weak self] in self?.confirm() }
    addSubview(cancelButton)
    addSubview(confirmButton)
    deleteButton.onClick = { [weak self] in self?.onDelete?() }
    addSubview(deleteButton)
    title.isHidden = inSettings
    cancelButton.isHidden = inSettings
    confirmButton.isHidden = inSettings
    deleteButton.isHidden = !inSettings
    refreshChoices()
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }
  override var mouseDownCanMoveWindow: Bool { false }
  static let width: CGFloat = 268

  var profileTitles: [String] { profiles.map(\.title) }
  var isTyping: Bool { nameField.field.currentEditor() != nil }

  func focusName() {
    window?.makeFirstResponder(nameField.field)
    nameField.field.currentEditor()?.selectAll(nil)
  }

  private func customCell(_ path: WritableKeyPath<SpaceDraft, String?>) -> SpaceChoiceCell {
    let cell = SpaceChoiceCell(kind: .custom)
    cell.onClick = { [weak self] in self?.pickColor(path) }
    addSubview(cell)
    return cell
  }

  // MARK: Choices

  private func choose(icon: String) {
    draft.icon = draft.icon == icon ? nil : icon
    changed()
  }

  private func choose(_ path: WritableKeyPath<SpaceDraft, String?>, _ hex: String?) {
    draft[keyPath: path] = hex
    changed()
  }

  /// Any colour: macOS's colour panel, followed live.
  private func pickColor(_ path: WritableKeyPath<SpaceDraft, String?>) {
    pickingColor = path
    let panel = NSColorPanel.shared
    panel.showsAlpha = false
    panel.setTarget(self)
    panel.setAction(#selector(colorPicked(_:)))
    if let hex = draft[keyPath: path], let rgb = ProfileColor.parse(hex) {
      panel.color = NSColor(srgbRed: rgb.r, green: rgb.g, blue: rgb.b, alpha: 1)
    }
    if !TestEnvironment.isTestBuild { panel.orderFront(nil) }
  }

  @objc private func colorPicked(_ panel: NSColorPanel) {
    guard let path = pickingColor else { return }
    draft[keyPath: path] = ProfileColor.hex(of: panel.color)
    changed()
  }

  /// For tests: a colour as if picked in the panel.
  func pickCustom(_ which: String, hex: String) -> Bool {
    guard let valid = Space.validHex(hex) else { return false }
    choose(which == "accent" ? \.accent : \.color, valid)
    return true
  }

  @objc private func profileChosen() {
    let index = profileButton.indexOfSelectedItem
    draft.profile = profiles.indices.contains(index) ? profiles[index].directory : Self.newProfile
    changed()
  }

  func chooseProfile(_ index: Int) -> Bool {
    guard index >= 0, index <= profiles.count else { return false }
    profileButton.selectItem(at: index)
    profileChosen()
    return true
  }

  func choose(iconAt index: Int) -> Bool {
    guard SpaceTheme.icons.indices.contains(index) else { return false }
    choose(icon: SpaceTheme.icons[index])
    return true
  }

  func choose(window index: Int?, accent: Int?) {
    if let index { choose(\.color, index == 0 ? nil : SpaceTheme.windows[min(index - 1, SpaceTheme.windows.count - 1)]) }
    if let accent { choose(\.accent, accent == 0 ? nil : SpaceTheme.accents[min(accent - 1, SpaceTheme.accents.count - 1)]) }
  }

  func setName(_ text: String) {
    nameField.field.stringValue = text
    controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: nameField.field))
  }

  private func selectProfileItem() {
    if draft.profile == Self.newProfile {
      profileButton.selectItem(at: profiles.count)
    } else {
      profileButton.selectItem(at: profiles.firstIndex { $0.directory == draft.profile } ?? 0)
    }
  }

  private func changed() {
    refreshChoices()
    onChange?(draft)
  }

  private func refreshChoices() {
    for (cell, icon) in zip(iconCells, SpaceTheme.icons) { cell.chosen = draft.icon == icon }
    let windows = [nil] + SpaceTheme.windows.map(Optional.some)
    for (index, cell) in windowCells.enumerated() {
      cell.chosen = index < windows.count ? windows[index] == draft.color
        : draft.color.map { !SpaceTheme.windows.contains($0) } ?? false
    }
    let accents = [nil] + SpaceTheme.accents.map(Optional.some)
    for (index, cell) in accentCells.enumerated() {
      cell.chosen = index < accents.count ? accents[index] == draft.accent
        : draft.accent.map { !SpaceTheme.accents.contains($0) } ?? false
    }
    windowCells.last?.customHex = draft.color.flatMap { SpaceTheme.windows.contains($0) ? nil : $0 }
    accentCells.last?.customHex = draft.accent.flatMap { SpaceTheme.accents.contains($0) ? nil : $0 }
    confirmButton.isEnabled = Space.name(from: draft.name) != nil
  }

  func controlTextDidChange(_ obj: Notification) {
    draft.name = nameField.field.stringValue
    changed()
  }

  func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
    switch selector {
    case #selector(NSResponder.insertNewline(_:)):
      if inSettings { window?.makeFirstResponder(nil) } else { confirm() }
      return true
    case #selector(NSResponder.cancelOperation(_:)):
      if !inSettings { onFinish?(false) }
      return true
    default:
      return false
    }
  }

  override func cancelOperation(_ sender: Any?) { if !inSettings { onFinish?(false) } }

  private func confirm() {
    guard Space.name(from: draft.name) != nil else { return }
    onFinish?(true)
  }

  // MARK: Layout

  override func layout() {
    super.layout()
    let inset: CGFloat = 12
    let width = bounds.width - inset * 2
    var y: CGFloat = inSettings ? 14 : 6
    func line(_ view: NSView, height: CGFloat, gap: CGFloat = 8) {
      view.frame = NSRect(x: inset, y: y, width: width, height: height)
      y += height + gap
    }
    if !inSettings { line(title, height: title.intrinsicContentSize.height, gap: 10) }
    line(nameField, height: 30, gap: 14)
    func label(_ index: Int) { line(labels[index], height: labels[index].intrinsicContentSize.height, gap: 6) }
    func grid(_ cells: [SpaceChoiceCell], columns: Int, size: CGFloat) {
      let step = min(width / CGFloat(columns), size + 12)
      for (index, cell) in cells.enumerated() {
        let column = index % columns, row = index / columns
        cell.frame = NSRect(x: inset + CGFloat(column) * step + (step - size) / 2, y: y + CGFloat(row) * (size + 4),
                            width: size, height: size).integral
      }
      let rows = (cells.count + columns - 1) / columns
      y += CGFloat(rows) * (size + 4) + 10
    }
    label(0)
    grid(iconCells, columns: 8, size: 26)
    label(1)
    grid(windowCells, columns: 10, size: 22)
    label(2)
    grid(accentCells, columns: 10, size: 22)
    label(3)
    profileButton.frame = NSRect(x: inset, y: y, width: min(width, 260), height: 24)
    y += 24 + 18
    let buttonWidth = (width - 8) / 2
    cancelButton.frame = NSRect(x: inset, y: y, width: buttonWidth, height: 28)
    confirmButton.frame = NSRect(x: inset + buttonWidth + 8, y: y, width: buttonWidth, height: 28)
    let deleteWidth = deleteButton.fittingSize.width
    deleteButton.frame = NSRect(x: inset, y: y, width: max(deleteWidth, 120), height: 28)
  }

  /// Laid out at the panel's width (or Settings' column), sized to what it holds.
  func fit(width: CGFloat = SpaceEditorView.width) {
    frame.size = NSSize(width: width, height: 1000)
    layoutSubtreeIfNeeded()
    frame.size.height = confirmButton.frame.maxY + (inSettings ? 14 : 12)
  }

  /// The height `fit` would give at a width.
  func height(forWidth width: CGFloat) -> CGFloat {
    let old = frame.size
    fit(width: width)
    let height = frame.height
    frame.size = old
    return height
  }

  var debug: [String: Any] {
    ["new": isNew, "name": draft.name, "icon": draft.icon ?? NSNull(), "color": draft.color ?? NSNull(),
     "accent": draft.accent ?? NSNull(), "profile": draft.profile ?? NSNull(),
     "profiles": profiles.map(\.title) + ["New Profile"], "canConfirm": confirmButton.isEnabled]
  }
}

/// One choice in the editor: an icon, a colour swatch (none: Ray's own, a slashed circle) or "any colour".
private final class SpaceChoiceCell: NSView {
  enum Kind {
    case icon(String)
    case colour(String?)
    case custom
  }

  let kind: Kind
  var onClick: (() -> Void)?
  var chosen = false { didSet { if oldValue != chosen { needsDisplay = true } } }
  var customHex: String? { didSet { needsDisplay = true } }
  private var hovered = false
  private var tracking: NSTrackingArea?

  init(kind: Kind) {
    self.kind = kind
    super.init(frame: .zero)
    setAccessibilityRole(.button)
    switch kind {
    case .icon(let icon): setAccessibilityLabel(icon.hasPrefix("sf:") ? String(icon.dropFirst(3)) : icon)
    case .colour(let hex): setAccessibilityLabel(hex ?? "None")
    case .custom: setAccessibilityLabel("Any Colour")
    }
  }

  required init?(coder: NSCoder) { fatalError() }

  override var mouseDownCanMoveWindow: Bool { false }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override func mouseDown(with event: NSEvent) {}
  override func mouseUp(with event: NSEvent) {
    if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
  }
  override func accessibilityPerformPress() -> Bool {
    onClick?()
    return true
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let tracking { removeTrackingArea(tracking) }
    let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
    addTrackingArea(area)
    tracking = area
  }

  override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
  override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }

  override func draw(_ dirtyRect: NSRect) {
    let rect = bounds
    switch kind {
    case .icon(let icon):
      if chosen || hovered {
        (chosen ? SelectedRow.fill(over: SpaceLook.background) : SidebarColors.hover).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
      }
      if icon.hasPrefix("sf:"), let symbol = NSImage(systemSymbolName: String(icon.dropFirst(3)), accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold)) {
        let tinted = NSImage(size: symbol.size, flipped: false) { box in
          symbol.draw(in: box)
          NSColor.labelColor.set()
          box.fill(using: .sourceAtop)
          return true
        }
        let size = tinted.size
        tinted.draw(in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height))
      } else {
        let text = NSAttributedString(string: icon, attributes: [.font: NSFont.systemFont(ofSize: 14)])
        let size = text.size()
        text.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
      }
    case .colour(let hex):
      drawSwatch(in: rect, hex: hex)
    case .custom:
      let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 3, dy: 3))
      if let hex = customHex {
        drawSwatch(in: rect, hex: hex)
        return
      }
      NSGradient(colors: [.systemRed, .systemYellow, .systemGreen, .systemTeal, .systemBlue, .systemPurple, .systemRed])?
        .draw(in: circle, angle: 90)
      if chosen { ring(rect) }
    }
  }

  private func drawSwatch(in rect: NSRect, hex: String?) {
    let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 3, dy: 3))
    if let hex, let rgb = ProfileColor.parse(hex) {
      NSColor(srgbRed: rgb.r, green: rgb.g, blue: rgb.b, alpha: 1).setFill()
      circle.fill()
    } else {
      SidebarColors.background.setFill()
      circle.fill()
      NSColor.tertiaryLabelColor.setStroke()
      circle.lineWidth = 1
      circle.stroke()
      let slash = NSBezierPath()
      slash.move(to: NSPoint(x: rect.minX + 6, y: rect.minY + 6))
      slash.line(to: NSPoint(x: rect.maxX - 6, y: rect.maxY - 6))
      slash.lineWidth = 1.2
      slash.stroke()
    }
    NSColor.black.withAlphaComponent(0.15).setStroke()
    circle.lineWidth = 0.5
    circle.stroke()
    if chosen { ring(rect) }
  }

  private func ring(_ rect: NSRect) {
    let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 0.75, dy: 0.75))
    ring.lineWidth = 1.5
    ProfileColor.visible(on: SpaceLook.background).setStroke()
    ring.stroke()
  }
}
