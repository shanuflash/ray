import AppKit

/// What the sidebar shows of a Space besides its rows: the footer's icon and the list's name.
struct SidebarSpace {
  let id: UUID
  let name: String
  let icon: NSImage
  /// An SF Symbol (drawn in the sidebar's ink) rather than an emoji or a dot.
  let template: Bool
}

/// A Space's lists, for the sidebar to draw the one a swipe is heading to before the switch happens.
struct SidebarSpaceLists {
  let space: SidebarSpace
  let favorites: [SidebarEntry]
  let pinned: [SidebarEntry]
  let today: [SidebarEntry]
  let active: SidebarEntry?
}

// MARK: Space name

/// The Space's name at the top of its list (Arc's): icon and name, small and semibold, in the sidebar's ink. A
/// right-click has the Space's menu.
final class SpaceHeaderView: NSView {
  static let height: CGFloat = 28
  private let icon = NSImageView()
  private let label = NSTextField(labelWithString: "")
  var menuProvider: (() -> NSMenu?)?
  var onDoubleClick: (() -> Void)?

  override init(frame: NSRect) {
    super.init(frame: frame)
    label.font = .systemFont(ofSize: 12, weight: .semibold)
    label.textColor = .secondaryLabelColor
    label.lineBreakMode = .byTruncatingTail
    icon.imageScaling = .scaleProportionallyDown
    icon.contentTintColor = .secondaryLabelColor
    addSubview(icon)
    addSubview(label)
    setAccessibilityRole(.staticText)
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }

  var title: String { label.stringValue }

  func show(_ space: SidebarSpace) {
    label.stringValue = space.name
    icon.image = space.icon
    setAccessibilityLabel("Space \(space.name)")
    needsLayout = true
  }

  override func layout() {
    super.layout()
    let size: CGFloat = 16
    icon.frame = NSRect(x: 10, y: (bounds.height - size) / 2, width: size, height: size).integral
    let height = label.intrinsicContentSize.height
    label.frame = NSRect(x: icon.frame.maxX + 6, y: ((bounds.height - height) / 2).rounded(),
                         width: max(0, bounds.width - icon.frame.maxX - 16), height: height)
  }

  override func menu(for event: NSEvent) -> NSMenu? { menuProvider?() }

  override func mouseDown(with event: NSEvent) {
    if event.clickCount == 2 { onDoubleClick?() }
  }
}

// MARK: Footer icons

/// The Space icons in the sidebar's footer (Arc's): the current one bright, the others dimmed; a click goes to that
/// Space, a right-click has its menu. Cells are Arc's 26 pt with no gap, so a press between icons still lands; past
/// what fits they shrink to dots.
final class SpaceDockView: NSView {
  static let cell: CGFloat = 26
  static let dot: CGFloat = 14
  private var cells: [SpaceDockCell] = []
  private(set) var spaces: [SidebarSpace] = []
  private(set) var current = 0
  var onSelect: ((Int) -> Void)?
  var menuProvider: ((Int) -> NSMenu?)?

  override var isFlipped: Bool { true }

  func show(_ spaces: [SidebarSpace], current: Int) {
    self.spaces = spaces
    self.current = current
    while cells.count < spaces.count {
      let cell = SpaceDockCell()
      addSubview(cell)
      cells.append(cell)
    }
    while cells.count > spaces.count { cells.removeLast().removeFromSuperview() }
    for (index, (cell, space)) in zip(cells, spaces).enumerated() {
      cell.show(space, current: index == current)
      cell.onClick = { [weak self] in self?.onSelect?(index) }
      cell.menuProvider = { [weak self] in self?.menuProvider?(index) }
    }
    needsLayout = true
  }

  /// One Space alone needs no switcher: Arc hides it too.
  var shows: Bool { spaces.count > 1 }

  var cellWidth: CGFloat {
    let fits = bounds.width / CGFloat(max(cells.count, 1))
    return fits >= Self.cell ? Self.cell : max(8, min(Self.dot, fits))
  }

  override func layout() {
    super.layout()
    let width = cellWidth
    let total = width * CGFloat(cells.count)
    var x = ((bounds.width - total) / 2).rounded()
    for cell in cells {
      cell.compact = width < Self.cell
      cell.frame = NSRect(x: x, y: 0, width: width, height: bounds.height)
      x += width
    }
  }

  /// For tests: the cell a Space's icon sits in, in window coordinates.
  func cellFrame(_ index: Int) -> NSRect? {
    guard cells.indices.contains(index) else { return nil }
    return cells[index].convert(cells[index].bounds, to: nil)
  }

  func cell(_ index: Int) -> NSView? { cells.indices.contains(index) ? cells[index] : nil }

