import AppKit

// Little Ray, Ray's Little Arc: a quick look at a link from another app (Settings › General › Open links from other
// apps in Little Ray, on by default as in Arc and Ardia), not a mini browser. The owner's picks of
// docs/mocks/little-ray.html (2026-11-24): chrome A (the pop-up window's look: one 38 pt row in Ray's sidebar colour,
// Ray's traffic lights, the engine's address centred and read only, Copy Link, then a labelled "Open in Ray ⌘O"; the
// page a card 6 pt in), placement 1 (Ardia's: 900×640 the first time, then the last size you gave one, never past
// 80 % of the screen, centred on the screen the pointer is on, each further one 24 pt down and right). No back or
// forward buttons, address field, command bar, site controls or ⌥⌘N. Always the normal profile, never private.
// It opens on the Space you're on, over another app's full screen too, as Arc's does: the page lives in a
// non-activating `LittleRayPanel` (an ordinary window went to Ray's full-screen Space or the desktop, and macOS swiped
// there); the engine's own window for the tab is never shown.
// Open in Ray (⌘O) moves the live page (history kept) into Today in Ray's window, as `PopupWindow`'s Open as Tab does
// (`adoptFromPopup`); ⌘W, Escape the page didn't use, or the close light close it and put it in Recently Closed, so
// ⇧⌘T brings it back as a Today tab with its history. Tabs its page opens go to Ray's window; its pop-ups get windows.

final class LittleRay: NSObject, RayCoreWindowDelegate, RayCoreTabDelegate {
  /// The open ones, so they live until their window closes.
  private(set) static var all: [LittleRay] = []
  static let rowHeight: CGFloat = 38
  static let inset: CGFloat = 6
  static let cornerRadius: CGFloat = 9
  static let defaultSize = NSSize(width: 900, height: 640)
  static let minimumSize = NSSize(width: 420, height: 300)
  /// The largest share of the screen's visible frame it takes (Ardia's `kLargestShareOfScreen`).
  static let largestShare: CGFloat = 0.8
  static let cascade: CGFloat = 24
  /// What happened, for the state log: "opened", "openedInRay", "closed", "pageClosed".
  private(set) static var steps: [String] = []

  let tab: RayCoreTab
  /// The engine's window for the tab. Never shown: macOS keeps an ordinary window off another app's full-screen Space
  /// (a link from full-screen Slack swiped to Ray's Space or to the desktop), so the page lives in `panel`, a
  /// non-activating panel that opens on the Space you're on, as an extension popup's page lives in its own window.
  private let coreWindow: RayCoreWindow
  private let panel: LittleRayPanel
  private let profile: RayCoreProfile
  private let root = LittleRayRootView()
  private let lights = WindowLights()
  private let address = PopupAddressView()
  private let copyButton = HoverIconButton.make("link", label: "Copy Link", size: 13)
  private let openButton = OpenInRayButton()
  /// Open in ‹Space› (Arc's Little Arc): the Spaces to open the page in, when there's more than one.
  private let spaceButton = HoverIconButton.make("chevron.down", label: "Open in Space", size: 11)
  private let card = NSView()
  private var closeObserver: NSObjectProtocol?
  private var resizeObserver: NSObjectProtocol?
  private var closed = false
  /// Put in Recently Closed already (once).
  private var remembered = false
  private var copiedReset: DispatchWorkItem?

  var window: NSWindow { panel }

  /// The Little Ray that's key, if one is (⌘W, ⇧⌘C and ⌘O act on it, not on a tab behind).
  static var key: LittleRay? { all.first { $0.window.isKeyWindow } }

