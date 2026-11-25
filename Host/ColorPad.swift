import AppKit

/// Ray's own colour picker (owner's pick A, 2026-11-25): a saturation/brightness pad over a hue bar, with the colour
/// and its hex under them. Every colour row's + swatch (`SwatchRow.onCustomHex`) opens it in place, instead of macOS's
/// colour window: the Space theme, Settings › Spaces and Appearance, profile colours and the welcome.
final class ColorPadView: NSView, NSTextFieldDelegate {
  static let size = NSSize(width: 240, height: 214)
  var onChange: ((String) -> Void)?
  private(set) var hue: CGFloat = 0.72
  private(set) var saturation: CGFloat = 0.6
  private(set) var brightness: CGFloat = 0.9
  private let pad = ColorPadField()
  private let bar = ColorHueBar()
  private let swatch = NSView()
  private let hexField = EditorField(placeholder: "#RRGGBB")

  init(hex: String?) {
    super.init(frame: NSRect(origin: .zero, size: Self.size))
    wantsLayer = true
    layer?.cornerRadius = Panels.radius
    layer?.cornerCurve = .continuous
    if let hex, let rgb = ProfileColor.parse(hex) {
      var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
      NSColor(srgbRed: rgb.r, green: rgb.g, blue: rgb.b, alpha: 1).getHue(&h, saturation: &s, brightness: &b, alpha: &a)
      (hue, saturation, brightness) = (h, s, b)
    }
    pad.onPick = { [weak self] s, b in self?.set(saturation: s, brightness: b) }
    bar.onPick = { [weak self] h in self?.set(hue: h) }
    swatch.wantsLayer = true
    swatch.layer?.cornerRadius = 11
    swatch.layer?.borderWidth = 0.5
    hexField.field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
    hexField.field.delegate = self
    hexField.field.setAccessibilityLabel("Hex colour")
    [pad, bar, swatch, hexField].forEach(addSubview)
    refresh()
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }
  override var wantsUpdateLayer: Bool { true }
  override func updateLayer() {
    layer?.backgroundColor = SurfaceBackdrop.solidFill.cgColor
    swatch.layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.2).cgColor
  }

  var hex: String {
    ProfileColor.hex(of: NSColor(colorSpace: .sRGB, hue: hue, saturation: saturation, brightness: brightness, alpha: 1))
  }

  func set(hue: CGFloat? = nil, saturation: CGFloat? = nil, brightness: CGFloat? = nil) {
    if let hue { self.hue = min(max(hue, 0), 1) }
    if let saturation { self.saturation = min(max(saturation, 0), 1) }
    if let brightness { self.brightness = min(max(brightness, 0), 1) }
    refresh()
    onChange?(hex)
  }

  private func refresh() {
    pad.hue = hue
    pad.point = (saturation, brightness)
    bar.hue = hue
    swatch.layer?.backgroundColor = NSColor(colorSpace: .sRGB, hue: hue, saturation: saturation, brightness: brightness, alpha: 1).cgColor
    if hexField.field.currentEditor() == nil { hexField.field.stringValue = hex }
  }

  func controlTextDidChange(_ obj: Notification) {
    var text = hexField.field.stringValue.trimmingCharacters(in: .whitespaces)
    if !text.hasPrefix("#") { text = "#" + text }
    guard text.count == 7, let valid = Space.validHex(text), let rgb = ProfileColor.parse(valid) else { return }
    var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    NSColor(srgbRed: rgb.r, green: rgb.g, blue: rgb.b, alpha: 1).getHue(&h, saturation: &s, brightness: &b, alpha: &a)
    (hue, saturation, brightness) = (h, s, b)
    refresh()
    onChange?(valid)
  }

  func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
    if selector == #selector(NSResponder.cancelOperation(_:)) || selector == #selector(NSResponder.insertNewline(_:)) {
      ColorPadPopup.close()
      return true
    }
    return false
  }

  override func layout() {
    super.layout()
    let inset: CGFloat = 12
    let width = bounds.width - inset * 2
    pad.frame = NSRect(x: inset, y: inset, width: width, height: 130)
    bar.frame = NSRect(x: inset, y: pad.frame.maxY + 10, width: width, height: 14)
    let rowY = bar.frame.maxY + 10
    swatch.frame = NSRect(x: inset, y: rowY + 3, width: 22, height: 22)
    hexField.frame = NSRect(x: swatch.frame.maxX + 8, y: rowY, width: 96, height: 28)
  }
}

/// The pad: saturation left to right, brightness bottom to top, for one hue; a ring where the colour sits.
final class ColorPadField: NSView {
  var hue: CGFloat = 0 { didSet { if oldValue != hue { picture = nil; needsDisplay = true } } }
  var point: (CGFloat, CGFloat) = (0, 1) { didSet { needsDisplay = true } }
  var onPick: ((CGFloat, CGFloat) -> Void)?
  private var picture: CGImage?

  override var isFlipped: Bool { true }
  override var mouseDownCanMoveWindow: Bool { false }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  private func makePicture() -> CGImage? {
    let w = 64, h = 40
    var bytes = [UInt8](repeating: 255, count: w * h * 4)
    for y in 0..<h {
      for x in 0..<w {
        let c = NSColor(colorSpace: .sRGB, hue: hue, saturation: CGFloat(x) / CGFloat(w - 1), brightness: 1 - CGFloat(y) / CGFloat(h - 1),
                        alpha: 1).usingColorSpace(.sRGB)!
        let i = (y * w + x) * 4
        bytes[i] = UInt8(c.redComponent * 255)
        bytes[i + 1] = UInt8(c.greenComponent * 255)
        bytes[i + 2] = UInt8(c.blueComponent * 255)
      }
    }
    guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
    return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                   space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                   provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
  }

