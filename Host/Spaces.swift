import AppKit

/// One of Arc's Spaces: a name, an icon, a theme (a Window colour for the browser and an Accent) and a profile, with
/// its own pinned tabs, folders and Today. Favorites belong to the profile, so Spaces on one profile share them
/// (`SidebarState.favorites`). Saved in Sidebar.json's `spaces`.
final class Space: Codable {
  static let firstName = "Personal"
  static let nameLimit = 40

  let id: UUID
  var name: String
  /// An emoji or "sf:<symbol>"; nil shows a dot in the Space's colour.
  var icon: String?
  /// The browser's colour for this Space (`#RRGGBB`): the sidebar and the window around the page. Nil is Ray's own.
  var color: String?
  /// The accent (`#RRGGBB`) every accent of Ray's takes while the Space shows. Nil is the profile colour (Settings ›
  /// Appearance).
  var accent: String?
  /// The engine profile its pages load in (a directory name under the data dir); nil is the default profile.
  var profile: String?
  /// Light or dark for the window while the Space shows ("light", "dark"); nil follows Ray's setting.
  var mode: String?
  /// How strongly the Window colour washes the sidebar (0.1–0.85); nil is `SpaceLook.defaultStrength`.
  var strength: Double?
  var pinned: [SidebarEntry] = []
  var today: [SidebarEntry] = []
  /// The tab it shows when you come back to it.
  var activeEntryID: UUID?

  init(name: String, id: UUID = UUID()) {
    self.id = id
    self.name = name
  }

  private enum CodingKeys: String, CodingKey {
    case id, name, icon, color, accent, profile, mode, strength, pinned, today, activeEntryID
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(UUID.self, forKey: .id)
    name = Self.name(from: try c.decodeIfPresent(String.self, forKey: .name) ?? "") ?? Self.firstName
    icon = try c.decodeIfPresent(String.self, forKey: .icon).flatMap(Self.validIcon)
    color = try c.decodeIfPresent(String.self, forKey: .color).flatMap(Self.validHex)
    accent = try c.decodeIfPresent(String.self, forKey: .accent).flatMap(Self.validHex)
    profile = try c.decodeIfPresent(String.self, forKey: .profile).flatMap(Self.validProfile)
    mode = try c.decodeIfPresent(String.self, forKey: .mode).flatMap { ["light", "dark"].contains($0) ? $0 : nil }
    strength = try c.decodeIfPresent(Double.self, forKey: .strength).map { min(max($0, 0.1), 0.85) }
    pinned = try c.decodeIfPresent([SidebarEntry].self, forKey: .pinned) ?? []
    today = try c.decodeIfPresent([SidebarEntry].self, forKey: .today) ?? []
    activeEntryID = try c.decodeIfPresent(UUID.self, forKey: .activeEntryID)
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(id, forKey: .id)
    try c.encode(name, forKey: .name)
    try c.encodeIfPresent(icon, forKey: .icon)
    try c.encodeIfPresent(color, forKey: .color)
    try c.encodeIfPresent(accent, forKey: .accent)
    try c.encodeIfPresent(profile, forKey: .profile)
    try c.encodeIfPresent(mode, forKey: .mode)
    try c.encodeIfPresent(strength, forKey: .strength)
    try c.encode(pinned, forKey: .pinned)
    try c.encode(today, forKey: .today)
    try c.encodeIfPresent(activeEntryID, forKey: .activeEntryID)
  }

  // MARK: Checked values

  /// A name as typed: one plain line, trimmed, at most `nameLimit` characters; nil when nothing is left.
  static func name(from text: String) -> String? {
    SidebarEntry.name(from: text).map { String($0.prefix(nameLimit)) }
  }

  static func validHex(_ text: String) -> String? {
    ProfileColor.parse(text.uppercased()) != nil ? text.uppercased() : nil
  }

  /// "sf:<symbol>" with a plain symbol name, or a short emoji (one grapheme).
  static func validIcon(_ text: String) -> String? {
    if text.hasPrefix("sf:") {
      let name = text.dropFirst(3)
      return !name.isEmpty && name.count <= 60 && name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." }) ? text : nil
    }
    return text.count == 1 && text.unicodeScalars.contains { $0.properties.isEmoji && $0.value > 0x7F } ? text : nil
  }

