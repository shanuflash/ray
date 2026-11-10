import AppKit
import ScreenCaptureKit

// Ray's screen-sharing picker (owner's pick B, docs/mocks/screen-share.html): a question from the page's top centre
// over the tab that asked, Tabs / Windows / Screen, cards with a picture of each, Cancel and Share. Nothing is chosen
// when it opens and Share waits for a choice; its buttons are dead for 0.5 s each time it appears; Return does nothing
// (a page brought it); Escape, a click outside or the page going to another site is "don't share"; a tab switch puts
// it away until the tab is back. The full origin of the frame that asked (which gets the stream) is from the engine.
// Tabs need nothing from macOS; windows and screens need Screen Recording permission, without which the picker says
// so and offers System Settings (Ray never asks macOS by itself). Test builds list fake windows and screens and never
// call ScreenCaptureKit.

struct ShareSource {
  /// The engine's source id for a window or screen; "tab:<entry id>" for a tab (its capture id is read at Share).
  let id: String
  let kind: ShareKind
  let title: String
  var picture: CGImage?
  var icon: NSImage?
  weak var tab: RayCoreTab?
}

/// A page's getDisplayMedia(), as the page script sent it and the engine vouched for it.
struct ShareRequest {
  let pageId: Int
  let frame: String
  /// The asking frame's origin, from the engine: the one the stream goes to.
  let origin: String
  /// The tab's site when it asked: another site cancels it.
  let site: String?
  let audio: Bool
  let systemAudio: Bool
  let windowAudio: String
  /// The page's `displaySurface` hint: the picker opens on that kind.
  let surface: String
  /// False when the page asked to leave its own tab out (`selfBrowserSurface: "exclude"`).
  let selfTab: Bool
  weak var tab: RayCoreTab?

  /// The page script's message, checked field by field; nil when anything is off.
  static func parse(_ json: String, tab: RayCoreTab, frame: String, origin: String) -> ShareRequest? {
    guard json.utf8.count <= 1024, let data = json.data(using: .utf8),
          let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let id = message["id"] as? NSNumber, CFGetTypeID(id) != CFBooleanGetTypeID(),
          let pageId = Int(exactly: id.doubleValue), pageId >= 1, pageId <= Int(Int32.max),
          !frame.isEmpty, frame.count <= 64, origin.hasPrefix("http") || origin.hasPrefix("file") || origin == "null",
          origin.count <= 2048 else { return nil }
    func flag(_ key: String) -> Bool { (message[key] as? Bool) ?? false }
    func choice(_ key: String, _ allowed: [String]) -> String {
      (message[key] as? String).flatMap { allowed.contains($0) ? $0 : nil } ?? ""
    }
    return ShareRequest(
      pageId: pageId, frame: frame, origin: origin, site: tab.committedOrigin, audio: flag("audio"),
      systemAudio: flag("systemAudio"), windowAudio: choice("windowAudio", ["exclude", "window", "system"]),
      surface: choice("surface", ["browser", "window", "monitor"]), selfTab: (message["selfTab"] as? Bool) ?? true,
      tab: tab)
  }

  /// The audio the engine is told to share with a source of this kind, when the box is ticked (Ardia's rules: a
  /// tab's own sound; a screen's system sound where macOS can; a window's app or system sound as the page prefers).
  func audioOffer(for kind: ShareKind) -> (label: String, engine: String)? {
    guard audio else { return nil }
    let support = RayCoreEngine.desktopCaptureAudio
    let system = support["system"]?.boolValue == true, application = support["application"]?.boolValue == true
    switch kind {
    case .tab: return ("Share tab audio", "tab")
    case .screen: return system && systemAudio ? ("Share system audio", "system") : nil
    case .window:
      if windowAudio == "window" { return application ? ("Share app audio", "application") : system ? ("Share system audio", "system") : nil }
      if windowAudio == "system" { return system ? ("Share system audio", "system") : nil }
      return nil
    case .unknown: return nil
    }
  }
}

// MARK: Share sources

/// Windows and screens to offer, and their pictures, from ScreenCaptureKit (only with Screen Recording permission).
enum ShareSources {
  #if RAY_TEST_HOOKS
  /// Test builds: whether the fake permission is granted (`share permission on|off`).
  static var testPermission = false
  #endif

