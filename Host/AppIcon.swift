import AppKit

// Ray's app icon: the Neon CRT mark (owner's pick, docs/mocks/logo-scanline.html) and the alternates the user can
// choose in Settings › Appearance › App icon (layout B of docs/mocks/app-icons.html: the styles and themes as cards,
// then a colour row when Colour is chosen). The default is the bundle's own icon (Branding/Ray.icon, built by actool,
// so macOS 26's Dark, Clear and Tinted looks work); an alternate is a PNG that scripts/build-app.sh exports from
// Branding/alternates/<name>.icon into Contents/Resources/AppIcons.
//
// How the choice sticks (Ardia's, Circa's and Crest's way): while Ray runs, `NSApp.applicationIconImage`; the choice is
// also the app's own preference `appIcon` (an icon's name), and the Dock tile plug-in (DockTile/, built into
// Contents/PlugIns) draws it while Ray isn't running. The signed bundle is never written, so Finder and Launchpad keep
// the default icon (docs/MISSING.md). Reapplied at every launch (Sparkle replaces the app), and a notice named after
// the bundle id tells a running plug-in about a change.

enum AppIconSet {
  /// The icon cards of Settings, in order: the styles, then the themes; `colour` follows.
  static let styles: [(name: String, title: String)] = [
    ("crt", "Neon CRT"), ("phosphor", "Phosphor"), ("amber", "Amber"), ("ice", "Ice"), ("vapor", "Vaporwave"),
    ("paper", "Paper"), ("mono", "Mono"), ("glass", "Clear"), ("classic", "Classic"),
    ("vice", "Vice Nights"), ("blocks", "Blocks"), ("beach", "Beach"), ("christmas", "Christmas"),
    ("halloween", "Halloween"), ("space", "Deep Space"), ("sakura", "Sakura"),
  ]
  /// The colour row: the profile colours Settings › Theme offers, lavender first (`space-<name>` icons).
  static let colours: [(name: String, title: String, hex: String)] = [
    ("lavender", "Lavender", "#8257E5"), ("blue", "Blue", "#2F6BEA"), ("teal", "Teal", "#12A594"),
    ("green", "Green", "#3EA64A"), ("amber", "Amber", "#F2B01E"), ("coral", "Coral", "#F0654A"),
    ("pink", "Pink", "#E5589D"), ("graphite", "Graphite", "#6B7280"),
  ]
  /// The setting's value for "the colour icon that matches the theme colour".
  static let matching = "colour"
  static let fallback = "crt"

  /// Every icon file's name: what scripts/build-app.sh exports and the check looks for.
  static var allNames: [String] { styles.map(\.name) + colours.map { "space-\($0.name)" } }

  /// The setting's validation: an icon's name or `colour`; the old unbuilt row's `default` is the Neon CRT.
  static func validated(_ value: String) -> String? {
    if value == "default" { return fallback }
    return value == matching || allNames.contains(value) ? value : nil
  }

  /// The icon a setting value shows: itself, or for `colour` the one nearest the theme colour.
  static func resolve(_ value: String) -> String {
    guard value == matching else { return value }
    let mine = rgb(ProfileColor.customHex ?? colours[0].hex)
    let nearest = colours.min { distance(rgb($0.hex), mine) < distance(rgb($1.hex), mine) }
    return "space-\(nearest?.name ?? "lavender")"
  }

  private static func rgb(_ hex: String) -> (Double, Double, Double) {
    let value = UInt32(hex.dropFirst(), radix: 16) ?? 0
    return (Double((value >> 16) & 0xFF), Double((value >> 8) & 0xFF), Double(value & 0xFF))
  }

  private static func distance(_ a: (Double, Double, Double), _ b: (Double, Double, Double)) -> Double {
    (a.0 - b.0) * (a.0 - b.0) + (a.1 - b.1) * (a.1 - b.1) + (a.2 - b.2) * (a.2 - b.2)
  }

