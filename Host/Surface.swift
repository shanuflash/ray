import AppKit

// The look Ray's notes and panels share: frosted glass (an `NSVisualEffectView` within the window under a light
// wash) or a solid card, a hairline edge, continuous corners and a soft shadow. Settings › Appearance › Panels and
// notes (`surfaceStyle`) picks glass or solid for all of them at once.

/// The background of a note or panel: put it at the bottom of the view, filling it; the view's own layer carries the
/// shadow (`SurfaceBackdrop.shadow(on:)`). It follows the setting and the appearance by itself.
final class SurfaceBackdrop: NSView {
  private var effect: NSVisualEffectView?
  private let wash = NSView()
  private var observation: SettingsObservation?
  private(set) var style = "glass"
  var radius: CGFloat {
    didSet { layer?.cornerRadius = radius }
  }

  init(radius: CGFloat) {
    self.radius = radius
    super.init(frame: .zero)
    wantsLayer = true
    layer?.cornerRadius = radius
    layer?.cornerCurve = .continuous
    layer?.masksToBounds = true
    layer?.borderWidth = 0.5
    autoresizingMask = [.width, .height]
    wash.wantsLayer = true
    wash.autoresizingMask = [.width, .height]
    addSubview(wash)
    observation = RaySettings.shared.observe(.surfaceStyle) { [weak self] _ in self?.apply() }
    apply()
  }

  required init?(coder: NSCoder) { fatalError() }

  static var style: String { RaySettings.shared[.surfaceStyle] == "solid" ? "solid" : "glass" }

  /// Takes the setting: adds or removes the frost, then repaints.
  func apply() {
    style = Self.style
    if style == "glass" {
      if effect == nil {
        // Within the window: it frosts the page under it (Chrome's layer included), never the desktop.
        let effect = NSVisualEffectView(frame: bounds)
        effect.material = .popover
        effect.blendingMode = .withinWindow
        effect.state = .active
        effect.autoresizingMask = [.width, .height]
        addSubview(effect, positioned: .below, relativeTo: wash)
        self.effect = effect
      }
    } else {
      effect?.removeFromSuperview()
      effect = nil
    }
    refreshColors()
  }

  /// The solid card, and what accents are measured against on glass too.
  static let solidFill = NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
      ? NSColor(srgbRed: 0x2C / 255.0, green: 0x2C / 255.0, blue: 0x31 / 255.0, alpha: 1) : .white
  }
  /// Over the frost: the mock's 68 % white, 66 % graphite, as the material already tints it.
  static let glassWash = NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
      ? NSColor(srgbRed: 0.16, green: 0.16, blue: 0.18, alpha: 0.35) : NSColor(white: 1, alpha: 0.4)
  }
  static let edge = NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.1) : NSColor(white: 0, alpha: 0.08)
  }

  func refreshColors() {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      wash.layer?.backgroundColor = (style == "glass" ? Self.glassWash : Self.solidFill).cgColor
      layer?.borderColor = Self.edge.cgColor
    }
    superview.map { Self.shadow(on: $0, radius: radius) }
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    refreshColors()
  }

  override func viewDidMoveToSuperview() {
    super.viewDidMoveToSuperview()
    frame = superview?.bounds ?? .zero
    refreshColors()
  }

  /// The soft shadow under a note or panel, on its own (unclipped) layer, following its bounds.
  static func shadow(on view: NSView, radius: CGFloat) {
    guard let layer = view.layer else { return }
    let dark = view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    layer.shadowColor = NSColor.black.cgColor
    layer.shadowOpacity = dark ? 0.45 : 0.16
    layer.shadowRadius = 14
    layer.shadowOffset = CGSize(width: 0, height: -6)
    layer.shadowPath = CGPath(roundedRect: view.bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
  }
}
