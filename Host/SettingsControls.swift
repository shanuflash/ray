import AppKit

// The Settings window's colours and controls, all in the profile's colour (`ProfileColor`), never the system accent.
// `RaySwitch` and `SwatchRow` are also the welcome's (Onboarding.swift).

enum SettingsColors {
  private static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
    NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light }
  }

  /// The window's sidebar: Ray's own sidebar colour, darker than the content.
  static let sidebar = SidebarColors.background
  /// The content column behind the rows.
  static let content = dynamic(light: NSColor(white: 1, alpha: 1), dark: NSColor(white: 0.135, alpha: 1))
  /// Kept for the welcome, which sits on the sidebar colour.
  static let background = SidebarColors.background
  static let separator = PanelColors.border
  static let switchOff = dynamic(light: NSColor(white: 0, alpha: 0.2), dark: NSColor(white: 1, alpha: 0.25))
  /// A segmented control's track and the search field's fill.
  static let track = SidebarColors.fill
  static let hover = SidebarColors.hover

  /// The selected sidebar row: a soft wash of the profile's colour over the sidebar.
  static let selectedFill = ProfileColor.mix(NSColor(name: nil) { _ in ProfileColor.accent }, over: sidebar, 0.17, dark: 0.26)
  /// Its icon and name: a tint of the profile's colour (darker in light mode, lighter in dark), moved just far enough
  /// to read on the wash (4.5:1).
  static let selectedInk = ProfileColor.legible(
    NSColor(name: nil) { appearance in
      let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
      var out = ProfileColor.accent
      NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
        let rgb = ProfileColor.accent.usingColorSpace(.sRGB) ?? .gray
        let toward: CGFloat = dark ? 1 : 0, amount: CGFloat = dark ? 0.4 : 0.18
        out = NSColor(srgbRed: rgb.redComponent + (toward - rgb.redComponent) * amount,
                      green: rgb.greenComponent + (toward - rgb.greenComponent) * amount,
                      blue: rgb.blueComponent + (toward - rgb.blueComponent) * amount, alpha: 1)
      }
      return out
    },
    on: selectedFill, minimum: 4.5)
  /// A search hit's flash over its row.
  static var flash: NSColor { ProfileColor.mix(NSColor(name: nil) { _ in ProfileColor.accent }, over: content, 0.16, dark: 0.26) }
  /// Accent marks on the content: rings, checks, links.
  static let mark = ProfileColor.visible(on: content)
  /// The call-to-action strip.
  static let strip = ProfileColor.mix(NSColor(name: nil) { _ in ProfileColor.accent }, over: content, 0.1, dark: 0.18)
}

func textHeight(_ label: NSTextField, width: CGFloat) -> CGFloat {
  guard !label.stringValue.isEmpty, let cell = label.cell else { return 0 }
  return ceil(cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: max(10, width), height: 10_000)).height)
}

extension NSView {
  /// Every view in the tree redraws (accent colours that views read in `updateLayer` or `draw`).
  func setNeedsDisplayRecursively() {
    needsDisplay = true
    subviews.forEach { $0.setNeedsDisplayRecursively() }
  }
}

/// A one-line label whose frame is exactly its line (a label draws from its top).
func settingsLabel(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
  let label = NSTextField(labelWithString: text)
  label.font = .systemFont(ofSize: size, weight: weight)
  label.textColor = color
  label.lineBreakMode = .byTruncatingTail
  label.isSelectable = false
  return label
}

// MARK: Switch

/// A switch in the profile's colour (NSSwitch follows the system accent instead).
final class RaySwitch: NSControl {
  var onChange: ((Bool) -> Void)?
  var isOn = false {
    didSet {
      guard oldValue != isOn else { return }
      placeKnob(animated: window != nil)
      needsDisplay = true
      NSAccessibility.post(element: self, notification: .valueChanged)
    }
  }
  private let knob = CALayer()