  static var hasPermission: Bool {
    #if RAY_TEST_HOOKS
    return testPermission
    #else
    return CGPreflightScreenCaptureAccess()
    #endif
  }

  /// Privacy › Screen Recording, after asking macOS once (which lists Ray there).
  static func openSettings() {
    #if RAY_TEST_HOOKS
    TestEnvironment.log("share: open Screen Recording settings")
    #else
    if !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess() }
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
      NSWorkspace.shared.open(url)
    }
    #endif
  }

  /// Every window (on screen, normal level, not tiny; Ray's own only its browser windows) and screen.
  static func desktop(_ done: @escaping ([ShareSource]) -> Void) {
    guard hasPermission else { return done([]) }
    #if RAY_TEST_HOOKS
    done([
      ShareSource(id: "window:4242:0", kind: .window, title: "Fake Window — Fake App"),
      ShareSource(id: "window:4243:0", kind: .window, title: "Notes"),
      ShareSource(id: "screen:1:0", kind: .screen, title: "Fake Display"),
    ])
    #else
    SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: true) { content, _ in
      DispatchQueue.main.async {
        guard let content else { return done([]) }
        let ours = Set(AppController.shared.windows.map { CGWindowID($0.window.windowNumber) })
        let me = ProcessInfo.processInfo.processIdentifier
        var sources: [ShareSource] = []
        for window in content.windows where window.windowLayer == 0 && window.frame.width >= 50 && window.frame.height >= 50 {
          guard let app = window.owningApplication else { continue }
          if app.processID == me && !ours.contains(window.windowID) { continue }
          let title = window.title.flatMap { $0.isEmpty ? nil : $0 } ?? app.applicationName
          guard !title.isEmpty else { continue }
          let named = title == app.applicationName || app.applicationName.isEmpty ? title : "\(title) — \(app.applicationName)"
          sources.append(ShareSource(
            id: "window:\(window.windowID):0", kind: .window, title: named,
            icon: NSRunningApplication(processIdentifier: app.processID)?.icon))
        }
        for display in content.displays {
          let screen = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.displayID }
          sources.append(ShareSource(id: "screen:\(display.displayID):0", kind: .screen,
                                     title: screen?.localizedName ?? "Display \(display.displayID)"))
        }
        // Screens in the order macOS lists them, the main one first.
        done(sources)
      }
    }
    #endif
  }

  /// Pictures of these windows or screens, one by one as they come (about 2× a card).
  static func pictures(of sources: [ShareSource], _ each: @escaping (String, CGImage) -> Void) {
    #if !RAY_TEST_HOOKS
    guard hasPermission, !sources.isEmpty else { return }
    SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: true) { content, _ in
      guard let content else { return }
      for source in sources {
        let filter: SCContentFilter
        let size: CGSize
        if source.kind == .window, let window = content.windows.first(where: { "window:\($0.windowID):0" == source.id }) {
          filter = SCContentFilter(desktopIndependentWindow: window)
          size = window.frame.size
        } else if source.kind == .screen, let display = content.displays.first(where: { "screen:\($0.displayID):0" == source.id }) {
          filter = SCContentFilter(display: display, excludingWindows: [])
          size = CGSize(width: display.width, height: display.height)
        } else { continue }
        guard size.width > 0, size.height > 0 else { continue }
        let config = SCStreamConfiguration()
        let scale = min(1, 320 / size.width, 200 / size.height) * 2
        config.width = max(2, Int(size.width * scale))
        config.height = max(2, Int(size.height * scale))
        config.showsCursor = false
        SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) { image, _ in
          guard let image else { return }
          DispatchQueue.main.async { each(source.id, image) }
        }
      }
    }
    #endif
  }
}

// MARK: Share picker

/// One window's picker: the requests its tabs made, the one shown over the active tab.
final class SharePicker {
  static let segments: [(title: String, kind: ShareKind)] = [("Tabs", .tab), ("Windows", .window), ("Screen", .screen)]

  private weak var controller: BrowserWindowController?
  private var waiting: [ShareRequest] = []
  private var shown: (request: ShareRequest, view: SharePickerView, handle: PanelHandle)?
  private var closingQuietly = false
  private var segment = 0
  private var selected: String?
  private var audioOn: [ShareKind: Bool] = [.tab: true]
  private var desktop: [ShareSource] = []
  private var desktopPictures: [String: CGImage] = [:]
  private var tabPictures: [UUID: CGImage] = [:]
  private var refresher: Timer?
  /// For the state log: the last answer and the source kind.
  private(set) var last: [String: Any]?
  var onChange: (() -> Void)?

