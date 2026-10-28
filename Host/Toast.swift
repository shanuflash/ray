import AppKit

/// A short note at the top right of the page, as Arc shows "Copied Current URL": 14 pt medium text in a 46 pt
/// rounded panel, an optional button on the right, gone after a couple of seconds.
final class ToastView: NSView {
  private let label = NSTextField(labelWithString: "")
  private let button = HoverIconButton()
  private var action: (() -> Void)?
  private var hideWork: DispatchWorkItem?
  private(set) var message = ""

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.cornerRadius = 12
    layer?.cornerCurve = .continuous
    layer?.borderWidth = 1
    layer?.shadowOpacity = 0.2
    layer?.shadowRadius = 10
    layer?.shadowOffset = CGSize(width: 0, height: -3)
    label.font = .systemFont(ofSize: 14, weight: .medium)
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
    alphaValue = 0
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }
  override var wantsUpdateLayer: Bool { true }
  override var mouseDownCanMoveWindow: Bool { false }

  override func updateLayer() {
    let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    layer?.backgroundColor = (dark ? NSColor(white: 0.2, alpha: 0.96) : NSColor(white: 0.98, alpha: 0.96)).cgColor
    layer?.borderColor = (dark ? NSColor(white: 1, alpha: 0.1) : NSColor(white: 0, alpha: 0.1)).cgColor
    button.layer?.backgroundColor = (dark ? NSColor(white: 1, alpha: 0.14) : NSColor(white: 0, alpha: 0.07)).cgColor
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    needsDisplay = true
  }

  /// The size it wants for its message, at most `limit` wide.
  func fit(_ limit: CGFloat) -> NSSize {
    let text = ceil(label.intrinsicContentSize.width)
    let buttonWidth: CGFloat = button.isHidden ? 0 : 31 + 9
    return NSSize(width: min(limit, 12 + text + buttonWidth + 12), height: 46)
  }

  func show(_ message: String, symbol: String? = nil, action: (() -> Void)? = nil) {
    self.message = message
    label.stringValue = message
    button.isHidden = symbol == nil
    button.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
    self.action = action
    needsLayout = true
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.18
      animator().alphaValue = 1
    }
    hideWork?.cancel()
    let work = DispatchWorkItem { [weak self] in self?.hide() }
    hideWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.2, execute: work)
  }

  func hide() {
    hideWork?.cancel()
    hideWork = nil
    message = ""
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.25
      animator().alphaValue = 0
    }
  }

  @objc private func buttonClicked() { action?() }

  override func layout() {
    super.layout()
    let mid = bounds.height / 2
    button.frame = NSRect(x: bounds.width - 12 - 31, y: mid - 15.5, width: 31, height: 31)
    let right = button.isHidden ? bounds.width - 12 : button.frame.minX - 9
    label.frame = NSRect(x: 12, y: mid - 9, width: max(0, right - 12), height: 18)
  }
}