  override init(frame: NSRect) {
    super.init(frame: NSRect(x: 0, y: 0, width: 38, height: 22))
    wantsLayer = true
    layer?.cornerRadius = 11
    knob.backgroundColor = NSColor.white.cgColor
    knob.cornerRadius = 9
    knob.shadowColor = NSColor.black.cgColor
    knob.shadowOpacity = 0.25
    knob.shadowRadius = 1.5
    knob.shadowOffset = CGSize(width: 0, height: -0.5)
    layer?.addSublayer(knob)
    setAccessibilityRole(.checkBox)
    focusRingType = .exterior
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }
  override var intrinsicContentSize: NSSize { NSSize(width: 38, height: 22) }
  override var fittingSize: NSSize { intrinsicContentSize }
  override var wantsUpdateLayer: Bool { true }
  override var acceptsFirstResponder: Bool { true }
  override var mouseDownCanMoveWindow: Bool { false }

  override func updateLayer() {
    layer?.backgroundColor = (isOn ? ProfileColor.accent : SettingsColors.switchOff).cgColor
    placeKnob(animated: false)
  }

  override func layout() {
    super.layout()
    placeKnob(animated: false)
  }

  private func placeKnob(animated: Bool) {
    CATransaction.begin()
    CATransaction.setDisableActions(!animated)
    CATransaction.setAnimationDuration(0.16)
    knob.frame = CGRect(x: isOn ? bounds.width - 20 : 2, y: 2, width: 18, height: 18)
    CATransaction.commit()
  }

  override func drawFocusRingMask() {
    NSBezierPath(roundedRect: bounds, xRadius: 11, yRadius: 11).fill()
  }

  override var focusRingMaskBounds: NSRect { bounds }

  override func mouseDown(with event: NSEvent) { press() }

  override func keyDown(with event: NSEvent) {
    if event.characters == " " { press() } else { super.keyDown(with: event) }
  }

  /// A click or the space bar.
  func press() {
    isOn.toggle()
    onChange?(isOn)
  }

  override func accessibilityValue() -> Any? { NSNumber(value: isOn ? 1 : 0) }
  override func accessibilityPerformPress() -> Bool {
    press()
    return true
  }
}

// MARK: Segmented

/// Two or three options side by side: a track in the sidebar's fill, the chosen one filled with the profile's colour
/// and its title in the white or black that reads on it.
final class RaySegmentedControl: NSControl {
  var onChoose: ((Int) -> Void)?
  let titles: [String]
  var selectedIndex = -1 {
    didSet {
      guard oldValue != selectedIndex else { return }
      needsDisplay = true
      needsLayout = true
      NSAccessibility.post(element: self, notification: .valueChanged)
    }
  }
  private let thumb = CALayer()
  private var labels: [NSTextField] = []
  private static let height: CGFloat = 26

  init(titles: [String]) {
    self.titles = titles
    super.init(frame: .zero)
    wantsLayer = true
    layer?.cornerRadius = 7
    layer?.cornerCurve = .continuous
    thumb.cornerRadius = 5
    thumb.cornerCurve = .continuous
    layer?.addSublayer(thumb)
    for title in titles {
      let label = settingsLabel(title, size: 12, weight: .medium)
      label.alignment = .center
      labels.append(label)
      addSubview(label)
    }
    setAccessibilityRole(.radioGroup)
    focusRingType = .exterior
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }
  override var wantsUpdateLayer: Bool { true }
  override var acceptsFirstResponder: Bool { true }
  override var mouseDownCanMoveWindow: Bool { false }

  private var segmentWidth: CGFloat {
    ceil(labels.map { $0.intrinsicContentSize.width }.max() ?? 40) + 24
  }

  override var intrinsicContentSize: NSSize {
    NSSize(width: segmentWidth * CGFloat(titles.count) + 4, height: Self.height)
  }
  override var fittingSize: NSSize { intrinsicContentSize }

  override func updateLayer() {
    layer?.backgroundColor = SettingsColors.track.cgColor
    thumb.backgroundColor = ProfileColor.accent.cgColor
    thumb.isHidden = selectedIndex < 0
    for (index, label) in labels.enumerated() {
      label.textColor = index == selectedIndex ? ProfileColor.foreground(on: ProfileColor.accent) : .labelColor
    }
  }

  override func layout() {
    super.layout()
    let width = (bounds.width - 4) / CGFloat(max(1, titles.count))
    for (index, label) in labels.enumerated() {
      let height = ceil(label.intrinsicContentSize.height)
      label.frame = NSRect(x: 2 + CGFloat(index) * width, y: ((bounds.height - height) / 2).rounded(), width: width, height: height)
    }
    CATransaction.begin()
    CATransaction.setDisableActions(window == nil)
    CATransaction.setAnimationDuration(0.16)
    thumb.frame = CGRect(x: 2 + CGFloat(max(0, selectedIndex)) * width, y: 2, width: width, height: bounds.height - 4)
    CATransaction.commit()
    needsDisplay = true
  }

