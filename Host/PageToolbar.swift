import AppKit

protocol PageToolbarDelegate: AnyObject {
  func toolbarToggleSidebar(_ toolbar: PageToolbarView)
  func toolbarBack(_ toolbar: PageToolbarView)
  func toolbarForward(_ toolbar: PageToolbarView)
  func toolbarReload(_ toolbar: PageToolbarView)
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

  var addressText: String { address.text }
  var addressDebug: [String: Any] { address.debug }

  @objc private func toggleSidebar() { delegate?.toolbarToggleSidebar(self) }
  @objc private func back() { delegate?.toolbarBack(self) }
  @objc private func forward() { delegate?.toolbarForward(self) }
  @objc private func reload() { delegate?.toolbarReload(self) }
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

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.cornerRadius = 8
    layer?.cornerCurve = .continuous
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

  /// The host in medium weight, as Ardia and Dia show it; the rest of the address in grey only while hovered.
  private func render() {
    let font = NSFont.systemFont(ofSize: 13)
    let shown = NSMutableAttributedString(string: parts.host, attributes: [
      .font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.labelColor,
    ])
    if hovered, !parts.trail.isEmpty {
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
    return ["look": "\(look)", "icon": !securityIcon.isHidden, "textOffset": label.frame.midY - bounds.midY]
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

  /// Host (without www.) and path, as Dia shows it; built-in pages as ray://.
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
    return (bareHost + port, path)
  }

  override func layout() {
    super.layout()
    let mid = bounds.height / 2
    // Ardia's lock: 7 pt in, 18 wide, the text 3 pt after it.
    securityIcon.frame = NSRect(x: 7, y: (mid - 9).rounded(), width: 18, height: 18)
    let x: CGFloat = securityIcon.isHidden ? 8 : 28
    // One line tall, so the text sits on the middle (a label draws from its frame's top).
    let line = ceil(label.intrinsicContentSize.height)
    label.frame = NSRect(x: x, y: (mid - line / 2).rounded(), width: max(0, bounds.width - x - 8), height: line)
  }
}
