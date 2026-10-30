import AppKit

/// A folder's look: its colour (one of Chrome's tab group colours, or none) and its icon (an SF Symbol or an emoji),
/// the same for pinned and Today folders. Saved in Sidebar.json as plain strings; anything unknown reads as none.
enum FolderLook {
  /// Chrome's tab group colours minus grey, in Chrome's order. A folder's colour is one of these or nil (none, which
  /// is Chrome's grey).
  static let colors = ["blue", "red", "yellow", "green", "pink", "purple", "cyan", "orange"]

  private static let hex: [String: UInt32] = [
    "blue": 0x4C8DF6, "red": 0xE5534B, "yellow": 0xE3B341, "green": 0x3FB06C,
    "pink": 0xDB61A2, "purple": 0x9B6CF0, "cyan": 0x35B8C6, "orange": 0xEE8434,
  ]

  private static func srgb(_ value: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255, alpha: 1)
  }

  /// No colour: a neutral grey that reads on both the light and the dark sidebar.
  static let noColor = NSColor(name: nil) {
    $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? srgb(0x9A9AA1) : srgb(0x8E8E93)
  }

  /// The colour's name if it's one of `colors`, else nil.
  static func valid(_ name: String?) -> String? {
    name.flatMap { colors.contains($0) ? $0 : nil }
  }

  static func color(_ name: String?) -> NSColor {
    valid(name).flatMap { hex[$0] }.map(srgb) ?? noColor
  }

  /// The colour as Chrome's tab group API names it (none is "grey").
  static func chromeColor(_ name: String?) -> String { valid(name) ?? "grey" }

  /// A Chrome group colour as Ray's: grey (or anything Ray doesn't know) is none.
  static func rayColor(chrome: String) -> String? { valid(chrome) }

  /// A new folder's colour: the first of `colors` the fewest folders use, as Chrome picks a new group's.
  static func nextColor(avoiding used: [String?]) -> String {
    var counts: [String: Int] = [:]
    for name in used { if let name = valid(name) { counts[name, default: 0] += 1 } }
    let fewest = colors.map { counts[$0] ?? 0 }.min() ?? 0
    return colors.first { (counts[$0] ?? 0) == fewest } ?? colors[0]
  }

  /// The colour menu's item title.
  static func title(_ name: String?) -> String {
    guard let name = valid(name) else { return "None" }
    return name.prefix(1).uppercased() + name.dropFirst()
  }

  /// A colour's dot for menu items; none is a ring with a slash through it.
  static func swatch(_ name: String?, size: CGFloat = 12) -> NSImage {
    let known = valid(name)
    let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
      if let known {
        color(known).setFill()
        NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
      } else {
        drawNone(in: rect, color: .tertiaryLabelColor)
      }
      return true
    }
    image.accessibilityDescription = title(known)
    return image
  }

  /// The "none" swatch: a thin ring with a slash from its top right to its bottom left.
  static func drawNone(in rect: NSRect, color: NSColor) {
    let width = max(1, rect.width / 12)
    color.setStroke()
    let ring = NSBezierPath(ovalIn: rect.insetBy(dx: width / 2 + 0.25, dy: width / 2 + 0.25))
    ring.lineWidth = width
    ring.stroke()
    let half = rect.width * 0.275
    let slash = NSBezierPath()
    slash.move(to: NSPoint(x: rect.midX + half, y: rect.midY + half))
    slash.line(to: NSPoint(x: rect.midX - half, y: rect.midY - half))
    slash.lineWidth = width
    slash.stroke()
  }

  // MARK: Icons

  /// An SF Symbol icon is saved as "sf:<name>"; anything else is an emoji.
  static let symbolPrefix = "sf:"

  /// The SF Symbol's name for an "sf:" icon, else nil.
  static func symbolName(_ icon: String?) -> String? {
    guard let icon, icon.hasPrefix(symbolPrefix) else { return nil }
    return String(icon.dropFirst(symbolPrefix.count))
  }

  /// Whether a string is one emoji: one grapheme, shown as emoji by default or asked to be by U+FE0F, at most 16
  /// UTF-8 bytes (a family or a flag fits; a paragraph of joiners doesn't).
  static func isEmoji(_ s: String) -> Bool {
    guard s.utf8.count <= 16, s.count == 1, let character = s.first else { return false }
    let scalars = character.unicodeScalars
    return scalars.contains { $0.properties.isEmojiPresentation }
      || scalars.contains { $0.value == 0xFE0F } && scalars.contains { $0.properties.isEmoji }
  }

  /// A saved icon Ray can draw: "sf:" plus a symbol macOS has, or one emoji. Anything else is drawn as none.
  static func isValidIcon(_ s: String?) -> Bool {
    guard let s, !s.isEmpty else { return false }
    if let name = symbolName(s) {
      return !name.isEmpty && name.utf8.count <= 64 && NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
    }
    return isEmoji(s)
  }

  /// The icon if it's valid, else nil.
  static func validIcon(_ s: String?) -> String? { isValidIcon(s) ? s : nil }

  // Symbols and emoji with their search words: Ardia's IconPicker.tsx lists (Apache-2.0).
  private static let symbolNames = [
    "star", "heart", "bookmark", "flag", "pin", "bolt", "flame", "leaf", "globe", "house", "briefcase", "cart", "bag", "creditcard",
    "dollarsign.circle", "chart.bar", "chart.line.uptrend.xyaxis", "calendar", "clock", "alarm", "envelope", "bubble.left", "phone", "video",
    "music.note", "headphones", "gamecontroller", "paintbrush", "camera", "film", "tv", "airplane", "map", "car", "fork.knife", "cup.and.saucer",
    "figure.run", "sportscourt", "pawprint", "tree", "sun.max", "moon", "cloud", "snowflake", "sparkles", "gift", "trophy", "target", "brain",
    "eye", "laptopcomputer", "desktopcomputer", "keyboard", "hammer", "wrench.and.screwdriver", "gearshape", "testtube.2", "ant", "lock",
    "key", "puzzlepiece", "shippingbox", "folder", "archivebox", "newspaper", "link", "magnifyingglass", "safari", "tag", "lightbulb",
    "questionmark.circle", "exclamationmark.triangle", "book", "graduationcap", "doc.text", "list.bullet", "checkmark.circle", "person.2",
  ]

  /// The symbols the editor offers, without any this macOS doesn't have (worked out once, on first use).
  static let symbols: [(name: String, keywords: String)] = symbolNames
    .filter { NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil }
    .map { ($0, $0.replacingOccurrences(of: ".", with: " ")) }

  static let emoji: [(char: String, keywords: String)] = [
    ("⭐️", "star favorite"), ("🔥", "fire hot"), ("❤️", "heart love"), ("✅", "check done"), ("📌", "pin"), ("🚀", "rocket launch ship"),
    ("💡", "idea bulb"), ("📝", "note memo write"), ("📚", "books read study"), ("📖", "book read"), ("🎓", "school graduate"), ("💼", "work briefcase"),
    ("🏠", "home house"), ("🛒", "shopping cart"), ("💰", "money"), ("💳", "card pay"), ("📈", "chart growth stocks"), ("📊", "chart data"),
    ("🗓️", "calendar date"), ("⏰", "alarm time"), ("📧", "email mail"), ("💬", "chat message"), ("📞", "phone call"), ("🎥", "video camera"),
    ("🎵", "music song"), ("🎧", "headphones music"), ("🎮", "game play"), ("🎨", "art design paint"), ("📷", "photo camera"), ("🎬", "movie film"),
    ("📺", "tv watch"), ("🍿", "popcorn movie"), ("✈️", "travel plane"), ("🗺️", "map travel"), ("🏖️", "beach holiday"), ("🌍", "world earth globe"),
    ("🍕", "pizza food"), ("🍔", "burger food"), ("☕️", "coffee"), ("🍷", "wine"), ("🍎", "apple fruit"), ("🥗", "salad food healthy"),
    ("🏋️", "gym fitness"), ("⚽️", "football soccer sport"), ("🏀", "basketball sport"), ("🚴", "bike cycling"), ("🧘", "yoga calm"), ("💊", "health pill"),
    ("🐶", "dog pet"), ("🐱", "cat pet"), ("🦊", "fox"), ("🐼", "panda"), ("🦄", "unicorn"), ("🐙", "octopus github"),
    ("🌱", "plant grow"), ("🌸", "flower blossom"), ("🌈", "rainbow"), ("☀️", "sun"), ("🌙", "moon night"), ("❄️", "snow cold"),
    ("⚡️", "lightning fast"), ("💎", "gem diamond"), ("🎁", "gift present"), ("🎉", "party celebrate"), ("🏆", "trophy win"), ("🎯", "target goal"),
    ("🧠", "brain think"), ("👀", "eyes look"), ("🤖", "robot ai bot"), ("👾", "alien game"), ("💻", "laptop computer code"), ("🖥️", "desktop computer"),
    ("⌨️", "keyboard type"), ("🛠️", "tools build"), ("⚙️", "settings gear"), ("🔧", "wrench fix"), ("🧪", "test lab science"), ("🔬", "science research"),
    ("🐛", "bug"), ("🔒", "lock secure"), ("🔑", "key"), ("🧩", "puzzle extension"), ("📦", "package box"), ("🗂️", "folder files"),
    ("📁", "folder"), ("🗃️", "archive"), ("📰", "news paper"), ("🔗", "link"), ("🔍", "search find"), ("🧭", "compass explore"),
    ("🏷️", "tag label"), ("💭", "thought"), ("❓", "question"), ("❗️", "important"), ("⚠️", "warning"), ("🚧", "construction wip"),
    ("🟥", "red square"), ("🟧", "orange square"), ("🟨", "yellow square"), ("🟩", "green square"), ("🟦", "blue square"), ("🟪", "purple square"),
    ("🔴", "red circle"), ("🟠", "orange circle"), ("🟡", "yellow circle"), ("🟢", "green circle"), ("🔵", "blue circle"), ("🟣", "purple circle"),
  ]

  private static func words(_ text: String) -> [Substring] {
    text.lowercased().split { !$0.isLetter && !$0.isNumber }
  }

  /// The editor's search: every word typed starts a word of the name or its keywords, ignoring case. Empty matches all.
  static func matches(_ query: String, name: String, keywords: String) -> Bool {
    let typed = words(query)
    guard !typed.isEmpty else { return true }
    let targets = words(name + " " + keywords)
    return typed.allSatisfy { word in targets.contains { $0.hasPrefix(word) } }
  }

  /// The symbols matching a search, as icon values ("sf:<name>").
  static func symbols(matching query: String) -> [String] {
    symbols.filter { matches(query, name: $0.name, keywords: $0.keywords) }.map { symbolPrefix + $0.name }
  }

  static func emoji(matching query: String) -> [String] {
    emoji.filter { matches(query, name: "", keywords: $0.keywords) }.map(\.char)
  }

  /// An SF Symbol drawn in one colour. The colour resolves when the image draws, so draw it at once (it isn't cached
  /// per appearance).
  static func symbolImage(_ name: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSImage? {
    let config = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
    guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
    else { return nil }
    return NSImage(size: base.size, flipped: false) { rect in
      base.draw(in: rect)
      color.set()
      rect.fill(using: .sourceAtop)
      return true
    }
  }
}