  /// Profile directories Ray makes: "Space <uuid>" (letters, digits, space, dash). Never a path.
  static func validProfile(_ text: String) -> String? {
    guard text.hasPrefix("Space "), text.count <= 64, text != "Default" else { return nil }
    return text.allSatisfy { $0.isLetter || $0.isNumber || $0 == " " || $0 == "-" } ? text : nil
  }

  static func newProfileDirectory() -> String { "Space \(UUID().uuidString)" }
}

/// The Space themes' presets: Arc-like colours, each a Window colour and its Accent.
enum SpaceTheme {
  static let windows: [String] = ["#8257E5", "#2F6BEA", "#12A594", "#3EA64A", "#F2B01E", "#F0654A", "#E5589D", "#6B7280"]
  static let accents: [String] = ["#8257E5", "#2F6BEA", "#12A594", "#3EA64A", "#E0A100", "#F0654A", "#E5589D", "#6B7280"]
  static let icons: [String] = ["🌱", "💼", "🎨", "🏠", "📚", "🎧", "✈️", "🧪", "💡", "🛒", "🎮", "⭐", "🔥", "🌙", "☕️", "🎯",
                                "sf:star.fill", "sf:heart.fill", "sf:bolt.fill", "sf:leaf.fill", "sf:briefcase.fill",
                                "sf:house.fill", "sf:book.fill", "sf:gamecontroller.fill"]
}

/// What a Space's theme does to Ray's colours. The window colour is a wash over Ray's own sidebar colour, strong
/// enough to read as the Space's and light enough that the sidebar's text keeps its contrast, as Arc's themes; the
/// accent stands in for the profile colour while the Space shows. One normal window, so these are app-wide.
enum SpaceLook {
  /// Posted after the shown Space's theme changed (a switch, an edit).
  static let didChange = Notification.Name("RaySpaceLookDidChange")
  private static var window: NSColor?
  private(set) static var windowHex: String?
  private static var windowStrength: Double?
  static let defaultStrength = 0.30

  /// The window's colour now: the Space's wash, or Ray's own.
  static var background: NSColor { window ?? SidebarColors.background }

  static func apply(_ space: Space?, privateWindow: Bool = false) {
    let hex = privateWindow ? nil : space?.color
    let strength = space?.strength
    if hex != windowHex || strength != windowStrength {
      windowHex = hex
      windowStrength = strength
      window = hex.map { windowColor($0, strength: strength) }
    }
    ProfileColor.override(hex: privateWindow ? nil : space?.accent)
    NotificationCenter.default.post(name: didChange, object: nil)
  }
}

extension SpaceLook {
  /// The window's colour for a Window colour (nil: Ray's own).
  static func windowColor(_ hex: String?, strength: Double? = nil) -> NSColor {
    guard let rgb = hex.flatMap(ProfileColor.parse) else { return SidebarColors.background }
    let tint = NSColor(srgbRed: rgb.r, green: rgb.g, blue: rgb.b, alpha: 1)
    let light = CGFloat(strength ?? defaultStrength)
    return ProfileColor.mix(tint, over: SidebarColors.background, light, dark: light * 0.8)
  }

  /// Part way from one resolved colour to another, in sRGB.
  static func blend(_ a: CGColor, _ b: CGColor, _ t: CGFloat) -> CGColor? {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let x = a.converted(to: space, intent: .defaultIntent, options: nil)?.components,
          let y = b.converted(to: space, intent: .defaultIntent, options: nil)?.components, x.count >= 3, y.count >= 3
    else { return nil }
    let k = min(max(t, 0), 1)
    return CGColor(srgbRed: x[0] + (y[0] - x[0]) * k, green: x[1] + (y[1] - x[1]) * k, blue: x[2] + (y[2] - x[2]) * k,
                   alpha: 1)
  }
}

/// The window's colour under everything (a layer colour, so it's resolved again when the appearance changes).
final class ThemeBackdropView: NSView {
  var onAppearance: (() -> Void)?

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    onAppearance?()
  }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A Space's icon as an image for the footer and menus: its emoji, its symbol, or a dot in its colour.