  /// An icon's artwork (the exported PNG), nil when the build left it out.
  static func artwork(_ name: String) -> NSImage? {
    guard let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "AppIcons") else { return nil }
    return NSImage(contentsOf: url)
  }

  // MARK: Applying

  private static var observation: SettingsObservation?
  private static var colourObserver: NSObjectProtocol?
  private static var lastResolved: String?
  private static var applied = "bundle"
  private static var posts = 0

  private static var domain: String { Bundle.main.bundleIdentifier ?? "dev.shanus.ray" }

  /// At launch and on every change of the setting (and of the theme colour while it's `colour`).
  static func start() {
    apply()
    observation = RaySettings.shared.observe(.appIcon) { _ in apply() }
    colourObserver = NotificationCenter.default.addObserver(forName: ProfileColor.didChange, object: nil, queue: .main) { _ in
      if RaySettings.shared[.appIcon] == matching { apply() }
    }
  }

  private static func apply() {
    let name = resolve(RaySettings.shared[.appIcon])
    if name == fallback {
      NSApp.applicationIconImage = nil
      applied = "bundle"
    } else if let artwork = artwork(name) {
      NSApp.applicationIconImage = AppIconCanvas.dockImage(artwork: artwork)
      applied = name
    } else {
      NSApp.applicationIconImage = nil
      applied = "bundle"
    }
    // The plug-in's copy of the choice (the app's own preference domain) and its notice.
    CFPreferencesSetAppValue("appIcon" as CFString, name as CFString, domain as CFString)
    CFPreferencesAppSynchronize(domain as CFString)
    if name != lastResolved {
      lastResolved = name
      posts += 1
      DistributedNotificationCenter.default().postNotificationName(
        Notification.Name("\(domain).appIconChanged"), object: nil, userInfo: ["icon": name], deliverImmediately: true)
    }
  }

  /// For the state log (`looks.appIcon`): what's chosen, what shows, and what the plug-in would read.
  static var debug: [String: Any] {
    let chosen = RaySettings.shared[.appIcon]
    let plugIn = Bundle.main.builtInPlugInsURL?.appendingPathComponent("RayDockTile.docktileplugin")
    return [
      "chosen": chosen, "resolved": resolve(chosen), "applied": applied, "posts": posts,
      "prefs": CFPreferencesCopyAppValue("appIcon" as CFString, domain as CFString) as? String ?? "",
      "artwork": artwork(resolve(chosen)) != nil,
      "files": allNames.filter { artwork($0) != nil }.count,
      "plugIn": plugIn.map { FileManager.default.fileExists(atPath: $0.path) } ?? false,
      "plugInKey": Bundle.main.object(forInfoDictionaryKey: "NSDockTilePlugIn") as? String ?? "",
    ]
  }

  // MARK: Test

  /// `appicon state|press <value>|colour <name|match>` (the pane's own controls: `settings open appearance` first).
  static func test(_ argument: String) -> String {
    let words = argument.split(separator: " ").map(String.init)
    var state = debug
    if let control = AppIconControl.current { state["control"] = control.debug }
    let json = { (value: Any) -> String in
      (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? "null"
    }
    switch words.first {
    case "state": return json(state)
    case "press":
      guard words.count == 2, let control = AppIconControl.current else { return "no pane" }
      return control.press(words[1]) ? "ok" : "no such card"
    case "colour":
      guard words.count == 2, let control = AppIconControl.current else { return "no pane" }
      return control.pressColour(words[1]) ? "ok" : "no such colour"
    default: return "usage: appicon state|press <value>|colour <name|match>"
    }
  }
}

// MARK: Settings control

/// Settings › Appearance › App icon, layout B: the styles and themes as picture cards, four to a row, then Colour; when
/// Colour is chosen, one more line, "Icon colour", with a swatch for each profile colour and the first for the one that
/// follows the theme colour. Pictures are the icon at 56 pt on the card band (`PictureCard`, as every picture choice).
final class AppIconControl: NSView, SettingsWideControl {
  static weak var current: AppIconControl?
  private static let columns = 4
  private static let rowGap: CGFloat = 8
  /// The colour line: a hairline, 14 pt, the swatches' 28 pt.
  private static let colourBlock: CGFloat = 1 + 14 + 28 + 2

