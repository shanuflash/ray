import AppKit

/// A short note at the top right of the page, as Arc shows "Copied Current URL": 14 pt medium text in a 46 pt
/// rounded panel, an optional button in a rounded square on the right. It drops in from above on a spring and lifts
/// away as it fades, after a couple of seconds. A figure (Arc's zoom level, "110%") is a smaller panel of bold
/// digits.
final class ToastView: NSView {
  private let label = NSTextField(labelWithString: "")
  private let button = NSButton()
  private var action: (() -> Void)?
  private var hideWork: DispatchWorkItem?
  private(set) var message = ""
  private var figure = false
  private static let font = NSFont.systemFont(ofSize: 14, weight: .medium)
  private static let figureFont = NSFont.monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
  private var font: NSFont { figure ? Self.figureFont : Self.font }
  private static let buttonSize: CGFloat = 31
  private static let rise: CGFloat = 14

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.cornerRadius = 12
    layer?.cornerCurve = .continuous
    layer?.borderWidth = 1
    layer?.shadowOpacity = 0.25
    layer?.shadowRadius = 12
    layer?.shadowOffset = CGSize(width: 0, height: -4)
    label.font = Self.font
    label.textColor = .labelColor
    label.lineBreakMode = .byTruncatingTail
    button.isBordered = false
    button.bezelStyle = .regularSquare
    button.imagePosition = .imageOnly
    button.symbolConfiguration = .init(pointSize: 13, weight: .medium)
    button.contentTintColor = .labelColor
    button.refusesFirstResponder = true
    button.target = self
    button.action = #selector(buttonClicked)
    button.wantsLayer = true
    button.layer?.cornerRadius = 8
    button.layer?.cornerCurve = .continuous
    addSubview(label)
    addSubview(button)
    isHidden = true
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }
  override var wantsUpdateLayer: Bool { true }
  override var mouseDownCanMoveWindow: Bool { false }

  override func updateLayer() {
    let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    layer?.backgroundColor = (dark ? NSColor(white: 0.2, alpha: 0.97) : NSColor(white: 0.98, alpha: 0.97)).cgColor
    layer?.borderColor = (dark ? NSColor(white: 1, alpha: 0.12) : NSColor(white: 0, alpha: 0.1)).cgColor
    button.layer?.backgroundColor = (dark ? NSColor(white: 1, alpha: 0.14) : NSColor(white: 0, alpha: 0.07)).cgColor
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    needsDisplay = true
  }

  /// The size it wants for its message, at most `limit` wide: the text measured in its font, plus the label's own
  /// few points of padding, so it never truncates while there's room.
  func fit(_ limit: CGFloat) -> NSSize {
    let text = ceil((message as NSString).size(withAttributes: [.font: font]).width) + 6
    if figure { return NSSize(width: min(limit, 12 + text + 12), height: 38) }
    let buttonWidth = button.isHidden ? 0 : Self.buttonSize + 10
    return NSSize(width: min(limit, 14 + text + buttonWidth + 8), height: 46)
  }

  func show(_ message: String, symbol: String? = nil, figure: Bool = false, action: (() -> Void)? = nil) {
    let wasShowing = !isHidden && !self.message.isEmpty
    self.message = message
    self.figure = figure
    label.font = font
    label.alignment = figure ? .center : .natural
    layer?.cornerRadius = figure ? 10 : 12
    label.stringValue = message
    button.isHidden = symbol == nil
    button.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
    self.action = action
    needsLayout = true
    isHidden = false
    if !wasShowing { animateIn() }
    hideWork?.cancel()
    let work = DispatchWorkItem { [weak self] in self?.hide() }
    hideWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + (figure ? 1.4 : 2.4), execute: work)
  }

  func hide() {
    hideWork?.cancel()
    hideWork = nil
    guard !message.isEmpty else { return }
    message = ""
    animateOut()
  }

  // Drops in from just above on a spring and fades in; leaves by lifting and fading. The model stays at rest, so
  // the layout can move it freely; only the presentation travels.
  private func animateIn() {
    guard let layer else { return }
    layer.removeAllAnimations()
    let drop = CASpringAnimation(keyPath: "transform.translation.y")
    drop.fromValue = Self.rise
    drop.toValue = 0
    drop.mass = 1
    drop.stiffness = 420
    drop.damping = 26
    drop.duration = drop.settlingDuration
    let scale = CASpringAnimation(keyPath: "transform.scale")
    scale.fromValue = 0.94
    scale.toValue = 1
    scale.mass = 1
    scale.stiffness = 420
    scale.damping = 26
    scale.duration = scale.settlingDuration
    let fade = CABasicAnimation(keyPath: "opacity")
    fade.fromValue = 0
    fade.toValue = 1
    fade.duration = 0.18
    fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
    layer.opacity = 1
    layer.add(drop, forKey: "drop")
    layer.add(scale, forKey: "scale")
    layer.add(fade, forKey: "fade")
  }

  private func animateOut() {
    guard let layer else { return }
    let lift = CABasicAnimation(keyPath: "transform.translation.y")
    lift.fromValue = 0
    lift.toValue = Self.rise / 2
    let fade = CABasicAnimation(keyPath: "opacity")
    fade.fromValue = 1
    fade.toValue = 0
    let group = CAAnimationGroup()
    group.animations = [lift, fade]
    group.duration = 0.22
    group.timingFunction = CAMediaTimingFunction(name: .easeIn)
    CATransaction.begin()
    CATransaction.setCompletionBlock { [weak self] in
      guard let self, self.message.isEmpty else { return }
      self.isHidden = true
    }
    layer.opacity = 0
    layer.add(group, forKey: "leave")
    CATransaction.commit()
  }

  @objc private func buttonClicked() { action?() }

  /// For tests: whether the shown message is cut short.
  var truncated: Bool {
    layoutSubtreeIfNeeded()
    return label.frame.width < ceil((message as NSString).size(withAttributes: [.font: font]).width)
  }

  override func layout() {
    super.layout()
    let mid = bounds.height / 2
    button.frame = NSRect(x: bounds.width - 8 - Self.buttonSize, y: mid - Self.buttonSize / 2,
                          width: Self.buttonSize, height: Self.buttonSize)
    if figure {
      label.frame = NSRect(x: 8, y: mid - 10, width: max(0, bounds.width - 16), height: 20)
      return
    }
    let right = button.isHidden ? bounds.width - 8 : button.frame.minX - 10
    label.frame = NSRect(x: 14, y: mid - 9, width: max(0, right - 14), height: 18)
  }
}
