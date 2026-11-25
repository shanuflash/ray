import AppKit

/// New Space and Edit Space… (the owner's recording of Arc's flow, `docs/mocks/spaces-create.html`, 2026-11-25), in
/// Ray's own look: the Space's sidebar becomes the form under its top row. A picture, "Create a Space", the name with
/// an icon button (`SpaceIconPicker`), the Profile pop-up (New Profile… opens `NewProfileCard`), the Theme row (opens
/// `SpaceThemePanel` beside the sidebar), Create Space and Cancel. Every change shows on the window at once.
final class SpaceCreateView: NSView, NSTextFieldDelegate {
  private(set) var draft: SpaceDraft
  let isNew: Bool
  var onChange: ((SpaceDraft) -> Void)?
  var onFinish: ((Bool) -> Void)?
  var onIcon: ((NSView) -> Void)?
  var onTheme: ((NSView) -> Void)?
  var onNewProfile: (() -> Void)?
  var onDelete: (() -> Void)?

  private let art = SpaceArt()
  private let title = NSTextField(labelWithString: "")
  private let subtitle = NSTextField(wrappingLabelWithString: "Separate your tabs for life, work, projects and more.")
  private let nameField = EditorField(placeholder: "Space name")
  let iconButton = SpaceIconButton()
  private let profileLabel = NSTextField(labelWithString: "Profile")
  private let profileButton = NSPopUpButton(frame: .zero, pullsDown: false)
  let themeRow = SpaceThemeRow()
  let confirmButton: PanelButton
  let cancelButton = PanelButton(title: "Cancel")
  private let deleteLink = NSButton(title: "Delete Space…", target: nil, action: nil)
  private(set) var profiles: [SpaceProfileChoice]

  init(draft: SpaceDraft, isNew: Bool, profiles: [SpaceProfileChoice]) {
    self.draft = draft
    self.isNew = isNew
    self.profiles = profiles
    confirmButton = PanelButton(title: isNew ? "Create Space" : "Done", primary: true)
    super.init(frame: .zero)
    wantsLayer = true
    title.stringValue = isNew ? "Create a Space" : "Edit Space"
    title.font = .systemFont(ofSize: 15, weight: .semibold)
    title.alignment = .center
    subtitle.font = .systemFont(ofSize: 12)
    subtitle.textColor = .secondaryLabelColor
    subtitle.alignment = .center
    subtitle.isHidden = !isNew
    nameField.fill = SidebarColors.fill
    nameField.field.stringValue = draft.name
    nameField.field.delegate = self
    nameField.field.setAccessibilityLabel("Space name")
    iconButton.onClick = { [weak self] in
      guard let self else { return }
      self.onIcon?(self.iconButton)
    }
    profileLabel.font = .systemFont(ofSize: 12.5)
    profileLabel.textColor = .secondaryLabelColor
    profileButton.font = .systemFont(ofSize: 12.5)
    profileButton.target = self
    profileButton.action = #selector(profileChosen)
    themeRow.onClick = { [weak self] in
      guard let self else { return }
      self.onTheme?(self.themeRow)
    }
    cancelButton.onClick = { [weak self] in self?.onFinish?(false) }
    confirmButton.onClick = { [weak self] in self?.confirm() }
    deleteLink.isBordered = false
    deleteLink.contentTintColor = .systemRed
    deleteLink.font = .systemFont(ofSize: 12)
    deleteLink.target = self
    deleteLink.action = #selector(deletePressed)
    deleteLink.isHidden = isNew
    [art, title, subtitle, nameField, iconButton, profileLabel, profileButton, themeRow, confirmButton, cancelButton, deleteLink]
      .forEach(addSubview)
    reloadProfiles(profiles)
    refresh()
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }
  override var mouseDownCanMoveWindow: Bool { false }
  override var wantsUpdateLayer: Bool { true }
  override func updateLayer() { layer?.backgroundColor = SpaceLook.background.cgColor }

  var profileTitles: [String] { profiles.map(\.title) }
  var isTyping: Bool { nameField.field.currentEditor() != nil }

  func focusName() {
    window?.makeFirstResponder(nameField.field)
    nameField.field.currentEditor()?.selectAll(nil)
  }

  func reloadProfiles(_ choices: [SpaceProfileChoice]) {
    profiles = choices
    profileButton.removeAllItems()
    for choice in choices {
      profileButton.addItem(withTitle: choice.title)
    }
    profileButton.menu?.addItem(.separator())
    profileButton.addItem(withTitle: "New Profile…")
    profileButton.selectItem(at: choices.firstIndex { $0.directory == draft.profile } ?? 0)
  }

  /// A profile made in the card: chosen.
  func useProfile(_ directory: String, choices: [SpaceProfileChoice]) {
    draft.profile = directory
    reloadProfiles(choices)
    changed()
  }

  func update(_ edit: (inout SpaceDraft) -> Void) {
    edit(&draft)
    changed()
  }

  private func changed() {
    refresh()
    onChange?(draft)
  }

  private func refresh() {
    iconButton.icon = draft.icon
    themeRow.colors = (draft.color, draft.accent)
    art.tint = draft.color
    confirmButton.isEnabled = Space.name(from: draft.name) != nil
  }

