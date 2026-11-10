import AppKit

// Screen sharing in Ray's own look (docs/mocks/screen-share.html; owner's picks: picker B, note B, marks A). A page's
// getDisplayMedia() reaches Ray through the page script (`displayMedia`), Ray's picker (`SharePicker.swift`) asks what
// to share, and the engine allows that one source for that frame and origin (`allowDesktopCapture`). While a share
// runs, Ray shows it: a held note at the page's top centre with Stop Sharing (and Share This Tab on another tab while a
// tab is shared), a mark on the shared and the sharing tabs' rows, and a ring round the shared page. Chrome's own bar
// (its floating "… is sharing a window" widget) is hidden the moment it shows; its tab-sharing strip Ray never drew.
//
// Why sharing Ray's own window failed in Chrome's picker: Ray's window is a Chrome views widget, so Chrome's picker
// gave it a widget id and captured it through Chrome's compositor, which never draws Ray's AppKit views or the page's
// layers. Ray's picker names every window by its macOS window number only (`window:<id>:0`), so macOS captures what is
// on screen, Ray's windows included.

enum ShareKind: String {
  case tab, window, screen
  /// Started without Ray's picker (an extension's desktopCapture): what it shows is Chrome's to know.
  case unknown
}

/// A tab's share mark in the sidebar: the tab being shared, or the tab sharing (the meeting).
enum ShareMark: String { case shared, sharing }

/// Every share running in Ray, app-wide: tabs of any window can share or be shared.
final class ScreenShares {
  static let shared = ScreenShares()
  static let didChange = Notification.Name("RayScreenSharesDidChange")

  struct Live {
    weak var capturer: RayCoreTab?
    var kind: ShareKind
    /// The page that asked, as the engine verified it.
    var origin: String
    /// The tab shared, for a tab share.
    weak var captured: RayCoreTab?
    var started: Date
  }

  private struct Grant {
    weak var capturer: RayCoreTab?
    let kind: ShareKind
    weak var captured: RayCoreTab?
    let origin: String
    let at: Date
  }

  private(set) var live: [Live] = []
  private var grants: [Grant] = []
  /// Each tab's capture state as the engine last said it.
  private var capturing: Set<ObjectIdentifier> = []
  /// For the state log: how shares ended.
  private(set) var last: [String: Any]?

  /// Ray's picker allowed a source for this tab: the capture it starts within 15 s (the engine's grant) is of it.
  func granted(_ capturer: RayCoreTab, kind: ShareKind, captured: RayCoreTab?, origin: String) {
    grants.removeAll { $0.capturer == nil || $0.capturer === capturer || Date().timeIntervalSince($0.at) > 15 }
    grants.append(Grant(capturer: capturer, kind: kind, captured: captured, origin: origin, at: Date()))
    // A tab already sharing that picks again: its new source shows once it starts.
    if capturing.contains(ObjectIdentifier(capturer)) { begin(capturer) }
  }