  init(controller: BrowserWindowController) {
    self.controller = controller
  }

  // MARK: Asking

  /// The page script's `displayMedia`, with the engine's frame and verified origin. The engine only passes it with
  /// the permissions policy's display-capture and a click.
  func asked(_ json: String, tab: RayCoreTab, frame: String, origin: String) {
    guard let request = ShareRequest.parse(json, tab: tab, frame: frame, origin: origin) else { return }
    // One per tab: a second ask replaces the first, which gets "no".
    for old in waiting where old.tab === tab { answer(old, sourceId: nil, audio: nil) }
    waiting.removeAll { $0.tab === tab }
    if let shown, shown.request.tab === tab {
      self.shown = nil
      answer(shown.request, sourceId: nil, audio: nil)
      closeQuietly(shown.handle)
    }
    waiting.append(request)
    update()
  }

  /// Shows the active tab's request if no other panel is open; call when tabs switch or a panel closes.
  func update() {
    for request in waiting where request.tab == nil || request.tab?.closed == true || request.tab?.committedOrigin != request.site {
      answer(request, sourceId: nil, audio: nil)
    }
    waiting.removeAll { $0.tab == nil || $0.tab?.closed == true || $0.tab?.committedOrigin != $0.site }
    guard let controller, shown == nil, !controller.panels.isOpen,
          let request = waiting.first(where: { $0.tab === controller.activeTab && $0.tab != nil }) else {
      onChange?()
      return
    }
    show(request, in: controller)
  }

