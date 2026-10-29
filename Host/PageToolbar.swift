import AppKit

protocol PageToolbarDelegate: AnyObject {
  func toolbarToggleSidebar(_ toolbar: PageToolbarView)
  func toolbarBack(_ toolbar: PageToolbarView)
  func toolbarForward(_ toolbar: PageToolbarView)
  func toolbarReload(_ toolbar: PageToolbarView)
  func toolbarStop(_ toolbar: PageToolbarView)
  func toolbarEditAddress(_ toolbar: PageToolbarView)
  func toolbarCopyLink(_ toolbar: PageToolbarView)
  func toolbarSiteControls(_ toolbar: PageToolbarView)
}

/// The address bar above the page, as in Dia: the page's address (click to edit, like ⌘L), a copy-link button and
/// the site controls (sliders) button. With the sidebar hidden, a sidebar button, back, forward and reload lead; a
/// docked sidebar has its own, so they're not repeated here. The sidebar's own address field
/// shows regardless; View › Show Address Bar on Page turns this one off.
final class PageToolbarView: NSView {
  /// Ardia's bar: 41 pt tall, 30 pt buttons centred 21.2 pt down at 21, 56, 92 and 127 pt, the address field
  /// 30 pt tall from 145 pt (8 pt in when the docked sidebar has the buttons instead).
  static let height: CGFloat = 41
  private static let buttonSize: CGFloat = 30
  private static let buttonTop: CGFloat = 6
  private static let centers: [CGFloat] = [21, 56, 92, 127]
  weak var delegate: PageToolbarDelegate?

  private let sidebarButton = PageToolbarView.button("sidebar.left", "Show Sidebar")
  private let backButton = PageToolbarView.button("chevron.left", "Back")
  private let forwardButton = PageToolbarView.button("chevron.right", "Forward")
  private let reloadButton = PageToolbarView.button("arrow.clockwise", "Reload")
  /// While the page loads the reload button is a stop button (an ✕), as in Dia and Ardia.
  private(set) var isStopping = false
  private let copyButton = PageToolbarView.button("link", "Copy Link")
  /// Opens the site controls panel, which hangs below it.
  let siteButton = PageToolbarView.button("slider.horizontal.3", "Site Controls")
  private let address = ToolbarAddressView()

  /// How far the sidebar button and back, forward and reload are in: 1 while the sidebar is hidden (peeking
  /// included, so the bar stays still as the sidebar slides over), 0 while it's docked. The window sets it from the
  /// sidebar's own spring every frame, so the buttons fade in and the address slides over as the sidebar goes.
  var navigation: CGFloat = 0 {
    didSet {
      navigation = min(1, max(0, navigation))
      if navigation != oldValue { needsLayout = true }
    }
  }
  var showsNavigation: Bool { navigation > 0.5 }