  /// The engine's `didChangeMediaAccess`: `screen` is true while the tab captures a tab, a window or a screen.
  func accessChanged(_ tab: RayCoreTab, screen: Bool) {
    let id = ObjectIdentifier(tab)
    if screen {
      guard !capturing.contains(id) else { return }
      capturing.insert(id)
      begin(tab)
      return
    }
    guard capturing.remove(id) != nil else { return }
    // Share This Tab Instead restarts the capture: a share ends only if it stays off for a moment (Ardia's 1.5 s).
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self, weak tab] in
      guard let self, let tab, !self.capturing.contains(ObjectIdentifier(tab)) else { return }
      self.end(tab, how: "stopped")
    }
  }

  private func begin(_ tab: RayCoreTab) {
    let grant = grants.last { $0.capturer === tab && Date().timeIntervalSince($0.at) < 20 }
    grants.removeAll { $0.capturer === tab }
    // The same share restarting (Share This Tab Instead stops and starts the capture): it stays as it is.
    if grant == nil, live.contains(where: { $0.capturer === tab }) {
      changed()
      return
    }
    let kind = grant?.kind ?? .unknown
    let share = Live(capturer: tab, kind: kind, origin: grant?.origin ?? tab.committedOrigin ?? "",
                     captured: grant?.captured, started: Date())
    live.removeAll { $0.capturer == nil || $0.capturer === tab }
    live.append(share)
    if kind != .tab { ChromeShareBar.watch() }
    changed()
  }

  private func end(_ tab: RayCoreTab, how: String) {
    guard let share = live.first(where: { $0.capturer === tab }) else { return }
    live.removeAll { $0.capturer == nil || $0.capturer === tab }
    last = ["kind": share.kind.rawValue, "how": how]
    changed()
  }

  /// A tab closed: whatever it shared or was shared is over as far as Ray shows it.
  func forget(_ tab: RayCoreTab) {
    capturing.remove(ObjectIdentifier(tab))
    let before = live.count
    live.removeAll { $0.capturer == nil || $0.capturer === tab }
    if live.count != before { changed() }
  }

  func mark(for tab: RayCoreTab) -> ShareMark? {
    if live.contains(where: { $0.captured === tab && $0.capturer != nil }) { return .shared }
    if live.contains(where: { $0.capturer === tab }) { return .sharing }
    return nil
  }

  /// The newest share whose sharing tab is in a window of `profile` (a private window's shares stay its own).
  func latest(in profile: RayCoreProfile) -> Live? {
    live.last { share in
      guard let capturer = share.capturer, !capturer.closed else { return false }
      return Self.window(of: capturer)?.profile === profile
    }
  }

  static func window(of tab: RayCoreTab) -> BrowserWindowController? {
    AppController.shared.windows.first { $0.state.entry(for: tab) != nil }
  }

  func isShared(_ tab: RayCoreTab) -> Bool { mark(for: tab) == .shared }

  /// Stop Sharing: every capture the sharing tab runs.
  func stop(_ capturer: RayCoreTab) {
    capturer.stopCapture()
    last = ["how": "stop"]
    changed()
  }

  /// The shared tab's mark, or its note: stops whoever shares it (the sharing tab's own mark stops its share).
  func stopSharing(_ tab: RayCoreTab) -> Bool {
    guard let share = live.last(where: { $0.captured === tab || $0.capturer === tab }), let capturer = share.capturer
    else { return false }
    stop(capturer)
    return true
  }

  /// Share This Tab Instead (Chrome's): the tab share moves to `tab`.
  @discardableResult
  func shareInstead(_ tab: RayCoreTab, for capturer: RayCoreTab) -> Bool {
    guard tab.canShareThisTabInstead(for: capturer), tab.shareThisTabInstead(for: capturer),
          let index = live.firstIndex(where: { $0.capturer === capturer }) else { return false }
    live[index].captured = tab
    live[index].kind = .tab
    grants.removeAll { $0.capturer === capturer }
    last = ["how": "instead"]
    changed()
    return true
  }

  private func changed() {
    NotificationCenter.default.post(name: Self.didChange, object: self)
  }

  var state: [String: Any] {
    [
      "live": live.compactMap { share -> [String: Any]? in
        guard let capturer = share.capturer else { return nil }
        return ["capturer": Int(capturer.tabId), "kind": share.kind.rawValue, "origin": share.origin,
                "captured": share.captured.map { Int($0.tabId) } ?? NSNull()]
      },
      "capturing": capturing.count, "last": last ?? NSNull(), "hiddenBars": ChromeShareBar.hidden,
    ]
  }
}

// MARK: Chrome's share bar

/// Chrome's own "… is sharing a window / your screen · Stop sharing · Hide" bar (ScreenCaptureNotificationUIViews): a
/// borderless views widget at the status level on every Space, without a parent, at the bottom of the screen. Ray
/// shows its own note instead and hides Chrome's as soon as it appears (Chrome's own Hide does the same). Looked for
/// only for a little while after a window or screen share starts. Chrome draws its tab-sharing strip in its own tab
/// strip, which Ray doesn't have, so nothing to hide for a tab.
enum ChromeShareBar {
  private(set) static var hidden = 0
  /// A stand-in for checks (`share fakebar`), which can't start a window share without Screen Recording permission.
  static let testIdentifier = NSUserInterfaceItemIdentifier("ray.test.chromeShareBar")