  @objc private func profileChosen() {
    let index = profileButton.indexOfSelectedItem
    if profiles.indices.contains(index) {
      draft.profile = profiles[index].directory
      changed()
    } else {
      // New Profile…: the card names it; until then the pop-up shows what was chosen.
      profileButton.selectItem(at: profiles.firstIndex { $0.directory == draft.profile } ?? 0)
      onNewProfile?()
    }
  }

  @objc private func deletePressed() { onDelete?() }

  func controlTextDidChange(_ obj: Notification) {
    draft.name = nameField.field.stringValue
    changed()
  }

  func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
    switch selector {
    case #selector(NSResponder.insertNewline(_:)):
      confirm()
      return true
    case #selector(NSResponder.cancelOperation(_:)):
      onFinish?(false)
      return true
    default:
      return false
    }
  }

  override func cancelOperation(_ sender: Any?) { onFinish?(false) }

  private func confirm() {
    guard Space.name(from: draft.name) != nil else { return }
    onFinish?(true)
  }

  // MARK: Layout

  override func layout() {
    super.layout()
    let inset: CGFloat = 12
    let width = bounds.width - inset * 2
    var y: CGFloat = 14
    art.frame = NSRect(x: (bounds.width - 96) / 2, y: y, width: 96, height: 66)
    y += 66 + 12
    let titleHeight = title.intrinsicContentSize.height
    title.frame = NSRect(x: inset, y: y, width: width, height: titleHeight)
    y += titleHeight + 3
    if !subtitle.isHidden {
      let height = subtitle.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width - 20, height: 200)).height ?? 32
      subtitle.frame = NSRect(x: inset + 10, y: y, width: width - 20, height: height)
      y += height
    }
    y += 16
    // The name with its icon button inside the field's left end, as Arc's.
    nameField.frame = NSRect(x: inset, y: y, width: width, height: 34)
    iconButton.frame = NSRect(x: inset + 4, y: y + 4, width: 26, height: 26)
    nameField.contentInsetLeft = 32
    y += 34 + 6
    let rowHeight: CGFloat = 34
    let popUp = profileButton.intrinsicContentSize
    profileLabel.frame = NSRect(x: inset + 10, y: y + (rowHeight - profileLabel.intrinsicContentSize.height) / 2,
                                width: 60, height: profileLabel.intrinsicContentSize.height)
    profileButton.frame = NSRect(x: inset + width - min(popUp.width, width - 80), y: y + (rowHeight - popUp.height) / 2,
                                 width: min(popUp.width, width - 80), height: popUp.height)
    y += rowHeight + 6
    themeRow.frame = NSRect(x: inset, y: y, width: width, height: rowHeight)
    let bottom = bounds.height - 12
    deleteLink.sizeToFit()
    var buttonsTop = bottom - 28
    if !deleteLink.isHidden {
      deleteLink.frame = NSRect(x: (bounds.width - deleteLink.frame.width) / 2, y: bottom - deleteLink.frame.height,
                                width: deleteLink.frame.width, height: deleteLink.frame.height)
      buttonsTop -= deleteLink.frame.height + 8
    }
    let half = (width - 8) / 2
    cancelButton.frame = NSRect(x: inset, y: buttonsTop, width: half, height: 28)
    confirmButton.frame = NSRect(x: inset + half + 8, y: buttonsTop, width: half, height: 28)
  }

  // MARK: Tests and the controller

  func setName(_ text: String) {
    nameField.field.stringValue = text
    controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
  }

  func choose(iconAt index: Int) -> Bool {
    guard SpaceTheme.icons.indices.contains(index) else { return false }
    update { $0.icon = SpaceTheme.icons[index] }
    return true
  }

  func choose(window index: Int?, accent: Int?) {
    if let index { update { $0.color = index == 0 ? nil : SpaceTheme.windows[min(index - 1, SpaceTheme.windows.count - 1)] } }
    if let accent { update { $0.accent = accent == 0 ? nil : SpaceTheme.accents[min(accent - 1, SpaceTheme.accents.count - 1)] } }
  }

  func pickCustom(_ which: String, hex: String) -> Bool {
    guard let valid = Space.validHex(hex) else { return false }
    update { if which == "accent" { $0.accent = valid } else { $0.color = valid } }
    return true
  }

  /// The nth of the pop-up's choices; one past the profiles is New Profile (a new one made with the Space).
  func chooseProfile(_ index: Int) -> Bool {
    guard index >= 0, index <= profiles.count else { return false }
    update { $0.profile = index < profiles.count ? profiles[index].directory : SpaceEditorView.newProfile }
    return true
  }

  var debug: [String: Any] {
    ["new": isNew, "name": draft.name, "icon": draft.icon ?? NSNull(), "color": draft.color ?? NSNull(),
     "accent": draft.accent ?? NSNull(), "profile": draft.profile ?? NSNull(), "mode": draft.mode ?? NSNull(),
     "strength": draft.strength ?? NSNull(), "profiles": profiles.map(\.title) + ["New Profile"],
     "canConfirm": confirmButton.isEnabled, "form": "sidebar", "emoji": EmojiCatalog.count, "emojiFromMacOS": EmojiCatalog.fromMacOS]
  }
}

// MARK: Pieces of the form