  override init(frame: NSRect) {
    super.init(frame: frame)
    for (button, action) in [
      (sidebarButton, #selector(toggleSidebar)), (backButton, #selector(back)), (forwardButton, #selector(forward)),
      (reloadButton, #selector(reload)), (copyButton, #selector(copyLink)), (siteButton, #selector(siteControls)),
    ] {
      button.target = self
      button.action = action
      addSubview(button)
    }
    for button in [sidebarButton, backButton, forwardButton, reloadButton] { button.isHidden = true }
    address.onClick = { [weak self] in
      guard let self else { return }
      self.delegate?.toolbarEditAddress(self)
    }
    addSubview(address)
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }
  override var mouseDownCanMoveWindow: Bool { true }

  func show(url: String, security: String?, canGoBack: Bool, canGoForward: Bool) {
    address.show(url: url, security: security)
    backButton.isEnabled = canGoBack
    forwardButton.isEnabled = canGoForward
    reloadButton.isEnabled = !url.isEmpty
    copyButton.isHidden = url.isEmpty
    siteButton.isHidden = url.isEmpty
    needsLayout = true
  }

  /// The active tab's load: the reload button is a stop button while it loads, and its navigation's sweep
  /// (`LoadSweeps`) is drawn in the address field. `tab` identifies the tab: another one shows its own state at
  /// once, with no animation from the old tab's width.
  func showLoading(_ loading: Bool, sweep: LoadSweeps.Sweep, progress: Double, tab: Int) {
    address.showLoading(loading, sweep: sweep, progress: progress, tab: tab)
    guard loading != isStopping else { return }
    isStopping = loading
    reloadButton.image = NSImage(
      systemSymbolName: loading ? "xmark" : "arrow.clockwise", accessibilityDescription: loading ? "Stop" : "Reload")
    reloadButton.toolTip = loading ? "Stop Loading" : "Reload"
  }

  var addressText: String { address.text }
  var showsFullAddress: Bool {
    get { address.showsFullAddress }
    set { address.showsFullAddress = newValue }
  }
  /// Settings › Show loading progress in the address bar: off, the field draws no wash (the reload button still
  /// turns into stop while the page loads).
  var showsLoadingWash: Bool {
    get { address.showsLoadingWash }
    set { address.showsLoadingWash = newValue }
  }
  /// The profile's colour changed: the wash takes it up.
  func refreshAccent() { address.refreshAccent() }
  var addressDebug: [String: Any] {
    address.debug.merging(["stopButton": isStopping]) { _, new in new }
  }

  /// For tests: the reload/stop button's own action (the button hides while the sidebar is docked).
  func pressReload() { reload() }

  /// For tests: the address field as it is on screen this moment (mid-animation too: it draws the layers'
  /// presentation), at 2x, into a PNG.
  func snapshotAddress(to path: String) -> Bool {
    guard let layer = address.layer else { return false }
    let shown = layer.presentation() ?? layer
    let size = address.bounds.size, scale: CGFloat = 2
    guard size.width > 0, size.height > 0,
          let context = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                                  bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
    // The window's own colour behind the field, as on screen.
    var background = NSColor.windowBackgroundColor.cgColor
    effectiveAppearance.performAsCurrentDrawingAppearance { background = SidebarColors.background.cgColor }
    context.setFillColor(background)
    context.fill(CGRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale))
    context.scaleBy(x: scale, y: scale)
    // The field is flipped: draw it top down.
    context.translateBy(x: 0, y: size.height)
    context.scaleBy(x: 1, y: -1)
    shown.render(in: context)
    guard let image = context.makeImage() else { return false }
    let rep = NSBitmapImageRep(cgImage: image)
    guard let png = rep.representation(using: .png, properties: [:]) else { return false }
    return (try? png.write(to: URL(fileURLWithPath: path))) != nil
  }

  @objc private func toggleSidebar() { delegate?.toolbarToggleSidebar(self) }
  @objc private func back() { delegate?.toolbarBack(self) }
  @objc private func forward() { delegate?.toolbarForward(self) }
  @objc private func reload() {
    if isStopping { delegate?.toolbarStop(self) } else { delegate?.toolbarReload(self) }
  }
  @objc private func copyLink() { delegate?.toolbarCopyLink(self) }
  @objc private func siteControls() { delegate?.toolbarSiteControls(self) }

  override func layout() {
    super.layout()
    let size = Self.buttonSize, top = Self.buttonTop
    let progress = navigation
    for (button, center) in zip([sidebarButton, backButton, forwardButton, reloadButton], Self.centers) {
      // They drift in from a little to the left as they fade, following the sidebar out.
      button.frame = NSRect(x: (center - size / 2 - 14 * (1 - progress)).rounded(), y: top, width: size, height: size)
      button.alphaValue = progress * progress
      button.isHidden = progress < 0.01
    }
    let left = (8 + (145 - 8) * progress).rounded()
    siteButton.frame = NSRect(x: bounds.width - 8 - size, y: top, width: size, height: size)
    copyButton.frame = NSRect(x: siteButton.frame.minX - size + 2, y: top, width: size, height: size)
    let right = copyButton.isHidden ? bounds.width - 12 : copyButton.frame.minX - 4
    address.frame = NSRect(x: left, y: top, width: max(0, right - left), height: size)
  }

  private static func button(_ symbol: String, _ label: String) -> HoverIconButton {
    let button = HoverIconButton()
    button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
    button.symbolConfiguration = .init(pointSize: 13, weight: .medium)
    button.isBordered = false
    button.bezelStyle = .regularSquare
    button.imagePosition = .imageOnly
    button.contentTintColor = .secondaryLabelColor
    button.refusesFirstResponder = true
    button.toolTip = label
    return button
  }
}

/// The page's address in the toolbar: host and path (never the page's own words), with the not-secure mark when it
/// applies; a click opens the command bar on it.
private final class ToolbarAddressView: NSView {
  var onClick: (() -> Void)?
  private let label = NSTextField(labelWithString: "")
  private let securityIcon = NSImageView()
  private var hovered = false
  private(set) var text = ""
  private(set) var look = ConnectionLook.quiet
  private let wash = LoadingWash()

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.cornerRadius = 8
    layer?.cornerCurve = .continuous
    // Under the label and icon, above the hover fill.
    layer?.insertSublayer(wash.host, at: 0)
    label.lineBreakMode = .byTruncatingTail
    securityIcon.symbolConfiguration = .init(pointSize: 12, weight: .medium)
    securityIcon.isHidden = true
    addSubview(securityIcon)
    addSubview(label)
    addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }
  override var wantsUpdateLayer: Bool { true }
  override var mouseDownCanMoveWindow: Bool { false }

