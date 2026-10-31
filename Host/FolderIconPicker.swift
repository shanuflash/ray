import AppKit

/// Right-click a folder › Change Icon…: Arc's icon panel. A rounded panel in the window (never an NSPopover), its arrow
/// on the folder's icon: "Icon" with a trash button that takes the icon off, and a grid of filled symbols. A pick
/// applies at once and closes it; a click elsewhere, Escape or a tab switch closes it too. It springs out of the arrow
/// and fades back into it.
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
  static let arrow: CGFloat = 9
  static var size: NSSize {
    let rows = CGFloat((symbols.count + columns - 1) / columns)
    return NSSize(width: CGFloat(columns) * cell + inset * 2, height: arrow + header + rows * cell + inset)
  }

  /// A symbol picked ("sf:<name>"), or nil from the trash button.
  var onPick: ((String?) -> Void)?
  var onClose: (() -> Void)?
  private(set) var chosen: String?
  /// Where the arrow's tip points, in this view's coordinates (top edge, flipped).
  private var arrowX: CGFloat = 0
  private let panel = CAShapeLayer()
  private let title = NSTextField(labelWithString: "Icon")
  private let trash = NSButton()
  private var cells: [NSButton] = []
  private let selection = CALayer()
  private var monitor: Any?
  private var closing = false

  init(chosen: String?) {
    self.chosen = chosen
    super.init(frame: NSRect(origin: .zero, size: Self.size))
    wantsLayer = true
    layer?.addSublayer(panel)
    panel.shadowOpacity = 0.28
    panel.shadowRadius = 18
    panel.shadowOffset = CGSize(width: 0, height: -6)
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

  /// Places the panel under `anchor` (a rect in `superview`'s coordinates) with its arrow on the anchor's middle,
  /// kept inside `bounds` with 8 pt to spare.
  func place(under anchor: NSRect, within bounds: NSRect) {
    let size = Self.size
    let x = min(max(anchor.midX - 40, bounds.minX + 8), bounds.maxX - size.width - 8)
    let y = (superview?.isFlipped ?? false) ? anchor.maxY + 2 : anchor.minY - 2 - size.height
    frame = NSRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
    arrowX = min(max(anchor.midX - frame.minX, 22), size.width - 22)
    needsLayout = true
    needsDisplay = true
  }

  override func layout() {
    super.layout()
    let top = Self.arrow
    title.frame = NSRect(x: 0, y: top + (Self.header - 20) / 2 + 2, width: bounds.width, height: 20)
    let titleWidth = ceil(title.intrinsicContentSize.width)
    trash.frame = NSRect(x: bounds.midX + titleWidth / 2 + 10, y: top + (Self.header - 26) / 2 + 2, width: 26, height: 26)
    for (index, cell) in cells.enumerated() {
      cell.frame = NSRect(x: Self.inset + CGFloat(index % Self.columns) * Self.cell,
                          y: top + Self.header + CGFloat(index / Self.columns) * Self.cell, width: Self.cell, height: Self.cell)
    }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    panel.frame = bounds
    panel.path = Self.shape(in: bounds, arrowX: arrowX)
    panel.shadowPath = panel.path
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
      panel.fillColor = (dark ? NSColor(white: 0.2, alpha: 1) : NSColor(white: 0.985, alpha: 1)).cgColor
      panel.strokeColor = (dark ? NSColor(white: 1, alpha: 0.12) : NSColor(white: 0, alpha: 0.1)).cgColor
      panel.lineWidth = 0.5
      selection.backgroundColor = (dark ? NSColor(white: 1, alpha: 0.16) : NSColor(white: 0, alpha: 0.08)).cgColor
      CATransaction.commit()
    }
  }

  /// A rounded panel with an arrow on its top edge.
  private static func shape(in rect: NSRect, arrowX: CGFloat) -> CGPath {
    let body = NSRect(x: rect.minX + 0.5, y: rect.minY + arrow, width: rect.width - 1, height: rect.height - arrow - 0.5)
    let radius: CGFloat = 18
    let path = CGMutablePath()
    path.move(to: CGPoint(x: body.minX + radius, y: body.minY))
    path.addLine(to: CGPoint(x: arrowX - arrow - 2, y: body.minY))
    path.addQuadCurve(to: CGPoint(x: arrowX, y: rect.minY + 0.5), control: CGPoint(x: arrowX - 3, y: body.minY))
    path.addQuadCurve(to: CGPoint(x: arrowX + arrow + 2, y: body.minY), control: CGPoint(x: arrowX + 3, y: body.minY))
    path.addArc(tangent1End: CGPoint(x: body.maxX, y: body.minY), tangent2End: CGPoint(x: body.maxX, y: body.maxY), radius: radius)
    path.addArc(tangent1End: CGPoint(x: body.maxX, y: body.maxY), tangent2End: CGPoint(x: body.minX, y: body.maxY), radius: radius)
    path.addArc(tangent1End: CGPoint(x: body.minX, y: body.maxY), tangent2End: CGPoint(x: body.minX, y: body.minY), radius: radius)
    path.addArc(tangent1End: CGPoint(x: body.minX, y: body.minY), tangent2End: CGPoint(x: body.maxX, y: body.minY), radius: radius)
    path.closeSubpath()
    return path
  }

  // MARK: Showing and closing

  /// Springs out of the arrow's tip; clicks elsewhere in the app close it.
  func appear() {
    window?.makeFirstResponder(self)
    monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
      guard let self, event.window === self.window else { return event }
      if !self.bounds.contains(self.convert(event.locationInWindow, from: nil)) { self.close() }
      return event
    }
    guard let layer, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
    let grow = CASpringAnimation(keyPath: "transform")
    grow.fromValue = NSValue(caTransform3D: aboutTip(layer, scale: 0.86))
    grow.toValue = NSValue(caTransform3D: CATransform3DIdentity)
    grow.stiffness = 420
    grow.damping = 30
    grow.duration = grow.settlingDuration
    let fade = CABasicAnimation(keyPath: "opacity")
    fade.fromValue = 0
    fade.toValue = 1
    fade.duration = 0.14
    layer.add(grow, forKey: "appear.scale")
    layer.add(fade, forKey: "appear.opacity")
    Self.animations += 1
  }

  /// Closes it (fading back into the arrow), once.
  func close() {
    guard !closing else { return }
    closing = true
    if let monitor { NSEvent.removeMonitor(monitor) }
    monitor = nil
    let done = { [weak self] in
      self?.removeFromSuperview()
      self?.onClose?()
    }
    guard let layer, window != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return done() }
    CATransaction.begin()
    CATransaction.setCompletionBlock(done)
    let shrink = CABasicAnimation(keyPath: "transform")
    shrink.fromValue = NSValue(caTransform3D: CATransform3DIdentity)
    shrink.toValue = NSValue(caTransform3D: aboutTip(layer, scale: 0.92))
    let fade = CABasicAnimation(keyPath: "opacity")
    fade.fromValue = 1
    fade.toValue = 0
    for animation in [shrink, fade] {
      animation.duration = 0.13
      animation.timingFunction = CAMediaTimingFunction(name: .easeIn)
      animation.fillMode = .forwards
      animation.isRemovedOnCompletion = false
      layer.add(animation, forKey: "close." + (animation.keyPath ?? ""))
    }
    CATransaction.commit()
    Self.animations += 1
  }

  /// A scale about the arrow's tip, whatever anchor AppKit gave the view's layer.
  private func aboutTip(_ layer: CALayer, scale: CGFloat) -> CATransform3D {
    let size = layer.bounds.size
    let anchor = CGPoint(x: layer.anchorPoint.x * size.width, y: layer.anchorPoint.y * size.height)
    let tip = CGPoint(x: arrowX, y: layer.isGeometryFlipped ? 0 : size.height)
    let d = CGPoint(x: tip.x - anchor.x, y: tip.y - anchor.y)
    var t = CATransform3DMakeTranslation(d.x, d.y, 0)
    t = CATransform3DScale(t, scale, scale, 1)
    return CATransform3DTranslate(t, -d.x, -d.y, 0)
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
    ["chosen": chosen ?? NSNull(), "symbols": Self.symbols.count, "frame": NSStringFromRect(frame), "arrowX": arrowX,
     "closing": closing]
  }
}
