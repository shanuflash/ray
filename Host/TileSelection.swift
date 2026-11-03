import AppKit
import CoreImage

// Arc's selected favorite: a 3 pt ring and a faint wash, both the tile's own favicon blurred and blown up, so a Gmail
// tile rings red, yellow, green and blue. Adapted from Ardia's DockSelection.swift and BlurredIcon.swift (the "blur"
// kind), Copyright 2026 Mantra Patel, Apache License 2.0.

/// A favicon blurred once (and a saturated copy for the ring on dark), cached per image.
final class BlurredIcon {
  let plain: CGImage
  let darkRing: CGImage

  private static let cache = NSCache<NSImage, BlurredIcon>()
  private static let context = CIContext()

  private init(plain: CGImage, darkRing: CGImage) {
    self.plain = plain
    self.darkRing = darkRing
  }

  static func of(_ image: NSImage) -> BlurredIcon? {
    if let cached = cache.object(forKey: image) { return cached }
    guard let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
          let plain = blur(source), let darkRing = saturate(plain) else { return nil }
    let icon = BlurredIcon(plain: plain, darkRing: darkRing)
    cache.setObject(icon, forKey: image)
    return icon
  }

  private static func blur(_ image: CGImage) -> CGImage? {
    guard let filter = CIFilter(name: "CIGaussianBlur") else { return nil }
    filter.setValue(CIImage(cgImage: image), forKey: kCIInputImageKey)
    filter.setValue(5, forKey: kCIInputRadiusKey)
    guard let output = filter.outputImage else { return nil }
    return context.createCGImage(output, from: output.extent)
  }

  private static func saturate(_ image: CGImage) -> CGImage? {
    guard let filter = CIFilter(name: "CIColorControls") else { return nil }
    filter.setValue(CIImage(cgImage: image), forKey: kCIInputImageKey)
    filter.setValue(2.0, forKey: kCIInputSaturationKey)
    filter.setValue(-0.1, forKey: kCIInputBrightnessKey)
    guard let output = filter.outputImage else { return nil }
    return context.createCGImage(output, from: output.extent)
  }
}

/// The selected tile's face: a light base under the blurred icon at 22 %, and the ring (the blurred icon again,
/// masked to the tile's edge). Sits under the tile's icon; hidden when the tile has no favicon of its own.
final class TileSelectionLayer: CALayer {
  static let strokeWidth: CGFloat = 3

  private let tile = CALayer()
  private let background = CALayer()
  private let tint = CALayer()
  private let ring = CALayer()
  private let ringImage = CALayer()
  private let ringMask = CALayer()

  override init() {
    super.init()
    tile.masksToBounds = true
    tile.addSublayer(background)
    tile.addSublayer(tint)
    tint.opacity = 0.22
    for layer in [tint, ringImage] {
      layer.contentsGravity = .resizeAspectFill
      layer.masksToBounds = true
    }
    ring.addSublayer(ringImage)
    ringMask.borderColor = NSColor.white.cgColor
    ring.mask = ringMask
    addSublayer(tile)
    addSublayer(ring)
    isHidden = true
  }

  override init(layer: Any) { super.init(layer: layer) }
  required init?(coder: NSCoder) { fatalError() }

  /// Draws the face for `blurred` in the layer's bounds, or hides it (nil).
  func show(_ blurred: BlurredIcon?, dark: Bool, radius: CGFloat, scale: CGFloat) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }
    guard let blurred else {
      isHidden = true
      return
    }
    isHidden = false
    let big = bounds.insetBy(dx: -bounds.width * 0.75, dy: -bounds.height * 0.75)
    for layer in [tile, background, tint, ring, ringImage, ringMask] { layer.contentsScale = scale }
    tile.frame = bounds
    tile.cornerRadius = radius
    tile.cornerCurve = .continuous
    background.frame = bounds
    background.backgroundColor = NSColor.white.withAlphaComponent(dark ? 0.2 : 1).cgColor
    tint.frame = big
    tint.contents = blurred.plain
    for shape in [ring, ringMask] {
      shape.frame = bounds
      shape.cornerRadius = radius
      shape.cornerCurve = .continuous
    }
    ringImage.frame = big
    ringMask.borderWidth = (Self.strokeWidth * scale).rounded() / scale
    ring.backgroundColor = (dark ? NSColor.black : NSColor.white).cgColor
    ringImage.contents = dark ? blurred.darkRing : blurred.plain
    ringImage.opacity = dark ? 0.75 : 1
  }
}
