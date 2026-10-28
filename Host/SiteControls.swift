import AppKit

/// The site controls panel under the address bar's sliders button, as in Dia: quick actions (share, copy link,
/// find, cast), the extensions as tiles with a "+" for the Web Store, the site's permissions, and a footer with the
/// connection's state and a "…" menu. The site is the tab's committed origin as the engine reports it, never
/// anything the page says. It's an in-window panel over the page's top right; a click elsewhere, Escape, a tab
/// switch or a navigation to another origin closes it.
final class SiteControlsView: NSView {
  enum Action {
    case share, copyLink, find, cast, addExtension, siteSettings, clearData, developerTools
    case runExtension(String)
  }

  struct Extension {
    let id: String
    let name: String
    let icon: NSImage?
    let enabled: Bool
  }

  static let width: CGFloat = 288
  private static let padding: CGFloat = 16
  private static let gap: CGFloat = 8
  private static let tileHeight: CGFloat = 40
  private static let rowHeight: CGFloat = 44

  var onAction: ((Action) -> Void)?
  var onClose: (() -> Void)?

  /// The site's origin (from the engine), or nil for pages without one (ray:// pages, files).
  let origin: String?
  private let profile: ArdiaCoreProfile
  private let security: String
  private let host: String
  private let zoom: Double
  private let onResetZoom: () -> Void

  private let quickTiles: [(name: String, tile: PanelTile)]
  private var extensionTiles: [(id: String, tile: PanelTile)] = []
  private var extensionIcons: [String: Bool] = [:]
  private let addTile = PanelTile(symbol: "plus", label: "Get Extensions")
  private let extensionsHeader = SiteControlsView.header("Extensions")
  private let settingsHeader = SiteControlsView.header("Settings")
  private var rows: [SettingRow] = []
  private let divider = NSBox()
  private let securityPill = SecurityPill()
  private let moreButton = PanelTile(symbol: "ellipsis", label: "More")
  private(set) var settings: [(type: String, value: String, isDefault: Bool)] = []