  private func show(_ request: ShareRequest, in controller: BrowserWindowController) {
    segment = ["window": 1, "monitor": 2][request.surface] ?? 0
    selected = nil
    audioOn = [.tab: true]
    let view = SharePickerView(origin: PermissionPromptView.display(request.origin))
    view.onSegment = { [weak self] index in
      guard let self else { return }
      self.segment = index
      self.selected = nil
      self.reload()
    }
    view.onSelect = { [weak self] id in
      self?.selected = id
      self?.render()
    }
    view.onAudio = { [weak self] on in
      guard let self, let kind = self.selectedSource?.kind else { return }
      self.audioOn[kind] = on
      self.onChange?()
    }
    view.onShare = { [weak self] in self?.share() }
    view.onCancel = { [weak self] in self?.cancel(how: "button") }
    view.onOpenSettings = { ShareSources.openSettings() }
    let handle = controller.panels.open(PanelSpec(
      name: "sharePicker", content: view, anchor: controller.questionAnchor,
      closesOn: [.escape, .tabSwitch, .otherSite], origin: request.site, asks: true,
      onClose: { [weak self, weak view] in
        guard let self, let view, self.shown?.view === view else { return }
        self.shown = nil
        self.refresher?.invalidate()
        if self.closingQuietly { return }
        // A tab switch or another panel puts it away for later; Escape or another site is "don't share".
        if let reason = controller.panels.lastClosedBy, reason == "tabSwitch" || reason == "another" {
          self.onChange?()
        } else {
          self.waiting.removeAll { $0.tab === request.tab && $0.pageId == request.pageId }
          self.answer(request, sourceId: nil, audio: nil, how: "closed")
        }
      }))
    shown = (request, view, handle)
    // The asking tab is the shown one: a fresh picture of it.
    if let entry = controller.state.entry(for: request.tab!) { pictureTab(entry) }
    reload()
    refresher?.invalidate()
    refresher = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in self?.reload() }
    onChange?()
  }

  private func reload() {
    render()
    ShareSources.desktop { [weak self] sources in
      guard let self, self.shown != nil else { return }
      self.desktop = sources
      self.desktopPictures = self.desktopPictures.filter { id, _ in sources.contains { $0.id == id } }
      if let selected = self.selected, selected.hasPrefix("window:") || selected.hasPrefix("screen:"),
         !sources.contains(where: { $0.id == selected }) { self.selected = nil }
      self.render()
      self.loadPictures()
    }
  }

  private func loadPictures() {
    guard segment > 0 else { return }
    let kind = Self.segments[segment].kind
    ShareSources.pictures(of: desktop.filter { $0.kind == kind }) { [weak self] id, image in
      guard let self, self.shown != nil else { return }
      self.desktopPictures[id] = image
      self.render()
    }
  }

  private func pictureTab(_ entry: SidebarEntry) {
    guard let tab = entry.tab, !tab.closed else { return }
    let id = entry.id
    tab.copyPicture(1) { [weak self] picture in
      guard let self, let picture else { return }
      self.tabPictures[id] = picture
      if self.shown != nil { self.render() }
    }
  }

  /// This profile's open web pages in every window, the asking tab first, then the most recently used.
  private var tabs: [ShareSource] {
    guard let controller, let request = shown?.request else { return [] }
    let windows = AppController.shared.windows.filter { $0.profile === controller.profile }
    var entries: [(SidebarEntry, BrowserWindowController)] = []
    for window in windows {
      for entry in window.state.allEntries where !entry.isFolder && entry.isLive {
        guard let tab = entry.tab, !tab.closed, let scheme = URL(string: tab.url)?.scheme,
              ["http", "https", "file"].contains(scheme) else { continue }
        if tab === request.tab && !request.selfTab { continue }
        entries.append((entry, window))
      }
    }
    entries.sort { a, b in
      if a.0.tab === request.tab { return true }
      if b.0.tab === request.tab { return false }
      return a.0.lastActive > b.0.lastActive
    }
    return entries.map { entry, window in
      ShareSource(id: "tab:\(entry.id.uuidString)", kind: .tab, title: entry.displayTitle,
                  picture: tabPictures[entry.id] ?? window.tabPicture(of: entry),
                  icon: window.sidebarIcon(for: entry), tab: entry.tab)
    }
  }

  private var shownSources: [ShareSource] {
    let kind = Self.segments[segment].kind
    if kind == .tab { return tabs }
    return desktop.filter { $0.kind == kind }.map { source in
      var source = source
      source.picture = desktopPictures[source.id]
      return source
    }
  }

  private var selectedSource: ShareSource? { selected.flatMap { id in shownSources.first { $0.id == id } } }

  private func render() {
    guard let shown else { return }
    let kind = Self.segments[segment].kind
    let offer = selectedSource.flatMap { shown.request.audioOffer(for: $0.kind) }
    let audio = offer.map { ($0.label, audioOn[selectedSource!.kind] ?? false) }
    shown.view.show(segment: segment, sources: shownSources, needsPermission: kind != .tab && !ShareSources.hasPermission,
                    selected: selected, audio: audio)
    shown.handle.contentChanged()
    onChange?()
  }

  // MARK: Answering

  private func share() {
    guard let shown, shown.view.ready, let source = selectedSource, let tab = shown.request.tab, !tab.closed else { return }
    let request = shown.request
    var sourceId = source.id
    if source.kind == .tab {
      guard let shared = source.tab, !shared.closed, let id = shared.mediaCaptureSourceId else { return cancel(how: "gone") }
      sourceId = id
    }
    let offer = request.audioOffer(for: source.kind)
    let audio = offer != nil && audioOn[source.kind] == true ? offer!.engine : nil
    self.shown = nil
    refresher?.invalidate()
    closeQuietly(shown.handle)
    waiting.removeAll { $0.tab === tab && $0.pageId == request.pageId }
    ScreenShares.shared.granted(tab, kind: source.kind, captured: source.kind == .tab ? source.tab : nil, origin: request.origin)
    RayCoreEngine.allowDesktopCapture(sourceId, tab: tab, frame: request.frame, origin: request.origin, audio: audio)
    answer(request, sourceId: sourceId, audio: audio, how: "share", kind: source.kind)
    update()
  }

  private func cancel(how: String) {
    guard let shown else { return }
    self.shown = nil
    refresher?.invalidate()
    closeQuietly(shown.handle)
    waiting.removeAll { $0.tab === shown.request.tab && $0.pageId == shown.request.pageId }
    answer(shown.request, sourceId: nil, audio: nil, how: how)
    update()
  }

  private func closeQuietly(_ handle: PanelHandle) {
    closingQuietly = true
    handle.close()
    closingQuietly = false
  }

  /// The page's answer: the source to open, or nil (the page's promise rejects with NotAllowedError).
  private func answer(_ request: ShareRequest, sourceId: String?, audio: String?, how: String = "replaced", kind: ShareKind? = nil) {
    if let tab = request.tab, !tab.closed {
      let reply: [String: Any] = ["id": request.pageId, "sourceId": sourceId ?? NSNull(), "audio": audio != nil]
      if let data = try? JSONSerialization.data(withJSONObject: reply), let json = String(data: data, encoding: .utf8) {
        tab.callFrame(request.frame, kind: "displayMedia", json: json)
      }
    }
    last = ["answer": sourceId == nil ? "cancel" : "share", "how": how, "kind": kind?.rawValue ?? NSNull(),
            "source": sourceId.map { $0.hasPrefix("web-contents-media-stream:") ? "tab" : $0 } ?? NSNull(),
            "audio": audio ?? NSNull()]
    onChange?()
  }

  // MARK: Share picker tests

  var state: [String: Any] {
    var open: Any = NSNull()
    if let shown {
      open = [
        "origin": shown.request.origin, "segment": Self.segments[segment].title, "ready": shown.view.ready,
        "items": shownSources.map { ["title": $0.title, "kind": $0.kind.rawValue, "picture": $0.picture != nil,
                                     "icon": $0.icon != nil, "self": $0.tab != nil && $0.tab === shown.request.tab] },
        "selected": selected.flatMap { id in shownSources.firstIndex { $0.id == id } } ?? NSNull(),
        "shareEnabled": shown.view.shareEnabled, "audio": shown.view.audioState ?? NSNull(),
        "needsPermission": shown.view.needsPermission, "message": shown.view.message ?? NSNull(),
        "size": NSStringFromSize(shown.view.frame.size), "activeTab": shown.request.tab === controller?.activeTab,
      ] as [String: Any]
    }
    return ["open": open, "waiting": waiting.count, "last": last ?? NSNull()]
  }

  /// `share segment <n>|pick <n>|double <n>|audio|press share|cancel|settings|escape`, as the controls would.
  func test(_ argument: String) -> String {
    let words = argument.split(separator: " ").map(String.init)
    guard let shown else { return "no picker" }
    let view = shown.view
    switch (words.first, words.count > 1 ? Int(words[1]) : nil) {
    case ("segment", let n?) where SharePicker.segments.indices.contains(n): view.pressSegment(n)
    case ("pick", let n?) where shownSources.indices.contains(n): view.pressCard(n, double: false)
    case ("double", let n?) where shownSources.indices.contains(n): view.pressCard(n, double: true)
    case ("audio", _): return view.pressAudio() ? "ok" : "no audio box"
    case ("press", _) where words.count == 2:
      switch words[1] {
      case "share": return view.pressShare()
      case "cancel": return view.pressCancel()
      case "settings": return view.pressSettings() ? "ok" : "no settings button"
      default: return "usage: share press share|cancel|settings"
      }
    case ("escape", _): shown.handle.close()
    #if RAY_TEST_HOOKS
    case ("snap", _) where words.count == 2: return ShareSnapshot.draw(view, to: words[1]) ? "ok" : "no picture"
    #endif
    default: return "usage: share segment|pick|double <n>, share audio, share press share|cancel|settings, share escape"
    }
    return "ok"
  }
}

