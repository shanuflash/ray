import AppKit

// A page's sized pop-up (`window.open` with a width or height: Google, Apple and Microsoft sign-ins, payment checks,
// "Connect to Slack") in a small window of its own at the size the page asked, as Arc, Chrome and Ardia open them;
// Ray made them Today tabs before. The owner's pick B of docs/mocks/popup-window.html (2026-11-23): Ray's sidebar
// colour framing the page as a card, one 38 pt row with Ray's traffic lights, the pop-up's address centred (host,
// then the path in grey: a pop-up can be any site, so its address always shows, from the engine, never the page) and
// Open as Tab, which moves the page into a Today tab beside its opener. Its own engine window adopts the tab (Ardia's
// `ArdiaPopupWindow`). ⌘W closes it; a tab it opens goes to Ray's window, a pop-up it opens gets a window of its own.

final class PopupWindow: NSObject, RayCoreWindowDelegate, RayCoreTabDelegate {
  /// The open ones, so they live until their window closes.
  private(set) static var all: [PopupWindow] = []
  static let rowHeight: CGFloat = 38
  static let inset: CGFloat = 6
  static let cornerRadius: CGFloat = 9
  /// When the page asks for no size: Chrome's default pop-up is about this big.
  static let defaultSize = NSSize(width: 500, height: 600)
  static let minimumSize = NSSize(width: 260, height: 180)

  let tab: RayCoreTab
  private let coreWindow: RayCoreWindow
  private weak var owner: BrowserWindowController?
  /// The sidebar entry of the tab that opened it: Open as Tab lands right after it.
  private let openerID: UUID?
  private let root = PopupRootView()
  private let lights = WindowLights()
  private let address = PopupAddressView()
  private let openAsTabButton = HoverIconButton.make("plus.rectangle", label: "Open as Tab", size: 13)
  private let card = NSView()
  private var adopted = false
  private var closeObserver: NSObjectProtocol?
  private var closed = false
  /// The window whose page opened it. The pop-up is its child window: it stays above it and on its Space, so a
  /// full-screen Ray keeps it on its own Space (a window of its own went to the desktop's).
  private weak var parent: NSWindow?

  var window: NSWindow { coreWindow.window }

  /// A pop-up the page in `owner`'s window opened (the engine's `popup` disposition): its window, at the size and
  /// place the page asked for (kept on the opener's screen).
  @discardableResult
  static func open(_ tab: RayCoreTab, from owner: BrowserWindowController, opener: SidebarEntry?,
                   parent: NSWindow? = nil) -> PopupWindow {
    let popup = PopupWindow(tab: tab, owner: owner, openerID: opener?.id, parent: parent ?? owner.window)
    all.append(popup)
    // Adopting the tab inside the engine's tab strip notification would trip its reentrancy check.
    DispatchQueue.main.async { popup.takeTab() }
    return popup
  }

  /// The pop-up window that's key, if one is (⌘W from the menu closes it, not a tab behind it).
  static var key: PopupWindow? { all.first { $0.window.isKeyWindow } }