  override func draw(_ dirtyRect: NSRect) {
    guard let context = NSGraphicsContext.current?.cgContext else { return }
    if picture == nil { picture = makePicture() }
    context.saveGState()
    context.addPath(CGPath(roundedRect: bounds, cornerWidth: 8, cornerHeight: 8, transform: nil))
    context.clip()
    if let picture {
      // Flipped view: draw the image upright.
      context.translateBy(x: 0, y: bounds.height)
      context.scaleBy(x: 1, y: -1)
      context.interpolationQuality = .high
      context.draw(picture, in: CGRect(origin: .zero, size: bounds.size))
    }
    context.restoreGState()
    let center = NSPoint(x: point.0 * bounds.width, y: (1 - point.1) * bounds.height)
    let ring = NSBezierPath(ovalIn: NSRect(x: center.x - 7, y: center.y - 7, width: 14, height: 14))
    ring.lineWidth = 2.5
    NSColor.white.setStroke()
    ring.stroke()
    let edge = NSBezierPath(ovalIn: NSRect(x: center.x - 8.5, y: center.y - 8.5, width: 17, height: 17))
    edge.lineWidth = 0.5
    NSColor.black.withAlphaComponent(0.3).setStroke()
    edge.stroke()
  }

  private func pick(_ event: NSEvent) {
    let p = convert(event.locationInWindow, from: nil)
    onPick?(min(max(p.x / bounds.width, 0), 1), 1 - min(max(p.y / bounds.height, 0), 1))
  }
  override func mouseDown(with event: NSEvent) { pick(event) }
  override func mouseDragged(with event: NSEvent) { pick(event) }
}

/// The hue bar under the pad.
final class ColorHueBar: NSView {
  var hue: CGFloat = 0 { didSet { needsDisplay = true } }
  var onPick: ((CGFloat) -> Void)?

  override var isFlipped: Bool { true }
  override var mouseDownCanMoveWindow: Bool { false }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func draw(_ dirtyRect: NSRect) {
    let colors = stride(from: 0.0, through: 1.0, by: 1.0 / 12).map { NSColor(colorSpace: .sRGB, hue: $0, saturation: 1, brightness: 1, alpha: 1) }
    let shape = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
    NSGradient(colors: colors)?.draw(in: shape, angle: 0)
    let x = min(max(hue * bounds.width, 4), bounds.width - 4)
    let knob = NSBezierPath(roundedRect: NSRect(x: x - 3, y: 1, width: 6, height: bounds.height - 2), xRadius: 3, yRadius: 3)
    knob.lineWidth = 2
    NSColor.white.setStroke()
    knob.stroke()
  }

  private func pick(_ event: NSEvent) {
    let p = convert(event.locationInWindow, from: nil)
    onPick?(min(max(p.x / bounds.width, 0), 0.999))
  }
  override func mouseDown(with event: NSEvent) { pick(event) }
  override func mouseDragged(with event: NSEvent) { pick(event) }
}

/// The pad in a borderless child window under the + it came from: it works over Settings, the welcome and a browser
/// window alike (and over Ray's panels, which are views). One at a time; a click elsewhere, Escape, Return in its
/// field or its window going away closes it.
enum ColorPadPopup {
  private static var window: NSWindow?
  private static var monitor: Any?
  private static var observer: NSObjectProtocol?
  private(set) static var pad: ColorPadView?
  /// How many opened and how many colours they gave (tests).
  private(set) static var opened = 0
  private(set) static var changes = 0

  static var isOpen: Bool { window != nil }

  static func show(from anchor: NSView, hex: String?, onChange: @escaping (String) -> Void) {
    close()
    guard let parent = anchor.window else { return }
    let pad = ColorPadView(hex: hex)
    pad.onChange = { hex in
      changes += 1
      onChange(hex)
    }
    let size = ColorPadView.size
    let anchorRect = parent.convertToScreen(anchor.convert(anchor.bounds, to: nil))
    var origin = NSPoint(x: anchorRect.minX, y: anchorRect.minY - 6 - size.height)
    if let screen = parent.screen?.visibleFrame {
      origin.x = min(max(origin.x, screen.minX + 8), screen.maxX - size.width - 8)
      if origin.y < screen.minY + 8 { origin.y = anchorRect.maxY + 6 }
    }
    let window = ColorPadWindow(contentRect: NSRect(origin: origin, size: size), styleMask: [.borderless],
                                backing: .buffered, defer: false)
    window.isOpaque = false
    window.backgroundColor = .clear
    window.hasShadow = true
    window.isReleasedWhenClosed = false
    window.contentView = pad
    window.appearance = parent.effectiveAppearance
    parent.addChildWindow(window, ordered: .above)
    window.orderFront(nil)
    self.window = window
    self.pad = pad
    opened += 1
    monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { event in
      if event.type == .keyDown {
        if event.keyCode == 53 { close(); return nil }
        return event
      }
      if event.window !== window { close() }
      return event
    }
    observer = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: parent,
                                                      queue: .main) { _ in close() }
  }

  static func close() {
    if let monitor { NSEvent.removeMonitor(monitor) }
    monitor = nil
    if let observer { NotificationCenter.default.removeObserver(observer) }
    observer = nil
    if let window {
      window.parent?.removeChildWindow(window)
      window.orderOut(nil)
    }
    window = nil
    pad = nil
  }

  static var debug: [String: Any] {
    ["open": isOpen, "hex": pad?.hex ?? NSNull(), "opened": opened, "changes": changes]
  }
}

/// Takes keys (the hex field) without the app activating anything else.
final class ColorPadWindow: NSWindow {
  override var canBecomeKey: Bool { true }
}