// MARK: Share picker view

/// The picker's content: header, Tabs / Windows / Screen, a grid of cards (two rows, scrolling), the audio box,
/// Cancel and Share. A fixed size, so switching kinds doesn't reshape the panel.
final class SharePickerView: NSView {
  static let width: CGFloat = 460
  private static let pad: CGFloat = 14
  private static let columns = 3
  private static let cardHeight: CGFloat = 118
  private static let gridHeight: CGFloat = cardHeight * 2 + 4

  var onSegment: ((Int) -> Void)?
  var onSelect: ((String) -> Void)?
  var onAudio: ((Bool) -> Void)?
  var onShare: (() -> Void)?
  var onCancel: (() -> Void)?
  var onOpenSettings: (() -> Void)?
  private(set) var ready = false
  private(set) var needsPermission = false
  private var selected: String?
  private var shownCount = 0

  private let icon = NSImageView()
  private let titleLabel = NSTextField(labelWithString: "Choose what to share")
  private let originLabel: NSTextField
  private let segments = RaySegmentedControl(titles: SharePicker.segments.map(\.title))
  private let scroll = NSScrollView()
  private let grid = FlippedView()
  private var cards: [ShareCardView] = []
  private let messageLabel = NSTextField(wrappingLabelWithString: "")
  private let settingsButton = PanelButton(title: "Open Settings")
  private let separator = CALayer()
  private let audioBox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
  private let cancelButton = PanelButton(title: "Cancel")
  private let shareButton = PanelButton(title: "Share", primary: true)