  static func watch() {
    for delay in [0, 0.05, 0.15, 0.4, 1, 2, 4] {
      DispatchQueue.main.asyncAfter(deadline: .now() + delay) { scan() }
    }
  }

  static func scan() {
    let ours = Set(AppController.shared.windows.map { ObjectIdentifier($0.window) })
    for window in NSApp.windows where window.isVisible && !ours.contains(ObjectIdentifier(window)) && looksLikeBar(window) {
      let wasKey = window.isKeyWindow
      window.orderOut(nil)
      hidden += 1
      TestEnvironment.log("share: hid Chrome's share bar (\(NSStringFromClass(type(of: window))), \(NSStringFromRect(window.frame)))")
      // A screen share's bar takes the focus as it shows: back to the window the person was in.
      if wasKey { AppController.shared.current?.window.makeKeyAndOrderFront(nil) }
    }
  }

  private static func looksLikeBar(_ window: NSWindow) -> Bool {
    let chromes = NSStringFromClass(type(of: window)).hasPrefix("NativeWidgetMac") || window.identifier == testIdentifier
    return chromes && window.parent == nil && window.level == .statusBar && !window.styleMask.contains(.titled)
      && window.collectionBehavior.contains(.canJoinAllSpaces) && window.frame.height < 120
  }

  #if RAY_TEST_HOOKS
  /// A window shaped as Chrome's bar is, then a scan, as after a window share starts.
  static func testFake() -> Bool {
    let bar = NSWindow(contentRect: NSRect(x: 200, y: 40, width: 420, height: 44), styleMask: .borderless,
                       backing: .buffered, defer: false)
    bar.identifier = testIdentifier
    bar.level = .statusBar
    bar.collectionBehavior = [.canJoinAllSpaces]
    bar.isReleasedWhenClosed = false
    bar.alphaValue = 0.01
    bar.ignoresMouseEvents = true
    bar.orderFront(nil)
    let before = hidden
    scan()
    let gone = !bar.isVisible && hidden == before + 1
    bar.close()
    return gone
  }
  #endif
}

// MARK: Share indicators

/// One window's view of the shares: the note at the page's top centre, the ring round a shared page, and the rows'
/// marks (the sidebar asks `ScreenShares.mark`).
final class ShareIndicators {
  static let noteKey = "screenShare"
  private weak var controller: BrowserWindowController?
  /// The share whose note ✕ put away in this window (until another share or a change of what it shows).
  private var hiddenNote: String?
  private var ring: SharedPageRing?
  private var observer: NSObjectProtocol?
  private var marked: Set<ObjectIdentifier> = []
  private(set) var noteText: String?
  var onChange: (() -> Void)?

  init(controller: BrowserWindowController) {
    self.controller = controller
    observer = NotificationCenter.default.addObserver(forName: ScreenShares.didChange, object: nil, queue: .main) {
      [weak self] _ in self?.sharesChanged()
    }
  }

  deinit { observer.map(NotificationCenter.default.removeObserver) }

  private func sharesChanged() {
    guard let controller else { return }
    // Rows whose mark changes redraw: the ones marked before and the ones marked now.
    let shares = ScreenShares.shared
    var now: Set<ObjectIdentifier> = []
    for entry in controller.state.allEntries {
      guard let tab = entry.tab, entry.isLive, shares.mark(for: tab) != nil else { continue }
      now.insert(ObjectIdentifier(tab))
    }
    for entry in controller.state.allEntries {
      guard let tab = entry.tab else { continue }
      let id = ObjectIdentifier(tab)
      if now.contains(id) || marked.contains(id) { controller.refreshRow(entry) }
    }
    marked = now
    refresh()
  }