// MARK: Folder icon

/// A folder's icon in the sidebar, 18 × 16 pt: a back panel with a tab, two sheets of paper and a front flap in the
/// folder's colour (an optional symbol or emoji on it), all CALayers. Opening, the sheets rise out of it fanning apart
/// and the flap leans back on a spring; hover lifts the sheets a touch; a tab dragged over opens it wider and pulses it.
/// Not flipped: the layers are y-up, and the flap hinges at its bottom edge. Clicks go to the row under it.
final class FolderIconView: NSView {
  static let size = NSSize(width: 18, height: 16)
  /// Springs added since launch, for checks (recorded app-side, not polled).
  static var springsStarted = 0

  private let root = CALayer()
  private let back = CAShapeLayer()
  /// The sheet in front (white) and the one behind it (a little grey), as the mock's `.paper` and `.paper.p2`.
  private let paper1 = CALayer()
  private let paper2 = CALayer()
  /// The flap's hinge: carries the transform and the shadow; the gradient, its top highlight and the glyph ride on it.
  private let front = CALayer()
  private let flap = CAGradientLayer()
  private let flapMask = CAShapeLayer()
  private let highlight = CALayer()
  private let symbol = CALayer()
  private let emoji = CATextLayer()

  private(set) var colorName: String?
  private(set) var icon: String?
  private(set) var isOpen = false
  private(set) var isHovered = false
  private(set) var isDropTarget = false