/// Three small window cards fanned, the front one in the Space's colour.
final class SpaceArt: NSView {
  var tint: String? { didSet { needsDisplay = true } }
  override var isFlipped: Bool { true }

  override func draw(_ dirtyRect: NSRect) {
    let size = NSSize(width: 44, height: 54)
    let colors: [NSColor] = [.systemGreen, .systemBlue,
                             tint.flatMap(ProfileColor.parse).map { NSColor(srgbRed: $0.r, green: $0.g, blue: $0.b, alpha: 1) }
                               ?? ProfileColor.lavender]
    for (index, (angle, dx)) in [(-0.22, -18.0), (0.2, 18.0), (0.0, 0.0)].enumerated() {
      NSGraphicsContext.saveGraphicsState()
      let transform = NSAffineTransform()
      transform.translateX(by: bounds.midX + CGFloat(dx), yBy: bounds.midY + 4)
      transform.rotate(byRadians: CGFloat(angle))
      transform.concat()
      let card = NSRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height)
      let shadow = NSShadow()
      shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
      shadow.shadowBlurRadius = 4
      shadow.shadowOffset = NSSize(width: 0, height: -1)
      shadow.set()
      NSColor.textBackgroundColor.setFill()
      NSBezierPath(roundedRect: card, xRadius: 7, yRadius: 7).fill()
      NSShadow().set()
      colors[index].withAlphaComponent(0.6).setFill()
      NSBezierPath(roundedRect: NSRect(x: card.minX, y: card.minY, width: card.width * 0.34, height: card.height),
                   xRadius: 7, yRadius: 7).fill()
      NSGraphicsContext.restoreGraphicsState()
    }
  }
}

/// The icon button in the name field: the Space's emoji or symbol, a dashed square with a plus when it has none.
final class SpaceIconButton: NSView {
  var icon: String? { didSet { needsDisplay = true } }
  var onClick: (() -> Void)?
  private var hovered = false
  private var tracking: NSTrackingArea?

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
    if hovered {
      SidebarColors.hover.setFill()
      NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
    }
    if let icon {
      drawIcon(icon, in: bounds, size: 15)
    } else {
      let box = NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 5), xRadius: 4, yRadius: 4)
      box.lineWidth = 1
      box.setLineDash([2.5, 2], count: 2, phase: 0)
      NSColor.secondaryLabelColor.setStroke()
      box.stroke()
      let plus = NSAttributedString(string: "+", attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                                                              .foregroundColor: NSColor.secondaryLabelColor])
      let size = plus.size()
      plus.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2))
    }
  }
}

/// An emoji or an SF Symbol ("sf:") centred in a rect.
func drawIcon(_ icon: String, in rect: NSRect, size: CGFloat) {
  if icon.hasPrefix("sf:"), let symbol = NSImage(systemSymbolName: String(icon.dropFirst(3)), accessibilityDescription: nil)?
    .withSymbolConfiguration(.init(pointSize: size - 2, weight: .semibold)) {
    let tinted = NSImage(size: symbol.size, flipped: false) { box in
      symbol.draw(in: box)
      NSColor.labelColor.set()
      box.fill(using: .sourceAtop)
      return true
    }
    let s = tinted.size
    tinted.draw(in: NSRect(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2, width: s.width, height: s.height))
  } else {
    let text = NSAttributedString(string: icon, attributes: [.font: NSFont.systemFont(ofSize: size)])
    let s = text.size()
    text.draw(at: NSPoint(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2))
  }
}

/// "Theme" with the Window and Accent colours as two dots and a chevron; a click opens the theme panel.
final class SpaceThemeRow: NSView {
  var colors: (String?, String?) = (nil, nil) { didSet { needsDisplay = true } }
  var onClick: (() -> Void)?
  private var hovered = false
  private var tracking: NSTrackingArea?

  override var isFlipped: Bool { true }
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
    (hovered ? SidebarColors.hover : NSColor.clear).setFill()
    NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
    let label = NSAttributedString(string: "Theme", attributes: [.font: NSFont.systemFont(ofSize: 12.5),
                                                                 .foregroundColor: NSColor.secondaryLabelColor])
    label.draw(at: NSPoint(x: 10, y: (bounds.height - label.size().height) / 2))
    var x = bounds.width - 22 - 16 * 2
    for hex in [colors.0, colors.1] {
      let dot = NSRect(x: x, y: (bounds.height - 12) / 2, width: 12, height: 12)
      (hex.flatMap(ProfileColor.parse).map { NSColor(srgbRed: $0.r, green: $0.g, blue: $0.b, alpha: 1) } ?? SidebarColors.background)
        .setFill()
      let circle = NSBezierPath(ovalIn: dot)
      circle.fill()
      NSColor.labelColor.withAlphaComponent(0.25).setStroke()
      circle.lineWidth = 0.5
      circle.stroke()
      x += 16
    }
    let chevron = NSAttributedString(string: "›", attributes: [.font: NSFont.systemFont(ofSize: 14, weight: .medium),
                                                               .foregroundColor: NSColor.tertiaryLabelColor])
    chevron.draw(at: NSPoint(x: bounds.width - 16, y: (bounds.height - chevron.size().height) / 2))
  }
}

// MARK: Icon picker