  private init(tab: RayCoreTab, owner: BrowserWindowController, openerID: UUID?, parent: NSWindow) {
    self.parent = parent
    self.tab = tab
    self.owner = owner
    self.openerID = openerID
    let features = tab.popupFeatures ?? [:]
    let page = NSSize(width: max(features["width"]?.doubleValue ?? Self.defaultSize.width, Self.minimumSize.width),
                      height: max(features["height"]?.doubleValue ?? Self.defaultSize.height, Self.minimumSize.height))
    let content = NSSize(width: page.width + Self.inset * 2, height: page.height + Self.rowHeight + Self.inset)
    coreWindow = RayCoreWindow(contentRect: NSRect(origin: .zero, size: content))
    super.init()
    coreWindow.delegate = self
    let window = coreWindow.window
    window.styleMask.formUnion([.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView])
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    window.isReleasedWhenClosed = false
    window.isRestorable = false
    window.tabbingMode = .disallowed
    window.animationBehavior = .documentWindow
    window.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
    window.minSize = NSSize(width: Self.minimumSize.width + Self.inset * 2,
                            height: Self.minimumSize.height + Self.rowHeight + Self.inset)
    let isPrivate = tab.profile?.offTheRecord == true
    if isPrivate { window.appearance = NSAppearance(named: .darkAqua) }
    window.backgroundColor = isPrivate ? SidebarColors.privateBackground : SidebarColors.background
    closeObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in self?.windowWillClose() }
    for kind: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
      window.standardWindowButton(kind)?.isHidden = true
    }
    window.setContentSize(content)
    place(features: features)

    let host = coreWindow.hostView
    root.frame = host.bounds
    root.autoresizingMask = [.width, .height]
    root.onLayout = { [weak self] in self?.layout() }
    host.addSubview(root)
    card.wantsLayer = true
    card.layer?.cornerRadius = Self.cornerRadius
    card.layer?.cornerCurve = .continuous
    card.layer?.masksToBounds = true
    card.layer?.backgroundColor = NSColor.white.cgColor
    openAsTabButton.target = self
    openAsTabButton.action = #selector(openAsTab)
    openAsTabButton.toolTip = "Open as Tab"
    [lights, address, openAsTabButton, card].forEach(root.addSubview)
    updateTitle()
    address.show(url: tab.url, security: ConnectionLook.level(tab.securityInfo))
    layout()
  }

  /// The page's x and y are screen points from the top left of the main screen, as `window.open` gives them; without
  /// them, centred over the opener's window and a little down. Always kept on the opener's screen.
  private func place(features: [String: NSNumber]) {
    let screen = parent?.screen ?? NSScreen.main
    let visible = screen?.visibleFrame ?? .zero
    var frame = window.frame
    if !visible.isEmpty {
      frame.size = NSSize(width: min(frame.width, visible.width), height: min(frame.height, visible.height))
    }
    if features["x"] != nil || features["y"] != nil {
      let primary = NSScreen.screens.first?.frame ?? visible
      let content = window.contentRect(forFrameRect: frame)
      let left = features["x"]?.doubleValue ?? (parent.map { $0.frame.midX - frame.width / 2 } ?? visible.midX)
      let top = features["y"]?.doubleValue ?? (parent.map { primary.maxY - $0.frame.maxY + 60 } ?? 60)
      frame.origin = NSPoint(x: left, y: primary.maxY - top - content.height)
    } else if let parent {
      frame.origin = NSPoint(x: parent.frame.midX - frame.width / 2, y: parent.frame.maxY - frame.height - 60)
    } else {
      frame.origin = NSPoint(x: visible.midX - frame.width / 2, y: visible.midY - frame.height / 2)
    }
    if !visible.isEmpty {
      frame.origin.x = max(visible.minX, min(frame.minX, visible.maxX - frame.width))
      frame.origin.y = max(visible.minY, min(frame.minY, visible.maxY - frame.height))
    }
    window.setFrame(frame, display: false)
  }

  private func takeTab() {
    guard !tab.closed else { return close() }
    adopted = true
    coreWindow.adoptTab(tab)
    if let profile = tab.profile { coreWindow.activeProfile = profile }
    tab.delegate = self
    tab.view.removeFromSuperview()
    tab.view.autoresizingMask = [.width, .height]
    card.addSubview(tab.view)
    layout()
    if launchedInBackground { coreWindow.showInactive() } else { window.makeKeyAndOrderFront(nil) }
    if let parent, parent.isVisible, window.parent == nil { parent.addChildWindow(window, ordered: .above) }
    tab.focus()
    owner?.logState("popupWindow")
  }

  private func layout() {
    let bounds = root.bounds
    let row = Self.rowHeight
    // Flipped root: the row on top.
    lights.frame = NSRect(x: 14, y: (row - 16) / 2, width: WindowLights.width, height: 16)
    openAsTabButton.frame = NSRect(x: bounds.width - 8 - 28, y: (row - 28) / 2, width: 28, height: 28)
    let side = max(lights.frame.maxX, bounds.width - openAsTabButton.frame.minX) + 10
    address.frame = NSRect(x: side, y: (row - 20) / 2, width: max(0, bounds.width - side * 2), height: 20)
    card.frame = NSRect(x: Self.inset, y: row, width: max(0, bounds.width - Self.inset * 2),
                        height: max(0, bounds.height - row - Self.inset)).integral
    if tab.view.superview === card { tab.view.frame = card.bounds }
  }

  private func updateTitle() {
    let title = tab.title
    window.title = title.isEmpty || title == tab.url ? AddressInput.addressParts(for: tab.url).text : title
  }

  /// Open as Tab: the page moves into a Today tab right after the tab that opened it, and this window goes.
  @objc private func openAsTab() {
    guard !closed, !tab.closed, let owner else { return }
    closed = true
    tab.view.removeFromSuperview()
    owner.adoptFromPopup(tab, after: openerID, foreground: true)
    Self.all.removeAll { $0 === self }
    window.orderOut(nil)
    // The engine window is empty now: closing it closes nothing else.
    DispatchQueue.main.async { [coreWindow] in coreWindow.close() }
    owner.logState("popupWindow")
  }

  /// For tests: the window's own views (Chrome's page draws nothing into it) as a PNG.
  func snapshot(to path: String) -> Bool {
    guard let frame = window.contentView?.superview,
          let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { return false }
    frame.cacheDisplay(in: frame.bounds, to: rep)
    guard let data = rep.representation(using: .png, properties: [:]) else { return false }
    return (try? data.write(to: URL(fileURLWithPath: path))) != nil
  }

  /// For tests: the Open as Tab button's click.
  func pressOpenAsTab() { openAsTab() }

  func close() {
    guard !closed else { return }
    closed = true
    coreWindow.close()
  }

  private func windowWillClose() {
    closed = true
    if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
    closeObserver = nil
    if tab.delegate === self { tab.delegate = nil }
    window.parent?.removeChildWindow(window)
    let me = self
    DispatchQueue.main.async {
      Self.all.removeAll { $0 === me }
      me.owner?.logState("popupWindow")
    }
  }

  // MARK: RayCoreWindowDelegate

  func window(_ window: RayCoreWindow, didInsert tab: RayCoreTab, opener: RayCoreTab?, disposition: String) {
    guard tab !== self.tab, let owner else { return }
    if disposition == "popup" {
      PopupWindow.open(tab, from: owner, opener: nil, parent: self.window)
      return
    }
    // A tab the pop-up opens goes to Ray's window, after the tab that opened the pop-up.
    DispatchQueue.main.async { [openerID] in
      owner.adoptFromPopup(tab, after: openerID, foreground: disposition != "background_tab")
    }
  }

  func window(_ window: RayCoreWindow, didRemove tab: RayCoreTab) {
    guard tab === self.tab, !closed else { return }
    // The page closed itself (a sign-in done): the window goes too.
    DispatchQueue.main.async { [weak self] in self?.close() }
  }

  func window(_ window: RayCoreWindow, preHandleKeyEvent event: NSEvent) -> Bool {
    if Self.isCloseKey(event) {
      close()
      return true
    }
    return Shortcuts.isReserved(event) && (NSApp.mainMenu?.performKeyEquivalent(with: event) ?? false)
  }

  func window(_ window: RayCoreWindow, handleKeyEvent event: NSEvent) -> Bool {
    if Self.isCloseKey(event) {
      close()
      return true
    }
    return event.type == .keyDown && (NSApp.mainMenu?.performKeyEquivalent(with: event) ?? false)
  }

  /// Close Tab's key as the menu has it now (⌘W unless Settings › Shortcuts moved it).
  private static func isCloseKey(_ event: NSEvent) -> Bool {
    guard event.type == .keyDown, let item = MainMenu.item(for: #selector(AppController.closeTab(_:))),
          !item.keyEquivalent.isEmpty else { return false }
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).intersection([.command, .option, .control, .shift])
    return event.charactersIgnoringModifiers?.lowercased() == item.keyEquivalent.lowercased()
      && flags == item.keyEquivalentModifierMask.intersection([.command, .option, .control, .shift])
  }

  // MARK: RayCoreTabDelegate

  func tabDidChangeTitle(_ tab: RayCoreTab) { updateTitle() }
  func tabDidChangeURL(_ tab: RayCoreTab) {
    updateTitle()
    address.show(url: tab.url, security: ConnectionLook.level(tab.securityInfo))
  }
  func tabDidChangeSecurity(_ tab: RayCoreTab) {
    address.show(url: tab.url, security: ConnectionLook.level(tab.securityInfo))
  }
  func tab(_ tab: RayCoreTab, requestsActivation reason: String) {
    if !launchedInBackground { window.makeKeyAndOrderFront(nil) }
  }
  func tab(_ tab: RayCoreTab, externalAppRequest request: [String: Any]) {
    owner?.tab(tab, externalAppRequest: request)
  }

  /// For the state log.
  var debug: [String: Any] {
    ["url": tab.url, "address": address.text, "frame": NSStringFromRect(window.frame),
     "card": NSStringFromRect(card.frame), "page": NSStringFromRect(tab.view.frame), "adopted": adopted,
     "pageInCard": tab.view.superview === card, "visible": window.isVisible, "title": window.title,
     "child": window.parent != nil && window.parent === parent,
     "fullScreenAuxiliary": window.collectionBehavior.contains(.fullScreenAuxiliary)]
  }
}