  override func mouseDown(with event: NSEvent) {
    let x = convert(event.locationInWindow, from: nil).x
    press(Int((x - 2) / ((bounds.width - 4) / CGFloat(max(1, titles.count)))))
  }

  override func keyDown(with event: NSEvent) {
    switch event.keyCode {
    case 123: press(max(0, selectedIndex - 1))
    case 124: press(min(titles.count - 1, selectedIndex + 1))
    default: super.keyDown(with: event)
    }
  }

  /// A click on segment `index`, or a test's press.
  @discardableResult
  func press(_ index: Int) -> Bool {
    guard titles.indices.contains(index) else { return false }
    selectedIndex = index
    onChoose?(index)
    return true
  }

  override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill() }
  override var focusRingMaskBounds: NSRect { bounds }
  override func accessibilityValue() -> Any? { titles.indices.contains(selectedIndex) ? titles[selectedIndex] : "" }
}

// MARK: Picture choices

/// Options shown as pictures (each drawn by the setting's own builder, a `MiniRayWindow` say) with captions under
/// them. The chosen one has a 2.5 pt ring in the profile's colour and a check before its caption.
final class PictureChoiceControl: NSView, SettingsSizing {
  var onChoose: ((String) -> Void)?
  private(set) var cards: [PictureCard] = []
  /// The chosen value.
  var selection: String? {
    didSet { cards.forEach { $0.isSelected = $0.value == selection } }
  }

  static let pictureSize = NSSize(width: 112, height: 72)

  init(choices: [SettingChoice], picture: (String) -> NSView) {
    super.init(frame: .zero)
    for choice in choices {
      let card = PictureCard(choice: choice, picture: picture(choice.value))
      card.onClick = { [weak self] in self?.choose(choice.value) }
      cards.append(card)
      addSubview(card)
    }
    setAccessibilityRole(.radioGroup)
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }

  var selectedIndex: Int { cards.firstIndex { $0.isSelected } ?? -1 }

  private func choose(_ value: String) {
    selection = value
    onChoose?(value)
  }

  /// A test's press of picture `index`.
  func press(index: Int) -> Bool {
    guard cards.indices.contains(index) else { return false }
    choose(cards[index].value)
    return true
  }

  func height(forWidth width: CGFloat) -> CGFloat { PictureCard.height }
  override var fittingSize: NSSize { NSSize(width: CGFloat(cards.count) * (Self.pictureSize.width + 18), height: PictureCard.height) }

  override func layout() {
    super.layout()
    for (index, card) in cards.enumerated() {
      card.frame = NSRect(x: CGFloat(index) * (Self.pictureSize.width + 18), y: 0, width: Self.pictureSize.width + 8,
                          height: PictureCard.height)
      card.needsLayout = true
    }
  }
}

final class PictureCard: NSView {
  let value: String
  var onClick: (() -> Void)?
  var isSelected = false {
    didSet {
      guard oldValue != isSelected else { return }
      caption.font = .systemFont(ofSize: 12, weight: isSelected ? .medium : .regular)
      needsDisplay = true
      needsLayout = true
      NSAccessibility.post(element: self, notification: .valueChanged)
    }
  }
  private let picture: NSView
  private let ring = CAShapeLayer()
  private let caption: NSTextField
  private let check = NSImageView()

  /// Ring room (4), the picture, a gap and the caption's line.
  static let height: CGFloat = 4 + PictureChoiceControl.pictureSize.height + 4 + 8 + 16