/// Arc's Space icon picker in Ray's panel: Emoji or Icon, a trash button, search (emoji by their Unicode names),
/// the emoji grid with category tabs under it, or Ray's symbols.
final class SpaceIconPicker: NSView, NSTextFieldDelegate {
  static let size = NSSize(width: 300, height: 330)
  var onPick: ((String?) -> Void)?
  private let mode = RaySegmentedControl(titles: ["Emoji", "Icon"])
  private let trash = NSButton()
  private let search = EditorField(placeholder: "Search")
  private let scroll = NSScrollView()
  private let grid = SpaceIconGrid()
  private var tabs: [NSButton] = []
  private var category = 0
  private(set) var chosen: String?

  init(chosen: String?) {
    self.chosen = chosen
    super.init(frame: NSRect(origin: .zero, size: Self.size))
    mode.selectedIndex = chosen?.hasPrefix("sf:") == true ? 1 : 0
    mode.onChoose = { [weak self] _ in self?.reload() }
    trash.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "No Icon")
    trash.isBordered = false
    trash.contentTintColor = .secondaryLabelColor
    trash.target = self
    trash.action = #selector(clear)
    search.field.delegate = self
    scroll.documentView = grid
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.scrollerStyle = .overlay
    grid.onPick = { [weak self] icon in
      self?.chosen = icon
      self?.onPick?(icon)
    }
    for (index, tab) in EmojiCatalog.categories.enumerated() {
      let button = NSButton(title: tab.symbol, target: self, action: #selector(tabPressed(_:)))
      button.isBordered = false
      button.font = .systemFont(ofSize: 14)
      button.tag = index
      button.toolTip = tab.name
      tabs.append(button)
      addSubview(button)
    }
    [mode, trash, search, scroll].forEach(addSubview)
    reload()
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }

  @objc private func clear() {
    chosen = nil
    onPick?(nil)
  }

  @objc private func tabPressed(_ sender: NSButton) {
    category = sender.tag
    search.field.stringValue = ""
    reload()
  }

  func controlTextDidChange(_ obj: Notification) { reload() }

  private func reload() {
    let query = search.field.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
    if mode.selectedIndex == 1 {
      grid.items = SpaceIconPicker.symbols.filter { query.isEmpty || $0.contains(query) }.map { "sf:" + $0 }
    } else if !query.isEmpty {
      grid.items = EmojiCatalog.search(query)
    } else {
      grid.items = EmojiCatalog.categories[category].emoji
    }
    grid.chosen = chosen
    tabs.forEach { $0.isHidden = mode.selectedIndex == 1 }
    for tab in tabs { tab.contentTintColor = tab.tag == category ? .labelColor : .secondaryLabelColor }
    needsLayout = true
  }

  override func layout() {
    super.layout()
    let inset: CGFloat = 10
    let modeSize = NSSize(width: 150, height: 26)
    mode.frame = NSRect(x: (bounds.width - modeSize.width) / 2, y: inset, width: modeSize.width, height: modeSize.height)
    trash.frame = NSRect(x: bounds.width - inset - 26, y: inset, width: 26, height: 26)
    search.frame = NSRect(x: inset, y: mode.frame.maxY + 8, width: bounds.width - inset * 2, height: 28)
    let tabsHeight: CGFloat = mode.selectedIndex == 1 ? 0 : 30
    scroll.frame = NSRect(x: inset, y: search.frame.maxY + 8, width: bounds.width - inset * 2,
                          height: bounds.height - search.frame.maxY - 8 - tabsHeight - inset)
    grid.frame.size = NSSize(width: scroll.contentSize.width, height: grid.height(forWidth: scroll.contentSize.width))
    let tabWidth = (bounds.width - inset * 2) / CGFloat(max(tabs.count, 1))
    for (index, tab) in tabs.enumerated() {
      tab.frame = NSRect(x: inset + CGFloat(index) * tabWidth, y: bounds.height - inset - 24, width: tabWidth, height: 24)
    }
  }

  static let symbols: [String] = [
    "star.fill", "heart.fill", "bolt.fill", "flame.fill", "leaf.fill", "moon.fill", "sun.max.fill", "cloud.fill",
    "briefcase.fill", "house.fill", "book.fill", "graduationcap.fill", "gamecontroller.fill", "music.note",
    "paintpalette.fill", "camera.fill", "cart.fill", "airplane", "car.fill", "globe.americas.fill", "flag.fill",
    "bell.fill", "lightbulb.fill", "hammer.fill", "wrench.and.screwdriver.fill", "terminal.fill",
    "chevron.left.forwardslash.chevron.right", "person.2.fill", "bubble.left.fill", "envelope.fill", "calendar",
    "checkmark.square.fill", "tray.full.fill", "doc.fill", "folder.fill", "gift.fill", "fork.knife", "cup.and.saucer.fill",
    "dumbbell.fill", "pawprint.fill", "bicycle", "film.fill", "headphones", "sparkles", "square.grid.2x2.fill",
  ].filter { NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil }

  /// For tests: the nth item now shown.
  func pick(_ index: Int) -> Bool {
    guard grid.items.indices.contains(index) else { return false }
    grid.onPick?(grid.items[index])
    return true
  }

  func setSearch(_ text: String) {
    search.field.stringValue = text
    reload()
  }