  override func updateLayer() {
    layer?.backgroundColor = (hovered ? SidebarColors.hover : .clear).cgColor
  }

  override func mouseEntered(with event: NSEvent) {
    hovered = true
    needsDisplay = true
    render()
  }

  override func mouseExited(with event: NSEvent) {
    hovered = false
    needsDisplay = true
    render()
  }

  private var parts = (host: "", trail: "")

  /// View › Show Full Address (on unless turned off): the path and query after the host, in grey. Off, they show
  /// only while hovered, as in Dia.
  var showsFullAddress = true {
    didSet { if oldValue != showsFullAddress { render() } }
  }

  /// The host in medium weight, as Ardia and Dia show it, then the rest of the address in grey. The host always
  /// comes first and a long address loses its end, never the host.
  private func render() {
    let font = NSFont.systemFont(ofSize: 13)
    let shown = NSMutableAttributedString(string: parts.host, attributes: [
      .font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.labelColor,
    ])
    if hovered || showsFullAddress, !parts.trail.isEmpty {
      shown.append(NSAttributedString(string: parts.trail, attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]))
    }
    let style = NSMutableParagraphStyle()
    style.lineBreakMode = .byTruncatingTail
    shown.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: shown.length))
    label.attributedStringValue = shown
  }

  override func mouseDown(with event: NSEvent) { onClick?() }

  var debug: [String: Any] {
    layoutSubtreeIfNeeded()
    return [
      "look": "\(look)", "icon": !securityIcon.isHidden, "textOffset": label.frame.midY - bounds.midY,
      "shown": label.attributedStringValue.string,
      "loading": wash.loading, "progress": wash.progress, "wash": wash.active, "washFinishing": wash.finishing,
      "washFraction": wash.fraction, "washColor": wash.lineColor,
      "progressSteps": wash.steps, "sweeps": wash.sweeps,
    ]
  }

  /// Settings › Show loading progress in the address bar. Turning it off mid-load ends the wash like a finished load.
  var showsLoadingWash = true {
    didSet {
      if oldValue != showsLoadingWash {
        showLoading(lastLoad.loading, sweep: lastLoad.sweep, progress: lastLoad.progress, tab: lastLoad.tab)
      }
    }
  }
  private var lastLoad = (loading: false, sweep: LoadSweeps.Sweep(), progress: 0.0, tab: -1)

  func showLoading(_ loading: Bool, sweep: LoadSweeps.Sweep, progress: Double, tab: Int) {
    lastLoad = (loading, sweep, progress, tab)
    var shown = sweep
    shown.running = sweep.running && showsLoadingWash
    wash.update(loading: loading, sweep: shown, progress: progress, tab: tab)
  }

  func refreshAccent() { wash.applyTint(for: effectiveAppearance) }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    wash.applyTint(for: effectiveAppearance)
  }

  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    needsLayout = true
  }

  func show(url: String, security: String?) {
    parts = Self.parts(for: url)
    text = parts.host + parts.trail
    render()
    let look = ConnectionLook.of(level: security, url: url)
    securityIcon.image = look.symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: look.label) }
    securityIcon.contentTintColor = look.tint
    securityIcon.isHidden = text.isEmpty || look.symbol == nil
    self.look = look
    needsLayout = true
  }

  /// Host (without www.) and the path and query, as Dia shows it; built-in pages as ray://. The path stays
  /// percent-encoded, so lookalike characters can't pass for something else.
  static func parts(for url: String) -> (host: String, trail: String) {
    guard !url.isEmpty else { return ("", "") }
    let shown = AddressInput.display(for: url)
    guard let components = URLComponents(string: shown), let host = components.host, !host.isEmpty else {
      return (AddressInput.pillText(for: url), "")
    }
    if components.scheme == AddressInput.internalScheme { return (shown, "") }
    let bareHost = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    let port = components.port.map { ":\($0)" } ?? ""
    let path = components.percentEncodedPath == "/" ? "" : components.percentEncodedPath
    let query = components.percentEncodedQuery.map { "?\($0)" } ?? ""
    return (bareHost + port, path.isEmpty && !query.isEmpty ? "/" + query : path + query)
  }

  override func layout() {
    super.layout()
    wash.layout(in: bounds, scale: window?.backingScaleFactor ?? 2, appearance: effectiveAppearance)
    let mid = bounds.height / 2
    // Ardia's lock: 7 pt in, 18 wide, the text 3 pt after it.
    securityIcon.frame = NSRect(x: 7, y: (mid - 9).rounded(), width: 18, height: 18)
    let x: CGFloat = securityIcon.isHidden ? 8 : 28
    // One line tall, so the text sits on the middle (a label draws from its frame's top).
    let line = ceil(label.intrinsicContentSize.height)
    label.frame = NSRect(x: x, y: (mid - line / 2).rounded(), width: max(0, bounds.width - x - 8), height: line)
  }
}