  func press(_ index: Int) -> Bool {
    guard cells.indices.contains(index) else { return false }
    onSelect?(index)
    return true
  }
}

private final class SpaceDockCell: NSView {
  private let icon = NSImageView()
  private let hover = CALayer()
  private let dotLayer = CALayer()
  var onClick: (() -> Void)?
  var menuProvider: (() -> NSMenu?)?
  var compact = false { didSet { if oldValue != compact { needsLayout = true } } }
  private var isCurrent = false
  private var tracking: NSTrackingArea?

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    hover.cornerRadius = 6
    hover.opacity = 0
    layer?.addSublayer(hover)
    layer?.addSublayer(dotLayer)
    icon.imageScaling = .scaleProportionallyDown
    addSubview(icon)
    setAccessibilityRole(.button)
  }

  required init?(coder: NSCoder) { fatalError() }

  func show(_ space: SidebarSpace, current: Bool) {
    isCurrent = current
    icon.image = space.icon
    icon.contentTintColor = space.template ? .labelColor : nil
    toolTip = space.name
    setAccessibilityLabel(space.name)
    setAccessibilitySelected(current)
    needsLayout = true
    needsDisplay = true
  }

  override var wantsUpdateLayer: Bool { true }

  override func updateLayer() {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      hover.backgroundColor = SidebarColors.hover.cgColor
      dotLayer.backgroundColor = NSColor.labelColor.cgColor
    }
  }

  override func layout() {
    super.layout()
    let size: CGFloat = 16
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    hover.frame = NSRect(x: (bounds.width - 26) / 2, y: (bounds.height - 26) / 2, width: 26, height: 26)
    let dot: CGFloat = isCurrent ? 6 : 5
    dotLayer.frame = NSRect(x: (bounds.width - dot) / 2, y: (bounds.height - dot) / 2, width: dot, height: dot)
    dotLayer.cornerRadius = dot / 2
    dotLayer.isHidden = !compact
    dotLayer.opacity = isCurrent ? 1 : 0.35
    CATransaction.commit()
    icon.isHidden = compact
    icon.frame = PixelGrid.align(NSRect(x: (bounds.width - size) / 2, y: (bounds.height - size) / 2, width: size, height: size), in: self)
    icon.alphaValue = isCurrent ? 1 : 0.4
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let tracking { removeTrackingArea(tracking) }
    let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
    addTrackingArea(area)
    tracking = area
  }

  override func mouseEntered(with event: NSEvent) { hover.opacity = compact ? 0 : 1 }
  override func mouseExited(with event: NSEvent) { hover.opacity = 0 }
  override var mouseDownCanMoveWindow: Bool { false }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override func mouseDown(with event: NSEvent) {}
  override func mouseUp(with event: NSEvent) {
    if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
  }
  override func menu(for event: NSEvent) -> NSMenu? { menuProvider?() }
  override func accessibilityPerformPress() -> Bool {
    onClick?()
    return true
  }
}

// MARK: Switch motion

/// The switch between two Spaces' lists (owner's pick 2C of `docs/mocks/spaces.html`): Arc's slide, the list
/// following the fingers 1:1 and springing onto a Space, with the rows trailing a little behind each other and the
/// Space's name moving at half speed. Favorites stay put: they're shared. Both lists are pictures of the real rows,
/// cut into one layer per row, over the hidden list while it moves, so nothing is laid out per frame.
final class SpaceSlide: NSView {
  /// How far each row lags the one above it at a full Space's distance.
  static let trail: CGFloat = 7
  /// The name's speed against the rows'.
  static let headerSpeed: CGFloat = 0.55

  struct Shot {
    let image: CGImage
    /// Each row's band in the picture (points, top down), the header's flagged.
    let bands: [(rect: NSRect, header: Bool)]
    let size: NSSize
    let scale: CGFloat
    /// Test builds: rows with nothing drawn in them.
    var blankBands = 0
  }

  private var oldLayers: [(CALayer, Int, Bool)] = []
  private var newLayers: [(CALayer, Int, Bool)] = []
  /// +1: the new Space comes in from the right (a Space to the right of this one in the footer).
  private(set) var direction: CGFloat = 1
  private(set) var progress: CGFloat = 0
  /// For the state log: frames drawn part way.
  private(set) var steps = 0

  override init(frame: NSRect) {
    super.init(frame: frame)
    let host = CALayer()
    host.masksToBounds = true
    layer = host
    wantsLayer = true
  }