  var shown: [String] { grid.items }
}

/// The picker's grid: drawn as one view (a thousand emoji as buttons is too many), 8 to a row.
final class SpaceIconGrid: NSView {
  var items: [String] = [] { didSet { needsDisplay = true; invalidate() } }
  var chosen: String? { didSet { needsDisplay = true } }
  var onPick: ((String) -> Void)?
  private static let cell: CGFloat = 34
  private var hovered: Int?
  private var tracking: NSTrackingArea?

  override var isFlipped: Bool { true }

  private func invalidate() {
    if let scroll = enclosingScrollView {
      frame.size.height = height(forWidth: scroll.contentSize.width)
    }
  }

  private var columns: Int { max(1, Int(bounds.width / Self.cell)) }

  func height(forWidth width: CGFloat) -> CGFloat {
    let columns = max(1, Int(width / Self.cell))
    return CGFloat((items.count + columns - 1) / columns) * Self.cell
  }

  private func rect(_ index: Int) -> NSRect {
    let step = bounds.width / CGFloat(columns)
    return NSRect(x: CGFloat(index % columns) * step + (step - Self.cell) / 2, y: CGFloat(index / columns) * Self.cell,
                  width: Self.cell, height: Self.cell)
  }

  private func index(at point: NSPoint) -> Int? {
    let step = bounds.width / CGFloat(columns)
    let index = Int(point.y / Self.cell) * columns + Int(point.x / step)
    return items.indices.contains(index) ? index : nil
  }

  override func draw(_ dirtyRect: NSRect) {
    for (index, item) in items.enumerated() {
      let box = rect(index)
      guard box.intersects(dirtyRect) else { continue }
      if item == chosen || index == hovered {
        (item == chosen ? SelectedRow.fill(over: SurfaceBackdrop.solidFill) : SidebarColors.hover).setFill()
        NSBezierPath(roundedRect: box.insetBy(dx: 2, dy: 2), xRadius: 7, yRadius: 7).fill()
      }
      drawIcon(item, in: box, size: 20)
    }
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let tracking { removeTrackingArea(tracking) }
    let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                              owner: self)
    addTrackingArea(area)
    tracking = area
  }

  override func mouseMoved(with event: NSEvent) {
    let now = index(at: convert(event.locationInWindow, from: nil))
    if now != hovered { hovered = now; needsDisplay = true }
  }
  override func mouseExited(with event: NSEvent) { hovered = nil; needsDisplay = true }
  override func mouseDown(with event: NSEvent) {}
  override func mouseUp(with event: NSEvent) {
    guard let index = index(at: convert(event.locationInWindow, from: nil)) else { return }
    chosen = items[index]
    onPick?(items[index])
  }
}

/// macOS's own emoji, the set its emoji picker shows (Arc's Space icons are these): every emoji macOS names in
/// CoreEmoji's `AppleName.strings` (1,900-odd, ZWJ sequences and flags included, no skin tones), with those names for
/// search, sorted into the picker's categories. Without that file (it's private and could move), every scalar
/// Unicode shows as an emoji by default, named by Unicode.
enum EmojiCatalog {
  struct Category {
    let name: String
    let symbol: String
    let emoji: [String]
  }

