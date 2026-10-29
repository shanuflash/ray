import AppKit

/// A tiny Ray window drawn on layers, in the profile's colour: traffic lights, the sidebar with its address pill and
/// tab rows (one active, maybe one highlighted as new), and the page, with or without its address bar (the host
/// alone, or the host and the grey rest of the address). Settings uses it for live pictures beside a row and for
/// picture choices (`appearanceChoice`); it follows the profile's colour and, unless forced, the appearance.
final class MiniRayWindow: NSView {
  enum Row {
    case plain, active, new
  }

  /// The sidebar's tab rows, top to bottom.
  var rows: [Row] = [.plain, .active, .plain, .plain] { didSet { needsDisplay = true } }
  var showsAddressBar = true { didSet { needsDisplay = true } }
  /// Only the host shows in the page's address bar (Settings › Show only the site).
  var minimalAddress = false { didSet { needsDisplay = true } }
  /// Light or dark whatever the window is (picture choices); nil follows the window.
  var forcedAppearance: NSAppearance.Name? {
    didSet { appearance = forcedAppearance.flatMap { NSAppearance(named: $0) } }
  }

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.masksToBounds = true
    layer?.cornerCurve = .continuous
    NotificationCenter.default.addObserver(self, selector: #selector(accentChanged), name: ProfileColor.didChange, object: nil)
    setAccessibilityElement(false)
  }

  required init?(coder: NSCoder) { fatalError() }

  deinit { NotificationCenter.default.removeObserver(self) }

  override var isFlipped: Bool { true }
  override var wantsUpdateLayer: Bool { true }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  @objc private func accentChanged() { needsDisplay = true }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    needsDisplay = true
  }

  override func layout() {
    super.layout()
    needsDisplay = true
  }

  override func updateLayer() {
    guard let root = layer else { return }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    root.sublayers?.forEach { $0.removeFromSuperlayer() }
    effectiveAppearance.performAsCurrentDrawingAppearance { draw(into: root) }
    CATransaction.commit()
  }

  private func box(_ rect: CGRect, _ color: NSColor?, radius: CGFloat = 0, border: NSColor? = nil, in parent: CALayer) {
    let layer = CALayer()
    layer.frame = rect
    layer.backgroundColor = color?.cgColor
    layer.cornerRadius = radius
    layer.cornerCurve = .continuous
    if let border {
      layer.borderColor = border.cgColor
      layer.borderWidth = 0.75
    }
    parent.addSublayer(layer)
  }

  private func draw(into root: CALayer) {
    let width = bounds.width, height = bounds.height
    let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    let accent = ProfileColor.accent
    let ink = NSColor.labelColor
    root.cornerRadius = max(5, min(9, width / 16))
    root.backgroundColor = SidebarColors.background.cgColor
    root.borderColor = (dark ? NSColor(white: 1, alpha: 0.14) : NSColor(white: 0, alpha: 0.12)).cgColor
    root.borderWidth = 0.75

    // Traffic lights.
    let dot = max(2.6, width / 34)
    for (index, hex) in [0xFF5F57, 0xFEBC2E, 0x28C840].enumerated() {
      let color = NSColor(srgbRed: CGFloat(hex >> 16) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
      box(CGRect(x: 5 + CGFloat(index) * (dot + 1.6), y: 5, width: dot, height: dot), color, radius: dot / 2, in: root)
    }

    // Sidebar: the address pill, then the tab rows.
    let side = max(26, (width * 0.3).rounded())
    let unit = max(5, height / 11)
    box(CGRect(x: 4, y: 6 + dot + 3, width: side - 8, height: unit), SidebarColors.fill, radius: unit / 2.4, in: root)
    var y = 6 + dot + 3 + unit + 5
    let lineWidths: [CGFloat] = [0.62, 0.48, 0.7, 0.55, 0.4, 0.66]
    for (index, row) in rows.enumerated() {
      let rect = CGRect(x: 4, y: y, width: side - 8, height: unit)
      switch row {
      case .plain: break
      case .active: box(rect, SidebarColors.selected, radius: unit / 3, in: root)
      case .new: box(rect, accent.withAlphaComponent(dark ? 0.32 : 0.22), radius: unit / 3, border: accent, in: root)
      }
      let mark = row == .new ? accent : ink.withAlphaComponent(row == .active ? 0.55 : 0.28)
      let icon = unit * 0.5
      box(CGRect(x: rect.minX + 2.5, y: rect.midY - icon / 2, width: icon, height: icon), mark, radius: 1, in: root)
      let line = max(4, (rect.width - icon - 8) * lineWidths[index % lineWidths.count])
      box(CGRect(x: rect.minX + icon + 5, y: rect.midY - 0.9, width: line, height: 1.8), mark, radius: 0.9, in: root)
      y += unit + 2.5
    }

    // The page.
    let page = CGRect(x: side, y: 4, width: width - side - 4, height: height - 8)
    let pageLayer = CALayer()
    pageLayer.frame = page
    pageLayer.backgroundColor = (dark ? NSColor(white: 0.17, alpha: 1) : NSColor.white).cgColor
    pageLayer.cornerRadius = max(3, root.cornerRadius - 3)
    pageLayer.cornerCurve = .continuous
    pageLayer.masksToBounds = true
    pageLayer.borderColor = (dark ? NSColor(white: 1, alpha: 0.08) : NSColor(white: 0, alpha: 0.08)).cgColor
    pageLayer.borderWidth = 0.5
    root.addSublayer(pageLayer)
    var top: CGFloat = 0
    if showsAddressBar {
      let bar = max(7, unit + 2)
      let middle = bar / 2
      // Back and forward, then the host in the label's colour and the rest of the address in grey.
      for index in 0..<2 {
        box(CGRect(x: 4 + CGFloat(index) * 4.5, y: middle - 1.2, width: 2.4, height: 2.4), ink.withAlphaComponent(0.3), radius: 1.2, in: pageLayer)
      }
      let host = page.width * 0.2
      box(CGRect(x: 15, y: middle - 1.1, width: host, height: 2.2), ink.withAlphaComponent(0.75), radius: 1.1, in: pageLayer)
      if !minimalAddress {
        box(CGRect(x: 15 + host + 2, y: middle - 1.1, width: page.width * 0.32, height: 2.2), ink.withAlphaComponent(0.25), radius: 1.1, in: pageLayer)
      }
      box(CGRect(x: 0, y: bar, width: page.width, height: 0.5), ink.withAlphaComponent(0.12), in: pageLayer)
      top = bar + 0.5
    }
    // A header washed in the profile's colour, then lines of text.
    let hero = CGRect(x: 6, y: top + 5, width: page.width - 12, height: max(8, (page.height - top) * 0.32))
    box(hero, accent.withAlphaComponent(dark ? 0.42 : 0.3), radius: 2.5, in: pageLayer)
    var line = hero.maxY + 5
    for fraction in [0.86, 0.7, 0.8, 0.5] as [CGFloat] where line + 2 < page.height - 3 {
      box(CGRect(x: 6, y: line, width: (page.width - 12) * fraction, height: 1.8), ink.withAlphaComponent(0.18), radius: 0.9, in: pageLayer)
      line += 5
    }
  }

  // MARK: Pictures

  /// A picture choice of Light, Dark or Automatic (half and half).
  static func appearanceChoice(_ value: String) -> NSView {
    switch value {
    case "light", "dark":
      let mini = MiniRayWindow()
      mini.forcedAppearance = value == "dark" ? .darkAqua : .aqua
      return mini
    default:
      return SplitMiniRayWindow()
    }
  }
}