  /// What the active tab shows: call on tab switches, panel changes and share changes.
  func refresh() {
    guard let controller else { return }
    let active = controller.activeTab
    let showsRing = active.map(ScreenShares.shared.isShared) ?? false
    if showsRing {
      if ring == nil { ring = SharedPageRing() }
      if let ring { controller.placeSharedPageRing(ring) }
    } else if let ring, ring.superview != nil {
      ring.removeFromSuperview()
    }
    updateNote(active: active)
    // The note says "Sharing this tab" in the same spot: the ring's tag only once the note is put away.
    ring?.showsTag = noteText == nil
    onChange?()
  }

  var ringShown: Bool { ring?.superview != nil }

  /// The window laid out: the ring follows the page card.
  func layout() {
    if let ring, ring.superview != nil { controller?.placeSharedPageRing(ring) }
  }

  private func updateNote(active: RayCoreTab?) {
    guard let controller else { return }
    guard let share = ScreenShares.shared.latest(in: controller.profile), let capturer = share.capturer else {
      hiddenNote = nil
      if noteText != nil { controller.notes.dismiss(key: Self.noteKey) }
      noteText = nil
      return
    }
    let isShared = active != nil && share.captured === active
    let text: String
    switch share.kind {
    case .tab: text = isShared ? "Sharing this tab" : "Sharing another tab"
    case .window: text = "Sharing a window"
    case .screen, .unknown: text = "Sharing your screen"
    }
    let identity = "\(ObjectIdentifier(capturer).hashValue)/\(share.kind.rawValue)/\(text)"
    // A panel over the page (the picker, a question) has the top centre; the note comes back when it closes.
    guard hiddenNote != identity, !controller.panels.isOpen else {
      if noteText != nil { controller.notes.dismiss(key: Self.noteKey) }
      noteText = nil
      return
    }
    var actions: [NoteAction] = []
    if share.kind == .tab, !isShared, let active, active.canShareThisTabInstead(for: capturer) {
      actions.append(NoteAction("Share This Tab") { [weak capturer, weak active] in
        guard let capturer, let active else { return }
        ScreenShares.shared.shareInstead(active, for: capturer)
      })
    }
    actions.append(NoteAction(actions.isEmpty ? "Stop Sharing" : "Stop", destructive: true) { [weak capturer] in
      capturer.map(ScreenShares.shared.stop)
    })
    actions.append(NoteAction(symbol: "xmark", label: "Hide") { [weak self] _ in
      self?.hiddenNote = identity
      self?.noteText = nil
      self?.refresh()
    })
    let note = Note(text, detail: PermissionPromptView.display(share.origin), icon: .symbol("rectangle.inset.filled"),
                    actions: actions, spot: .top, lasts: .held, key: Self.noteKey, asks: true)
    if noteText != text || !controller.notes.update(key: Self.noteKey, { $0 = note }) {
      controller.notes.show(note)
    }
    noteText = text
  }

  var state: [String: Any] {
    ["note": noteText ?? NSNull(), "ring": ringShown, "ringTag": ring?.showsTag == true && ringShown, "ringFrame": ring.map { NSStringFromRect($0.frame) } ?? NSNull()]
  }
}

// MARK: Shared page ring

/// Round the shared page while it's shown (Chrome's border round a captured tab, in the profile's colour): a 2 pt
/// ring inside the page card's corners with a faint glow, and a small "Shared" tab at its top centre (only while the
/// share note, which says as much in that spot, is put away). Ray's layer
/// over the page, so the people watching never see it. Takes no clicks.
final class SharedPageRing: NSView {
  private let line = CALayer()
  private let glow = CALayer()
  private let chip = NSView()
  private let chipIcon = NSImageView()
  private let chipLabel = NSTextField(labelWithString: "Shared")
  private var colorObserver: NSObjectProtocol?
  var showsTag = true {
    didSet { chip.isHidden = !showsTag }
  }