  init(choice: SettingChoice, picture: NSView) {
    value = choice.value
    self.picture = picture
    caption = settingsLabel(choice.title, size: 12)
    super.init(frame: .zero)
    wantsLayer = true
    ring.fillColor = nil
    ring.lineWidth = 2.5
    layer?.addSublayer(ring)
    addSubview(picture)
    check.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)
    check.symbolConfiguration = .init(pointSize: 10, weight: .bold)
    addSubview(check)
    addSubview(caption)
    setAccessibilityElement(true)
    setAccessibilityRole(.radioButton)
    setAccessibilityLabel(choice.title)
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }
  override var wantsUpdateLayer: Bool { true }
  override var mouseDownCanMoveWindow: Bool { false }
  override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }

  override func updateLayer() {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    ring.strokeColor = (isSelected ? SettingsColors.mark : NSColor.clear).cgColor
    CATransaction.commit()
    check.isHidden = !isSelected
    check.contentTintColor = SettingsColors.mark
    caption.textColor = isSelected ? .labelColor : .secondaryLabelColor
  }

  override func layout() {
    super.layout()
    let size = PictureChoiceControl.pictureSize
    let box = NSRect(x: 4, y: 4, width: size.width, height: size.height)
    picture.frame = box
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    ring.frame = bounds
    // 2.5 pt, 1.5 pt clear of the picture's edge.
    ring.path = CGPath(roundedRect: box.insetBy(dx: -2.75, dy: -2.75), cornerWidth: 9, cornerHeight: 9, transform: nil)
    CATransaction.commit()
    // Measured as drawn, then given the room to its right so nothing truncates.
    let font = caption.font ?? .systemFont(ofSize: 12)
    let captionWidth = ceil(NSAttributedString(string: caption.stringValue, attributes: [.font: font]).size().width)
    let checkWidth: CGFloat = isSelected ? 14 : 0
    let start = max(0, (box.midX - (captionWidth + checkWidth) / 2).rounded())
    let y = box.maxY + 8
    check.frame = NSRect(x: start, y: y, width: 12, height: 16)
    caption.frame = NSRect(x: start + checkWidth, y: y, width: max(captionWidth + 4, bounds.width - start - checkWidth), height: 16)
  }

  override func mouseDown(with event: NSEvent) { onClick?() }
  override func accessibilityPerformPress() -> Bool {
    onClick?()
    return true
  }
  override func accessibilityValue() -> Any? { NSNumber(value: isSelected ? 1 : 0) }
}

// MARK: Call to action

/// A pane's one call to action, at its top: a strip tinted with the profile's colour, an icon, one sentence and one
/// button ("Make Ray your default browser" · Make Default). Not a dialog.
final class SettingsCallToAction: NSView, SettingsSizing {
  private let icon = NSImageView()
  private let label: NSTextField
  private let button: AccentButton

  init(symbol: String, text: String, button title: String, action: @escaping () -> Void) {
    label = NSTextField(wrappingLabelWithString: text)
    button = AccentButton(title: title)
    super.init(frame: .zero)
    wantsLayer = true
    layer?.cornerRadius = 10
    layer?.cornerCurve = .continuous
    icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    icon.symbolConfiguration = .init(pointSize: 17, weight: .medium)
    label.font = .systemFont(ofSize: 13)
    label.isSelectable = false
    button.onClick = action
    addSubview(icon)
    addSubview(label)
    addSubview(self.button)
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }
  override var wantsUpdateLayer: Bool { true }

  override func updateLayer() {
    layer?.backgroundColor = SettingsColors.strip.cgColor
    icon.contentTintColor = ProfileColor.legible(ProfileColor.accent, on: SettingsColors.strip, minimum: 3)
  }

  private func textWidth(_ width: CGFloat) -> CGFloat { width - 14 - 24 - 12 - button.intrinsicContentSize.width - 14 - 14 }

  func height(forWidth width: CGFloat) -> CGFloat { max(52, textHeight(label, width: textWidth(width)) + 28) }

  override func layout() {
    super.layout()
    icon.frame = NSRect(x: 14, y: ((bounds.height - 24) / 2).rounded(), width: 24, height: 24)
    let size = button.intrinsicContentSize
    button.frame = NSRect(x: bounds.width - 14 - size.width, y: ((bounds.height - size.height) / 2).rounded(),
                          width: size.width, height: size.height)
    let height = textHeight(label, width: textWidth(bounds.width))
    label.frame = NSRect(x: 50, y: ((bounds.height - height) / 2).rounded(), width: textWidth(bounds.width), height: height)
  }

  /// For tests: what a click on its button does.
  func press() { button.onClick?() }
}

/// A small button filled with the profile's colour, its title in the white or black that reads on it.
final class AccentButton: NSControl {
  var onClick: (() -> Void)?
  private let label: NSTextField

