import AppKit

/// Right-click a folder › Change Icon…: Arc's icon panel's content, shown by `Panels` under the folder's icon (the
/// panels' look and motion): "Icon" with a trash button that takes the icon off, and a grid of filled symbols. A pick
/// applies at once and closes it; a click elsewhere, Escape or a tab switch closes it too.
final class FolderIconPicker: NSView {
  /// Arc's set, in Arc's order (filled symbols); any this macOS lacks drop out.
  static let symbols: [String] = [
    "star.fill", "bookmark.fill", "heart.fill", "bolt.fill", "triangle.fill", "asterisk", "bell.fill", "lightbulb.fill",
    "bubble.left.fill", "person.2.fill", "wrench.and.screwdriver.fill", "oval.fill", "circle.fill", "moon.fill",
    "globe.americas.fill", "leaf.fill", "cloud.fill", "pawprint.fill", "fork.knife", "airplane", "music.note",
    "video.fill", "chevron.left.forwardslash.chevron.right", "gamecontroller.fill",
  ].filter { NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil }

  static let columns = 8
  static let cell: CGFloat = 36
  static let inset: CGFloat = 12
  static let header: CGFloat = 40
  static var size: NSSize {
    let rows = CGFloat((symbols.count + columns - 1) / columns)
    return NSSize(width: CGFloat(columns) * cell + inset * 2, height: header + rows * cell + inset)
  }

  /// A symbol picked ("sf:<name>"), or nil from the trash button.
  var onPick: ((String?) -> Void)?
  /// Asks its panel to close.
  var requestClose: (() -> Void)?
  private(set) var chosen: String?
  private let title = NSTextField(labelWithString: "Icon")
  private let trash = NSButton()
  private var cells: [NSButton] = []
  private let selection = CALayer()
  private(set) var closing = false

  init(chosen: String?) {
    self.chosen = chosen
    super.init(frame: NSRect(origin: .zero, size: Self.size))
    wantsLayer = true
    selection.cornerRadius = 9
    selection.cornerCurve = .continuous
    layer?.addSublayer(selection)
    title.font = .systemFont(ofSize: 15, weight: .semibold)
    title.alignment = .center
    addSubview(title)
    trash.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "Remove Icon")
    trash.symbolConfiguration = .init(pointSize: 14, weight: .regular)
    trash.isBordered = false
    trash.imagePosition = .imageOnly
    trash.contentTintColor = .secondaryLabelColor
    trash.target = self
    trash.action = #selector(clear)
    trash.refusesFirstResponder = true
    trash.toolTip = "Remove Icon"
    addSubview(trash)
    for name in Self.symbols {
      let button = NSButton()
      button.image = NSImage(systemSymbolName: name, accessibilityDescription: name)
      button.symbolConfiguration = .init(pointSize: 15, weight: .medium)
      button.isBordered = false
      button.imagePosition = .imageOnly
      button.contentTintColor = .labelColor
      button.target = self
      button.action = #selector(choose(_:))
      button.refusesFirstResponder = true
      button.identifier = NSUserInterfaceItemIdentifier("sf:" + name)
      cells.append(button)
      addSubview(button)
    }
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }
  override var wantsUpdateLayer: Bool { true }
  override var mouseDownCanMoveWindow: Bool { false }
  override var acceptsFirstResponder: Bool { true }

  override func layout() {
    super.layout()
    let top: CGFloat = 0
    title.frame = NSRect(x: 0, y: top + (Self.header - 20) / 2 + 2, width: bounds.width, height: 20)
    let titleWidth = ceil(title.intrinsicContentSize.width)
    trash.frame = NSRect(x: bounds.midX + titleWidth / 2 + 10, y: top + (Self.header - 26) / 2 + 2, width: 26, height: 26)
    for (index, cell) in cells.enumerated() {
      cell.frame = NSRect(x: Self.inset + CGFloat(index % Self.columns) * Self.cell,
                          y: top + Self.header + CGFloat(index / Self.columns) * Self.cell, width: Self.cell, height: Self.cell)
    }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    if let at = cells.first(where: { $0.identifier?.rawValue == chosen }) {
      selection.frame = at.frame.insetBy(dx: 2, dy: 2)
      selection.isHidden = false
    } else {
      selection.isHidden = true
    }
    CATransaction.commit()
  }

  override func updateLayer() {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      selection.backgroundColor = (dark ? NSColor(white: 1, alpha: 0.16) : NSColor(white: 0, alpha: 0.08)).cgColor
      CATransaction.commit()
    }
  }

  // MARK: Closing

  /// Closes its panel, once.
  func close() {
    guard !closing else { return }
    closing = true
    requestClose?()
  }

  override func cancelOperation(_ sender: Any?) { close() }
  override func keyDown(with event: NSEvent) {
    if event.keyCode == 53 { close() } else { super.keyDown(with: event) }
  }

  @objc private func choose(_ sender: NSButton) { pick(sender.identifier?.rawValue) }
  @objc private func clear() { pick(nil) }

  /// What a click on a symbol (or the trash button, nil) does. For tests too.
  func pick(_ icon: String?) {
    guard !closing else { return }
    chosen = icon
    needsLayout = true
    onPick?(icon)
    close()
  }

  // MARK: Tests

  /// Panels shown and closed with animation, for checks (record app-side; the springs are too quick to poll).
  static var animations = 0

  var debug: [String: Any] {
    ["chosen": chosen ?? NSNull(), "symbols": Self.symbols.count, "frame": NSStringFromRect(frame), "closing": closing]
  }
}