  private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
  private var scale: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }

  override init(frame: NSRect) {
    super.init(frame: frame.isEmpty ? NSRect(origin: frame.origin, size: Self.size) : frame)
    wantsLayer = true
    build()
    pose(animated: false)
  }

  convenience init() { self.init(frame: .zero) }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { false }
  override var wantsUpdateLayer: Bool { true }
  override var intrinsicContentSize: NSSize { Self.size }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  private func quietly(_ body: () -> Void) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    body()
    CATransaction.commit()
  }

  /// The layers at the mock's geometry, turned y-up (CSS y is 16 minus ours).
  private func build() {
    quietly {
      root.bounds = CGRect(origin: .zero, size: Self.size)
      layer?.addSublayer(root)

      let body = CGMutablePath()
      body.move(to: CGPoint(x: 1, y: 8))
      body.addArc(tangent1End: CGPoint(x: 1, y: 14.5), tangent2End: CGPoint(x: 6.7, y: 14.5), radius: 1.7)
      body.addLine(to: CGPoint(x: 6.7, y: 14.5))
      body.addLine(to: CGPoint(x: 8.3, y: 12.8))
      body.addArc(tangent1End: CGPoint(x: 17, y: 12.8), tangent2End: CGPoint(x: 17, y: 0), radius: 1.7)
      body.addArc(tangent1End: CGPoint(x: 17, y: 0), tangent2End: CGPoint(x: 1, y: 0), radius: 1.7)
      body.addArc(tangent1End: CGPoint(x: 1, y: 0), tangent2End: CGPoint(x: 1, y: 14.5), radius: 1.7)
      body.closeSubpath()
      back.frame = root.bounds
      back.path = body
      root.addSublayer(back)

      for (paper, x, width) in [(paper2, 4.5, 11.5), (paper1, 3, 12)] as [(CALayer, CGFloat, CGFloat)] {
        paper.bounds = CGRect(x: 0, y: 0, width: width, height: 9)
        paper.position = CGPoint(x: x + width / 2, y: 2.5 + 4.5)
        paper.cornerRadius = 1.5
        paper.borderWidth = 0.4
        root.addSublayer(paper)
      }

      let flapSize = CGSize(width: 18, height: 11)
      front.anchorPoint = CGPoint(x: 0.5, y: 0)
      front.bounds = CGRect(origin: .zero, size: flapSize)
      front.position = CGPoint(x: 9, y: 0)
      let shape = Self.flapPath(flapSize)
      front.shadowPath = shape
      front.shadowColor = NSColor.black.cgColor
      front.shadowOpacity = 0.12
      front.shadowRadius = 0.5
      front.shadowOffset = CGSize(width: 0, height: 0.5)
      root.addSublayer(front)

      flap.frame = front.bounds
      flap.startPoint = CGPoint(x: 0.5, y: 0)
      flap.endPoint = CGPoint(x: 0.5, y: 1)
      flapMask.frame = front.bounds
      flapMask.path = shape
      flap.mask = flapMask
      highlight.frame = CGRect(x: 0, y: flapSize.height - 0.5, width: flapSize.width, height: 0.5)
      flap.addSublayer(highlight)
      front.addSublayer(flap)

      // Centred on the flap, 0.3 pt low, as the mock's glyph.
      symbol.position = CGPoint(x: 9, y: 5.5 - 0.3)
      front.addSublayer(symbol)
      emoji.alignmentMode = .center
      emoji.position = symbol.position
      front.addSublayer(emoji)
      symbol.isHidden = true
      emoji.isHidden = true
    }
  }

  /// The flap's outline: 2.2 pt corners on top, 2.6 pt at the bottom.
  private static func flapPath(_ size: CGSize) -> CGPath {
    let path = CGMutablePath()
    let w = size.width, h = size.height
    path.move(to: CGPoint(x: w / 2, y: 0))
    path.addArc(tangent1End: CGPoint(x: w, y: 0), tangent2End: CGPoint(x: w, y: h), radius: 2.6)
    path.addArc(tangent1End: CGPoint(x: w, y: h), tangent2End: CGPoint(x: 0, y: h), radius: 2.2)
    path.addArc(tangent1End: CGPoint(x: 0, y: h), tangent2End: CGPoint(x: 0, y: 0), radius: 2.2)
    path.addArc(tangent1End: CGPoint(x: 0, y: 0), tangent2End: CGPoint(x: w, y: 0), radius: 2.6)
    path.closeSubpath()
    return path
  }

  override func layout() {
    super.layout()
    quietly { root.position = CGPoint(x: bounds.midX.rounded(), y: bounds.midY.rounded()) }
  }

  // MARK: Look

  /// Shows a folder's colour and icon (unknown ones as none).
  func show(color: String?, icon: String?) {
    let color = FolderLook.valid(color)
    let icon = FolderLook.validIcon(icon)
    guard color != colorName || icon != self.icon else { return }
    colorName = color
    self.icon = icon
    applyLook()
    needsDisplay = true
  }

  override func updateLayer() { applyLook() }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    needsDisplay = true
  }

  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    applyLook()
  }

  private static func rgb(_ color: NSColor) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
    let c = color.usingColorSpace(.sRGB) ?? color
    return (c.redComponent, c.greenComponent, c.blueComponent)
  }

  /// `a` moved `amount` of the way toward `b`.
  private static func mix(_ a: (r: CGFloat, g: CGFloat, b: CGFloat), toward b: CGFloat, _ amount: CGFloat) -> CGColor {
    CGColor(srgbRed: a.r + (b - a.r) * amount, green: a.g + (b - a.g) * amount, blue: a.b + (b - a.b) * amount, alpha: 1)
  }

  /// Resolves every colour against this view's appearance and redraws the glyph.
  private func applyLook() {
    let scale = self.scale
    effectiveAppearance.performAsCurrentDrawingAppearance {
      let base = FolderLook.color(colorName)
      let rgb = Self.rgb(base)
      // White on the flap as in the mock; black only where white would wash out (yellow, a very light colour).
      let luminance = 0.2126 * rgb.r + 0.7152 * rgb.g + 0.0722 * rgb.b
      let ink: NSColor = luminance > 0.65 ? .black : .white
      quietly {
        for sublayer in [root, back, paper1, paper2, front, flap, flapMask, highlight, symbol, emoji] {
          sublayer.contentsScale = scale
        }
        back.fillColor = Self.mix(rgb, toward: 0, 0.28)
        flap.colors = [Self.mix(rgb, toward: 0, 0), Self.mix(rgb, toward: 1, 0.22)]
        highlight.backgroundColor = NSColor(white: 1, alpha: 0.55).cgColor
        paper1.backgroundColor = NSColor.white.cgColor
        paper2.backgroundColor = NSColor(srgbRed: 0xF1 / 255.0, green: 0xF1 / 255.0, blue: 0xF4 / 255.0, alpha: 1).cgColor
        paper1.borderColor = NSColor(white: 0, alpha: 0.18).cgColor
        paper2.borderColor = paper1.borderColor

        symbol.isHidden = true
        emoji.isHidden = true
        if let name = FolderLook.symbolName(icon),
           let image = FolderLook.symbolImage(name, size: 7.5, weight: .semibold, color: ink) {
          symbol.bounds = CGRect(origin: .zero, size: image.size)
          symbol.contents = image.layerContents(forContentsScale: scale)
          symbol.isHidden = false
        } else if let icon {
          let font = NSFont.systemFont(ofSize: 8)
          let text = NSAttributedString(string: icon, attributes: [.font: font])
          let height = ceil(font.ascender - font.descender + font.leading)
          emoji.bounds = CGRect(x: 0, y: 0, width: 14, height: height)
          emoji.string = text
          emoji.isHidden = false
        }
      }
    }
  }

  // MARK: States

  /// Sets the icon's state. Animated changes run on springs from wherever the icon is now, so a change mid-flight
  /// reverses smoothly; with Reduce Motion, or `animated` false, it switches without moving and doesn't pulse.
  func setState(open: Bool, hovered: Bool, dropTarget: Bool, animated: Bool) {
    guard open != isOpen || hovered != isHovered || dropTarget != isDropTarget else { return }
    isOpen = open
    isHovered = hovered
    isDropTarget = dropTarget
    pose(animated: animated)
  }

  /// A skew as CSS's `translateX(dx) skewX(degrees)` (y-down) in our y-up layers: a negative CSS angle leans the top
  /// edge right, about the flap's bottom edge.
  private static func lean(_ cssDegrees: CGFloat, dx: CGFloat = 0) -> CATransform3D {
    let c = tan(-cssDegrees * .pi / 180)
    return CATransform3DMakeAffineTransform(CGAffineTransform(a: 1, b: 0, c: c, d: 1, tx: dx, ty: 0))
  }

  /// CSS's `translateY(y) rotate(degrees)` (y-down, clockwise) in y-up layers, about the sheet's centre.
  private static func lift(_ cssY: CGFloat, rotate cssDegrees: CGFloat = 0) -> CATransform3D {
    CATransform3DRotate(CATransform3DMakeTranslation(0, -cssY, 0), -cssDegrees * .pi / 180, 0, 0, 1)
  }

  /// The mock's values per state: drop target over open over hovered (closed only) over closed.
  private var targets: (front: CATransform3D, paper1: CATransform3D, paper2: CATransform3D) {
    if isDropTarget { return (Self.lean(-18, dx: 1.5), Self.lift(-5, rotate: -8), Self.lift(-4, rotate: 10)) }
    if isOpen { return (Self.lean(-13, dx: 1), Self.lift(-3.5, rotate: -5), Self.lift(-2.5, rotate: 7)) }
    if isHovered { return (Self.lean(-5), Self.lift(0.5), Self.lift(0.5)) }
    return (CATransform3DIdentity, Self.lift(2), Self.lift(2))
  }

  private func pose(animated: Bool) {
    let animate = animated && !reduceMotion && window != nil
    let to = targets
    move(front, to: to.front, animate: animate, delay: 0)
    move(paper1, to: to.paper1, animate: animate, delay: 0)
    move(paper2, to: to.paper2, animate: animate, delay: 0.03)
    pulse(isDropTarget && animate)
  }

  private func move(_ layer: CALayer, to target: CATransform3D, animate: Bool, delay: CFTimeInterval) {
    guard !CATransform3DEqualToTransform(layer.transform, target) else {
      if !animate { layer.removeAnimation(forKey: "pose") }
      return
    }
    let from = layer.presentation()?.transform ?? layer.transform
    quietly { layer.transform = target }
    guard animate else {
      layer.removeAnimation(forKey: "pose")
      return
    }
    // About cubic-bezier(.3, 1.45, .5, 1) over 0.34 s: ~10% overshoot, settled in ~0.35 s.
    let spring = CASpringAnimation(keyPath: "transform")
    spring.mass = 1
    spring.stiffness = 380
    spring.damping = 23
    spring.fromValue = NSValue(caTransform3D: from)
    spring.toValue = NSValue(caTransform3D: target)
    spring.duration = spring.settlingDuration
    if delay > 0 {
      spring.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) + delay
      spring.fillMode = .backwards
    }
    layer.add(spring, forKey: "pose")
    Self.springsStarted += 1
  }

  /// The drop target's nudge: the whole icon breathes 1 → 1.08 and back while a tab is over it.
  private func pulse(_ on: Bool) {
    guard on else {
      root.removeAnimation(forKey: "pulse")
      return
    }
    guard root.animation(forKey: "pulse") == nil else { return }
    let nudge = CABasicAnimation(keyPath: "transform.scale")
    nudge.fromValue = 1
    nudge.toValue = 1.08
    nudge.duration = 0.5
    nudge.autoreverses = true
    nudge.repeatCount = .infinity
    nudge.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
    root.add(nudge, forKey: "pulse")
  }

  /// For checks: what the icon shows and does.
  var debug: [String: Any] {
    [
      "color": colorName ?? NSNull(), "icon": icon ?? NSNull(), "open": isOpen, "hovered": isHovered,
      "dropTarget": isDropTarget, "pulsing": root.animation(forKey: "pulse") != nil,
      "glyphShown": !symbol.isHidden || !emoji.isHidden,
    ]
  }
}