  init() {
    super.init(frame: .zero)
    wantsLayer = true
    layer?.masksToBounds = true
    for ring in [glow, line] {
      ring.cornerCurve = .continuous
      layer?.addSublayer(ring)
    }
    line.borderWidth = 2
    glow.borderWidth = 6
    chip.wantsLayer = true
    chip.layer?.cornerRadius = 8
    chip.layer?.cornerCurve = .continuous
    chip.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
    chipIcon.image = NSImage(systemSymbolName: "rectangle.inset.filled", accessibilityDescription: nil)
    chipIcon.symbolConfiguration = .init(pointSize: 9, weight: .semibold)
    chipLabel.font = .systemFont(ofSize: 11, weight: .semibold)
    [chipIcon, chipLabel].forEach(chip.addSubview)
    addSubview(chip)
    setAccessibilityElement(true)
    setAccessibilityRole(.staticText)
    setAccessibilityLabel("This tab is being shared")
    colorObserver = NotificationCenter.default.addObserver(forName: ProfileColor.didChange, object: nil, queue: .main) {
      [weak self] _ in self?.needsDisplay = true
    }
  }

  required init?(coder: NSCoder) { fatalError() }

  deinit { colorObserver.map(NotificationCenter.default.removeObserver) }

  override var wantsUpdateLayer: Bool { true }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func updateLayer() {
    let accent = ProfileColor.accent
    line.borderColor = accent.cgColor
    glow.borderColor = accent.withAlphaComponent(0.16).cgColor
    chip.layer?.backgroundColor = accent.cgColor
    let ink = ProfileColor.foreground(on: accent)
    chipIcon.contentTintColor = ink
    chipLabel.textColor = ink
  }

  override func layout() {
    super.layout()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    let radius = layer?.cornerRadius ?? 0
    line.frame = bounds
    line.cornerRadius = radius
    glow.frame = bounds.insetBy(dx: 2, dy: 2)
    glow.cornerRadius = max(0, radius - 2)
    CATransaction.commit()
    let labelSize = chipLabel.intrinsicContentSize
    let width = ceil(labelSize.width) + 12 + 5 + 16
    chip.frame = NSRect(x: ((bounds.width - width) / 2).rounded(), y: bounds.height - 20, width: width, height: 20)
    chipIcon.frame = NSRect(x: 8, y: 4, width: 12, height: 12)
    let height = ceil(labelSize.height)
    chipLabel.frame = NSRect(x: 25, y: ((20 - height) / 2).rounded(), width: ceil(labelSize.width) + 2, height: height)
  }
}

#if RAY_TEST_HOOKS
// MARK: Share snapshots

/// For tests (`share snap <path>`): a view drawn from its layers into `<path>-light.png` and `<path>-dark.png` at 2×
/// on the surfaces' solid colour, to look at the picker, or the window (sidebar marks, the note, the page's ring;
/// the page itself is Chrome's and draws nothing here).
enum ShareSnapshot {
  static func draw(_ view: NSView, to path: String) -> Bool {
    for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
      let old = view.appearance
      view.appearance = NSAppearance(named: appearance)
      defer { view.appearance = old }
      view.layoutSubtreeIfNeeded()
      view.displayIfNeeded()
      view.subviews.forEach { $0.displayIfNeeded() }
      CATransaction.flush()
      guard let layer = view.layer else { return false }
      let size = view.bounds.size
      guard let context = CGContext(data: nil, width: Int(size.width * 2), height: Int(size.height * 2), bitsPerComponent: 8,
                                    bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
      context.scaleBy(x: 2, y: 2)
      view.effectiveAppearance.performAsCurrentDrawingAppearance { context.setFillColor(SurfaceBackdrop.solidFill.cgColor) }
      context.fill(CGRect(origin: .zero, size: size))
      if view.isFlipped {
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
      }
      layer.render(in: context)
      guard let image = context.makeImage(),
            let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]),
            (try? png.write(to: URL(fileURLWithPath: "\(path)-\(name).png"))) != nil else { return false }
    }
    return true
  }
}
#endif