/// The colours of the loading wash and its line, from the profile's colour (`ProfileColor`). The default profile
/// gets Dia's, measured on white. Dia's isn't one colour: it ramps from a pale pink lilac at the
/// trailing end to a deeper blue-violet lavender at the leading edge (line #F5D0FF → #9366C5, the wash's bottom
/// #F1E4F9 → #D3C5E8), and the ramp travels with the leading edge. The wash is about a sixth as strong at the
/// field's top as at its bottom.
struct LoadingTint {
  /// Trailing end to leading edge, at the wash's full (bottom) strength.
  var wash: [NSColor]
  /// Trailing end to leading edge.
  var line: [NSColor]
  /// The wash's strength at the field's top, relative to its bottom.
  var topFade: Float

  /// Dia's own ramp for the default profile; any other colour gets one built the same way from it.
  static var current: LoadingTint { ProfileColor.isDefault ? .dia : LoadingTint(accent: ProfileColor.accent) }

  static let dia = LoadingTint(
    wash: [
      rgba(0xB0, 0x60, 0xE0, light: 0.18, dark: 0.16),
      rgba(0x90, 0x58, 0xD0, light: 0.25, dark: 0.22),
      rgba(0x7A, 0x50, 0xC0, light: 0.33, dark: 0.3),
    ],
    line: [
      rgba(0xE0, 0x70, 0xFF, light: 0.33, dark: 0.45),
      rgba(0xB0, 0x70, 0xF0, light: 0.5, dark: 0.6),
      rgba(0x6A, 0x3D, 0xB0, light: 0.65, dark: 0.8),
      rgba(0x5A, 0x2D, 0xA0, light: 0.7, dark: 0.85),
    ],
    topFade: 0.15)