  private var cards: [PictureCard] = []
  private var pictures: [String: IconPicture] = [:]
  private let line = Hairline()
  private let colourLabel = settingsLabel("Icon colour", size: 13)
  private var swatches: [IconSwatch] = []
  private var observation: SettingsObservation?
  private var colourObserver: NSObjectProtocol?
  private var showsColours = false

  override init(frame: NSRect) {
    super.init(frame: frame)
    let choices = AppIconSet.styles.map { SettingChoice(title: $0.title, value: $0.name) }
      + [SettingChoice(title: "Colour", value: AppIconSet.matching)]
    for choice in choices {
      let picture = IconPicture()
      pictures[choice.value] = picture
      let card = PictureCard(choice: choice, picture: picture)
      card.onClick = { [weak self] in self?.choose(card: choice.value) }
      cards.append(card)
      addSubview(card)
    }
    addSubview(line)
    addSubview(colourLabel)
    let entries: [(String, String, String?)] = [(AppIconSet.matching, "Match theme colour", nil)]
      + AppIconSet.colours.map { ("space-\($0.name)", $0.title, $0.hex) }
    for (value, name, hex) in entries {
      let swatch = IconSwatch(value: value, name: name, hex: hex)
      swatch.onClick = { _ = RaySettings.shared.set(.appIcon, value) }
      swatches.append(swatch)
      addSubview(swatch)
    }
    setAccessibilityRole(.group)
    setAccessibilityLabel("App icon")
    AppIconControl.current = self
    observation = RaySettings.shared.observe(.appIcon) { [weak self] _ in self?.refresh() }
    colourObserver = NotificationCenter.default.addObserver(forName: ProfileColor.didChange, object: nil, queue: .main) { [weak self] _ in
      self?.refresh()
    }
    refresh()
  }

  required init?(coder: NSCoder) { fatalError() }

  deinit { if let colourObserver { NotificationCenter.default.removeObserver(colourObserver) } }

  override var isFlipped: Bool { true }

  /// The card a setting value belongs to: every colour's is Colour.
  private func card(for value: String) -> String {
    value == AppIconSet.matching || value.hasPrefix("space-") ? AppIconSet.matching : value
  }

  private func choose(card value: String) {
    let current = RaySettings.shared[.appIcon]
    // Colour keeps the colour already chosen.
    if value == AppIconSet.matching, card(for: current) == AppIconSet.matching { return }
    _ = RaySettings.shared.set(.appIcon, value)
  }

  private func refresh() {
    let value = RaySettings.shared[.appIcon]
    let selected = card(for: value)
    for card in cards { card.isSelected = card.value == selected }
    for (name, picture) in pictures {
      let icon = name == AppIconSet.matching
        ? (value.hasPrefix("space-") ? value : AppIconSet.resolve(AppIconSet.matching)) : name
      picture.image = AppIconSet.artwork(icon)
    }
    for swatch in swatches { swatch.isSelected = swatch.value == value }
    let shows = selected == AppIconSet.matching
    guard shows != showsColours else { return }
    showsColours = shows
    line.isHidden = !shows
    colourLabel.isHidden = !shows
    for swatch in swatches { swatch.isHidden = !shows }
    needsLayout = true
    settingsPaneChanged()
  }

  private var rows: Int { (cards.count + Self.columns - 1) / Self.columns }

  func height(forWidth width: CGFloat) -> CGFloat {
    CGFloat(rows) * PictureCard.height + CGFloat(rows - 1) * Self.rowGap + (showsColours ? Self.colourBlock + 4 : 0)
  }