  init(origin: String?, url: String, profile: ArdiaCoreProfile, security: String, isInternal: Bool, extensions: [Extension],
       zoom: Double, resetZoom: @escaping () -> Void) {
    self.origin = origin
    self.profile = profile
    self.security = security
    self.zoom = zoom
    self.onResetZoom = resetZoom
    host = origin.flatMap { URLComponents(string: $0)?.host } ?? ""
    quickTiles = [
      ("share", PanelTile(symbol: "square.and.arrow.up", label: "Share")),
      ("copyLink", PanelTile(symbol: "link", label: "Copy Link")),
      ("find", PanelTile(symbol: "text.magnifyingglass", label: "Find in Page")),
      ("cast", PanelTile(symbol: "tv.badge.wifi", label: "Cast")),
    ]
    super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 100))
    wantsLayer = true
    layer?.cornerRadius = 14
    layer?.cornerCurve = .continuous
    layer?.borderWidth = 1
    layer?.shadowOpacity = 0.28
    layer?.shadowRadius = 18
    layer?.shadowOffset = CGSize(width: 0, height: -6)
    for (name, tile) in quickTiles {
      tile.onPress = { [weak self] in self?.perform(name) }
      addSubview(tile)
    }
    addSubview(extensionsHeader)
    for item in extensions {
      let tile = PanelTile(image: item.icon, label: item.name)
      tile.isEnabled = item.enabled
      tile.onPress = { [weak self] in self?.onAction?(.runExtension(item.id)) }
      extensionTiles.append((item.id, tile))
      extensionIcons[item.id] = item.icon != nil
      addSubview(tile)
    }
    addTile.onPress = { [weak self] in self?.onAction?(.addExtension) }
    addSubview(addTile)
    addSubview(settingsHeader)
    divider.boxType = .separator
    addSubview(divider)
    securityPill.show(level: security, isInternal: isInternal, host: host, url: url)
    addSubview(securityPill)
    moreButton.round = true
    moreButton.onPress = { [weak self] in self?.showMore() }
    addSubview(moreButton)
    showSettings([])
    loadSettings()
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }
  override var wantsUpdateLayer: Bool { true }
  override var mouseDownCanMoveWindow: Bool { false }
  // Swallows clicks on its padding so they never reach the page below.
  override func mouseDown(with event: NSEvent) {}

  override func updateLayer() {
    layer?.backgroundColor = PanelColors.background.cgColor
    layer?.borderColor = PanelColors.border.cgColor
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    needsDisplay = true
  }

  private func perform(_ name: String) {
    switch name {
    case "share": onAction?(.share)
    case "copyLink": onAction?(.copyLink)
    case "find": onAction?(.find)
    case "cast": onAction?(.cast)
    default: break
    }
  }

  /// For tests: presses a tile by name ("share", "copyLink", "find", "cast", "add", or an extension's id).
  func press(_ name: String) -> Bool {
    if name == "add" { addTile.onPress?(); return true }
    if let tile = quickTiles.first(where: { $0.name == name })?.tile ?? extensionTiles.first(where: { $0.id == name })?.tile,
       tile.isEnabled {
      tile.onPress?()
      return true
    }
    return false
  }

  // MARK: Permissions

  private var isWeb: Bool { origin.map { $0.hasPrefix("http://") || $0.hasPrefix("https://") } ?? false }

  private func loadSettings() {
    guard let origin, isWeb else { return }
    EngineCalls.call("ac_site_settings_get", profile: profile, args: ["origin": origin]) { [weak self] reply in
      guard let self, let list = reply?["settings"] as? [String: [String: Any]] else { return }
      let settings = Permission.order.compactMap { type -> (String, String, Bool)? in
        guard let info = list[type], let value = info["value"] as? String else { return nil }
        return (type, value, info["isDefault"] as? Bool ?? true)
      }
      self.showSettings(settings)
    }
  }

  /// Pop-ups (the one most often wanted) and every permission this site has its own setting for.
  private func showSettings(_ settings: [(type: String, value: String, isDefault: Bool)]) {
    self.settings = settings
    rows.forEach { $0.removeFromSuperview() }
    rows = []
    if zoom > 0, abs(zoom - 1) > 0.001 {
      let row = SettingRow(symbol: "plus.magnifyingglass", title: "Zoom", subtitle: "\(Int((zoom * 100).rounded()))%",
                           on: false)
      row.toolTip = "Reset to 100%"
      row.onClick = { [weak self] _ in
        self?.onResetZoom()
        self?.close()
      }
      rows.append(row)
    }
    for setting in settings where setting.type == "popups" || !setting.isDefault {
      let permission = Permission(setting.type)
      let row = SettingRow(symbol: permission.symbol, title: permission.title, subtitle: Permission.label(setting.value),
                           on: setting.value == "allow")
      row.onClick = { [weak self] row in self?.showChoices(for: setting.type, current: setting.value, from: row) }
      rows.append(row)
    }
    rows.forEach { addSubview($0) }
    settingsHeader.isHidden = rows.isEmpty
    resize()
  }

  private func showChoices(for type: String, current: String, from row: NSView) {
    let menu = NSMenu()
    var values = ["allow", "block"]
    if Permission.askable.contains(type) { values.append("ask") }
    for value in values {
      let item = NSMenuItem(title: Permission.choice(value), action: #selector(choose(_:)), keyEquivalent: "")
      item.target = self
      item.representedObject = [type, value]
      item.state = value == current ? .on : .off
      menu.addItem(item)
    }
    menu.addItem(.separator())
    let reset = NSMenuItem(title: "Reset to Default", action: #selector(choose(_:)), keyEquivalent: "")
    reset.target = self
    reset.representedObject = [type, "default"]
    menu.addItem(reset)
    menu.popUp(positioning: nil, at: NSPoint(x: 44, y: row.bounds.maxY), in: row)
  }

  @objc private func choose(_ item: NSMenuItem) {
    guard let pair = item.representedObject as? [String] else { return }
    set(pair[0], to: pair[1])
  }

  /// Sets one permission for this site (`allow`, `block`, `ask` or `default`), then shows the engine's answer.
  func set(_ type: String, to value: String, completion: (() -> Void)? = nil) {
    guard let origin, isWeb, Permission.order.contains(type) else { return }
    EngineCalls.call("ac_site_settings_set", profile: profile, args: ["origin": origin, "type": type, "value": value]) {
      [weak self] _ in
      self?.loadSettings()
      completion?()
    }
  }

  // MARK: More

  private func showMore() {
    let menu = NSMenu()
    func add(_ title: String, _ action: Selector, enabled: Bool = true) {
      let item = NSMenuItem(title: title, action: enabled ? action : nil, keyEquivalent: "")
      item.target = self
      menu.addItem(item)
    }
    if isWeb {
      add("Site Settings…", #selector(openSiteSettings))
      add("Reset Permissions", #selector(resetPermissions), enabled: settings.contains { !$0.isDefault })
      add("Clear Cookies and Site Data…", #selector(clearData))
      menu.addItem(.separator())
    }
    add("Developer Tools", #selector(developerTools))
    menu.popUp(positioning: nil, at: NSPoint(x: 0, y: moreButton.bounds.maxY + 4), in: moreButton)
  }

  @objc private func openSiteSettings() { onAction?(.siteSettings) }
  @objc private func clearData() { onAction?(.clearData) }
  @objc private func developerTools() { onAction?(.developerTools) }

  @objc private func resetPermissions() {
    guard let origin, isWeb else { return }
    EngineCalls.call("ac_site_settings_reset", profile: profile, args: ["origin": origin]) { [weak self] _ in
      self?.loadSettings()
    }
  }

  // MARK: Layout

  private func resize() {
    let height = layoutContent(apply: false)
    setFrameSize(NSSize(width: Self.width, height: height))
    needsLayout = true
  }

  override func layout() {
    super.layout()
    _ = layoutContent(apply: true)
  }

  /// Lays the content out top down and returns the height it needs.
  private func layoutContent(apply: Bool) -> CGFloat {
    let pad = Self.padding, gap = Self.gap
    let inner = Self.width - pad * 2
    let tileWidth = ((inner - gap * 3) / 4).rounded(.down)
    var y = pad
    func place(_ view: NSView, _ frame: NSRect) { if apply { view.frame = frame } }
    func grid(_ tiles: [PanelTile]) {
      for (index, tile) in tiles.enumerated() {
        let column = CGFloat(index % 4), row = CGFloat(index / 4)
        place(tile, NSRect(x: pad + column * (tileWidth + gap), y: y + row * (Self.tileHeight + gap),
                           width: tileWidth, height: Self.tileHeight))
      }
      let lines = CGFloat((tiles.count + 3) / 4)
      y += lines * Self.tileHeight + max(0, lines - 1) * gap
    }
    grid(quickTiles.map(\.tile))
    y += 18
    place(extensionsHeader, NSRect(x: pad, y: y, width: inner, height: 16))
    y += 16 + 8
    grid(extensionTiles.map(\.tile) + [addTile])
    if !rows.isEmpty {
      y += 18
      place(settingsHeader, NSRect(x: pad, y: y, width: inner, height: 16))
      y += 16 + 4
      for row in rows {
        place(row, NSRect(x: pad - 6, y: y, width: inner + 12, height: Self.rowHeight))
        y += Self.rowHeight
      }
    }
    y += 10
    place(divider, NSRect(x: pad, y: y, width: inner, height: 1))
    y += 1 + 10
    let pill = securityPill.fittingWidth
    place(securityPill, NSRect(x: pad, y: y, width: pill, height: 32))
    place(moreButton, NSRect(x: Self.width - pad - 32, y: y, width: 32, height: 32))
    y += 32 + 12
    return y
  }

  // MARK: Showing

  func animateIn() {
    guard let layer else { return }
    layer.removeAllAnimations()
    let drop = CASpringAnimation(keyPath: "transform.translation.y")
    drop.fromValue = 8
    drop.toValue = 0
    let scale = CASpringAnimation(keyPath: "transform.scale")
    scale.fromValue = 0.96
    scale.toValue = 1
    for spring in [drop, scale] {
      spring.mass = 1
      spring.stiffness = 520
      spring.damping = 32
      spring.duration = spring.settlingDuration
    }
    let fade = CABasicAnimation(keyPath: "opacity")
    fade.fromValue = 0
    fade.toValue = 1
    fade.duration = 0.14
    fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
    layer.opacity = 1
    layer.add(drop, forKey: "drop")
    layer.add(scale, forKey: "scale")
    layer.add(fade, forKey: "fade")
  }

  func close() { onClose?() }

  /// Fades out and leaves its superview.
  func dismiss() {
    guard let layer else { return removeFromSuperview() }
    let fade = CABasicAnimation(keyPath: "opacity")
    fade.fromValue = 1
    fade.toValue = 0
    let scale = CABasicAnimation(keyPath: "transform.scale")
    scale.fromValue = 1
    scale.toValue = 0.98
    let group = CAAnimationGroup()
    group.animations = [fade, scale]
    group.duration = 0.12
    group.timingFunction = CAMediaTimingFunction(name: .easeIn)
    CATransaction.begin()
    CATransaction.setCompletionBlock { [weak self] in self?.removeFromSuperview() }
    layer.opacity = 0
    layer.add(group, forKey: "leave")
    CATransaction.commit()
  }

  var state: [String: Any] {
    [
      "origin": origin ?? NSNull(),
      "security": securityPill.text,
      "tiles": quickTiles.map(\.name),
      "extensions": extensionTiles.map(\.id),
      "extensionIcons": extensionIcons,
      "settings": rows.map { ["title": $0.title, "value": $0.subtitle] },
      "frame": NSStringFromRect(frame),
    ]
  }

  private static func header(_ text: String) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.font = .systemFont(ofSize: 12, weight: .semibold)
    label.textColor = .secondaryLabelColor
    return label
  }
}

enum PanelColors {
  private static func dynamic(dark: NSColor, light: NSColor) -> NSColor {
    NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light }
  }

  static let background = dynamic(dark: NSColor(white: 0.16, alpha: 0.98), light: NSColor(white: 0.985, alpha: 0.98))
  static let border = dynamic(dark: NSColor(white: 1, alpha: 0.1), light: NSColor(white: 0, alpha: 0.09))
  static let tile = dynamic(dark: NSColor(white: 1, alpha: 0.07), light: NSColor(white: 0, alpha: 0.045))
  static let tileHover = dynamic(dark: NSColor(white: 1, alpha: 0.13), light: NSColor(white: 0, alpha: 0.085))
}

/// The engine's site permissions, as Chrome's page info names them.
private struct Permission {
  let title: String
  let symbol: String

  static let order = [
    "popups", "camera", "microphone", "location", "notifications", "sound", "autoplay", "javascript", "images",
    "clipboard", "automaticDownloads", "cookies", "midi", "sensors", "windowManagement", "localFonts",
    "idleDetection", "storageAccess", "fileSystem", "keyboardLock", "pointerLock", "cameraPanTiltZoom",
  ]
  static let askable: Set<String> = [
    "camera", "microphone", "location", "notifications", "clipboard", "automaticDownloads", "midi",
    "windowManagement", "localFonts", "idleDetection", "storageAccess", "fileSystem", "keyboardLock",
    "pointerLock", "cameraPanTiltZoom",
  ]

  init(_ type: String) {
    switch type {
    case "popups": (title, symbol) = ("Pop-ups and Redirects", "arrow.up.forward.app")
    case "camera": (title, symbol) = ("Camera", "video")
    case "microphone": (title, symbol) = ("Microphone", "mic")
    case "location": (title, symbol) = ("Location", "location")
    case "notifications": (title, symbol) = ("Notifications", "bell")
    case "sound": (title, symbol) = ("Sound", "speaker.wave.2")
    case "autoplay": (title, symbol) = ("Autoplay", "play.rectangle")
    case "javascript": (title, symbol) = ("JavaScript", "curlybraces")
    case "images": (title, symbol) = ("Images", "photo")
    case "clipboard": (title, symbol) = ("Clipboard", "doc.on.clipboard")
    case "automaticDownloads": (title, symbol) = ("Automatic Downloads", "arrow.down.circle")
    case "cookies": (title, symbol) = ("Cookies and Site Data", "circle.hexagongrid")
    case "midi": (title, symbol) = ("MIDI Devices", "pianokeys")
    case "sensors": (title, symbol) = ("Motion Sensors", "gyroscope")
    case "windowManagement": (title, symbol) = ("Window Management", "macwindow.on.rectangle")
    case "localFonts": (title, symbol) = ("Fonts", "textformat")
    case "idleDetection": (title, symbol) = ("Your Device Use", "person.badge.clock")
    case "storageAccess": (title, symbol) = ("Embedded Content", "square.on.square")
    case "fileSystem": (title, symbol) = ("File Editing", "doc.badge.gearshape")
    case "keyboardLock": (title, symbol) = ("Keyboard Lock", "keyboard")
    case "pointerLock": (title, symbol) = ("Pointer Lock", "cursorarrow")
    case "cameraPanTiltZoom": (title, symbol) = ("Camera Pan and Zoom", "camera.metering.center.weighted")
    default: (title, symbol) = (type, "slider.horizontal.3")
    }
  }

  static func label(_ value: String) -> String {
    switch value {
    case "allow": return "Allowed"
    case "block": return "Blocked"
    case "ask": return "Ask"
    default: return "Default"
    }
  }

  static func choice(_ value: String) -> String {
    switch value {
    case "allow": return "Allow"
    case "block": return "Block"
    default: return "Ask"
    }
  }
}

/// A rounded square button with a resting fill, an SF Symbol or image in the middle.
private final class PanelTile: NSView {
  var onPress: (() -> Void)?
  var isEnabled = true { didSet { imageView.alphaValue = isEnabled ? 1 : 0.35 } }
  var round = false { didSet { needsLayout = true } }
  private let imageView = NSImageView()
  private var hovered = false
  private var pressed = false

  convenience init(symbol: String, label: String) {
    self.init(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label)
      ?? NSImage(systemSymbolName: "display", accessibilityDescription: label), label: label, symbol: true)
  }

  init(image: NSImage?, label: String, symbol: Bool = false) {
    super.init(frame: .zero)
    wantsLayer = true
    layer?.cornerCurve = .continuous
    imageView.image = image ?? NSImage(systemSymbolName: "puzzlepiece.extension", accessibilityDescription: label)
    imageView.symbolConfiguration = .init(pointSize: 15, weight: .regular)
    imageView.contentTintColor = .labelColor
    imageView.imageScaling = .scaleProportionallyUpOrDown
    addSubview(imageView)
    toolTip = label
    setAccessibilityRole(.button)
    setAccessibilityLabel(label)
    addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
  }

  required init?(coder: NSCoder) { fatalError() }

  override var wantsUpdateLayer: Bool { true }
  override var mouseDownCanMoveWindow: Bool { false }

  override func updateLayer() {
    layer?.backgroundColor = (hovered && isEnabled ? PanelColors.tileHover : PanelColors.tile).cgColor
    layer?.opacity = pressed ? 0.75 : 1
  }

  override func layout() {
    super.layout()
    layer?.cornerRadius = round ? bounds.height / 2 : 10
    let isSymbol = imageView.image?.isTemplate ?? true
    let side: CGFloat = isSymbol ? 20 : 18
    imageView.frame = NSRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side)
  }

  override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
  override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }

  override func mouseDown(with event: NSEvent) {
    guard isEnabled else { return }
    pressed = true
    needsDisplay = true
  }

  override func mouseUp(with event: NSEvent) {
    guard pressed else { return }
    pressed = false
    needsDisplay = true
    if bounds.contains(convert(event.locationInWindow, from: nil)) { onPress?() }
  }
}