/// Automatic: the left half light, the right half dark.
private final class SplitMiniRayWindow: NSView {
  private let left = NSView(), right = NSView()
  private let light = MiniRayWindow(), dark = MiniRayWindow()

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    for (half, mini, name) in [(left, light, NSAppearance.Name.aqua), (right, dark, .darkAqua)] {
      half.wantsLayer = true
      half.layer?.masksToBounds = true
      mini.forcedAppearance = name
      half.addSubview(mini)
      addSubview(half)
    }
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func layout() {
    super.layout()
    let half = (bounds.width / 2).rounded()
    left.frame = NSRect(x: 0, y: 0, width: half, height: bounds.height)
    right.frame = NSRect(x: half, y: 0, width: bounds.width - half, height: bounds.height)
    light.frame = bounds
    dark.frame = NSRect(x: -half, y: 0, width: bounds.width, height: bounds.height)
  }
}

/// A `MiniRayWindow` beside a setting's row that shows what the setting does now: `update` sets it up from the
/// settings, at first and after each change of `keys`.
final class SettingsLivePicture: NSView {
  let mini = MiniRayWindow()
  private var observation: SettingsObservation?
  static let size = NSSize(width: 96, height: 62)

  init(following keys: [AnySettingKey], update: @escaping (MiniRayWindow) -> Void) {
    super.init(frame: NSRect(origin: .zero, size: Self.size))
    addSubview(mini)
    update(mini)
    observation = RaySettings.shared.observe(keys) { [weak self] in
      guard let self else { return }
      update(self.mini)
    }
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }
  override var fittingSize: NSSize { Self.size }
  override var intrinsicContentSize: NSSize { Self.size }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func layout() {
    super.layout()
    mini.frame = bounds
  }

  /// For the state log: what it draws now.
  var debug: [String: Any] {
    ["rows": mini.rows.map { "\($0)" }, "addressBar": mini.showsAddressBar, "minimalAddress": mini.minimalAddress]
  }
}