  /// Opens `url` (already through `AddressInput.link(fromOtherApp:)`) in a new Little Ray, in front.
  @discardableResult
  static func open(_ url: String) -> LittleRay? {
    guard let engine = RayCoreEngine.shared else { return nil }
    LinkActivationOrder.shared.linkArriving()
    let little = LittleRay(url: url, profile: engine.defaultProfile)
    all.append(little)
    steps.append("opened")
    if launchedInBackground {
      // Test instances: behind whatever the user has in front, never on every Space.
      little.panel.collectionBehavior = [.fullScreenAuxiliary]
      little.panel.orderFront(nil)
    } else {
      LinkActivationOrder.shared.opening(little.panel)
      little.panel.makeKeyAndOrderFront(nil)
      LinkActivationOrder.shared.shown()
    }
    little.tab.noteShown(byHost: true)
    little.tab.focus()
    little.log()
    return little
  }

  private init(url: String, profile: RayCoreProfile) {
    self.profile = profile
    let size = Self.size(on: Self.screenForNewWindow())
    coreWindow = RayCoreWindow(contentRect: NSRect(origin: .zero, size: size))
    coreWindow.activeProfile = profile
    tab = coreWindow.openTab(url, profile: profile, foreground: true)
    panel = LittleRayPanel(
      contentRect: NSRect(origin: .zero, size: size),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView, .nonactivatingPanel],
      backing: .buffered, defer: false)
    super.init()
    coreWindow.delegate = self
    tab.delegate = self
    panel.isFloatingPanel = false
    panel.hidesOnDeactivate = false
    panel.becomesKeyOnlyIfNeeded = false
    panel.titlebarAppearsTransparent = true
    panel.titleVisibility = .hidden
    panel.isReleasedWhenClosed = false
    panel.isRestorable = false
    panel.tabbingMode = .disallowed
    panel.animationBehavior = .documentWindow
    // Shown on the Space you're on (another app's full screen included), and stays there.
    panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
    panel.minSize = NSSize(width: Self.minimumSize.width + Self.inset * 2,
                           height: Self.minimumSize.height + Self.rowHeight + Self.inset)
    panel.backgroundColor = SidebarColors.background
    for kind: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
      panel.standardWindowButton(kind)?.isHidden = true
    }
    place()
    closeObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.willCloseNotification, object: panel, queue: .main) { [weak self] _ in self?.windowWillClose() }
    resizeObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.didEndLiveResizeNotification, object: panel, queue: .main) { [weak self] _ in
        guard let self else { return }
        RaySettings.shared.rememberLittleRaySize(self.panel.contentRect(forFrameRect: self.panel.frame).size)
      }

    root.frame = NSRect(origin: .zero, size: size)
    root.autoresizingMask = [.width, .height]
    root.onLayout = { [weak self] in self?.layout() }
    panel.contentView = root
    card.wantsLayer = true
    card.layer?.cornerRadius = Self.cornerRadius
    card.layer?.cornerCurve = .continuous
    card.layer?.masksToBounds = true
    card.layer?.backgroundColor = NSColor.white.cgColor
    copyButton.target = self
    copyButton.action = #selector(copyLink)
    copyButton.toolTip = "Copy Link"
    openButton.onClick = { [weak self] in self?.openInRay() }
    spaceButton.target = self
    spaceButton.action = #selector(showSpaces)
    [lights, address, copyButton, openButton, spaceButton, card].forEach(root.addSubview)
    tab.view.removeFromSuperview()
    tab.view.autoresizingMask = [.width, .height]
    card.addSubview(tab.view)
    updateTitle()
    address.show(url: tab.url, security: ConnectionLook.level(tab.securityInfo))
    layout()
  }

  // MARK: Size and place

  /// The screen the pointer is on (where the link was clicked), else the main one.
  private static func screenForNewWindow() -> NSScreen? {
    let mouse = NSEvent.mouseLocation
    return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
  }

  /// The content size: the last one you gave a Little Ray, else 900×640; at least the minimum and at most 80 % of the
  /// screen's visible frame (Ardia's `FitSide`).
  static func size(on screen: NSScreen?) -> NSSize {
    let wanted = RaySettings.shared.littleRaySize.map(NSSizeFromString).flatMap { $0.width > 0 && $0.height > 0 ? $0 : nil }
      ?? defaultSize
    guard let visible = screen?.visibleFrame, !visible.isEmpty else { return wanted }
    func fit(_ wanted: CGFloat, _ minimum: CGFloat, _ room: CGFloat) -> CGFloat {
      let largest = min(max((room * largestShare).rounded(), minimum), room)
      return min(min(max(wanted, minimum), largest).rounded(), room)
    }
    return NSSize(width: fit(wanted.width, minimumSize.width + inset * 2, visible.width),
                  height: fit(wanted.height, minimumSize.height + rowHeight + inset, visible.height))
  }

  /// Centred on the pointer's screen; each Little Ray already open moves the next one 24 pt down and right.
  private func place() {
    let screen = Self.screenForNewWindow()
    guard let visible = screen?.visibleFrame, !visible.isEmpty else { return window.center() }
    var frame = window.frame
    let step = CGFloat(Self.all.filter { !$0.closed }.count) * Self.cascade
    frame.origin = NSPoint(x: (visible.midX - frame.width / 2 + step).rounded(),
                           y: (visible.midY - frame.height / 2 - step).rounded())
    frame.origin.x = max(visible.minX, min(frame.minX, visible.maxX - frame.width))
    frame.origin.y = max(visible.minY, min(frame.minY, visible.maxY - frame.height))
    window.setFrame(frame, display: false)
  }

  private func layout() {
    let bounds = root.bounds
    let row = Self.rowHeight
    // Flipped root: the row on top.
    lights.frame = NSRect(x: 14, y: (row - 16) / 2, width: WindowLights.width, height: 16)
    let openWidth = openButton.intrinsicContentSize.width
    let spaces = Self.spaceChoices
    spaceButton.isHidden = spaces.count < 2
    let right = spaceButton.isHidden ? bounds.width - 8 : bounds.width - 8 - 22 - 2
    spaceButton.frame = NSRect(x: bounds.width - 8 - 22, y: (row - 28) / 2, width: 22, height: 28)
    openButton.frame = NSRect(x: right - openWidth, y: (row - 28) / 2, width: openWidth, height: 28)
    copyButton.frame = NSRect(x: openButton.frame.minX - 4 - 28, y: (row - 28) / 2, width: 28, height: 28)
    let side = max(lights.frame.maxX, bounds.width - copyButton.frame.minX) + 10
    address.frame = NSRect(x: side, y: (row - 20) / 2, width: max(0, bounds.width - side * 2), height: 20)
    card.frame = NSRect(x: Self.inset, y: row, width: max(0, bounds.width - Self.inset * 2),
                        height: max(0, bounds.height - row - Self.inset)).integral
    if tab.view.superview === card { tab.view.frame = card.bounds }
  }

  private func updateTitle() {
    let title = tab.title
    window.title = title.isEmpty || title == tab.url ? AddressInput.addressParts(for: tab.url).text : title
  }

  // MARK: Actions

  /// Copy Link (and ⇧⌘C while it's key): the engine's address; the button shows a tick for a moment.
  @objc func copyLink() {
    let url = tab.url
    guard !url.isEmpty, !closed else { return }
    let pasteboard = BrowserWindowController.pasteboard
    pasteboard.clearContents()
    pasteboard.setString(url, forType: .string)
    copyButton.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Copied")
    copiedReset?.cancel()
    let reset = DispatchWorkItem { [weak self] in
      self?.copyButton.image = NSImage(systemSymbolName: "link", accessibilityDescription: "Copy Link")
    }
    copiedReset = reset
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: reset)
    Self.steps.append("copied")
    log()
  }

  /// The normal window's Spaces, for Open in ‹Space›.
  private static var spaceChoices: [Space] {
    AppController.shared.windows.first { !$0.isPrivate }?.state.spaces ?? []
  }

  @objc private func showSpaces() {
    let menu = NSMenu()
    let current = AppController.shared.windows.first { !$0.isPrivate }?.state.current
    for space in Self.spaceChoices {
      let item = NSMenuItem(title: "Open in \(space.name)", action: #selector(openInSpace(_:)), keyEquivalent: "")
      item.target = self
      item.representedObject = space.id
      item.image = SpaceIcon.image(for: space, size: 14)
      item.state = space === current ? .on : .off
      menu.addItem(item)
    }
    menu.popUp(positioning: nil, at: NSPoint(x: 0, y: spaceButton.bounds.maxY + 4), in: spaceButton)
  }

  @objc private func openInSpace(_ item: NSMenuItem) {
    guard let id = item.representedObject as? UUID else { return }
    openInRay(space: id)
  }

  /// For the state log: the Spaces Open in ‹Space› offers.
  var spaceTitles: [String] { spaceButton.isHidden ? [] : Self.spaceChoices.map { "Open in \($0.name)" } }

  /// Open in Ray (⌘O): the live page moves into Today in Ray's normal window (opened again if it was closed), shown
  /// and in front; this window goes. `space`: Open in ‹Space›, that Space's Today (on another profile the page
  /// opens there afresh: a tab can't change profile).
  func openInRay(space: UUID? = nil) {
    guard !closed, !tab.closed, let owner = AppController.shared.openMainWindow() else { return }
    let target = space.flatMap { id in owner.state.space(id: id) }
    if let target, target.profile != nil {
      let url = tab.url
      closed = true
      Self.all.removeAll { $0 === self }
      Self.steps.append("openedInSpace")
      owner.openInSpace(url, target)
      if tab.delegate === self { tab.delegate = nil }
      tab.close()
      panel.close()
      if !launchedInBackground {
        owner.window.makeKeyAndOrderFront(nil)
        NSApp.activate()
      }
      owner.logState("littleRay")
      return
    }
    closed = true
    tab.view.removeFromSuperview()
    if tab.delegate === self { tab.delegate = nil }
    owner.adoptFromPopup(tab, after: nil, foreground: true, in: target)
    if target != nil { Self.steps.append("openedInSpace") }
    Self.all.removeAll { $0 === self }
    Self.steps.append("openedInRay")
    // The engine window is empty now: closing it (with the panel) closes nothing else.
    panel.close()
    if !launchedInBackground {
      owner.window.makeKeyAndOrderFront(nil)
      NSApp.activate()
    }
    owner.logState("littleRay")
  }

  /// ⌘W, Escape or the close light: the page goes to Recently Closed (⇧⌘T brings it back as a Today tab, with its
  /// history), then the window closes.
  func close() {
    guard !closed else { return }
    panel.close()
  }

  /// Puts the page in Recently Closed, its back/forward list tagged for Chrome's tab restore (as a closed Today tab's).
  private func remember() {
    guard !remembered, !tab.closed else { return }
    remembered = true
    let url = tab.url
    guard !url.isEmpty, url != "about:blank", !url.lowercased().hasPrefix("javascript:") else { return }
    let tag = "ray-closed-" + UUID().uuidString
    EngineCalls.call("ac_tab_restore_tag", profile: profile, args: ["tab": Int(tab.tabId), "key": tag]) { _ in }
    ClosedTabs.main.add(ClosedTab(
      entryID: UUID(), kind: .today, index: 0, parentID: nil, pinnedURL: nil, url: url, title: tab.title,
      customTitle: nil, favicon: tab.favicon, restoreKey: tag))
  }

  /// The panel is closing: by ⌘W, Escape or the close light (the page goes to Recently Closed first), or after Open in
  /// Ray or the page closing itself (already `closed`). The engine's window and its tab go with it.
  private func windowWillClose() {
    if !closed {
      remember()
      Self.steps.append("closed")
    }
    closed = true
    tab.noteShown(byHost: false)
    DispatchQueue.main.async { [coreWindow] in coreWindow.close() }
    copiedReset?.cancel()
    for observer in [closeObserver, resizeObserver].compactMap({ $0 }) { NotificationCenter.default.removeObserver(observer) }
    closeObserver = nil
    resizeObserver = nil
    if tab.delegate === self { tab.delegate = nil }
    let me = self
    DispatchQueue.main.async {
      Self.all.removeAll { $0 === me }
      me.log()
    }
  }

  private func log() { AppController.shared.current?.logState("littleRay") }

  /// For tests: a key the page didn't use, as the engine hands it over.
  func pageDidNotUse(_ event: NSEvent) -> Bool { window(coreWindow, handleKeyEvent: event) }

  /// For tests: a live resize ending at that content size (remembered for the next one).
  func resize(to size: NSSize) {
    window.setContentSize(size)
    RaySettings.shared.rememberLittleRaySize(window.contentRect(forFrameRect: window.frame).size)
  }

  /// For tests: the close light's click (macOS's performClose, which asks the engine first).
  func pressCloseLight() { window.performClose(nil) }

  /// For tests: the window's own views (Chrome's page draws nothing into it) as a PNG.
  func snapshot(to path: String) -> Bool {
    guard let frame = window.contentView?.superview,
          let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { return false }
    frame.cacheDisplay(in: frame.bounds, to: rep)
    guard let data = rep.representation(using: .png, properties: [:]) else { return false }
    return (try? data.write(to: URL(fileURLWithPath: path))) != nil
  }

  // MARK: RayCoreWindowDelegate

  func window(_ window: RayCoreWindow, didInsert tab: RayCoreTab, opener: RayCoreTab?, disposition: String) {
    guard tab !== self.tab else { return }
    guard let owner = AppController.shared.openMainWindow() else { return }
    if disposition == "popup" {
      PopupWindow.open(tab, from: owner, opener: nil, parent: self.window)
      return
    }
    // A tab the page opens goes to Ray's window, at the top of Today.
    DispatchQueue.main.async {
      owner.adoptFromPopup(tab, after: nil, foreground: disposition != "background_tab")
    }
  }

  func window(_ window: RayCoreWindow, didRemove tab: RayCoreTab) {
    guard tab === self.tab, !closed else { return }
    // The page closed itself: the window goes too (nothing to bring back).
    Self.steps.append("pageClosed")
    DispatchQueue.main.async { [weak self] in
      guard let self, !self.closed else { return }
      self.closed = true
      self.panel.close()
    }
  }

  func window(_ window: RayCoreWindow, preHandleKeyEvent event: NSEvent) -> Bool {
    if PopupWindow.isCloseKey(event) {
      close()
      return true
    }
    return Shortcuts.isReserved(event) && (NSApp.mainMenu?.performKeyEquivalent(with: event) ?? false)
  }

  /// Keys the page didn't use: Escape closes it (a dialog, a full-screen video or a find on the page takes Escape
  /// first), the rest go to the menu (⌘O, ⇧⌘C).
  func window(_ window: RayCoreWindow, handleKeyEvent event: NSEvent) -> Bool {
    if PopupWindow.isCloseKey(event) || Self.isEscape(event) {
      close()
      return true
    }
    return event.type == .keyDown && (NSApp.mainMenu?.performKeyEquivalent(with: event) ?? false)
  }

  private static func isEscape(_ event: NSEvent) -> Bool {
    event.type == .keyDown && event.keyCode == 53
      && event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
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
    if !launchedInBackground { panel.makeKeyAndOrderFront(nil) }
  }
  func tab(_ tab: RayCoreTab, externalAppRequest request: [String: Any]) {
    AppController.shared.current?.tab(tab, externalAppRequest: request)
  }

  /// For the state log.
  var debug: [String: Any] {
    ["url": tab.url, "address": address.text, "frame": NSStringFromRect(window.frame),
     "content": NSStringFromSize(window.contentRect(forFrameRect: window.frame).size),
     "card": NSStringFromRect(card.frame), "pageInCard": tab.view.superview === card, "visible": window.isVisible,
     "key": window.isKeyWindow, "private": profile.offTheRecord, "openLabel": openButton.title, "openInSpaces": spaceTitles,
     "copied": copyButton.image?.accessibilityDescription == "Copied",
     "fullScreenAuxiliary": window.collectionBehavior.contains(.fullScreenAuxiliary)]
  }
}