  /// A ramp shaped like Dia's around another colour: the leading edge is the colour a little deepened, the trailing
  /// end paler and shifted toward pink (Dia's runs about 23° of hue from #5A2DA0 back to #E070FF).
  init(accent: NSColor) {
    var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
    var light = accent
    NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance { light = accent.usingColorSpace(.sRGB) ?? accent }
    light.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
    func stop(_ t: CGFloat, light: CGFloat, dark: CGFloat) -> NSColor {
      let shifted = (hue + 0.065 * (1 - t)).truncatingRemainder(dividingBy: 1)
      let base = NSColor(hue: shifted, saturation: saturation * (0.55 + 0.45 * t),
                         brightness: 1 - (1 - brightness * 0.7) * t, alpha: 1)
      return NSColor(name: nil) {
        base.withAlphaComponent($0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light)
      }
    }
    wash = [stop(0, light: 0.18, dark: 0.16), stop(0.5, light: 0.25, dark: 0.22), stop(1, light: 0.33, dark: 0.3)]
    line = [stop(0, light: 0.33, dark: 0.45), stop(1.0 / 3, light: 0.5, dark: 0.6), stop(2.0 / 3, light: 0.65, dark: 0.8),
            stop(1, light: 0.7, dark: 0.85)]
    topFade = 0.15
  }

  init(wash: [NSColor], line: [NSColor], topFade: Float) {
    self.wash = wash
    self.line = line
    self.topFade = topFade
  }

  /// One colour at two strengths: a light field needs less of it than a dark one to read the same.
  static func rgba(_ r: Int, _ g: Int, _ b: Int, light: CGFloat, dark: CGFloat) -> NSColor {
    let base = NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    return NSColor(name: nil) {
      base.withAlphaComponent($0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light)
    }
  }
}

/// The page-load look inside the address field, as Dia draws it (measured from a recording of Dia, dark, at 120 fps):
/// a 1 pt line along the field's bottom edge with a crisp leading end, and a glow over it that is strongest just
/// above the line and fades toward the top. Both are brightest at the leading end and fade out about one field
/// width behind it, so at full width the left end has nearly gone; a faint halo runs a little ahead of the end.
/// One sweep per navigation (`LoadSweeps`): it fades in at the left as it starts, moves right in eased steps as the
/// load's progress rises (never backwards), runs out to the full width at the end, holds a moment and fades while
/// drifting on. Switching tabs snaps to the new tab's state.
///
/// One Core Animation layer, `sweep`, whose contents are that look drawn once per size, scale and colour; a load
/// only moves it (`position.x`) and fades it (`opacity`).
private final class LoadingWash {
  /// Clips to the field's rounded rect.
  let host = CALayer()
  private let sweep = CALayer()

  /// The halo ahead of the leading end.
  static let halo: CGFloat = 48
  static let fadeInDuration: CFTimeInterval = 0.12
  static let stepDuration: CFTimeInterval = 0.3
  /// The run out to the full width, then the drift on while it fades (Dia: full width, ~0.1 s, then a 0.15 s fade).
  static let runOutDuration: CFTimeInterval = 0.3
  static let fadeDelay: CFTimeInterval = 0.38
  static let fadeDuration: CFTimeInterval = 0.15
  static let drift = 0.12