/// One setting: a round icon (filled with the profile's colour when it's allowed), its name and its value.
private final class SettingRow: NSView {
  var onClick: ((SettingRow) -> Void)?
  let title: String
  let subtitle: String
  private let circle = NSView()
  private let icon = NSImageView()
  private let titleLabel: NSTextField
  private let subtitleLabel: NSTextField
  private let on: Bool
  private var hovered = false

  init(symbol: String, title: String, subtitle: String, on: Bool) {
    self.title = title
    self.subtitle = subtitle
    self.on = on
    titleLabel = NSTextField(labelWithString: title)
    subtitleLabel = NSTextField(labelWithString: subtitle)
    super.init(frame: .zero)
    wantsLayer = true
    layer?.cornerRadius = 10
    layer?.cornerCurve = .continuous
    circle.wantsLayer = true
    circle.layer?.cornerRadius = 14
    icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    icon.symbolConfiguration = .init(pointSize: 12, weight: .medium)
    titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
    titleLabel.lineBreakMode = .byTruncatingTail
    subtitleLabel.font = .systemFont(ofSize: 12)
    subtitleLabel.textColor = .secondaryLabelColor
    addSubview(circle)
    circle.addSubview(icon)
    addSubview(titleLabel)
    addSubview(subtitleLabel)
    setAccessibilityRole(.button)
    setAccessibilityLabel("\(title), \(subtitle)")
    addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }
  override var wantsUpdateLayer: Bool { true }
  override var mouseDownCanMoveWindow: Bool { false }

