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
  static let height: CGFloat = 40
  weak var delegate: PageToolbarDelegate?

  private let sidebarButton = PageToolbarView.button("sidebar.left", "Show Sidebar")
  private let backButton = PageToolbarView.button("chevron.left", "Back")
  private let forwardButton = PageToolbarView.button("chevron.right", "Forward")
  private let reloadButton = PageToolbarView.button("arrow.clockwise", "Reload")
  private let copyButton = PageToolbarView.button("link", "Copy Link")
  /// Opens the site controls panel, which hangs below it.
  let siteButton = PageToolbarView.button("slider.horizontal.3", "Site Controls")
  private let address = ToolbarAddressView()

  /// The sidebar button and back, forward and reload: shown while the sidebar is hidden (peeking included, so the
  /// bar stays still as the sidebar slides over).
  var showsNavigation = false {
    didSet {
      guard oldValue != showsNavigation else { return }
      for button in [sidebarButton, backButton, forwardButton, reloadButton] { button.isHidden = !showsNavigation }
      needsLayout = true
    }
  }

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

  @objc private func toggleSidebar() { delegate?.toolbarToggleSidebar(self) }
  @objc private func back() { delegate?.toolbarBack(self) }
  @objc private func forward() { delegate?.toolbarForward(self) }
  @objc private func reload() { delegate?.toolbarReload(self) }
  @objc private func copyLink() { delegate?.toolbarCopyLink(self) }
  @objc private func siteControls() { delegate?.toolbarSiteControls(self) }

  override func layout() {
    super.layout()
    let mid = bounds.height / 2
    var x: CGFloat = 4
    for button in [sidebarButton, backButton, forwardButton, reloadButton] where !button.isHidden {
      button.frame = NSRect(x: x, y: mid - 14, width: 28, height: 28)
      x += button === sidebarButton ? 36 : 30
    }
    siteButton.frame = NSRect(x: bounds.width - 4 - 28, y: mid - 14, width: 28, height: 28)
    copyButton.frame = NSRect(x: siteButton.frame.minX - 30, y: mid - 14, width: 28, height: 28)
    let right = copyButton.isHidden ? bounds.width - 4 : copyButton.frame.minX - 6
    address.frame = NSRect(x: x + 4, y: mid - 14, width: max(0, right - x - 4), height: 28)
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

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.cornerRadius = 7
    layer?.cornerCurve = .continuous
    label.font = .systemFont(ofSize: 13)
    label.textColor = .secondaryLabelColor
    label.lineBreakMode = .byTruncatingTail
    securityIcon.symbolConfiguration = .init(pointSize: 11, weight: .medium)
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
  }

  override func mouseExited(with event: NSEvent) {
    hovered = false
    needsDisplay = true
  }

  override func mouseDown(with event: NSEvent) { onClick?() }

  func show(url: String, security: String?) {
    text = Self.text(for: url)
    label.stringValue = text
    let level = security ?? (URLComponents(string: url)?.scheme == "http" ? "insecure" : "none")
    switch level {
    case "insecure", "certificateError":
      securityIcon.image = NSImage(systemSymbolName: "lock.slash.fill", accessibilityDescription: "Not secure")
      securityIcon.contentTintColor = .systemRed
      securityIcon.isHidden = text.isEmpty
    case "mixed":
      securityIcon.image = NSImage(systemSymbolName: "lock.trianglebadge.exclamationmark.fill", accessibilityDescription: "Partly secure")
      securityIcon.contentTintColor = .systemOrange
      securityIcon.isHidden = text.isEmpty
    default:
      securityIcon.isHidden = true
    }
    needsLayout = true
  }

  /// Host (without www.) and path, as Dia shows it; built-in pages as ray://.
  static func text(for url: String) -> String {
    guard !url.isEmpty else { return "" }
    let shown = AddressInput.display(for: url)
    guard let components = URLComponents(string: shown), let host = components.host, !host.isEmpty else {
      return AddressInput.pillText(for: url)
    }
    if components.scheme == AddressInput.internalScheme { return shown }
    let bareHost = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    let port = components.port.map { ":\($0)" } ?? ""
    let path = components.percentEncodedPath == "/" ? "" : components.percentEncodedPath
    return bareHost + port + path
  }

  override func layout() {
    super.layout()
    let mid = bounds.height / 2
    securityIcon.frame = NSRect(x: 8, y: mid - 8, width: 16, height: 16)
    let x: CGFloat = securityIcon.isHidden ? 8 : 28
    label.frame = NSRect(x: x, y: mid - 9, width: max(0, bounds.width - x - 8), height: 18)
  }
}