  /// The tab is loading (the state log's `loading`; the sweep can end before the tab stops).
  private(set) var loading = false
  /// The tab's progress as the engine reports it, for the state log.
  private(set) var progress = 0.0
  /// A sweep is showing: from its start until it ends.
  private(set) var active = false
  /// The run out and the fade are still going (they don't tick while the window is off screen).
  private(set) var finishing = false
  /// Where the leading end is heading, 0...1 of the field's width.
  private(set) var fraction = 0.0
  /// Distinct progress steps drawn for the last sweep.
  private(set) var steps = 0
  /// Sweeps the shown tab has started.
  private(set) var sweeps = 0
  private var tab: Int?
  private var size = CGSize.zero
  private var scale: CGFloat = 2
  private var generation = 0
  private var lineColours: [CGColor] = []

  init() {
    host.masksToBounds = true
    host.cornerRadius = 8
    host.cornerCurve = .continuous
    sweep.anchorPoint = .zero
    sweep.opacity = 0
    sweep.contentsGravity = .resize
    host.addSublayer(sweep)
  }

  private func origin(_ fraction: Double) -> CGFloat { ((CGFloat(fraction) - 1) * size.width).rounded() }
  private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

  private func quietly(_ body: () -> Void) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    body()
    CATransaction.commit()
  }

  func layout(in bounds: NSRect, scale newScale: CGFloat, appearance: NSAppearance) {
    guard size != bounds.size || scale != newScale else { return }
    size = bounds.size
    scale = newScale
    quietly {
      host.frame = bounds
      sweep.bounds = CGRect(x: 0, y: 0, width: bounds.width + Self.halo, height: bounds.height)
      sweep.contentsScale = scale
      sweep.position = CGPoint(x: origin(active || finishing ? fraction : 0), y: 0)
    }
    applyTint(for: appearance)
  }

  /// For tests: the leading end of the line, as `#RRGGBB`, so a theme change can be seen in what's drawn.
  var lineColor: String {
    guard let cg = lineColours.last, let color = NSColor(cgColor: cg) else { return "" }
    return ProfileColor.hex(of: color.withAlphaComponent(1))
  }

  func applyTint(for appearance: NSAppearance) {
    let tint = LoadingTint.current
    var colours = (wash: [CGColor](), line: [CGColor]())
    appearance.performAsCurrentDrawingAppearance {
      colours = (tint.wash.map(\.cgColor), tint.line.map(\.cgColor))
    }
    lineColours = colours.line
    guard size.width > 0, size.height > 0 else { return }
    let image = Self.draw(width: size.width, height: size.height, scale: scale, wash: colours.wash, line: colours.line)
    quietly { sweep.contents = image }
  }

  func update(loading now: Bool, sweep shown: LoadSweeps.Sweep, progress reported: Double, tab id: Int) {
    loading = now
    progress = reported
    sweeps = shown.count
    let target = min(1, max(LoadSweeps.minimum, shown.progress))
    if id != tab {
      tab = id
      snap(running: shown.running, to: target)
    } else if shown.running {
      if !active {
        begin(at: target)
      } else if target > fraction + 0.005 {
        advance(to: target)
      }
    } else if active {
      finish()
    }
  }

  private func begin(at target: Double) {
    generation += 1
    steps = 1
    fraction = target
    active = true
    finishing = false
    quietly {
      sweep.removeAllAnimations()
      sweep.opacity = 1
      sweep.position = CGPoint(x: origin(reduceMotion ? target : 0), y: 0)
    }
    guard !reduceMotion else { return }
    let fadeIn = CABasicAnimation(keyPath: "opacity")
    fadeIn.fromValue = 0
    fadeIn.toValue = 1
    fadeIn.duration = Self.fadeInDuration
    fadeIn.timingFunction = CAMediaTimingFunction(name: .easeOut)
    sweep.add(fadeIn, forKey: "fadeIn")
    // From the left edge: the presentation still shows wherever the last sweep was until this transaction commits.
    slide(to: target, from: origin(0))
  }

  private func advance(to target: Double) {
    steps += 1
    fraction = target
    slide(to: target)
  }

  /// One eased step, from wherever the sweep is drawn right now.
  private func slide(to target: Double, from start: CGFloat? = nil) {
    let to = origin(target)
    guard !reduceMotion else {
      quietly { sweep.position = CGPoint(x: to, y: 0) }
      return
    }
    let from = start ?? sweep.presentation()?.position.x ?? sweep.position.x
    quietly { sweep.position = CGPoint(x: to, y: 0) }
    let step = CABasicAnimation(keyPath: "position.x")
    step.fromValue = from
    step.toValue = to
    step.duration = Self.stepDuration
    step.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.6, 0.3, 1)
    sweep.add(step, forKey: "step")
  }

  /// Run out to the full width, hold a moment, then fade while drifting on (Reduce Motion: just the fade).
  private func finish() {
    generation += 1
    let mine = generation
    fraction = 1
    active = false
    finishing = true
    let from = sweep.presentation()?.position.x ?? sweep.position.x
    let fromOpacity = sweep.presentation()?.opacity ?? sweep.opacity
    let total = Self.fadeDelay + Self.fadeDuration
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    CATransaction.setCompletionBlock { [weak self] in
      guard let self, self.generation == mine else { return }
      self.finishing = false
      self.quietly {
        self.sweep.removeAllAnimations()
        self.sweep.position = CGPoint(x: self.origin(0), y: 0)
      }
    }
    sweep.removeAnimation(forKey: "step")
    sweep.opacity = 0
    if reduceMotion {
      sweep.position = CGPoint(x: origin(1), y: 0)
    } else {
      sweep.position = CGPoint(x: origin(1 + Self.drift), y: 0)
      let run = CAKeyframeAnimation(keyPath: "position.x")
      run.values = [from, origin(1), origin(1 + Self.drift)]
      run.keyTimes = [0, NSNumber(value: Self.runOutDuration / total), 1]
      run.timingFunctions = [CAMediaTimingFunction(controlPoints: 0.25, 0.6, 0.3, 1), CAMediaTimingFunction(name: .linear)]
      run.duration = total
      sweep.add(run, forKey: "step")
    }
    let fade = CABasicAnimation(keyPath: "opacity")
    fade.fromValue = fromOpacity
    fade.toValue = 0
    fade.duration = Self.fadeDuration
    fade.beginTime = sweep.convertTime(CACurrentMediaTime(), from: nil) + (reduceMotion ? 0 : Self.fadeDelay)
    fade.fillMode = .backwards
    fade.timingFunction = CAMediaTimingFunction(name: .easeIn)
    sweep.add(fade, forKey: "fade")
    CATransaction.commit()
  }

  /// Another tab: its state at once.
  private func snap(running now: Bool, to target: Double) {
    generation += 1
    active = now
    finishing = false
    fraction = now ? target : 0
    steps = now ? 1 : 0
    quietly {
      sweep.removeAllAnimations()
      sweep.opacity = now ? 1 : 0
      sweep.position = CGPoint(x: origin(fraction), y: 0)
    }
  }

  // MARK: The look

  /// Brightness along the sweep by distance behind the leading end, in field widths (Dia's line, measured).
  private static let trail: [(distance: CGFloat, level: CGFloat)] = [
    (0, 1), (0.2, 0.91), (0.4, 0.73), (0.6, 0.53), (0.8, 0.33), (1, 0.06),
  ]

  private static func trailLevel(_ distance: CGFloat) -> CGFloat {
    guard distance > 0 else { return 1 }
    for (a, b) in zip(trail, trail.dropFirst()) where distance <= b.distance {
      return a.level + (b.level - a.level) * (distance - a.distance) / (b.distance - a.distance)
    }
    return trail.last!.level
  }

  /// The glow by height above the bottom edge, in points: a tight part hugging the line and a broad one that
  /// reaches the top (Dia: about half as strong 3.5 pt up, a fifth at mid-height, a tenth at the top).
  private static func glowLevel(_ height: CGFloat) -> CGFloat {
    (0.6 * exp(-height / 1.8) + 0.4 * exp(-height / 16)) / 0.723
  }

  /// RGBA (sRGB) of a ramp of colours at 0...1 along it.
  private static func ramp(_ colours: [[CGFloat]], at t: CGFloat) -> [CGFloat] {
    guard colours.count > 1 else { return colours.first ?? [0, 0, 0, 0] }
    let at = min(1, max(0, t)) * CGFloat(colours.count - 1)
    let i = min(colours.count - 2, Int(at))
    let f = at - CGFloat(i)
    return (0..<4).map { colours[i][$0] + (colours[i + 1][$0] - colours[i][$0]) * f }
  }

  private static func components(_ colours: [CGColor]) -> [[CGFloat]] {
    let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
    return colours.map { colour in
      let c = colour.converted(to: srgb, intent: .defaultIntent, options: nil)?.components ?? [0, 0, 0, 0]
      return c.count >= 4 ? Array(c.prefix(4)) : [c[0], c[0], c[0], c.last ?? 1]
    }
  }

  /// The sweep's picture: the field's width plus the halo, the leading end at `width`. `wash` and `line` are
  /// `LoadingTint`'s ramps, trailing end to leading end. Only their colours are read; every point's strength is
  /// its ramp's leading end times `trail`, so the falloff is Dia's measured one.
  static func draw(width: CGFloat, height: CGFloat, scale: CGFloat, wash: [CGColor], line: [CGColor]) -> CGImage? {
    let pw = Int(((width + halo) * scale).rounded(.up)), ph = Int((height * scale).rounded(.up))
    guard pw > 0, ph > 0,
          let context = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: pw * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
          let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
    // Hues from the ramps; strength from their leading ends, falling off behind it as Dia's does (`trail`).
    let washRamp = components(wash), lineRamp = components(line)
    let washPeak = washRamp.last?[3] ?? 0, linePeak = lineRamp.last?[3] ?? 0
    // Per row, from the top: the glow, and how much of the 1 pt line the row covers (its lower half full, its
    // upper half a little under half, as Dia's two device pixels are).
    let rows: [(glow: CGFloat, line: CGFloat)] = (0..<ph).map { j in
      let top = (CGFloat(ph - j)) / scale, bottom = (CGFloat(ph - j - 1)) / scale
      func overlap(_ a: CGFloat, _ b: CGFloat) -> CGFloat { max(0, min(top, b) - max(bottom, a)) }
      let line = (overlap(0, 0.5) + 0.45 * overlap(0.5, 1)) * scale
      return (glowLevel((top + bottom) / 2), line)
    }
    for i in 0..<pw {
      let x = (CGFloat(i) + 0.5) / scale
      let along: CGFloat, glowAlong: CGFloat, lineAlong: CGFloat
      if x <= width {
        along = x / width
        glowAlong = trailLevel(1 - along)
        // A crisp end, a point and a half of antialiasing.
        lineAlong = glowAlong * min(1, (width - x) / 1.5 + 0.25)
      } else {
        along = 1
        let u = (x - width) / halo
        glowAlong = 0.45 * (1 - u) * (1 - u)
        lineAlong = 0
      }
      let w = ramp(washRamp, at: along), l = ramp(lineRamp, at: along)
      for j in 0..<ph {
        let glowAlpha = min(1, washPeak * glowAlong * rows[j].glow)
        let lineAlpha = min(1, linePeak * lineAlong * rows[j].line)
        let alpha = lineAlpha + glowAlpha * (1 - lineAlpha)
        let p = (j * pw + i) * 4
        for c in 0..<3 {
          let v = l[c] * lineAlpha + w[c] * glowAlpha * (1 - lineAlpha)
          data[p + c] = UInt8(max(0, min(255, (v * 255).rounded())))
        }
        data[p + 3] = UInt8(max(0, min(255, (alpha * 255).rounded())))
      }
    }
    return context.makeImage()
  }
}