  required init?(coder: NSCoder) { fatalError() }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  /// The visible part of a list, pictured from its layers (the rows draw with layers, which `cacheDisplay` misses).
  static func shot(of content: NSView, visible: NSRect, header: NSView?, scale: CGFloat) -> Shot? {
    guard let layer = content.layer, visible.width > 0, visible.height > 0,
          let context = CGContext(data: nil, width: Int(visible.width * scale), height: Int(visible.height * scale),
                                  bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    context.scaleBy(x: scale, y: scale)
    content.effectiveAppearance.performAsCurrentDrawingAppearance {
      if content.isFlipped {
        context.translateBy(x: 0, y: visible.height)
        context.scaleBy(x: 1, y: -1)
      }
      context.translateBy(x: -visible.minX, y: -visible.minY)
      layer.render(in: context)
    }
    // Test builds count rows with nothing drawn (a row pictured before its first draw).
    var pixels: [UInt8] = []
    if TestEnvironment.isTestBuild, let data = context.data {
      pixels = Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: context.bytesPerRow * context.height))
    }
    let bytesPerRow = context.bytesPerRow, height = context.height
    guard let image = context.makeImage() else { return nil }
    var bands: [(NSRect, Bool)] = []
    for view in content.subviews where !view.isHidden && view.alphaValue > 0.01 && view.frame.intersects(visible) {
      let rect = view.frame.offsetBy(dx: -visible.minX, dy: -visible.minY)
      bands.append((NSRect(x: 0, y: rect.minY, width: visible.width, height: rect.height), view === header))
    }
    bands.sort { $0.0.minY < $1.0.minY }
    var shot = Shot(image: image, bands: bands.map { (rect: $0.0, header: $0.1) }, size: visible.size, scale: scale)
    if !pixels.isEmpty {
      // The context's memory runs bottom row first: a band's rows counted from the top are flipped.
      shot.blankBands = bands.filter { band, _ in
        let top = max(0, Int(band.minY * scale)), bottom = min(height, Int(band.maxY * scale))
        guard bottom > top else { return false }
        for row in top..<bottom {
          let start = (height - 1 - row) * bytesPerRow
          var x = start + 3
          while x < start + bytesPerRow {
            if pixels[x] > 8 { return false }
            x += 4
          }
        }
        return true
      }.count
    }
    return shot
  }

  /// Starts a slide from one list's picture to the other's.
  /// `new` nil: no Space that way, the old list only stretches (a rubber band).
  /// `new`: the incoming list's picture; nil when the list itself moves in (`SidebarView.startSlide`) or for a rubber
  /// band.
  func begin(from old: Shot, to new: Shot?, direction: CGFloat) {
    self.direction = direction
    steps = 0
    layer?.sublayers?.forEach { $0.removeFromSuperlayer() }
    oldLayers = layers(for: old)
    newLayers = new.map(layers(for:)) ?? []
    set(progress: 0)
  }

  private func layers(for shot: Shot) -> [(CALayer, Int, Bool)] {
    var made: [(CALayer, Int, Bool)] = []
    var index = 0
    for band in shot.bands {
      let crop = CGRect(x: band.rect.minX * shot.scale, y: band.rect.minY * shot.scale,
                        width: band.rect.width * shot.scale, height: band.rect.height * shot.scale).integral
      guard let piece = shot.image.cropping(to: crop) else { continue }
      let slice = CALayer()
      slice.contents = piece
      slice.contentsScale = shot.scale
      slice.contentsGravity = .resize
      // The host isn't flipped: y counts up from the bottom.
      slice.frame = NSRect(x: band.rect.minX, y: bounds.height - band.rect.maxY, width: band.rect.width,
                           height: band.rect.height)
      slice.actions = ["position": NSNull(), "transform": NSNull(), "opacity": NSNull(), "bounds": NSNull()]
      layer?.addSublayer(slice)
      if !band.header { index += 1 }
      made.append((slice, band.header ? 0 : index, band.header))
    }
    return made
  }

  /// 0 shows the old list, 1 the new one; between, both, offset Arc's way with the trail.
  func set(progress value: CGFloat) {
    progress = value
    if value > 0.01 && value < 0.99 { steps += 1 }
    let width = bounds.width
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    func place(_ list: [(CALayer, Int, Bool)], distance: CGFloat) {
      for (slice, index, header) in list {
        let x = header ? distance * width * Self.headerSpeed : distance * width + distance * CGFloat(index) * Self.trail
        slice.transform = CATransform3DMakeTranslation(x, 0, 0)
        slice.opacity = header ? Float(max(0, 1 - abs(distance) * 1.3)) : 1
      }
    }
    place(oldLayers, distance: -value * direction)
    place(newLayers, distance: (1 - value) * direction)
    CATransaction.commit()
  }

  func clear() {
    layer?.sublayers?.forEach { $0.removeFromSuperlayer() }
    oldLayers = []
    newLayers = []
  }
}