  private static let appleNames: [String: String] = {
    let path = "/System/Library/PrivateFrameworks/CoreEmoji.framework/Resources/en.lproj/AppleName.strings"
    guard let data = FileManager.default.contents(atPath: path),
          let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String]
    else { return [:] }
    return plist.filter { Space.validIcon($0.key) != nil }
  }()

  /// Every emoji with its name.
  private static let all: [(emoji: String, name: String)] = {
    if !appleNames.isEmpty { return appleNames.map { ($0.key, $0.value.lowercased()) } }
    return (0x2190...0x2BFF).compactMap(scalarEmoji) + (0x1F000...0x1FAFF).compactMap(scalarEmoji)
  }()

  private static func scalarEmoji(_ value: Int) -> (String, String)? {
    guard let scalar = Unicode.Scalar(UInt32(value)), scalar.properties.isEmojiPresentation else { return nil }
    return (String(scalar), scalar.properties.name?.lowercased() ?? "")
  }

  private static let names = ["Smileys and People", "Animals and Nature", "Food and Drink", "Activity",
                              "Travel and Places", "Objects", "Symbols", "Flags"]
  private static let symbols = ["😀", "🐻", "🍔", "⚽️", "🚗", "💡", "❤️", "🏳️"]

  /// The picker's category for an emoji, by its first scalar (and flags by their shape).
  private static func category(_ emoji: String) -> Int {
    let scalars = emoji.unicodeScalars.map(\.value)
    guard let v = scalars.first else { return 6 }
    func any(_ ranges: [ClosedRange<UInt32>]) -> Bool { ranges.contains { $0.contains(v) } }
    if any([0x1F1E6...0x1F1FF]) || ((v == 0x1F3F3 || v == 0x1F3F4) && scalars.count > 1) || v == 0x1F3C1 || v == 0x1F6A9
      || v == 0x1F38C { return 7 }
    if any([0x1F600...0x1F64F, 0x1F910...0x1F92F, 0x1F930...0x1F939, 0x1F970...0x1F97F, 0x1F9B0...0x1F9B9,
            0x1F9CD...0x1F9DF, 0x1FAC0...0x1FAC5, 0x1FAE0...0x1FAFF, 0x1F440...0x1F487, 0x1F48B...0x1F48F,
            0x1F4A9...0x1F4A9, 0x1F466...0x1F478, 0x1F47B...0x1F480, 0x1F574...0x1F57A, 0x1F590...0x1F596,
            0x1F6B4...0x1F6B6, 0x1F6C0...0x1F6C0, 0x1F3C3...0x1F3CC, 0x1F9E0...0x1F9E0, 0x1F4AA...0x1F4AA,
            0x261D...0x261D, 0x263A...0x263A, 0x2639...0x2639, 0x270A...0x270D, 0x1F4A2...0x1F4A6, 0x1F4A8...0x1F4A8,
            0x1F4AB...0x1F4AC, 0x1F4AD...0x1F4AD, 0x1F48C...0x1F48C, 0x1F383...0x1F383, 0x1F385...0x1F385,
            0x1F9E3...0x1F9E6, 0x1F451...0x1F462, 0x1F393...0x1F393, 0x1F97B...0x1F97F, 0x1FA70...0x1FA7C]) { return 0 }
    if any([0x1F400...0x1F43F, 0x1F980...0x1F9AE, 0x1F330...0x1F344, 0x1F300...0x1F320, 0x1F32A...0x1F32C,
            0x1FAB0...0x1FABF, 0x1FAE8...0x1FAE8, 0x2600...0x2604, 0x26C4...0x26C8, 0x2744...0x2744, 0x2614...0x2614,
            0x2618...0x2618, 0x1F54A...0x1F54A, 0x1F577...0x1F578, 0x1F490...0x1F490, 0x1F4AE...0x1F4AE,
            0x1F940...0x1F940, 0x1F32D...0x1F32F, 0x2728...0x2728, 0x26A1...0x26A1, 0x1F525...0x1F525,
            0x1F4A7...0x1F4A7, 0x1F30A...0x1F30A]) { return 1 }
    if any([0x1F345...0x1F37F, 0x1F950...0x1F96F, 0x1F9C0...0x1F9CB, 0x1FAD0...0x1FADF, 0x2615...0x2615,
            0x1F32D...0x1F32F, 0x1F9C2...0x1F9C2, 0x1F942...0x1F942]) { return 2 }
    if any([0x1F380...0x1F3CF, 0x1F93A...0x1F94F, 0x1FA80...0x1FA8F, 0x26BD...0x26BE, 0x26F3...0x26F3,
            0x26F8...0x26F8, 0x1F3D3...0x1F3D3, 0x1F3F8...0x1F3F9, 0x265F...0x265F, 0x1F9E9...0x1F9E9,
            0x1F9F5...0x1F9F6, 0x1F6F7...0x1F6F7, 0x1F6F9...0x1F6F9, 0x1F396...0x1F39F]) { return 3 }
    if any([0x1F3D0...0x1F3FF, 0x1F680...0x1F6FF, 0x2708...0x2708, 0x26F0...0x26FA, 0x1F5FA...0x1F5FF,
            0x1F30B...0x1F31F, 0x1F301...0x1F309, 0x1F3A0...0x1F3A2, 0x1F3AA...0x1F3AA, 0x1F6E0...0x1F6FF,
            0x2693...0x2693, 0x231A...0x231B, 0x23F0...0x23F3, 0x1F550...0x1F567, 0x1F9F3...0x1F9F3, 0x1F6FB...0x1F6FC,
            0x1FA82...0x1FA82, 0x1F3CD...0x1F3CE]) {
      return any([0x231A...0x231B, 0x23F0...0x23F3]) ? 5 : 4
    }
    if any([0x1F4B0...0x1F4FF, 0x1F500...0x1F53D, 0x1F56F...0x1F5F9, 0x1FA90...0x1FAAF, 0x1F9E0...0x1F9FF,
            0x2328...0x2328, 0x260E...0x260E, 0x2702...0x2702, 0x2709...0x2709, 0x270F...0x2712, 0x1F48D...0x1F48E,
            0x1F4A1...0x1F4A1, 0x1F4A3...0x1F4A3, 0x1F488...0x1F48A, 0x1F3A5...0x1F3A9, 0x1F3B7...0x1F3BB,
            0x1F399...0x1F39E, 0x1F6CD...0x1F6CF, 0x1F6D2...0x1F6D2, 0x1F6AA...0x1F6AA, 0x1F6BD...0x1F6BF,
            0x1F6C1...0x1F6C1, 0x2692...0x2697, 0x2699...0x2699, 0x26B0...0x26B1, 0x1FA9C...0x1FA9C,
            0x1F9EF...0x1F9FF, 0x1FA78...0x1FA7C, 0x1F97C...0x1F97F]) { return 5 }
    return 6
  }

  static let categories: [Category] = {
    var lists = Array(repeating: [String](), count: names.count)
    for item in all.sorted(by: { $0.emoji.unicodeScalars.map(\.value).lexicographicallyPrecedes($1.emoji.unicodeScalars.map(\.value)) }) {
      lists[category(item.emoji)].append(item.emoji)
    }
    return names.indices.compactMap { i in
      lists[i].isEmpty ? nil : Category(name: names[i], symbol: symbols[i], emoji: lists[i])
    }
  }()

  /// Every emoji whose name has each typed word ("brief" finds 💼).
  static func search(_ query: String) -> [String] {
    let words = query.lowercased().split(separator: " ").map(String.init)
    return all.filter { item in words.allSatisfy { item.name.contains($0) } }
      .sorted { $0.name.count < $1.name.count }.map(\.emoji)
  }

  static var count: Int { all.count }
  static var fromMacOS: Bool { !appleNames.isEmpty }
}