/// Little Ray's window: a panel that never makes Ray the active app, so macOS shows it on the Space you're on, over
/// another app's full screen too; key, so the page takes typing, and main, so it reads as the front window.
final class LittleRayPanel: NSPanel {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { true }
}

/// Little Ray's root: flipped, the row free to drag the window by.
private final class LittleRayRootView: NSView {
  var onLayout: (() -> Void)?
  override var isFlipped: Bool { true }
  override var mouseDownCanMoveWindow: Bool { true }
  override func layout() {
    super.layout()
    onLayout?()
  }
}

/// "Open in Ray ⌘O": Ray's plain button look (`ButtonLook`), the title then the key in grey; the key follows the
/// menu item's when Settings › Shortcuts changes it.
final class OpenInRayButton: NSView {
  var onClick: (() -> Void)?
  private let label = NSTextField(labelWithString: "")
  private var hovered = false
  private var down = false
  private(set) var title = ""

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    ButtonLook.shape(layer)
    addSubview(label)
    setAccessibilityElement(true)
    setAccessibilityRole(.button)
    addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    refreshTitle()
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }
  override var wantsUpdateLayer: Bool { true }
  override var mouseDownCanMoveWindow: Bool { false }
  override var intrinsicContentSize: NSSize {
    NSSize(width: ceil(label.attributedStringValue.size().width) + 4 + 22, height: 28)
  }

  /// The title with the menu item's key as it is now.
  func refreshTitle() {
    let key = MainMenu.item(for: #selector(AppController.openLittleRayInRay(_:))).flatMap(KeyCombo.init(item:))?.display ?? ""
    let text = NSMutableAttributedString(string: "Open in Ray", attributes: [
      .font: NSFont.systemFont(ofSize: 12.5, weight: .medium), .foregroundColor: ButtonLook.ink(.plain),
    ])
    if !key.isEmpty {
      text.append(NSAttributedString(string: "  " + key, attributes: [
        .font: NSFont.systemFont(ofSize: 11.5), .foregroundColor: NSColor.secondaryLabelColor,
      ]))
    }
    label.attributedStringValue = text
    title = text.string
    setAccessibilityLabel("Open in Ray")
    invalidateIntrinsicContentSize()
    needsLayout = true
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window != nil { refreshTitle() }
  }

  override func layout() {
    super.layout()
    let height = ceil(label.intrinsicContentSize.height)
    label.frame = NSRect(x: 11, y: ((bounds.height - height) / 2).rounded(), width: bounds.width - 22, height: height)
  }

  override func updateLayer() {
    layer?.backgroundColor = ButtonLook.fill(.plain, hovered: hovered, pressed: down).cgColor
  }

  override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
  override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
  override func mouseDown(with event: NSEvent) { down = true; needsDisplay = true }
  override func mouseUp(with event: NSEvent) {
    let inside = bounds.contains(convert(event.locationInWindow, from: nil))
    down = false
    needsDisplay = true
    if inside { onClick?() }
  }
  override func accessibilityPerformPress() -> Bool {
    onClick?()
    return true
  }
}