  init(origin: String) {
    originLabel = NSTextField(wrappingLabelWithString: origin)
    super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 10))
    wantsLayer = true
    icon.image = NSImage(systemSymbolName: "rectangle.inset.filled.and.person.filled", accessibilityDescription: nil)
    icon.symbolConfiguration = .init(pointSize: 15, weight: .medium)
    icon.imageScaling = .scaleNone
    icon.wantsLayer = true
    icon.layer?.cornerRadius = 9
    icon.layer?.cornerCurve = .continuous
    titleLabel.font = .systemFont(ofSize: 13.5, weight: .semibold)
    originLabel.font = .systemFont(ofSize: 12)
    originLabel.textColor = .secondaryLabelColor
    originLabel.lineBreakMode = .byCharWrapping
    originLabel.maximumNumberOfLines = 2
    for label in [titleLabel, originLabel, messageLabel] { label.isSelectable = false }
    segments.onChoose = { [weak self] index in self?.onSegment?(index) }
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = true
    scroll.scrollerStyle = .overlay
    scroll.autohidesScrollers = true
    scroll.documentView = grid
    messageLabel.font = .systemFont(ofSize: 12)
    messageLabel.textColor = .secondaryLabelColor
    messageLabel.alignment = .center
    settingsButton.onClick = { [weak self] in self?.onOpenSettings?() }
    audioBox.font = .systemFont(ofSize: 12)
    audioBox.refusesFirstResponder = true
    audioBox.target = self
    audioBox.action = #selector(audioChanged)
    cancelButton.onClick = { [weak self] in self?.onCancel?() }
    shareButton.onClick = { [weak self] in self?.onShare?() }
    [icon, titleLabel, originLabel, segments, scroll, messageLabel, settingsButton, audioBox, cancelButton, shareButton]
      .forEach(addSubview)
    layer?.addSublayer(separator)
    setAccessibilityElement(true)
    setAccessibilityRole(.group)
    setAccessibilityLabel("Choose what to share")
    frame.size.height = layoutContent(apply: false)
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }
  override var mouseDownCanMoveWindow: Bool { false }
  override var wantsUpdateLayer: Bool { true }

  override func updateLayer() {
    icon.layer?.backgroundColor = PanelColors.tile.cgColor
    icon.contentTintColor = .secondaryLabelColor
    separator.backgroundColor = NSColor.separatorColor.cgColor
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    needsDisplay = true
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guard window != nil else { return }
    // Each time it appears its buttons wait, so a click meant for the page can't land on one.
    shownCount += 1
    let shown = shownCount
    ready = false
    updateButtons()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
      guard let self, self.window != nil, self.shownCount == shown else { return }
      self.ready = true
      self.updateButtons()
    }
  }

  var shareEnabled: Bool { shareButton.isEnabled }
  var audioState: [String: Any]? { audioBox.isHidden ? nil : ["label": audioBox.title, "on": audioBox.state == .on] }
  var message: String? { messageLabel.isHidden ? nil : messageLabel.stringValue }

  private func updateButtons() {
    cancelButton.isEnabled = ready
    shareButton.isEnabled = ready && selected != nil
    settingsButton.isEnabled = ready
  }

  func show(segment: Int, sources: [ShareSource], needsPermission: Bool, selected: String?, audio: (String, Bool)?) {
    segments.selectedIndex = segment
    self.selected = selected
    self.needsPermission = needsPermission
    // Cards are kept by source, so a picture that's coming isn't lost when the list refreshes.
    let old = Dictionary(cards.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    cards = needsPermission ? [] : sources.map { source in
      let card = old[source.id] ?? ShareCardView(id: source.id)
      card.show(source, selected: source.id == selected)
      card.onClick = { [weak self] double in
        guard let self else { return }
        self.onSelect?(source.id)
        if double, self.ready { self.onShare?() }
      }
      return card
    }
    grid.subviews.filter { view in !cards.contains { $0 === view } }.forEach { $0.removeFromSuperview() }
    cards.filter { $0.superview !== grid }.forEach(grid.addSubview)
    if needsPermission {
      messageLabel.stringValue = "Ray needs Screen Recording permission to share windows and screens."
    } else if sources.isEmpty {
      messageLabel.stringValue = segment == 0 ? "No tabs to share" : segment == 1 ? "No windows to share" : "No screens to share"
    }
    messageLabel.isHidden = !needsPermission && !sources.isEmpty
    settingsButton.isHidden = !needsPermission
    audioBox.isHidden = audio == nil
    if let audio {
      audioBox.title = audio.0
      audioBox.state = audio.1 ? .on : .off
    }
    updateButtons()
    needsLayout = true
  }

  @objc private func audioChanged() { onAudio?(audioBox.state == .on) }

  override func layout() {
    super.layout()
    _ = layoutContent(apply: true)
  }

  private func layoutContent(apply: Bool) -> CGFloat {
    let pad = Self.pad, width = Self.width, inner = width - pad * 2
    var y = pad
    let textX = pad + 36 + 11, textWidth = width - textX - pad
    let titleHeight = ceil(titleLabel.intrinsicContentSize.height)
    let originHeight = ceil(originLabel.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: textWidth, height: 200)).height ?? 16)
    if apply {
      icon.frame = NSRect(x: pad, y: y, width: 36, height: 36)
      titleLabel.frame = NSRect(x: textX, y: y + 1, width: textWidth, height: titleHeight)
      originLabel.frame = NSRect(x: textX, y: y + 1 + titleHeight + 1, width: textWidth, height: originHeight)
    }
    y += max(36, 1 + titleHeight + 1 + originHeight) + 12
    if apply { segments.frame = NSRect(x: pad, y: y, width: inner, height: 26) }
    y += 26 + 8
    let gridRect = NSRect(x: 8, y: y, width: width - 16, height: Self.gridHeight)
    if apply {
      scroll.frame = gridRect
      let cardWidth = floor((gridRect.width - CGFloat(Self.columns - 1) * 4) / CGFloat(Self.columns))
      for (index, card) in cards.enumerated() {
        let row = index / Self.columns, column = index % Self.columns
        card.frame = NSRect(x: CGFloat(column) * (cardWidth + 4), y: CGFloat(row) * (Self.cardHeight + 4),
                            width: cardWidth, height: Self.cardHeight)
      }
      let rows = (cards.count + Self.columns - 1) / Self.columns
      grid.frame = NSRect(x: 0, y: 0, width: gridRect.width, height: max(gridRect.height, CGFloat(rows) * (Self.cardHeight + 4) - 4))
      let messageWidth = inner - 40
      let messageHeight = ceil(messageLabel.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: messageWidth, height: 100)).height ?? 16)
      let block = messageHeight + (settingsButton.isHidden ? 0 : 12 + 28)
      let top = gridRect.midY - block / 2
      messageLabel.frame = NSRect(x: pad + 20, y: top.rounded(), width: messageWidth, height: messageHeight)
      let settingsWidth = settingsButton.fittingSize.width
      settingsButton.frame = NSRect(x: ((width - settingsWidth) / 2).rounded(), y: (top + messageHeight + 12).rounded(),
                                    width: settingsWidth, height: 28)
    }
    y += Self.gridHeight + 10
    if apply {
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      separator.frame = CGRect(x: 0, y: y, width: width, height: 1 / max(1, window?.backingScaleFactor ?? 2))
      CATransaction.commit()
    }
    y += 12
    if apply {
      let shareWidth = shareButton.fittingSize.width, cancelWidth = cancelButton.fittingSize.width
      shareButton.frame = NSRect(x: width - pad - shareWidth, y: y, width: shareWidth, height: 28)
      cancelButton.frame = NSRect(x: shareButton.frame.minX - 6 - cancelWidth, y: y, width: cancelWidth, height: 28)
      let boxHeight = ceil(audioBox.intrinsicContentSize.height)
      audioBox.frame = NSRect(x: pad, y: y + ((28 - boxHeight) / 2).rounded(), width: cancelButton.frame.minX - pad - 8,
                              height: boxHeight)
    }
    y += 28 + 12
    return y
  }

  // MARK: Share picker view tests

  func pressSegment(_ index: Int) { onSegment?(index) }
  func pressCard(_ index: Int, double: Bool) { cards[index].onClick?(double) }
  func pressAudio() -> Bool {
    guard !audioBox.isHidden else { return false }
    audioBox.performClick(nil)
    return true
  }
  func pressShare() -> String {
    guard shareButton.isEnabled else { return ready ? "nothing chosen" : "not ready" }
    shareButton.performClick(nil)
    return "ok"
  }
  func pressCancel() -> String {
    guard cancelButton.isEnabled else { return "not ready" }
    cancelButton.performClick(nil)
    return "ok"
  }
  func pressSettings() -> Bool {
    guard !settingsButton.isHidden, settingsButton.isEnabled else { return false }
    settingsButton.performClick(nil)
    return true
  }
}