enum SpaceIcon {
  static func image(for space: Space, size: CGFloat = 14) -> NSImage {
    if let icon = space.icon, icon.hasPrefix("sf:"),
       let symbol = NSImage(systemSymbolName: String(icon.dropFirst(3)), accessibilityDescription: space.name) {
      let config = NSImage.SymbolConfiguration(pointSize: size - 1, weight: .semibold)
      let image = symbol.withSymbolConfiguration(config) ?? symbol
      image.isTemplate = true
      return image
    }
    if let icon = space.icon {
      return NSImage(size: NSSize(width: size + 4, height: size + 4), flipped: false) { rect in
        let font = NSFont.systemFont(ofSize: size - 1)
        let text = NSAttributedString(string: icon, attributes: [.font: font])
        let bounds = text.size()
        text.draw(at: NSPoint(x: rect.midX - bounds.width / 2, y: rect.midY - bounds.height / 2))
        return true
      }
    }
    let color = (space.accent ?? space.color).flatMap(ProfileColor.parse)
      .map { NSColor(srgbRed: $0.r, green: $0.g, blue: $0.b, alpha: 1) } ?? NSColor.secondaryLabelColor
    return NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
      color.setFill()
      NSBezierPath(ovalIn: rect.insetBy(dx: rect.width * 0.28, dy: rect.height * 0.28)).fill()
      return true
    }
  }

  /// The icon as text for a menu title: the emoji, else nothing.
  static func prefix(for space: Space) -> String {
    guard let icon = space.icon, !icon.hasPrefix("sf:") else { return "" }
    return icon + " "
  }
}

/// One of another browser's Spaces (Arc's, Zen's) as the importer read it: it becomes a Space of Ray's.
struct ImportedSpace {
  let name: String
  /// An emoji, or an SF Symbol's name.
  let icon: String?
  /// `#RRGGBB`: the theme's mid tone (Arc's `primaryColorPalette.midTone`), the Window colour when it has no gradient.
  let color: String?
  /// The theme's own colours (Arc's gradient base colours), the first one Ray's Window colour. Arc's gradient,
  /// intensity, grain and light or dark mode have no place in Ray's theme yet.
  var colors: [String] = []
  let pinned: [ArcImport.Node]
  let today: [ArcImport.Node]

  /// Ray's icon for it: the emoji, or "sf:<symbol>" when macOS has that symbol.
  var rayIcon: String? {
    guard let icon, !icon.isEmpty else { return nil }
    if let emoji = Space.validIcon(icon) { return emoji }
    // Arc's named icons ("bulb", "flash") through Open Arc's table; else a name that is an SF Symbol already.
    let symbol = ArcIconNames.symbols[icon] ?? icon
    guard NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil else { return nil }
    return Space.validIcon("sf:" + symbol)
  }
}

/// A profile as Ray shows it (Settings › Spaces' Profiles, the editor's Profile pop-up, the data panes' chooser): its
/// engine directory (nil for the default one), a name and a colour. The engine knows profiles only by directory; this
/// is Ray's own, saved in Sidebar.json's `profiles`.
struct ProfileInfo: Codable, Equatable {
  var directory: String?
  var name: String
  /// `#RRGGBB`, the profile's avatar; nil is grey.
  var color: String?
  /// Where an imported profile came from ("arc:Profile 1"), so importing it again finds the same one.
  var source: String?

  static let defaultName = "Default"
  static let nameLimit = 40

  static func name(from text: String) -> String? {
    SidebarEntry.name(from: text).map { String($0.prefix(nameLimit)) }
  }

  /// The avatar: the name's first letter on the profile's colour.
  static func avatar(_ info: ProfileInfo, size: CGFloat = 18) -> NSImage {
    // No colour of its own: lavender, as the swatch row's first (nil) choice says.
    let fill = info.color.flatMap(ProfileColor.parse).map { NSColor(srgbRed: $0.r, green: $0.g, blue: $0.b, alpha: 1) }
      ?? ProfileColor.lavender
    let letter = String(info.name.first.map(String.init) ?? "·").uppercased()
    return NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
      fill.setFill()
      NSBezierPath(ovalIn: rect).fill()
      let text = NSAttributedString(string: letter, attributes: [
        .font: NSFont.systemFont(ofSize: size * 0.55, weight: .bold), .foregroundColor: ProfileColor.foreground(on: fill),
      ])
      let bounds = text.size()
      text.draw(at: NSPoint(x: rect.midX - bounds.width / 2, y: rect.midY - bounds.height / 2))
      return true
    }
  }
}