// MARK: Link activation

/// macOS activates Ray for a link from another app, and activating an app raises all its windows: Ray's own window
/// came up over Slack under the Little Ray. Ardia's `LinkActivationOrder`: as Ray becomes active, each of its windows on
/// screen is noted with the other app's window just above it, and once the Little Ray is open they go back under those
/// (now and on the next turn, as AppKit may raise them again), so only the Little Ray comes forward. When the link
/// arrives before the activation, they're also hidden until then, so they don't flash.
final class LinkActivationOrder {
  static let shared = LinkActivationOrder()
  private struct Placement {
    weak var window: NSWindow?
    let below: Int
  }
  /// A link and its activation are one event within this (Ardia's `pairing`).
  private static let pairing: TimeInterval = 3
  private static let arrivalPairing: TimeInterval = 1
  private static let hiddenLimit: TimeInterval = 0.5
  private var placements: [Placement] = []
  private var activatedAt: Date?
  private var linkAt: Date?
  private weak var opened: NSWindow?
  private var hidden: [() -> NSWindow?] = []
  private var activation = 0
  /// For the state log: how many times windows were put back.
  private(set) var restores = 0
  private var observers: [NSObjectProtocol] = []

  private init() {
    let center = NotificationCenter.default
    observers.append(center.addObserver(forName: NSApplication.willBecomeActiveNotification, object: nil, queue: .main) {
      [weak self] _ in self?.willBecomeActive()
    })
    observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) {
      [weak self] _ in self?.didBecomeActive()
    })
  }

  /// A link for a Little Ray is in: with Ray in the background, its activation is coming.
  func linkArriving() {
    if !NSApp.isActive { linkAt = Date() }
  }

  /// The Little Ray about to be shown (and activated): it stays in front.
  func opening(_ window: NSWindow) { opened = window }

  /// It's shown: the rest go back where they were if this activation came with it.
  func shown() {
    guard opened != nil, let activatedAt, Date().timeIntervalSince(activatedAt) < Self.pairing else { return }
    keepOthersWhereTheyWere()
  }

  private var linkExpected: Bool { linkAt.map { Date().timeIntervalSince($0) < Self.arrivalPairing } == true }

  private func willBecomeActive() {
    showHidden()
    activation += 1
    placements = Self.placements()
    activatedAt = nil
    guard linkExpected else { return }
    for placement in placements {
      guard let window = placement.window, window.isVisible, window.alphaValue == 1 else { continue }
      window.alphaValue = 0
      hidden.append { [weak window] in window }
    }
    let scheduledIn = activation
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.hiddenLimit) { [weak self] in
      guard let self, self.activation == scheduledIn else { return }
      self.showHidden()
    }
  }

  private func didBecomeActive() {
    activatedAt = Date()
    if linkExpected || opened.map({ $0.isVisible }) == true && linkAt != nil {
      linkAt = nil
      keepOthersWhereTheyWere()
    } else {
      opened = nil
      showHidden()
    }
  }

  private func keepOthersWhereTheyWere() {
    let placements = placements
    let front = opened
    opened = nil
    linkAt = nil
    guard !placements.isEmpty else { return showHidden() }
    restores += 1
    Self.restore(placements)
    front?.orderFrontRegardless()
    let scheduledIn = activation
    DispatchQueue.main.async { [weak self, weak front] in
      guard let self, self.activation == scheduledIn else { return }
      Self.restore(placements)
      front?.makeKeyAndOrderFront(nil)
      self.showHidden()
    }
  }

  private func showHidden() {
    let windows = hidden.compactMap { $0() }
    hidden = []
    for window in windows where window.alphaValue == 0 { window.alphaValue = 1 }
  }

  private static func restore(_ placements: [Placement]) {
    for placement in placements.reversed() {
      guard let window = placement.window, window.isVisible, !window.isMiniaturized else { continue }
      window.order(.below, relativeTo: placement.below)
    }
  }

  /// Ray's windows on screen, front to back, each with the other app's window just above it (none above: left out,
  /// it was in front already). Little Rays (and their pop-ups) never: they're what comes forward.
  private static func placements() -> [Placement] {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    let pid = ProcessInfo.processInfo.processIdentifier
    var above: Int?
    var result: [Placement] = []
    for info in list where (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0 {
      guard let number = (info[kCGWindowNumber as String] as? NSNumber)?.intValue else { continue }
      guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid else {
        above = number
        continue
      }
      guard let above, let window = NSApp.window(withWindowNumber: number),
            !LittleRay.all.contains(where: { $0.window === window || $0.window === window.parent }) else { continue }
      result.append(Placement(window: window, below: above))
    }
    return result
  }
}