  init(title: String) {
    label = settingsLabel(title, size: 13, weight: .medium)
    super.init(frame: .zero)
    wantsLayer = true
    layer?.cornerRadius = 7
    layer?.cornerCurve = .continuous
    addSubview(label)
    setAccessibilityElement(true)
    setAccessibilityRole(.button)
    setAccessibilityLabel(title)
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }
  override var wantsUpdateLayer: Bool { true }
  override var mouseDownCanMoveWindow: Bool { false }
  override var intrinsicContentSize: NSSize { NSSize(width: ceil(label.intrinsicContentSize.width) + 24, height: 28) }

  override func updateLayer() {
    layer?.backgroundColor = ProfileColor.accent.cgColor
    label.textColor = ProfileColor.foreground(on: ProfileColor.accent)
  }

  override func layout() {
    super.layout()
    let height = ceil(label.intrinsicContentSize.height)
    label.frame = NSRect(x: 12, y: ((bounds.height - height) / 2).rounded(), width: bounds.width - 24, height: height)
  }

  override func mouseDown(with event: NSEvent) { onClick?() }
  override func accessibilityPerformPress() -> Bool {
    onClick?()
    return true
  }
}

// MARK: Colour swatches

/// The row of colour choices: the default, the presets, and a custom colour that opens the colour panel. Also the
/// onboarding's colour step.
final class SwatchRow: NSView {
  var onChoose: ((String?) -> Void)?
  var onCustom: (() -> Void)?
  private var buttons: [SwatchButton] = []
  private let custom = SwatchButton(hex: nil, isCustom: true, name: "Custom Colour…")

  var count: Int { buttons.count + 1 }

  /// The chosen colour as `#RRGGBB`, nil for the default.
  var selection: String? {
    didSet { updateSelection() }
  }

  func press(index: Int) -> Bool {
    guard index >= 0, index < buttons.count else { return false }
    buttons[index].onClick?()
    return true
  }

  var selectedIndex: Int {
    if let index = buttons.firstIndex(where: { $0.isSelected }) { return index }
    return custom.isSelected ? buttons.count : -1
  }

  override var isFlipped: Bool { true }
  override var fittingSize: NSSize { NSSize(width: 340, height: 28) }

  override init(frame: NSRect) {
    super.init(frame: frame)
    let entries: [(String?, String)] = [(nil, "Lavender")] + ProfileColor.presets.map { ($0.hex as String?, $0.name) }
    for (hex, name) in entries {
      let button = SwatchButton(hex: hex, isCustom: false, name: name)
      button.onClick = { [weak self] in self?.onChoose?(hex) }
      buttons.append(button)
      addSubview(button)
    }
    custom.onClick = { [weak self] in self?.onCustom?() }
    addSubview(custom)
    updateSelection()
  }

  required init?(coder: NSCoder) { fatalError() }

  private func updateSelection() {
    var matched = false
    for button in buttons {
      button.isSelected = button.hex == selection
      matched = matched || button.isSelected
    }
    // A colour that isn't one of the swatches is the custom one.
    custom.hex = matched ? nil : selection
    custom.isSelected = !matched && selection != nil
  }

  override func layout() {
    super.layout()
    let size: CGFloat = 28, gap: CGFloat = 10
    for (index, button) in (buttons + [custom]).enumerated() {
      button.frame = NSRect(x: CGFloat(index) * (size + gap), y: 0, width: size, height: size)
    }
  }
}

/// One round colour choice; selected, it has a ring and a check mark in the colour that reads best on it.
private final class SwatchButton: NSControl {
  /// `#RRGGBB`; nil is the lavender, or for the custom button, no colour of its own yet.
  var hex: String? {
    didSet { if oldValue != hex { needsDisplay = true } }
  }
  let isCustom: Bool
  var onClick: (() -> Void)?
  var isSelected = false {
    didSet { if oldValue != isSelected { needsDisplay = true } }
  }
  private let fill = CALayer()
  private let rainbow = CAGradientLayer()
  private let ring = CAShapeLayer()
  private let check = NSImageView()

