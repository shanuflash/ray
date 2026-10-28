import AppKit

/// The browser profile's colour. Every accent in Ray's own UI takes it: the loading wash, progress, drop targets,
/// the command bar's selection, "on" states. Profiles and their settings don't exist yet, so every window has the
/// default, the lavender of Dia's loading wash. Ray's UI never uses `NSColor.controlAccentColor` (scripts/test.sh
/// fails on it).
enum ProfileColor {
  /// The default profile's colour: Dia's lavender, a little lighter on dark backgrounds so it reads the same.
  static let lavender = NSColor(name: nil) {
    $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
      ? NSColor(srgbRed: 0xA4 / 255.0, green: 0x86 / 255.0, blue: 0xF0 / 255.0, alpha: 1)
      : NSColor(srgbRed: 0x82 / 255.0, green: 0x57 / 255.0, blue: 0xE5 / 255.0, alpha: 1)
  }

  static var accent: NSColor = lavender

  static var isDefault: Bool { accent === lavender }
}