  override func updateLayer() {
    layer?.backgroundColor = (hovered ? PanelColors.tile : .clear).cgColor
    circle.layer?.backgroundColor = (on ? ProfileColor.accent : PanelColors.tileHover).cgColor
    icon.contentTintColor = on ? .white : .labelColor
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    needsDisplay = true
  }

  override func layout() {
    super.layout()
    let mid = bounds.height / 2
    circle.frame = NSRect(x: 6, y: mid - 14, width: 28, height: 28)
    icon.frame = NSRect(x: 5, y: 5, width: 18, height: 18)
    let x: CGFloat = 44
    titleLabel.frame = NSRect(x: x, y: mid - 17, width: bounds.width - x - 6, height: 17)
    subtitleLabel.frame = NSRect(x: x, y: mid + 1, width: bounds.width - x - 6, height: 16)
  }

  override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
  override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
  override func mouseDown(with event: NSEvent) { onClick?(self) }
}

/// The footer's connection state: "Secure" with a lock, "Not Secure" in red, and so on. The host in its tooltip
/// is the engine's committed origin.
private final class SecurityPill: NSView {
  private let icon = NSImageView()
  private let label = NSTextField(labelWithString: "")
  private(set) var text = ""

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.cornerRadius = 9
    layer?.cornerCurve = .continuous
    icon.symbolConfiguration = .init(pointSize: 12, weight: .semibold)
    label.font = .systemFont(ofSize: 13, weight: .medium)
    addSubview(icon)
    addSubview(label)
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }
  override var wantsUpdateLayer: Bool { true }

  override func updateLayer() {
    layer?.backgroundColor = PanelColors.tile.cgColor
  }

  func show(level: String, isInternal: Bool, host: String, url: String) {
    let symbol: String, tint: NSColor, tip: String
    switch (level, ConnectionLook.of(level: level, url: url)) {
    case ("secure", _):
      (text, symbol, tint) = ("Secure", "lock.fill", .labelColor)
      tip = "Your connection to \(host) is secure."
    case (_, .local):
      (text, symbol, tint) = ("Local", "laptopcomputer", .labelColor)
      tip = "\(host) is one of your own development sites."
    case (_, .partly):
      (text, symbol, tint) = ("Partly Secure", "lock.trianglebadge.exclamationmark.fill", .systemOrange)
      tip = "Parts of this page on \(host) aren't secure."
    case (_, .broken):
      (text, symbol, tint) = ("Not Secure", "lock.slash.fill", .systemRed)
      tip = "The certificate for \(host) isn't valid."
    case (_, .open):
      (text, symbol, tint) = ("Not Secure", "lock.open.fill", .secondaryLabelColor)
      tip = "Your connection to \(host) isn't encrypted."
    case ("local", _):
      (text, symbol, tint) = ("File", "doc", .labelColor)
      tip = "This page is a file on your Mac."
    default:
      (text, symbol, tint) = isInternal ? ("Ray", "sun.horizon.fill", .labelColor) : ("Page", "info.circle", .labelColor)
      tip = isInternal ? "This is one of Ray's own pages." : ""
    }
    icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    icon.contentTintColor = tint
    label.stringValue = text
    label.textColor = tint
    toolTip = tip.isEmpty ? nil : tip
    needsLayout = true
  }

  var fittingWidth: CGFloat {
    10 + 16 + 6 + ceil(label.intrinsicContentSize.width) + 12
  }

  override func layout() {
    super.layout()
    let mid = bounds.height / 2
    icon.frame = NSRect(x: 10, y: mid - 8, width: 16, height: 16)
    label.frame = NSRect(x: 32, y: mid - 9, width: bounds.width - 32 - 8, height: 18)
  }
}