// MARK: Theme panel

/// The Space's theme, in a panel beside the sidebar: Light, Auto or Dark; the Window colour and how strong it is (Ray's
/// light wash up to Arc's full colour); the Accent.
final class SpaceThemePanel: NSView {
  static let size = NSSize(width: 300, height: 238)
  var onChange: ((_ mode: String?, _ color: String?, _ strength: Double?, _ accent: String?) -> Void)?
  private let mode = RaySegmentedControl(titles: ["Light", "Auto", "Dark"])
  private let windowLabel = NSTextField(labelWithString: "Window")
  private let windowRow = SwatchRow(entries: [(nil, "Ray's")] + SpaceTheme.windows.map { ($0 as String?, $0) },
                                    none: SidebarColors.background)
  private let strengthLabel = NSTextField(labelWithString: "Strength")
  let strength = NSSlider(value: 0.3, minValue: 0.1, maxValue: 0.85, target: nil, action: nil)
  private let accentLabel = NSTextField(labelWithString: "Accent")
  private let accentRow = SwatchRow(entries: [(nil, "Profile colour")] + SpaceTheme.accents.map { ($0 as String?, $0) })
  private var values: (mode: String?, color: String?, strength: Double?, accent: String?)
  private var pickingAccent = false

  init(mode: String?, color: String?, strength: Double?, accent: String?) {
    values = (mode, color, strength, accent)
    super.init(frame: NSRect(origin: .zero, size: Self.size))
    self.mode.selectedIndex = mode == "light" ? 0 : mode == "dark" ? 2 : 1
    self.mode.onChoose = { [weak self] index in
      self?.values.mode = index == 0 ? "light" : index == 2 ? "dark" : nil
      self?.changed()
    }
    for label in [windowLabel, strengthLabel, accentLabel] {
      label.font = .systemFont(ofSize: 11, weight: .semibold)
      label.textColor = .secondaryLabelColor
    }
    windowRow.compact = true
    windowRow.selection = color
    windowRow.onChoose = { [weak self] hex in
      self?.values.color = hex
      self?.changed()
    }
    windowRow.onCustomHex = { [weak self] hex in
      self?.values.color = hex
      self?.changed()
    }
    self.strength.doubleValue = strength ?? SpaceLook.defaultStrength
    self.strength.isContinuous = true
    self.strength.target = self
    self.strength.action = #selector(strengthMoved)
    accentRow.compact = true
    accentRow.selection = accent
    accentRow.onChoose = { [weak self] hex in
      self?.values.accent = hex
      self?.changed()
    }
    accentRow.onCustomHex = { [weak self] hex in
      self?.values.accent = hex
      self?.changed()
    }
    [self.mode, windowLabel, windowRow, strengthLabel, self.strength, accentLabel, accentRow].forEach(addSubview)
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }

  @objc private func strengthMoved() {
    values.strength = (strength.doubleValue * 100).rounded() / 100
    changed()
  }

  private func pickColor(accent: Bool) {
    pickingAccent = accent
    let panel = NSColorPanel.shared
    panel.showsAlpha = false
    panel.setTarget(self)
    panel.setAction(#selector(colorPicked(_:)))
    if !TestEnvironment.isTestBuild { panel.orderFront(nil) }
  }

  @objc private func colorPicked(_ panel: NSColorPanel) {
    let hex = ProfileColor.hex(of: panel.color)
    if pickingAccent { values.accent = hex; accentRow.selection = hex } else { values.color = hex; windowRow.selection = hex }
    changed()
  }

  private func changed() {
    windowRow.selection = values.color
    accentRow.selection = values.accent
    onChange?(values.mode, values.color, values.strength, values.accent)
  }

  func choose(mode index: Int) {
    mode.selectedIndex = index
    values.mode = index == 0 ? "light" : index == 2 ? "dark" : nil
    changed()
  }

  /// The + of the Window or Accent row, as a click.
  func openPad(accent: Bool) {
    let row = accent ? accentRow : windowRow
    if let onCustomHex = row.onCustomHex {
      ColorPadPopup.show(from: row.customButton, hex: accent ? values.accent : values.color, onChange: onCustomHex)
    }
  }

  func setStrength(_ value: Double) {
    strength.doubleValue = value
    strengthMoved()
  }

  override func layout() {
    super.layout()
    let inset: CGFloat = 12
    let width = bounds.width - inset * 2
    mode.frame = NSRect(x: inset, y: inset, width: width, height: 26)
    var y = mode.frame.maxY + 14
    func label(_ field: NSTextField) {
      let height = field.intrinsicContentSize.height
      field.frame = NSRect(x: inset + 2, y: y, width: width, height: height)
      y += height + 6
    }
    label(windowLabel)
    let rowSize = windowRow.fittingSize
    windowRow.frame = NSRect(x: inset, y: y, width: rowSize.width, height: rowSize.height)
    y += rowSize.height + 12
    label(strengthLabel)
    strength.frame = NSRect(x: inset, y: y, width: width, height: 20)
    y += 20 + 12
    label(accentLabel)
    accentRow.frame = NSRect(x: inset, y: y, width: rowSize.width, height: rowSize.height)
  }
}

// MARK: New profile

/// New Profile…: a card over the window that names the profile (Arc's).
final class NewProfileCard: NSView, NSTextFieldDelegate {
  static let size = NSSize(width: 320, height: 186)
  var onFinish: ((String?) -> Void)?
  private let icon = NSImageView()
  private let title = NSTextField(labelWithString: "New Profile")
  private let message = NSTextField(wrappingLabelWithString: "A profile keeps its own history, passwords, cookies and extensions.")
  let field = EditorField(placeholder: "Profile name")
  private let note = NSTextField(labelWithString: "Profiles stay on this Mac.")
  let cancel = PanelButton(title: "Cancel")
  let create = PanelButton(title: "Create Profile", primary: true)