/// One source: its picture (a tab's page, a window, a screen) with the icon in its middle until there is one, and its
/// name. Chosen: the selected row's wash and a 2 pt ring in the profile's colour round the picture.
final class ShareCardView: NSView {
  let id: String
  var onClick: ((Bool) -> Void)?
  private let picture = CALayer()
  private let ring = CALayer()
  private let placeholder = NSImageView()
  private let name = NSTextField(labelWithString: "")
  private var selected = false
  private var hovered = false

  init(id: String) {
    self.id = id
    super.init(frame: .zero)
    wantsLayer = true
    layer?.cornerRadius = 9
    layer?.cornerCurve = .continuous
    picture.cornerRadius = 6
    picture.cornerCurve = .continuous
    picture.masksToBounds = true
    picture.contentsGravity = .resizeAspectFill
    picture.borderWidth = 0.5
    ring.cornerRadius = 7
    ring.cornerCurve = .continuous
    ring.borderWidth = 2
    layer?.addSublayer(picture)
    layer?.addSublayer(ring)
    placeholder.imageScaling = .scaleProportionallyUpOrDown
    name.font = .systemFont(ofSize: 12)
    name.alignment = .center
    name.lineBreakMode = .byTruncatingTail
    name.maximumNumberOfLines = 1
    [placeholder, name].forEach(addSubview)
    setAccessibilityElement(true)
    setAccessibilityRole(.radioButton)
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }
  override var wantsUpdateLayer: Bool { true }
  override var mouseDownCanMoveWindow: Bool { false }