  init(hex: String?, isCustom: Bool, name: String) {
    self.hex = hex
    self.isCustom = isCustom
    super.init(frame: .zero)
    wantsLayer = true
    toolTip = name
    setAccessibilityRole(.radioButton)
    setAccessibilityLabel(name)
    fill.cornerCurve = .continuous
    layer?.addSublayer(fill)
    if isCustom {
      rainbow.type = .conic
      rainbow.startPoint = CGPoint(x: 0.5, y: 0.5)
      rainbow.endPoint = CGPoint(x: 0.5, y: 0)
      rainbow.colors = [0xFF5E5B, 0xFFD25E, 0x6BD968, 0x5ED2FF, 0x7B6BFF, 0xE56BFF, 0xFF5E5B].map {
        NSColor(srgbRed: CGFloat(($0 >> 16) & 0xFF) / 255, green: CGFloat(($0 >> 8) & 0xFF) / 255, blue: CGFloat($0 & 0xFF) / 255, alpha: 1).cgColor
      }
      layer?.addSublayer(rainbow)
    }
    ring.fillColor = nil
    ring.lineWidth = 2
    layer?.addSublayer(ring)
    check.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)
    check.symbolConfiguration = .init(pointSize: 11, weight: .bold)
    check.imageScaling = .scaleNone
    addSubview(check)
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }
  override var wantsUpdateLayer: Bool { true }
  override var mouseDownCanMoveWindow: Bool { false }
  override var acceptsFirstResponder: Bool { true }
  override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(convert(point, from: superview)) ? self : nil }

  /// What shows inside the ring: the colour itself (the lavender follows the appearance).
  private var color: NSColor? {
    if let hex, let rgb = ProfileColor.parse(hex) {
      return NSColor(srgbRed: rgb.r, green: rgb.g, blue: rgb.b, alpha: 1)
    }
    return isCustom ? nil : ProfileColor.lavender
  }

  override func updateLayer() {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    let inset: CGFloat = 4
    let inner = bounds.insetBy(dx: inset, dy: inset)
    fill.frame = inner
    fill.cornerRadius = inner.width / 2
    fill.backgroundColor = color?.cgColor
    rainbow.frame = inner
    rainbow.cornerRadius = inner.width / 2
    rainbow.isHidden = color != nil
    ring.frame = bounds
    ring.path = CGPath(ellipseIn: bounds.insetBy(dx: 1, dy: 1), transform: nil)
    ring.strokeColor = (isSelected ? NSColor.labelColor.withAlphaComponent(0.55) : NSColor.clear).cgColor
    CATransaction.commit()
    check.isHidden = !isSelected
    if let color { check.contentTintColor = ProfileColor.foreground(on: color) }
    check.frame = bounds
  }

  override func mouseDown(with event: NSEvent) { onClick?() }
  override func keyDown(with event: NSEvent) {
    if event.characters == " " { onClick?() } else { super.keyDown(with: event) }
  }
  override func accessibilityPerformPress() -> Bool {
    onClick?()
    return true
  }
  override func accessibilityValue() -> Any? { NSNumber(value: isSelected ? 1 : 0) }
}

// MARK: Link

/// A text link in the profile's colour (readable on whatever it sits on).
final class LinkButton: NSButton {
  var onClick: (() -> Void)?
  /// What the link sits on, for its contrast.
  var background: NSColor = SettingsColors.content

  init(title: String) {
    super.init(frame: .zero)
    self.title = title
    isBordered = false
    bezelStyle = .regularSquare
    font = .systemFont(ofSize: 13, weight: .medium)
    target = self
    action = #selector(clicked)
    setButtonType(.momentaryChange)
    focusRingType = .exterior
    setAccessibilityRole(.link)
  }

  required init?(coder: NSCoder) { fatalError() }

  override var wantsUpdateLayer: Bool { false }

  override func draw(_ dirtyRect: NSRect) {
    let color = ProfileColor.legible(NSColor(name: nil) { _ in ProfileColor.accent }, on: background, minimum: 3)
    let attributes: [NSAttributedString.Key: Any] = [.font: font ?? .systemFont(ofSize: 13), .foregroundColor: color]
    NSAttributedString(string: title, attributes: attributes).draw(at: NSPoint(x: 0, y: 1))
  }

  override var intrinsicContentSize: NSSize {
    let size = NSAttributedString(string: title, attributes: [.font: font ?? .systemFont(ofSize: 13)]).size()
    return NSSize(width: ceil(size.width), height: ceil(size.height) + 2)
  }

  override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

  @objc private func clicked() { onClick?() }
}