/// The pop-up's root: flipped, the row free to drag the window by.
private final class PopupRootView: NSView {
  var onLayout: (() -> Void)?
  override var isFlipped: Bool { true }
  override var mouseDownCanMoveWindow: Bool { true }
  override func layout() {
    super.layout()
    onLayout?()
  }
}

/// The pop-up's address: the connection's icon (a lock for a secure page, Ray's marks otherwise), the host in medium
/// weight, then the rest in grey, cut at the end; the engine's URL, never anything the page says.
final class PopupAddressView: NSView {
  private let icon = NSImageView()
  private let label = NSTextField(labelWithString: "")
  private(set) var text = ""

  override init(frame: NSRect) {
    super.init(frame: frame)
    icon.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
    label.lineBreakMode = .byTruncatingTail
    label.maximumNumberOfLines = 1
    label.cell?.truncatesLastVisibleLine = true
    [icon, label].forEach(addSubview)
  }

  required init?(coder: NSCoder) { fatalError() }

  override var mouseDownCanMoveWindow: Bool { true }

  func show(url: String, security: String?) {
    let parts = AddressInput.addressParts(for: url)
    let look = ConnectionLook.of(level: security, url: url)
    let secure = look == .quiet && URLComponents(string: AddressInput.innerURL(of: url))?.scheme == "https"
    let symbol = secure ? "lock.fill" : look.symbol
    icon.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: secure ? "Secure" : look.label) }
    icon.contentTintColor = secure ? .secondaryLabelColor : look.tint
    icon.isHidden = icon.image == nil
    let shown = NSMutableAttributedString(string: parts.host, attributes: [
      .font: NSFont.systemFont(ofSize: 12.5, weight: .medium), .foregroundColor: NSColor.labelColor,
    ])
    shown.append(NSAttributedString(string: parts.trail, attributes: [
      .font: NSFont.systemFont(ofSize: 12.5), .foregroundColor: NSColor.secondaryLabelColor,
    ]))
    label.attributedStringValue = shown
    text = parts.host + parts.trail
    setAccessibilityLabel(text)
    needsLayout = true
  }

  override func layout() {
    super.layout()
    let iconWidth: CGFloat = icon.isHidden ? 0 : 14
    let lineHeight = ceil(label.intrinsicContentSize.height)
    let textWidth = min(ceil(label.intrinsicContentSize.width) + 2, max(0, bounds.width - iconWidth))
    let start = ((bounds.width - iconWidth - textWidth) / 2).rounded()
    icon.frame = NSRect(x: start, y: ((bounds.height - 12) / 2).rounded(), width: 12, height: 12)
    label.frame = NSRect(x: start + iconWidth, y: ((bounds.height - lineHeight) / 2).rounded(), width: textWidth, height: lineHeight)
  }
}