  override func layout() {
    super.layout()
    let cell = (bounds.width / CGFloat(Self.columns)).rounded(.down)
    for (index, card) in cards.enumerated() {
      card.frame = NSRect(x: CGFloat(index % Self.columns) * cell, y: CGFloat(index / Self.columns) * (PictureCard.height + Self.rowGap),
                          width: PictureChoiceControl.pictureSize.width + 8, height: PictureCard.height)
    }
    guard showsColours else { return }
    let top = CGFloat(rows) * (PictureCard.height + Self.rowGap) + 2
    line.frame = NSRect(x: 0, y: top, width: bounds.width, height: 1)
    let label = colourLabel.intrinsicContentSize
    colourLabel.frame = NSRect(x: 0, y: top + 15 + ((28 - label.height) / 2).rounded(), width: label.width, height: label.height)
    // Right-aligned, 24 pt swatches 5 pt apart, as Theme's row has them.
    let size: CGFloat = 24, gap: CGFloat = 5
    var x = bounds.width - CGFloat(swatches.count) * (size + gap) + gap
    for swatch in swatches {
      swatch.frame = NSRect(x: x, y: top + 15 + 2, width: size, height: size)
      x += size + gap
    }
  }

  // MARK: Tests

  func press(_ value: String) -> Bool {
    guard let card = cards.first(where: { $0.value == value }), card.onClick != nil else { return false }
    card.onClick?()
    return true
  }

  func pressColour(_ name: String) -> Bool {
    guard showsColours, let swatch = swatches.first(where: { $0.value == (name == "match" ? AppIconSet.matching : "space-\(name)") })
    else { return false }
    swatch.onClick?()
    return true
  }

  var debug: [String: Any] {
    [
      "cards": cards.map(\.value), "selected": cards.first(where: \.isSelected)?.value ?? "",
      "coloursShown": showsColours, "swatches": swatches.count,
      "colourSelected": swatches.first(where: \.isSelected)?.value ?? "",
      "pictures": pictures.filter { $0.value.image != nil }.count,
      "height": height(forWidth: 572),
    ]
  }
}

/// A card's picture: the icon at 56 pt, centred on the card band.
private final class IconPicture: NSView {
  private let imageView = NSImageView()
  var image: NSImage? {
    get { imageView.image }
    set { imageView.image = newValue }
  }

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.cornerRadius = 8
    layer?.cornerCurve = .continuous
    imageView.imageScaling = .scaleProportionallyUpOrDown
    addSubview(imageView)
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }
  override var wantsUpdateLayer: Bool { true }
  override func updateLayer() { layer?.backgroundColor = SettingsColors.band.cgColor }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func layout() {
    super.layout()
    imageView.frame = NSRect(x: ((bounds.width - 56) / 2).rounded(), y: ((bounds.height - 56) / 2).rounded(), width: 56, height: 56)
  }
}

/// A colour in the icon colour line: a 24 pt dot, ringed in the profile colour when chosen. The first, with no colour
/// of its own, is the theme colour with an inner ring.
private final class IconSwatch: NSControl {
  let value: String
  let hex: String?
  var onClick: (() -> Void)?
  var isSelected = false {
    didSet { if oldValue != isSelected { needsDisplay = true } }
  }

  init(value: String, name: String, hex: String?) {
    self.value = value
    self.hex = hex
    super.init(frame: .zero)
    toolTip = name
    setAccessibilityRole(.radioButton)
    setAccessibilityLabel(name)
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }
  override var mouseDownCanMoveWindow: Bool { false }
  override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(convert(point, from: superview)) ? self : nil }
  override func mouseDown(with event: NSEvent) { onClick?() }
  override func accessibilityPerformPress() -> Bool {
    onClick?()
    return true
  }
  override func accessibilityValue() -> Any? { NSNumber(value: isSelected ? 1 : 0) }

  override func draw(_ dirtyRect: NSRect) {
    let dot = bounds.insetBy(dx: 4, dy: 4)
    let colour = hex.flatMap { ProfileColor.parse($0) }.map { NSColor(srgbRed: $0.r, green: $0.g, blue: $0.b, alpha: 1) } ?? ProfileColor.accent
    colour.setFill()
    NSBezierPath(ovalIn: dot).fill()
    if hex == nil {
      NSColor.white.withAlphaComponent(0.9).setStroke()
      let inner = NSBezierPath(ovalIn: dot.insetBy(dx: 4, dy: 4))
      inner.lineWidth = 1.5
      inner.stroke()
    }
    if isSelected {
      SettingsColors.mark.setStroke()
      let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1))
      ring.lineWidth = 2
      ring.stroke()
    }
  }
}