  override init(frame: NSRect) {
    super.init(frame: NSRect(origin: .zero, size: Self.size))
    icon.image = NSImage(systemSymbolName: "person.crop.circle.badge.plus", accessibilityDescription: nil)
    icon.symbolConfiguration = .init(pointSize: 18, weight: .regular)
    icon.contentTintColor = .secondaryLabelColor
    title.font = .systemFont(ofSize: 13.5, weight: .semibold)
    message.font = .systemFont(ofSize: 12)
    message.textColor = .secondaryLabelColor
    note.font = .systemFont(ofSize: 11)
    note.textColor = .tertiaryLabelColor
    field.field.delegate = self
    cancel.onClick = { [weak self] in self?.onFinish?(nil) }
    create.onClick = { [weak self] in self?.confirm() }
    create.isEnabled = false
    [icon, title, message, field, note, cancel, create].forEach(addSubview)
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }

  func focus() { window?.makeFirstResponder(field.field) }

  func controlTextDidChange(_ obj: Notification) { create.isEnabled = ProfileInfo.name(from: field.field.stringValue) != nil }

  func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
    if selector == #selector(NSResponder.insertNewline(_:)) { confirm(); return true }
    if selector == #selector(NSResponder.cancelOperation(_:)) { onFinish?(nil); return true }
    return false
  }

  private func confirm() {
    guard let name = ProfileInfo.name(from: field.field.stringValue) else { return }
    onFinish?(name)
  }

  func type(_ text: String) {
    field.field.stringValue = text
    controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
  }

  override func layout() {
    super.layout()
    let inset: CGFloat = 16
    let width = bounds.width - inset * 2
    icon.frame = NSRect(x: inset, y: inset, width: 24, height: 24)
    title.frame = NSRect(x: inset + 32, y: inset + 3, width: width - 32, height: title.intrinsicContentSize.height)
    let height = message.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: 100)).height ?? 30
    message.frame = NSRect(x: inset, y: inset + 32, width: width, height: height)
    field.frame = NSRect(x: inset, y: message.frame.maxY + 10, width: width, height: 30)
    note.frame = NSRect(x: inset + 2, y: field.frame.maxY + 4, width: width, height: note.intrinsicContentSize.height)
    let half = (width - 8) / 2
    cancel.frame = NSRect(x: inset, y: bounds.height - inset - 28, width: half, height: 28)
    create.frame = NSRect(x: inset + half + 8, y: bounds.height - inset - 28, width: half, height: 28)
  }
}

// MARK: Made

/// Create Space's finish: the Space's icon on a card pops in the middle of the sidebar and goes (Arc's), on the
/// sidebar's spring; none with Reduce Motion.
enum SpacePop {
  static func play(_ icon: String?, in view: NSView) {
    guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, let host = view.layer else { return }
    let card = CALayer()
    let size = CGSize(width: 54, height: 62)
    card.bounds = CGRect(origin: .zero, size: size)
    card.position = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
    card.cornerRadius = 12
    card.backgroundColor = NSColor.white.cgColor
    card.shadowOpacity = 0.3
    card.shadowRadius = 12
    card.shadowOffset = CGSize(width: 0, height: -4)
    let image = NSImage(size: size, flipped: false) { rect in
      drawIcon(icon ?? "●", in: rect, size: 28)
      return true
    }
    card.contents = image
    card.contentsGravity = .center
    card.contentsScale = view.window?.backingScaleFactor ?? 2
    host.addSublayer(card)
    let grow = Spring.caAnimation(keyPath: "transform.scale", from: 0.2, to: 1, response: 0.32, dampingRatio: 0.6)
    card.add(grow, forKey: "grow")
    let fade = CABasicAnimation(keyPath: "opacity")
    fade.fromValue = 1
    fade.toValue = 0
    fade.beginTime = CACurrentMediaTime() + 0.7
    fade.duration = 0.25
    fade.fillMode = .forwards
    fade.isRemovedOnCompletion = false
    card.add(fade, forKey: "fade")
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { card.removeFromSuperlayer() }
  }
}
