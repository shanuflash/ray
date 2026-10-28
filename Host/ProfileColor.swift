import AppKit

/// The browser profile's colour. Every accent in Ray's own UI takes it: the loading wash, progress, drop targets,
/// the command bar's selection, "on" states. Settings › Appearance sets it (`RaySettings` calls `apply`); until
/// the user picks one it is the lavender of Dia's loading wash. Ray's UI never uses `NSColor.controlAccentColor`
/// (scripts/test.sh fails on it).
enum ProfileColor {
  /// Posted on the main thread after the colour changed; views that cache it as a layer colour refresh then.
  static let didChange = Notification.Name("RayProfileColorDidChange")

  /// The default profile's colour: Dia's lavender, a little lighter on dark backgrounds so it reads the same.
  static let lavender = NSColor(name: nil) {
    $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
      ? NSColor(srgbRed: 0xA4 / 255.0, green: 0x86 / 255.0, blue: 0xF0 / 255.0, alpha: 1)
      : NSColor(srgbRed: 0x82 / 255.0, green: 0x57 / 255.0, blue: 0xE5 / 255.0, alpha: 1)
  }

  /// The swatches Settings offers after the default (lavender, which is `nil` here): plain colours in the spirit of
  /// Arc's and Dia's themes, each readable as a fill under white or black text.
  static let presets: [(name: String, hex: String)] = [
    ("Blue", "#2F6BEA"), ("Teal", "#12A594"), ("Green", "#3EA64A"), ("Amber", "#F2B01E"),
    ("Coral", "#F0654A"), ("Pink", "#E5589D"), ("Graphite", "#6B7280"),
  ]

  /// The user's own colour as `#RRGGBB`, or nil for the lavender.
  private(set) static var customHex: String?
  private static var custom: NSColor?

  /// What every accent draws with. Resolved when drawn, so it follows the appearance (lavender) and the setting.
  static var accent: NSColor { custom ?? lavender }

  static var isDefault: Bool { custom == nil }

  /// Takes a new colour (`#RRGGBB`; anything else is the default) and tells the windows.
  static func apply(hex: String?) {
    let valid = hex.flatMap { parse($0) != nil ? $0.uppercased() : nil }
    guard valid != customHex else { return }
    customHex = valid
    custom = valid.flatMap(parse).map { NSColor(srgbRed: $0.r, green: $0.g, blue: $0.b, alpha: 1) }
    NotificationCenter.default.post(name: didChange, object: nil)
  }

  static func parse(_ hex: String) -> (r: CGFloat, g: CGFloat, b: CGFloat)? {
    guard hex.count == 7, hex.hasPrefix("#"), let value = UInt32(hex.dropFirst(), radix: 16) else { return nil }
    return (CGFloat((value >> 16) & 0xFF) / 255, CGFloat((value >> 8) & 0xFF) / 255, CGFloat(value & 0xFF) / 255)
  }

  /// `#RRGGBB` for a colour as it looks under an appearance.
  static func hex(of color: NSColor, appearance: NSAppearance.Name = .aqua) -> String {
    let rgb = resolved(color, appearance: appearance)
    func byte(_ v: CGFloat) -> Int { Int((v * 255).rounded()) }
    return String(format: "#%02X%02X%02X", byte(rgb.r), byte(rgb.g), byte(rgb.b))
  }

  private static func resolved(_ color: NSColor, appearance: NSAppearance.Name) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
    var out: (r: CGFloat, g: CGFloat, b: CGFloat) = (0, 0, 0)
    NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
      let rgb = color.usingColorSpace(.sRGB) ?? color
      out = (rgb.redComponent, rgb.greenComponent, rgb.blueComponent)
    }
    return out
  }

  // MARK: Contrast

  /// WCAG relative luminance of an sRGB colour.
  static func luminance(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGFloat {
    func linear(_ c: CGFloat) -> CGFloat { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
    return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
  }

  /// WCAG contrast ratio of two relative luminances, 1...21.
  static func contrast(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
    (max(a, b) + 0.05) / (min(a, b) + 0.05)
  }

  /// Whether white has the higher contrast against the colour (else black does).
  static func prefersWhite(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> Bool {
    let fill = luminance(r, g, b)
    return contrast(1, fill) >= contrast(0, fill)
  }

  /// The text or icon colour for something sitting on a fill of this colour: white or black, whichever has the
  /// higher WCAG contrast against it. Follows the appearance, as the lavender fill does.
  static func foreground(on color: NSColor) -> NSColor {
    NSColor(name: nil) { appearance in
      let name = appearance.bestMatch(from: [.darkAqua, .aqua]) ?? .aqua
      let rgb = resolved(color, appearance: name)
      return prefersWhite(rgb.r, rgb.g, rgb.b) ? .white : .black
    }
  }

  /// `"white"` or `"black"`: what `foreground(on:)` gives for a colour under an appearance, for the state log.
  static func foregroundName(on color: NSColor, appearance: NSAppearance.Name = .aqua) -> String {
    let rgb = resolved(color, appearance: appearance)
    return prefersWhite(rgb.r, rgb.g, rgb.b) ? "white" : "black"
  }
}