  func show(_ source: ShareSource, selected: Bool) {
    self.selected = selected
    name.stringValue = source.title
    toolTip = source.title
    setAccessibilityLabel(source.title)
    setAccessibilityValue(selected ? 1 : 0)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    picture.contents = source.picture
    CATransaction.commit()
    placeholder.isHidden = source.picture != nil
    if source.picture == nil {
      let symbol = source.kind == .screen ? "display" : source.kind == .window ? "macwindow" : "globe"
      placeholder.image = source.icon ?? NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
      placeholder.contentTintColor = source.icon == nil ? .secondaryLabelColor : nil
      placeholder.symbolConfiguration = .init(pointSize: 20, weight: .regular)
    }
    needsDisplay = true
  }

  override func updateLayer() {
    let surface = SurfaceBackdrop.solidFill
    layer?.backgroundColor = (selected ? SelectedRow.fill(over: surface) : hovered ? PanelColors.tileHover : .clear).cgColor
    picture.backgroundColor = PanelColors.tile.cgColor
    picture.borderColor = PanelColors.border.cgColor
    ring.borderColor = ProfileColor.accent.cgColor
    ring.isHidden = !selected
  }

  override func layout() {
    super.layout()
    let frame = NSRect(x: 8, y: 8, width: bounds.width - 16, height: 78)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    // The layer's own space is flipped for a flipped view.
    picture.frame = frame
    ring.frame = frame.insetBy(dx: -1, dy: -1)
    CATransaction.commit()
    let size: CGFloat = placeholder.image?.isTemplate == false ? 32 : 26
    placeholder.frame = NSRect(x: frame.midX - size / 2, y: frame.midY - size / 2, width: size, height: size)
    let height = ceil(name.intrinsicContentSize.height)
    name.frame = NSRect(x: 6, y: frame.maxY + 6, width: bounds.width - 12, height: height)
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    trackingAreas.forEach(removeTrackingArea)
    addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                   owner: self, userInfo: nil))
  }

  override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
  override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
  override func mouseUp(with event: NSEvent) {
    guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
    onClick?(event.clickCount >= 2)
  }
  override func mouseDown(with event: NSEvent) {}

  override func accessibilityPerformPress() -> Bool {
    onClick?(false)
    return true
  }
}
