import AppKit

final class BrowserWindowController: NSObject, RayCoreWindowDelegate, RayCoreTabDelegate, SidebarViewDelegate,
  CommandBarDelegate, FindBarDelegate, PageToolbarDelegate {
  enum CommandBarMode: String {
    case newTab
    case currentTab
  }

  private static let margin: CGFloat = 8
  private static let logsState = TestEnvironment["RAY_LOG_STATE"] == "1"

  let coreWindow: RayCoreWindow
  let profile: RayCoreProfile
  var onClose: (() -> Void)?

  private let root = WindowDragArea()
  private let sidebar = SidebarView()
  private let floating = FloatingSidebarFrame()
  private let pages = PageContainerView()
  private let toolbar = PageToolbarView()
  /// For tests: frames laid out mid-way through the last sidebar toggle, with the address bar's buttons part way in.
  private var navigationSteps = 0
  var toolbarShown: Bool { state.pageToolbar ?? true }
  private var commandBar: CommandBarView?
  private var commandBarMode = CommandBarMode.newTab
  private let history = HistoryCache()
  let searches = SearchSuggestions()
  private let favicons = FaviconCache()
  private let store: SidebarStore
  private(set) var state: SidebarState
  private var loadingEntry: SidebarEntry?
  private var peeking = false
  private var peekEndWork: DispatchWorkItem?
  /// Ctrl+Tab through recently used tabs: the order when it began (most recent first), where it is, and each tab's
  /// `lastActive` from before, so stepping through tabs doesn't reorder them.
  private struct TabCycle {
    var order: [SidebarEntry]
    var index: Int
    var lastActive: [UUID: Date]
  }
  private var tabCycle: TabCycle?
  /// The cycle is moving the selection itself (so `select` doesn't take that for the user going elsewhere).
  private var cycling = false
  /// Page zoom: the host each tab was last settled for, by tab id, and the hosts zoomed in this private window
  /// (nothing a private window does goes to Settings.json).
  private var zoomHosts: [Int32: String] = [:]
  private var privateZoomed: Set<String> = []
  private var applyingZoom = false
  private var lastDownloadProgress: Double?
  private lazy var dockSpring = Spring(value: state.sidebarHidden ? 0 : 1, response: 0.26, dampingRatio: 0.86) {
    [weak self] _ in self?.layout()
  }
  private static let fullScreenRowCenter: CGFloat = 24
  private static let revealWidth: CGFloat = 14
  private static let outsideReach: CGFloat = 24
  private static let holdSlack: CGFloat = 24
  private static let peekInset: CGFloat = 5
  private static let peekHideDelay: TimeInterval = 0.12
  private var pointerMonitors: [Any] = []
  private static let peekResponse: CGFloat = 0.14
  private static let peekDamping: CGFloat = 0.805
  private lazy var peekSpring = Spring(value: 0, response: Self.peekResponse, dampingRatio: Self.peekDamping) {
    [weak self] value in
    self?.layout()
    if value <= 0.001, self?.peeking == false { self?.finishPeek() }
  }

  var window: NSWindow { coreWindow.window }

  var activeEntry: SidebarEntry? { state.activeEntryID.flatMap(state.entry(id:)) }

  func owns(_ tab: RayCoreTab) -> Bool { state.entry(for: tab) != nil }
  /// The puzzle button in the sidebar's address field, or the sliders button while that field is hidden.
  var extensionsAnchor: NSView { sidebar.showsAddress ? sidebar.extensionsAnchor : toolbar.siteButton }

  var activeTab: RayCoreTab? { activeEntry.flatMap { $0.isLive ? $0.tab : nil } }

  var tabs: [RayCoreTab] { state.allEntries.compactMap { $0.isLive ? $0.tab : nil } }

  /// The normal profile behind this window: itself, or for a private window the profile it's the private side of.
  let mainProfile: RayCoreProfile
  var isPrivate: Bool { profile.offTheRecord }

  init(profile: RayCoreProfile, mainProfile: RayCoreProfile, store: SidebarStore) {
    self.profile = profile
    self.mainProfile = mainProfile
    self.store = store
    state = store.load() ?? SidebarState()
    state.archiveStaleToday()
    coreWindow = RayCoreWindow(contentRect: NSRect(x: 0, y: 0, width: 1360, height: 860))
    super.init()
    coreWindow.delegate = self
    coreWindow.activeProfile = profile
    configureWindow()
    sidebar.delegate = self
    let host = coreWindow.hostView
    root.frame = host.bounds
    root.autoresizingMask = [.width, .height]
    root.wantsLayer = true
    root.addSubview(pages)
    toolbar.delegate = self
    root.addSubview(toolbar)
    root.addSubview(sidebar)
    root.addSubview(floating)
    floating.isHidden = true
    host.addSubview(root)
    NotificationCenter.default.addObserver(
      self, selector: #selector(hostResized), name: NSView.frameDidChangeNotification, object: root)
    for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
      NotificationCenter.default.addObserver(self, selector: #selector(fullScreenChanged), name: name, object: window)
    }
    root.postsFrameChangedNotifications = true
    migrateLegacySettings()
    reloadSidebar()
    layout()
    installPointerMonitors()
    let center = NotificationCenter.default
    center.addObserver(self, selector: #selector(settingsChanged(_:)), name: RaySettings.didChange, object: nil)
    center.addObserver(self, selector: #selector(profileColorChanged), name: ProfileColor.didChange, object: nil)
    center.addObserver(self, selector: #selector(windowResignedKey), name: NSWindow.didResignKeyNotification, object: window)
    // Zoom levels the engine already holds are the user's own; the default zoom only touches the rest.
    RaySettings.shared.adoptExistingZoom(profile: mainProfile) { [weak self] in self?.settleZoomOfAllTabs() }
  }

  deinit {
    pointerMonitors.forEach(NSEvent.removeMonitor)
    NotificationCenter.default.removeObserver(self)
  }

  private func configureWindow() {
    let frame = window.frame
    window.styleMask.insert(.fullSizeContentView)
    if window.frame != frame { window.setFrame(frame, display: false) }
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    window.title = isPrivate ? "Ray — Private" : "Ray"
    if isPrivate {
      // Private windows are always dark and purple-tinted, with a Private badge, as Arc and Chrome mark theirs.
      window.appearance = NSAppearance(named: .darkAqua)
      sidebar.isPrivate = true
      floating.isPrivate = true
    }
    window.minSize = NSSize(width: 720, height: 460)
    window.backgroundColor = isPrivate ? SidebarColors.privateBackground : SidebarColors.background
    window.isReleasedWhenClosed = false
    window.isRestorable = false
    window.animationBehavior = .none
    window.tabbingMode = .disallowed
    window.acceptsMouseMovedEvents = true
  }

  // MARK: Layout

  @objc private func hostResized() { layout() }

  @objc private func fullScreenChanged() {
    layout()
    guard !closing, state.fullScreen != isFullScreen else { return }
    state.fullScreen = isFullScreen
    store.save(state)
  }

  private var isFullScreen: Bool { window.styleMask.contains(.fullScreen) }

  private static let windowedRowCenter: CGFloat = 26

  private func layout() {
    let bounds = root.bounds
    let margin = Self.margin
    let width = SidebarView.width
    let shown = dockSpring.value
    let peek = peekSpring.value

    if peeking || peek > 0.001 {
      let inset = Self.peekInset
      floating.frame = NSRect(
        x: inset - (width + 12) * (1 - peek), y: inset, width: width, height: bounds.height - inset * 2)
      sidebar.frame = floating.bounds
      sidebar.trafficLightsCenterY = isFullScreen ? Self.fullScreenRowCenter : Self.windowedRowCenter
      sidebar.reservesTrafficLights = !isFullScreen
    } else {
      sidebar.frame = NSRect(x: -width * (1 - shown), y: 0, width: width, height: bounds.height)
      sidebar.trafficLightsCenterY = isFullScreen ? Self.fullScreenRowCenter : Self.windowedRowCenter
      sidebar.reservesTrafficLights = !isFullScreen
    }
    let edge = isFullScreen ? margin * shown : margin
    let cardX = max(edge, width * shown)
    // Whole points only: Chrome's content layer follows the page by CALayer autoresizing, which rounds each
    // step to a point, so fractional sizes made the page creep a little further on every ⌘S.
    let left = cardX.rounded(), right = (bounds.width - edge).rounded()
    let bottom = edge.rounded()
    var top = (bounds.height - edge).rounded()
    toolbar.isHidden = !toolbarShown
    sidebar.showsAddress = !toolbarShown || sidebar.superview === floating
    toolbar.showsFullAddress = fullAddressShown
    toolbar.showsLoadingWash = RaySettings.shared.values.loadingProgress
    // One load indicator: the page's own line only when the address bar above it is off, and neither when Settings
    // turns progress off.
    pages.showsProgress = !toolbarShown && RaySettings.shared.values.loadingProgress
    if toolbarShown {
      // The address bar sits above the card, at the window's top edge, across the card's width.
      let height = PageToolbarView.height
      toolbar.frame = NSRect(x: left, y: bounds.height - height, width: max(0, right - left), height: height)
      toolbar.navigation = 1 - shown
      if toolbar.navigation > 0.05 && toolbar.navigation < 0.95 { navigationSteps += 1 }
      top = (bounds.height - height).rounded()
    }
    pages.frame = NSRect(x: left, y: bottom, width: max(0, right - left), height: max(0, top - bottom))
    pages.cornerRadius = isFullScreen ? PageContainerView.radius * shown : PageContainerView.radius
    permissions.update()
    layoutToast()
    layoutSiteControls()
    if let findBar {
      let size = FindBarView.size
      findBar.frame = NSRect(x: pages.frame.maxX - size.width - 12, y: pages.frame.maxY - size.height - 12,
                             width: size.width, height: size.height)
    }
    updateTrafficLights()
  }

  private func updateTrafficLights() {
    for kind: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
      window.standardWindowButton(kind)?.isHidden = !isFullScreen
    }
  }

  // MARK: Extensions and downloads

  private(set) lazy var extensions: ExtensionsController = {
    let controller = ExtensionsController(profile: profile, coreWindow: coreWindow)
    controller.onChange = { [weak self, weak controller] in
      guard let self, let controller else { return }
      self.sidebar.setExtensionsShown(controller.items.contains { $0.enabled })
      self.logState("extensions")
    }
    controller.openPage = { [weak self] url in self?.openToday(url, after: nil, foreground: true) }
    return controller
  }()

  private(set) lazy var downloads: DownloadsController = {
    let controller = DownloadsController(profile: mainProfile, offTheRecord: isPrivate)
    controller.onChange = { [weak self] newlyWaiting in self?.downloadsChanged(newlyWaiting: newlyWaiting) }
    return controller
  }()
  private var downloadsList: DownloadsListView?

  private func downloadsChanged(newlyWaiting: Bool) {
    let items = downloads.items
    let active = items.filter { $0.active && !$0.waiting }
    let progress = active.isEmpty ? nil : active.map(\.fraction).reduce(0, +) / Double(active.count)
    lastDownloadProgress = progress
    sidebar.setDownloads(progress: progress)
    if let downloadsList {
      downloadsList.show(items)
      sidebar.layoutDownloadsPanel()
    }
    if newlyWaiting {
      // A held download needs an answer: open the list where it can be given.
      showDownloads()
    } else if let started = items.first, started.active, !sidebar.downloadsOpen, started.received == 0 {
      showToast("Downloading \(started.filename)", symbol: "arrow.down.circle") { [weak self] in self?.showDownloads() }
    }
    logState("downloads")
  }

  /// The downloads panel slides up from the sidebar's footer; with the sidebar hidden, the sidebar comes out first
  /// and stays out while the panel is open.
  func showDownloads() {
    guard !sidebar.downloadsOpen else { return }
    downloads.loadHistory()
    if state.sidebarHidden && !peeking { beginPeek() }
    sidebar.layoutSubtreeIfNeeded()
    let list = DownloadsListView(frame: .zero)
    list.width = sidebar.downloadsPanelWidth
    list.controller = downloads
    list.onClose = { [weak self] in self?.closeDownloads() }
    list.show(downloads.items)
    downloadsList = list
    sidebar.openDownloads(DownloadsPanelView(list: list))
    logState("downloads")
  }

  func closeDownloads() {
    guard sidebar.downloadsOpen else { return }
    sidebar.closeDownloads()
    downloadsList = nil
    logState("downloads")
  }

  func toggleDownloads() {
    sidebar.downloadsOpen ? closeDownloads() : showDownloads()
  }

  // MARK: Test snapshots

  /// For tests: draws the page toolbar into a PNG (light appearance), to look at its design.
  func snapshotToolbar(to path: String) -> Bool {
    let view = toolbar
    let old = view.appearance
    view.appearance = NSAppearance(named: .aqua)
    defer { view.appearance = old }
    view.layoutSubtreeIfNeeded()
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
    view.cacheDisplay(in: view.bounds, to: rep)
    guard let png = rep.representation(using: .png, properties: [:]) else { return false }
    return (try? png.write(to: URL(fileURLWithPath: path))) != nil
  }

  /// For tests: draws the open downloads list into a PNG, to look at its design.
  func snapshotDownloads(to path: String) -> Bool {
    guard let panel = sidebar.downloadsPanel else { return false }
    for (name, appearance, view) in [("light", NSAppearance.Name.aqua, panel as NSView), ("dark", .darkAqua, panel),
                                     ("sidebar", .aqua, sidebar)] {
      let old = view.appearance
      view.appearance = NSAppearance(named: appearance)
      view.layoutSubtreeIfNeeded()
      view.displayIfNeeded()
      guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
      view.cacheDisplay(in: view.bounds, to: rep)
      let image = NSImage(size: view.bounds.size)
      image.lockFocus()
      (appearance == .aqua ? NSColor(white: 0.97, alpha: 1) : NSColor(white: 0.17, alpha: 1)).setFill()
      NSRect(origin: .zero, size: view.bounds.size).fill()
      rep.draw(in: NSRect(origin: .zero, size: view.bounds.size))
      image.unlockFocus()
      view.appearance = old
      guard let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
      else { return false }
      let file = path.replacingOccurrences(of: ".png", with: "-\(name).png")
      guard (try? png.write(to: URL(fileURLWithPath: file))) != nil else { return false }
    }
    return true
  }

  /// For tests: Keep or Discard through the open list's buttons.
  func pressDownload(_ id: String, keep: Bool) -> Bool {
    downloadsList?.row(for: id)?.press(keep: keep) ?? false
  }

  /// For tests: the pointer over a point of the window, as the sidebar's tracking areas would see it.
  func hoverSidebar(at point: NSPoint) { sidebar.debugHover(at: point) }

  /// For tests: Done in the open folder rename.
  func pressRenameDone() -> Bool { sidebar.debugPressRenameDone() }

  // MARK: Arc import

  private var arcPrompt: (alert: NSAlert, data: ArcImport)?

  /// File › Import from Arc…: Arc's favorites, and its pinned tabs and folders (one folder per space when there are
  /// several, until Ray has Spaces). Asks first; tabs come in closed and open when clicked.
  func importFromArc() {
    guard arcPrompt == nil else { return }
    let alert = NSAlert()
    guard let arc = ArcImport.load() else {
      alert.messageText = "Arc's sidebar wasn't found"
      alert.informativeText = "Ray looks for it in ~/Library/Application Support/Arc."
      alert.beginSheetModal(for: window)
      return
    }
    let counts = arc.counts
    alert.messageText = "Import from Arc?"
    let spaces = arc.spaces.map(\.name).joined(separator: ", ")
    alert.informativeText = "\(counts.favorites) favorites and \(counts.tabs) pinned tabs in \(counts.folders) folders"
      + (spaces.isEmpty ? "" : ", from \(spaces)") + ". They come in closed and open when you click them; "
      + "anything already in Ray isn't added twice. Arc's unpinned tabs stay behind."
    alert.addButton(withTitle: "Import")
    alert.addButton(withTitle: "Cancel")
    arcPrompt = (alert, arc)
    logState("arcImport")
    alert.beginSheetModal(for: window) { [weak self] response in
      guard let self else { return }
      self.arcPrompt = nil
      if response == .alertFirstButtonReturn { self.apply(arc) } else { self.logState("arcImport") }
    }
  }

  private func apply(_ arc: ArcImport) {
    var known = Set(state.allEntries.filter { !$0.isFolder }.map { $0.pinnedURL ?? $0.url })
    for case .tab(let url, let title) in arc.favorites where known.insert(url).inserted {
      state.favorites.append(SidebarEntry(kind: .favorite, url: url, title: title))
    }
    var added: [SidebarEntry] = []
    func add(_ nodes: [ArcImport.Node], in parent: UUID?) {
      for node in nodes {
        switch node {
        case .tab(let url, let title):
          guard known.insert(url).inserted else { continue }
          let entry = SidebarEntry(kind: .pinned, url: url, title: title)
          entry.parentID = parent
          added.append(entry)
        case .folder(let title, let children):
          let folder = SidebarEntry.folder(title, in: parent)
          folder.isOpen = false
          added.append(folder)
          let before = added.count
          add(children, in: folder.id)
          // Nothing new inside (all already in Ray): leave the folder out.
          if added.count == before { added.removeLast() }
        }
      }
    }
    if arc.spaces.count == 1 {
      add(arc.spaces[0].pinned, in: nil)
    } else {
      add(arc.spaces.map { ArcImport.Node.folder(title: $0.name, children: $0.pinned) }, in: nil)
    }
    state.pinned += added
    state.normalizePinned()
    changed("arcImport")
  }

  /// For tests: the import question on screen, and answering it.
  var arcImportShown: [String: Any]? {
    arcPrompt.map { ["favorites": $0.data.counts.favorites, "tabs": $0.data.counts.tabs, "folders": $0.data.counts.folders] }
  }

  func answerArcImport(_ accept: Bool) -> Bool {
    guard let arcPrompt else { return false }
    arcPrompt.alert.buttons[accept ? 0 : 1].performClick(nil)
    return true
  }

  // MARK: Permission prompts

  private(set) lazy var permissions: PermissionPrompts = {
    let prompts = PermissionPrompts()
    prompts.host = { [unowned self] in (self.root, self.pages.frame, self.activeTab) }
    prompts.onChange = { [weak self] in self?.logState("permission") }
    return prompts
  }()

  // MARK: Toast

  private lazy var toast = ToastView()

  func showToast(_ message: String, symbol: String? = nil, figure: Bool = false, action: (() -> Void)? = nil) {
    if toast.superview !== root { root.addSubview(toast, positioned: .above, relativeTo: nil) }
    toast.show(message, symbol: symbol, figure: figure, action: action)
    layoutToast()
    logState("toast")
  }

  /// Top right of the page card, 8 pt in (below the find bar while that's open).
  private func layoutToast() {
    guard toast.superview != nil else { return }
    let size = toast.fit(max(120, pages.frame.width - 16))
    let below = findBar.map { $0.frame.height + 8 } ?? 0
    toast.frame = NSRect(x: pages.frame.maxX - size.width - 8, y: pages.frame.maxY - size.height - 8 - below,
                         width: size.width, height: size.height)
  }

  // MARK: Find in page

  private var findBar: FindBarView?
  private weak var findTab: RayCoreTab?

  func showFind() {
    guard let tab = activeTab else { return }
    if findTab !== tab { closeFind() }
    let bar = findBar ?? FindBarView(frame: .zero)
    if findBar == nil {
      bar.delegate = self
      root.addSubview(bar, positioned: .above, relativeTo: pages)
      findBar = bar
      layout()
    }
    findTab = tab
    bar.focus()
    logState("find")
  }

  func findAgain(forward: Bool) {
    guard let findBar, findTab === activeTab, !findBar.text.isEmpty else { return showFind() }
    forward ? findBar.findNext() : findBar.findPrevious()
  }

  func closeFind() {
    guard let findBar else { return }
    findTab?.stopFinding()
    findBar.removeFromSuperview()
    self.findBar = nil
    let tab = findTab
    findTab = nil
    if let tab, tab === activeTab { focusPage(tab) }
    logState("find")
  }

  func findBar(_ bar: FindBarView, find text: String, forward: Bool) {
    findTab?.find(text, forward: forward)
  }

  func findBarClose(_ bar: FindBarView) { closeFind() }

  // MARK: Site controls

  private var siteControls: SiteControlsView?
  private var siteControlsMonitor: Any?
  /// Where popovers from the panel's actions (share, an extension's popup) hang once the panel has gone: the
  /// panel's top right, under the sliders button.
  private let siteAnchor = NSView()

  func toggleSiteControls() {
    siteControls == nil ? showSiteControls() : closeSiteControls()
  }

  func showSiteControls() {
    guard siteControls == nil, let entry = activeEntry, entry.isLive, let tab = entry.tab, !tab.closed else { return }
    extensions.refresh()
    let enabled = extensions.items.filter(\.enabled)
    let states = tab.actionStates(forExtensions: enabled.map(\.id))
    let items = enabled.map { item -> SiteControlsView.Extension in
      let state = states[item.id] as? [String: Any]
      return .init(id: item.id, name: item.name,
                   icon: extensions.icon(for: item, state: state),
                   enabled: state?["enabled"] as? Bool ?? true)
    }
    let level = tab.securityInfo["level"] as? String ?? "none"
    let isInternal = URLComponents(string: tab.url)?.scheme.map { ["chrome", AddressInput.internalScheme].contains($0) } ?? false
    let panel = SiteControlsView(
      origin: tab.committedOrigin, url: tab.url, profile: profile, security: level, isInternal: isInternal, extensions: items,
      zoom: tab.zoomFactor, defaultZoom: RaySettings.shared.values.defaultZoom,
      resetZoom: { [weak self, weak tab] in if let tab { self?.resetZoom(of: tab) } })
    panel.onAction = { [weak self, weak tab] action in
      guard let self, let tab, !tab.closed else { return }
      self.siteControlsAction(action, tab: tab)
    }
    panel.onClose = { [weak self] in self?.closeSiteControls() }
    if siteAnchor.superview !== root { root.addSubview(siteAnchor) }
    root.addSubview(panel, positioned: .below, relativeTo: floating)
    siteControls = panel
    toolbar.siteButton.isHeld = true
    layoutSiteControls()
    panel.animateIn()
    // A click anywhere else in the window, or Escape, closes it. App-local: only Ray's own events.
    siteControlsMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) {
      [weak self] event in
      guard let self, let panel = self.siteControls else { return event }
      if event.type == .keyDown {
        guard event.keyCode == 53, event.window === self.window else { return event }
        self.closeSiteControls()
        return nil
      }
      guard event.window === self.window else { return event }
      let point = self.root.convert(event.locationInWindow, from: nil)
      let button = self.toolbar.siteButton
      let onButton = self.toolbarShown && button.convert(button.bounds, to: self.root).contains(point)
      if !panel.frame.contains(point) && !onButton { self.closeSiteControls() }
      return event
    }
    logState("siteControls")
  }

  func closeSiteControls() {
    guard let panel = siteControls else { return }
    siteControls = nil
    if let siteControlsMonitor { NSEvent.removeMonitor(siteControlsMonitor) }
    siteControlsMonitor = nil
    toolbar.siteButton.isHeld = false
    panel.dismiss()
    logState("siteControls")
  }

  /// Under the sliders button, its right edge on the button's; with the address bar off, the page's top right.
  private func layoutSiteControls() {
    let size = siteControls?.frame.size ?? NSSize(width: SiteControlsView.width, height: 0)
    let right = toolbarShown ? toolbar.frame.maxX - 4 : pages.frame.maxX - 8
    let top = toolbarShown ? toolbar.frame.minY - 2 : pages.frame.maxY - 8
    siteAnchor.frame = NSRect(x: right - 28, y: top - 1, width: 28, height: 1)
    siteControls?.frame = NSRect(x: right - size.width, y: top - size.height, width: size.width, height: size.height)
  }

  private func siteControlsAction(_ action: SiteControlsView.Action, tab: RayCoreTab) {
    let origin = siteControls?.origin
    closeSiteControls()
    switch action {
    case .share:
      guard let url = URL(string: tab.url), !tab.url.isEmpty else { return }
      NSSharingServicePicker(items: [url]).show(relativeTo: siteAnchor.bounds, of: siteAnchor, preferredEdge: .minY)
    case .copyLink: copyURL()
    case .find: showFind()
    case .cast:
      if !tab.showCastDialog() { showToast("Casting isn't available on this page") }
    case .addExtension: openToday("https://chromewebstore.google.com/category/extensions", after: nil, foreground: true)
    case .runExtension(let id): extensions.run(id, on: tab, anchor: siteAnchor)
    case .siteSettings:
      guard let origin, let site = origin.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { return }
      openToday("chrome://settings/content/siteDetails?site=\(site)", after: activeEntry, foreground: true)
    case .developerTools: toggleDevTools()
    case .clearData:
      guard let origin, let host = URLComponents(string: origin)?.host else { return }
      let alert = NSAlert()
      alert.messageText = "Clear cookies and site data for \(host)?"
      alert.informativeText = "You'll be signed out of this site, and anything it keeps on your Mac will be deleted."
      alert.addButton(withTitle: "Cancel")
      alert.addButton(withTitle: "Clear").hasDestructiveAction = true
      alert.beginSheetModal(for: window) { [weak self, weak tab] response in
        guard response == .alertSecondButtonReturn, let self else { return }
        EngineCalls.call("ac_site_data_clear", profile: self.profile, args: ["origin": origin]) { [weak self] _ in
          tab?.reload()
          self?.showToast("Cleared Site Data")
        }
      }
    }
  }

  /// For tests: presses one of the panel's tiles, or sets a permission through it.
  func siteControlsCommand(_ words: [String]) -> Bool {
    guard let panel = siteControls else { return false }
    switch words.first {
    case "press": return words.count == 2 && panel.press(words[1])
    case "set":
      guard words.count == 3 else { return false }
      panel.set(words[1], to: words[2]) { [weak self] in
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self?.logState("siteControls") }
      }
      return true
    default: return false
    }
  }

  /// For tests: draws the open panel into PNGs (light and dark), to look at its design.
  func snapshotSiteControls(to path: String) -> Bool {
    guard let panel = siteControls else { return false }
    for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
      let old = panel.appearance
      panel.appearance = NSAppearance(named: appearance)
      panel.layoutSubtreeIfNeeded()
      panel.displayIfNeeded()
      defer { panel.appearance = old }
      guard let rep = panel.bitmapImageRepForCachingDisplay(in: panel.bounds) else { return false }
      panel.cacheDisplay(in: panel.bounds, to: rep)
      let image = NSImage(size: panel.bounds.size)
      image.lockFocus()
      panel.effectiveAppearance.performAsCurrentDrawingAppearance { PanelColors.background.setFill() }
      NSBezierPath(roundedRect: NSRect(origin: .zero, size: panel.bounds.size), xRadius: 14, yRadius: 14).fill()
      rep.draw(in: NSRect(origin: .zero, size: panel.bounds.size))
      image.unlockFocus()
      guard let tiff = image.tiffRepresentation,
            let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return false }
      guard (try? png.write(to: URL(fileURLWithPath: path.replacingOccurrences(of: ".png", with: "-\(name).png")))) != nil
      else { return false }
    }
    return true
  }

  @objc private func windowBecameKey() { AppController.shared.noteFocused(self) }

  func present(background: Bool) {
    AppController.shared.noteFocused(self)
    NotificationCenter.default.addObserver(self, selector: #selector(windowBecameKey), name: NSWindow.didBecomeKeyNotification, object: window)
    extensions.refresh()
    _ = downloads
    window.center()
    if background {
      // Test instances never go full screen: it would take over a Space in front of the user.
      coreWindow.showInactive()
    } else {
      window.makeKeyAndOrderFront(nil)
      if state.fullScreen == true {
        DispatchQueue.main.async { [weak self] in
          guard let self, !self.isFullScreen else { return }
          self.window.toggleFullScreen(nil)
        }
      }
    }
    layout()
  }

  func restore(startURL: String?) {
    if let entry = activeEntry ?? state.today.first ?? state.pinned.first(where: { !$0.isFolder }) {
      select(entry)
    } else if let startURL {
      openToday(startURL, after: nil, foreground: true)
    } else {
      beginNewTab()
    }
  }

  private var closing = false

  func prepareForQuit() {
    guard !closing else { return }
    store.saveNow(state)
    closing = true
  }

  func resumeAfterCancelledQuit() {
    guard closing else { return }
    closing = false
    for entry in state.allEntries where entry.tab?.closed == true {
      entry.tab = nil
      if entry.kind == .today { state.remove(entry) }
    }
    changed("quitCancelled")
  }

  // MARK: Entries

  private func reloadSidebar() {
    sidebar.show(favorites: state.favorites, pinned: state.pinned, today: state.today, active: activeEntry)
    sidebar.showAddress(activeEntry)
    sidebar.setNavigation(canGoBack: activeTab?.canGoBack ?? false, canGoForward: activeTab?.canGoForward ?? false)
    updateToolbar()
  }

  private var forcedOpen: Bool { state.sidebarHidden && activeEntry.map { !$0.isLive } ?? true }

  private func updateForcedPeek() {
    if forcedOpen {
      if !peeking { beginPeek() }
    } else if peeking, peekForced {
      peekForced = false
      schedulePeekEnd()
    }
    peekForced = forcedOpen
  }

  private var peekForced = false

  private func changed(_ event: String) {
    guard !closing else { return }
    updateForcedPeek()
    reloadSidebar()
    store.save(state)
    logState(event)
  }

  @discardableResult
  func openToday(_ url: String, after opener: SidebarEntry?, foreground: Bool) -> SidebarEntry {
    let entry = SidebarEntry(kind: .today, url: url)
    insertToday(entry, after: opener)
    load(entry, foreground: foreground)
    if foreground { select(entry) } else { changed("insert") }
    return entry
  }

  private func insertToday(_ entry: SidebarEntry, after opener: SidebarEntry?) {
    var opener = opener
    // Settings › Open new tabs next to the active tab: one with no opener goes right after the active one (when
    // that is in Today; otherwise at the top as usual).
    if opener == nil, RaySettings.shared.values.newTabNextToActive, let active = activeEntry, active.kind == .today {
      opener = active
    }
    if let opener, opener.kind == .today, let index = state.today.firstIndex(where: { $0 === opener }) {
      state.today.insert(entry, at: index + 1)
    } else {
      state.today.insert(entry, at: 0)
    }
  }

  private func load(_ entry: SidebarEntry, foreground: Bool) {
    guard !entry.isLive else { return }
    loadingEntry = entry
    let tab = coreWindow.openTab(entry.url, profile: profile, foreground: foreground)
    loadingEntry = nil
    if entry.tab !== tab { bind(entry, tab) }
  }

  private func bind(_ entry: SidebarEntry, _ tab: RayCoreTab) {
    entry.tab = tab
    tab.delegate = self
    pages.attach(tab)
  }

  func select(_ entry: SidebarEntry) {
    if entry.isFolder {
      perform(.toggleFolder, on: entry)
      return
    }
    load(entry, foreground: true)
    guard let tab = entry.tab, !tab.closed else { return }
    pages.show(tab)
    coreWindow.activate(tab)
    let switched = state.activeEntryID != entry.id
    // Going to a tab by any other way ends a Ctrl+Tab in progress.
    if switched, !cycling { tabCycle = nil }
    if switched, findTab != nil, findTab !== tab { closeFind() }
    if switched { closeSiteControls() }
    state.activeEntryID = entry.id
    if switched { permissions.update() }
    entry.lastActive = Date()
    if commandBar == nil { focusPage(tab) }
    if switched { changed("activate") }
  }

  func selectEntry(id: UUID) -> Bool {
    guard let entry = state.entry(id: id) else { return false }
    select(entry)
    return true
  }

  private func showNothing() {
    state.activeEntryID = nil
    pages.showNothing()
    changed("activate")
  }

  private func activateNeighbor(of index: Int, in list: [SidebarEntry]) {
    let candidates = list.indices.sorted { abs($0 - index) < abs($1 - index) }.map { list[$0] }
    if let next = candidates.first(where: { $0.isLive }) ?? state.allEntries.first(where: { $0.isLive }) {
      select(next)
    } else {
      showNothing()
    }
  }

  /// ⌘W: closes the active tab; with no tab open, the window (as Chrome and Arc do).
  func closeActive() {
    guard let entry = activeEntry else {
      window.performClose(nil)
      return
    }
    if entry.isLive {
      entry.tab?.close()
    } else if entry.kind == .today {
      state.remove(entry)
      changed("remove")
    }
  }

  func perform(_ action: SidebarRowAction, on entry: SidebarEntry) {
    switch action {
    case .close, .unload:
      if entry.isLive {
        entry.tab?.close()
      } else if entry.kind == .today {
        state.remove(entry)
        changed("remove")
      }
      return
    case .backToPinned:
      if let target = entry.pinnedURL, let tab = entry.tab, entry.isLive {
        tab.loadURL(target, userInitiated: true)
      }
      return
    case .pin:
      guard entry.kind == .today else { return }
      move(entry, to: .pinned(state.pinned.count, parent: nil))
      return
    case .unpin:
      guard entry.kind == .pinned else { return }
      move(entry, to: .today(0))
      return
    case .renameFolder:
      sidebar.beginRename(entry)
      return
    case .toggleFolder:
      guard entry.isFolder else { return }
      entry.isOpen = !(entry.isOpen ?? true)
    case .newFolder:
      // Around this tab: a new folder where it is, with the tab inside, named and ready to rename.
      let folder = SidebarEntry.folder("New Folder", in: entry.kind == .pinned ? entry.parentID : nil)
      let at = entry.kind == .pinned ? state.pinned.firstIndex { $0 === entry } ?? state.pinned.count : state.pinned.count
      state.pinned.insert(folder, at: at)
      move(entry, to: .folder(folder.id))
      sidebar.beginRename(folder)
      return
    case .newNestedFolder:
      guard entry.isFolder else { return }
      let folder = SidebarEntry.folder("New Folder", in: entry.id)
      entry.isOpen = true
      state.pinned.append(folder)
      state.normalizePinned()
      changed("sidebar")
      sidebar.beginRename(folder)
      return
    case .moveToFolder(let id):
      move(entry, to: .folder(id))
      return
    case .removeFromFolder:
      guard let parentID = entry.parentID, let parent = state.entry(id: parentID) else { return }
      let end = (state.pinned.firstIndex { $0 === parent } ?? 0) + state.block(of: parent).count
      move(entry, to: .pinned(end, parent: parent.parentID))
      return
    case .deleteFolder:
      // As in Crest: the folder goes, what was inside moves up a level.
      guard entry.isFolder else { return }
      for child in state.pinned where child.parentID == entry.id { child.parentID = entry.parentID }
      state.pinned.removeAll { $0 === entry }
      state.normalizePinned()
    case .addToFavorites:
      guard entry.kind != .favorite else { return }
      move(entry, to: .favorites(state.favorites.count))
      return
    case .removeFromFavorites:
      guard entry.kind == .favorite else { return }
      state.favorites.removeAll { $0 === entry }
      if entry.isLive {
        entry.kind = .today
        entry.pinnedURL = nil
        state.today.insert(entry, at: 0)
      } else if state.activeEntryID == entry.id {
        state.activeEntryID = nil
      }
    }
    changed("sidebar")
  }

  /// Moves an entry to a section and place; pinning keeps the page it's on as its pinned URL. A folder moves with
  /// everything inside it, and only within the pinned section.
  func move(_ entry: SidebarEntry, to target: SidebarDropTarget) {
    guard state.entry(id: entry.id) === entry else { return }
    let block = entry.kind == .pinned || entry.isFolder ? state.block(of: entry) : [entry]
    var parent: UUID?
    switch target {
    case .pinned(_, let id): parent = id
    case .folder(let id): parent = id
    case .favorites, .today:
      if entry.isFolder { return }
    }
    if let parent, parent == entry.id || block.contains(where: { $0.id == parent }) { return }
    if let parent, state.pinned.first(where: { $0.id == parent })?.isFolder != true { return }
    state.favorites.removeAll { $0 === entry }
    state.pinned.removeAll { item in block.contains { $0 === item } }
    state.today.removeAll { $0 === entry }
    entry.parentID = nil
    switch target {
    case .favorites(let index):
      if entry.pinnedURL == nil { entry.pinnedURL = entry.currentURL }
      entry.kind = .favorite
      state.favorites.insert(entry, at: min(index, state.favorites.count))
    case .pinned(let index, let parent):
      pin(block, at: index, in: parent)
    case .folder(let id):
      let folder = state.pinned.first { $0.id == id }!
      folder.isOpen = true
      pin(block, at: (state.pinned.firstIndex { $0 === folder } ?? 0) + state.block(of: folder).count, in: id)
    case .today(let index):
      entry.kind = .today
      entry.pinnedURL = nil
      state.today.insert(entry, at: min(index, state.today.count))
    }
    changed("sidebar")
  }

  private func pin(_ block: [SidebarEntry], at index: Int, in parent: UUID?) {
    guard let entry = block.first else { return }
    if !entry.isFolder {
      if entry.pinnedURL == nil { entry.pinnedURL = entry.currentURL }
      entry.kind = .pinned
    }
    entry.parentID = parent
    state.pinned.insert(contentsOf: block, at: min(index, state.pinned.count))
    state.normalizePinned()
  }

  /// File › New Folder: an empty folder at the end of the pinned tabs, named and ready to rename.
  func newFolder() {
    let folder = SidebarEntry.folder("New Folder", in: nil)
    state.pinned.append(folder)
    changed("sidebar")
    sidebar.beginRename(folder)
  }

  func rename(_ entry: SidebarEntry, to title: String) {
    let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard entry.isFolder, state.entry(id: entry.id) === entry else { return }
    entry.title = title.isEmpty ? "New Folder" : String(title.prefix(200))
    changed("sidebar")
  }

  func togglePin() {
    guard let entry = activeEntry else { return }
    perform(entry.kind == .today ? .pin : .unpin, on: entry)
  }

  func backToPinned() {
    guard let entry = activeEntry else { return }
    perform(.backToPinned, on: entry)
  }

  func clearToday() {
    for entry in state.today {
      if entry.isLive { entry.tab?.close() } else { state.remove(entry) }
    }
    changed("clear")
  }

  func cycleTab(by step: Int) {
    let live = state.allEntries.filter { $0.isLive }
    guard !live.isEmpty else { return }
    let index = live.firstIndex { $0.id == state.activeEntryID } ?? 0
    select(live[(index + step + live.count) % live.count])
  }

  /// ⌃Tab and ⌃⇧Tab. With Settings › Cycle through tabs in most recently used order on, each press goes one tab
  /// further back (or forward) through the tabs by when they were last used, as Chrome's tab search and Firefox do;
  /// holding Control keeps one walk going, and releasing it (`endTabCycle`) makes the tab it reached the most
  /// recently used. Off, it's the sidebar's order, like ⇧⌘] and ⇧⌘[.
  func cycleTabWithControl(by step: Int) {
    guard RaySettings.shared.values.recentTabCycling else { return cycleTab(by: step) }
    var cycle: TabCycle
    if let running = tabCycle {
      cycle = running
      // A tab closed in the middle of the walk drops out of it.
      cycle.order.removeAll { !$0.isLive }
    } else {
      let live = state.allEntries.filter { $0.isLive && !$0.isFolder }
      // Most recently used first, the current tab on top; ties keep the sidebar's order.
      var order = live.enumerated().sorted { ($0.element.lastActive, $1.offset) > ($1.element.lastActive, $0.offset) }.map(\.element)
      if let active = activeEntry, let at = order.firstIndex(where: { $0 === active }) {
        order.remove(at: at)
        order.insert(active, at: 0)
      }
      cycle = TabCycle(order: order, index: 0, lastActive: Dictionary(order.map { ($0.id, $0.lastActive) }, uniquingKeysWith: { first, _ in first }))
    }
    guard cycle.order.count > 1 else {
      tabCycle = cycle
      return
    }
    cycle.index = cycle.order.firstIndex { $0.id == state.activeEntryID } ?? 0
    cycle.index = (cycle.index + step + cycle.order.count) % cycle.order.count
    let target = cycle.order[cycle.index]
    cycling = true
    select(target)
    cycling = false
    // Passing through a tab doesn't make it recent; only where the walk ends does.
    if let before = cycle.lastActive[target.id] { target.lastActive = before }
    tabCycle = cycle
    logState("tabCycle")
  }

  /// Control was let go (or the window lost focus): the walk through recent tabs is over.
  func endTabCycle() {
    guard let cycle = tabCycle else { return }
    tabCycle = nil
    if let active = activeEntry, cycle.order.contains(where: { $0 === active }) {
      active.lastActive = Date()
      store.save(state)
    }
    logState("tabCycleEnd")
  }

  @objc private func windowResignedKey() { endTabCycle() }

  func selectTab(number: Int) {
    let entries = state.allEntries.filter { !$0.isFolder }
    guard !entries.isEmpty else { return }
    select(number >= 9 ? entries[entries.count - 1] : entries[min(number, entries.count) - 1])
  }

  // MARK: Page toolbar

  private func updateToolbar() {
    let entry = activeEntry
    let level = entry.flatMap { $0.isLive ? $0.tab?.securityInfo["level"] as? String : nil }
    toolbar.show(url: entry?.currentURL ?? "", security: level,
                 canGoBack: activeTab?.canGoBack ?? false, canGoForward: activeTab?.canGoForward ?? false)
    updateToolbarLoading()
  }

  /// The active tab's load in the address field and the reload button; other tabs' loads aren't drawn.
  private func updateToolbarLoading() {
    let tab = activeTab
    toolbar.showLoading(tab?.loading ?? false, progress: tab?.progress ?? 0, tab: tab.map { Int($0.tabId) } ?? -1)
  }

  /// Settings › Minimal URL in the address bar, the other way round.
  var fullAddressShown: Bool { !RaySettings.shared.values.minimalURL }

  /// View › Show Full Address: the same setting as Settings › Minimal URL in the address bar. Its change comes back
  /// through `settingsChanged`, in every window.
  func toggleFullAddress() {
    RaySettings.shared.update { $0.minimalURL.toggle() }
  }

  /// View › Show Address Bar on Page.
  func toggleToolbar() {
    state.pageToolbar = !toolbarShown
    layout()
    store.save(state)
    logState("toolbar")
  }

  func toolbarToggleSidebar(_ toolbar: PageToolbarView) { toggleSidebar() }
  func toolbarBack(_ toolbar: PageToolbarView) { activeTab?.goBack() }
  func toolbarForward(_ toolbar: PageToolbarView) { activeTab?.goForward() }
  func toolbarReload(_ toolbar: PageToolbarView) { activeTab?.reload() }
  func toolbarStop(_ toolbar: PageToolbarView) { activeTab?.stop() }
  func toolbarEditAddress(_ toolbar: PageToolbarView) { focusAddress() }
  func toolbarCopyLink(_ toolbar: PageToolbarView) { copyURL() }
  func toolbarSiteControls(_ toolbar: PageToolbarView) { toggleSiteControls() }

  /// For tests: the toolbar's reload (or, while loading, stop) button.
  func pressToolbarReload() { toolbar.pressReload() }

  // MARK: Sidebar visibility

  func toggleSidebar() {
    endPeek(animated: false)
    peekForced = false
    state.sidebarHidden.toggle()
    navigationSteps = 0
    dockSpring.animate(to: state.sidebarHidden ? 0 : 1, in: root)
    layout()
    updateForcedPeek()
    store.save(state)
    logState("sidebar")
  }

  func beginPeek() {
    guard state.sidebarHidden, !peeking else { return }
    peekEndWork?.cancel()
    peeking = true
    sidebar.removeFromSuperview()
    floating.content = sidebar
    floating.isHidden = false
    // Over the address bar too: a peeking sidebar covers everything at its edge.
    root.addSubview(floating, positioned: .above, relativeTo: toolbar)
    peekSpring.configure(response: Self.peekResponse, dampingRatio: Self.peekDamping)
    peekSpring.animate(to: 1, in: root)
    layout()
    logState("peek")
  }

  private func schedulePeekEnd() {
    guard peekEndWork == nil, !forcedOpen, !sidebar.isDragging, !sidebar.downloadsOpen else { return }
    let work = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.peekEndWork = nil
      if self.sidebar.isDragging || self.sidebar.downloadsOpen { return }
      self.endPeek(animated: true)
    }
    peekEndWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.peekHideDelay, execute: work)
  }

  private func cancelPeekEnd() {
    peekEndWork?.cancel()
    peekEndWork = nil
  }

  private func installPointerMonitors() {
    guard !launchedInBackground else { return }
    let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
    if let local = NSEvent.addLocalMonitorForEvents(matching: events, handler: { [weak self] event in
      self?.pointerMoved(screenPoint: NSEvent.mouseLocation)
      return event
    }) {
      pointerMonitors.append(local)
    }
    if let global = NSEvent.addGlobalMonitorForEvents(matching: events, handler: { [weak self] _ in
      self?.pointerMoved(screenPoint: NSEvent.mouseLocation)
    }) {
      pointerMonitors.append(global)
    }
  }

  private func pointerMoved(screenPoint: NSPoint) {
    guard state.sidebarHidden || peeking, window.isVisible, !window.isMiniaturized else { return }
    let frame = window.frame
    let point = NSPoint(x: screenPoint.x - frame.minX, y: frame.maxY - screenPoint.y)
    if point.x < 0 {
      let under = NSWindow.windowNumber(at: screenPoint, belowWindowWithWindowNumber: 0)
      if under != window.windowNumber, NSApp.window(withWindowNumber: under) != nil { return }
    }
    pointer(at: point, appActive: NSApp.isActive)
  }

  func pointer(at point: NSPoint, appActive: Bool) {
    let height = root.bounds.height
    guard point.y >= 0, point.y < height else {
      if peeking { schedulePeekEnd() }
      return
    }
    let reach = appActive ? Self.outsideReach : 0
    if peeking {
      let holdRight = Self.peekInset + SidebarView.width + Self.holdSlack
      if point.x >= -reach && point.x < holdRight { cancelPeekEnd() } else { schedulePeekEnd() }
    } else if point.x >= -reach && point.x < Self.revealWidth {
      beginPeek()
    }
  }

  func endPeek(animated: Bool) {
    cancelPeekEnd()
    guard peeking else { return }
    peeking = false
    if animated {
      peekSpring.configure(response: 0.15, dampingRatio: 1)
      peekSpring.animate(to: 0, in: root)
    } else {
      peekSpring.jump(to: 0)
    }
    logState("peek")
  }

  private func finishPeek() {
    guard !peeking, sidebar.superview !== root else { return }
    floating.isHidden = true
    sidebar.removeFromSuperview()
    sidebar.layer?.cornerRadius = 0
    sidebar.layer?.masksToBounds = false
    root.addSubview(sidebar, positioned: .above, relativeTo: toolbar)
    layout()
  }

  // MARK: Command bar

  func beginNewTab() {
    openCommandBar(.newTab, query: "")
  }

  func focusAddress() {
    openCommandBar(.currentTab, query: activeEntry.map { AddressInput.display(for: $0.currentURL) } ?? "")
  }

  /// ⇧⌘C, as in Arc and Chrome: the current page's full URL to the clipboard, and Arc's "Copied Current URL" toast
  /// with a share button.
  func copyURL() {
    guard let url = activeEntry?.currentURL, !url.isEmpty else { return }
    let pasteboard = Self.pasteboard
    pasteboard.clearContents()
    pasteboard.setString(url, forType: .string)
    showToast("Copied Current URL", symbol: "square.and.arrow.up") { [weak self] in
      guard let self, let link = URL(string: url) else { return }
      NSSharingServicePicker(items: [link]).show(relativeTo: self.toast.bounds, of: self.toast, preferredEdge: .minY)
    }
    logState("copyURL")
  }

  /// Test instances copy to a pasteboard of their own so checks never touch the user's clipboard.
  static let pasteboard = TestEnvironment["RAY_PASTEBOARD"].map { NSPasteboard(name: .init($0)) } ?? .general

  private func openCommandBar(_ mode: CommandBarMode, query: String) {
    commandBarMode = activeEntry == nil ? .newTab : mode
    let bar = commandBar ?? CommandBarView(frame: root.bounds)
    if commandBar == nil {
      bar.autoresizingMask = [.width, .height]
      bar.delegate = self
      bar.onSelectionChange = { [weak self] in self?.logState("commandBarSelection") }
      root.addSubview(bar)
      commandBar = bar
    }
    searches.warm()
    sidebar.setNewTabActive(commandBarMode == .newTab)
    bar.present(query: query)
    refreshSuggestions()
    // A private window doesn't suggest from your history.
    if !isPrivate { history.refresh(profile: profile) { [weak self] in self?.refreshSuggestions() } }
  }

  private func refreshSuggestions() {
    guard let bar = commandBar else { return }
    let query =
      commandBarMode == .currentTab && bar.field.stringValue == activeEntry?.currentURL ? "" : bar.field.stringValue
    let wantsSearches = Suggestions.wantsSearchSuggestions(for: query)
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    let rows = Suggestions.build(
      query: query, tabs: tabs, active: activeTab, history: history.entries,
      searches: wantsSearches ? searches.current(for: trimmed) : [], favicon: favicons.image(for:))
    bar.show(rows)
    let pages = rows.compactMap { row -> String? in
      if case .history(let url) = row.kind { return url }
      return nil
    }
    favicons.load(pages, profile: profile) { [weak self] in self?.refreshSuggestions() }
    logState("commandBar")
  }

  private func requestSearchSuggestions() {
    guard let bar = commandBar else { return }
    let query = bar.field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard Suggestions.wantsSearchSuggestions(for: query) else { return }
    searches.fetch(query) { [weak self] in self?.refreshSuggestions() }
  }

  private func closeCommandBar(focus: Bool) {
    guard let bar = commandBar else { return }
    commandBar = nil
    bar.removeFromSuperview()
    sidebar.setNewTabActive(false)
    if focus, let tab = activeTab { focusPage(tab) }
    logState("commandBar")
  }

  func commandBar(_ bar: CommandBarView, queryChanged query: String) {
    refreshSuggestions()
    requestSearchSuggestions()
  }

  func commandBar(_ bar: CommandBarView, choose suggestion: Suggestion) {
    let mode = commandBarMode
    closeCommandBar(focus: false)
    let url: String
    switch suggestion.kind {
    case .tab(let tab):
      if let entry = state.entry(for: tab) { select(entry) }
      return
    case .url(let target), .search(let target), .history(let target):
      url = target
    }
    // ray://settings/appearance is Ray's own Settings window, never a page.
    if showNativeSettings(for: url) { return }
    if mode == .newTab || activeTab == nil {
      openToday(url, after: nil, foreground: true)
    } else if let tab = activeTab {
      tab.loadURL(url, userInitiated: true)
      focusPage(tab)
    }
  }

  func commandBarDismiss(_ bar: CommandBarView) {
    closeCommandBar(focus: true)
  }

  // MARK: Pages

  func pageContains(windowPoint point: NSPoint) -> Bool {
    pages.bounds.contains(pages.convert(point, from: nil)) && commandBar == nil
  }

  private func focusPage(_ tab: RayCoreTab) {
    window.makeFirstResponder(tab.view)
    tab.focus()
  }

  func toggleDevTools() {
    guard let tab = activeTab else { return }
    if tab.devToolsView == nil { tab.showDevTools() } else { tab.closeDevTools() }
  }

  // MARK: SidebarViewDelegate

  func sidebar(_ sidebar: SidebarView, select entry: SidebarEntry) { select(entry) }

  func sidebar(_ sidebar: SidebarView, perform action: SidebarRowAction, on entry: SidebarEntry) {
    perform(action, on: entry)
  }

  func sidebar(_ sidebar: SidebarView, move entry: SidebarEntry, to target: SidebarDropTarget) {
    move(entry, to: target)
  }

  func sidebar(_ sidebar: SidebarView, rename entry: SidebarEntry, to title: String) {
    rename(entry, to: title)
  }

  func sidebarExtensions(_ sidebar: SidebarView, anchor: NSView) {
    extensions.refresh()
    extensions.menu(for: activeTab, anchor: anchor)
      .popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.maxY + 4), in: anchor)
  }

  func sidebarDownloads(_ sidebar: SidebarView, anchor: NSView) {
    toggleDownloads()
  }

  func sidebarNewTab(_ sidebar: SidebarView) { beginNewTab() }
  func sidebarOpenAddress(_ sidebar: SidebarView) { focusAddress() }
  func sidebarToggle(_ sidebar: SidebarView) { toggleSidebar() }
  func sidebarBack(_ sidebar: SidebarView) { activeTab?.goBack() }
  func sidebarForward(_ sidebar: SidebarView) { activeTab?.goForward() }
  func sidebarReload(_ sidebar: SidebarView) { activeTab?.reload() }

  func sidebarIcon(for entry: SidebarEntry) -> NSImage? {
    if entry.isLive, let icon = entry.tab?.favicon { return icon }
    let page = entry.pinnedURL ?? entry.url
    if let icon = favicons.image(for: page) ?? favicons.image(for: entry.url) { return icon }
    favicons.load([page, entry.url], profile: profile) { [weak self] in self?.reloadSidebar() }
    return nil
  }

  // MARK: RayCoreWindowDelegate

  func window(_ window: RayCoreWindow, didInsert tab: RayCoreTab, opener: RayCoreTab?, disposition: String) {
    TestEnvironment.log("tab \(tab.tabId) inserted (\(disposition))")
    if state.entry(for: tab) != nil { return }
    if let entry = loadingEntry, entry.tab == nil {
      bind(entry, tab)
      return
    }
    let entry = SidebarEntry(kind: .today, url: tab.url)
    bind(entry, tab)
    insertToday(entry, after: opener.flatMap(state.entry(for:)))
    if disposition == "background_tab" {
      changed("insert")
    } else {
      select(entry)
    }
  }

  func window(_ window: RayCoreWindow, didRemove tab: RayCoreTab) {
    guard let entry = state.entry(for: tab) else { return }
    if closing {
      pages.detach(tab)
      if tab.delegate === self { tab.delegate = nil }
      return
    }
    let list = state.allEntries
    let index = list.firstIndex { $0 === entry } ?? 0
    pages.detach(tab)
    if tab.delegate === self { tab.delegate = nil }
    entry.remember()
    entry.tab = nil
    let wasActive = state.activeEntryID == entry.id
    if entry.kind == .today {
      state.remove(entry)
    } else if let pinnedURL = entry.pinnedURL {
      entry.url = pinnedURL
    }
    if wasActive {
      activateNeighbor(of: index, in: state.allEntries)
    }
    changed("remove")
  }

  func window(_ window: RayCoreWindow, didActivate tab: RayCoreTab) {
    if let entry = state.entry(for: tab), entry.id != state.activeEntryID { select(entry) }
  }

  func window(_ window: RayCoreWindow, devToolsDidChangeFor tab: RayCoreTab, view devToolsView: NSView?) {
    if tab === activeTab { pages.setDevTools(devToolsView) }
    logState("devTools")
  }

  func window(_ window: RayCoreWindow, preHandleKeyEvent event: NSEvent) -> Bool {
    Shortcuts.isReserved(event) && (NSApp.mainMenu?.performKeyEquivalent(with: event) ?? false)
  }

  func window(_ window: RayCoreWindow, handleKeyEvent event: NSEvent) -> Bool {
    event.type == .keyDown && (NSApp.mainMenu?.performKeyEquivalent(with: event) ?? false)
  }

  func windowShouldClose(_ window: RayCoreWindow) -> Bool {
    prepareForQuit()
    DispatchQueue.main.async { [weak self] in self?.onClose?() }
    return true
  }

  // MARK: RayCoreTabDelegate

  private func tabChanged(_ tab: RayCoreTab, event: String) {
    guard !closing, let entry = state.entry(for: tab) else { return }
    entry.remember()
    sidebar.refresh(entry)
    if entry.id == state.activeEntryID {
      // A navigation to another site leaves the panel showing the old one's settings.
      if let panel = siteControls, panel.origin != tab.committedOrigin { closeSiteControls() }
      sidebar.showAddress(entry)
      sidebar.setNavigation(canGoBack: tab.canGoBack, canGoForward: tab.canGoForward)
      updateToolbar()
    }
    store.save(state)
    logState(event)
  }

  func tab(_ tab: RayCoreTab, didFindMatches count: Int32, active: Int32, final: Bool) {
    guard tab === findTab, let findBar else { return }
    findBar.setMatches(Int(count), active: Int(active))
    if final { logState("find") }
  }

  func tabDidChangeTitle(_ tab: RayCoreTab) { tabChanged(tab, event: "title") }
  func tabDidChangeURL(_ tab: RayCoreTab) {
    // Chrome's own settings page moved itself to Appearance (its left menu does that in place): Ray's window is
    // Appearance, so the tab goes back to where it was and the window opens.
    if !closing, let entry = state.entry(for: tab), let pane = AddressInput.nativeSettingsPane(for: tab.url) {
      leaveNativeSettings(tab, entry, pane: pane)
      return
    }
    // The settings page has no Search engine section any more: wherever the address came from, it shows the page itself.
    if !closing, AddressInput.isRemovedSettingsPage(tab.url) {
      tab.loadURL(AddressInput.settingsHome, userInitiated: true)
      return
    }
    tabChanged(tab, event: "url")
  }
  func tabDidChangeFavicon(_ tab: RayCoreTab) { tabChanged(tab, event: "favicon") }
  func tabDidChangeNavigationState(_ tab: RayCoreTab) { tabChanged(tab, event: "navigation") }
  func tabDidChangeSecurity(_ tab: RayCoreTab) { tabChanged(tab, event: "security") }

  func tabDidCommitDocument(_ tab: RayCoreTab) {
    // On the next turn of the run loop, by which time the engine has set its own zoom for the new page.
    DispatchQueue.main.async { [weak self, weak tab] in
      guard let self, let tab else { return }
      RaySettings.shared.adoptExistingZoom(profile: self.mainProfile) { [weak self, weak tab] in
        if let self, let tab { self.settleZoom(of: tab) }
      }
    }
  }

  func tabDidChangeZoom(_ tab: RayCoreTab) {
    noteZoomChanged(tab)
    if tab === zoomIndicatorTab { showZoomIndicator(for: tab) }
  }

  func tabDidChangeLoading(_ tab: RayCoreTab) {
    pages.updateProgress(for: tab)
    if tab === activeTab { updateToolbarLoading() }
    if !tab.loading { TestEnvironment.log("tab \(tab.tabId) loaded \(tab.url)") }
    if tab === activeTab { logState("loading") }
  }

  func tabDidChangeProgress(_ tab: RayCoreTab) {
    pages.updateProgress(for: tab)
    if tab === activeTab {
      updateToolbarLoading()
      logState("progress")
    }
  }

  func tab(_ tab: RayCoreTab, didFailLoad url: String, code: Int32, description text: String) {
    TestEnvironment.log("tab \(tab.tabId) failed \(url) (\(code) \(text))")
  }

  func tab(
    _ tab: RayCoreTab, didReceivePageMessage kind: String, json: String, frame frameId: String, main: Bool,
    origin: String
  ) {
    if kind == "hello" && main { TestEnvironment.log("page channel ready in tab \(tab.tabId) (\(origin))") }
  }

  // MARK: Settings

  /// An older Sidebar.json kept View › Show Full Address; it's Settings › Minimal URL in the address bar now.
  private func migrateLegacySettings() {
    guard !isPrivate, let full = state.fullAddress else { return }
    if !full { RaySettings.shared.update { $0.minimalURL = true } }
    state.fullAddress = nil
    store.save(state)
  }

  /// Every window follows the one set of settings.
  @objc private func settingsChanged(_ note: Notification) {
    let keys = note.userInfo?["keys"] as? [RaySetting] ?? []
    if keys.contains(.minimalURL) || keys.contains(.loadingProgress) {
      layout()
      updateToolbarLoading()
      if let tab = activeTab { pages.updateProgress(for: tab) }
    }
    if keys.contains(.defaultZoom) { settleZoomOfAllTabs() }
    if keys.contains(.recentTabCycling) { endTabCycle() }
    logState("settings")
  }

  /// The profile's colour changed: everything drawn with it takes the new one at once.
  @objc private func profileColorChanged() {
    root.setNeedsDisplayRecursively()
    pages.refreshAccent()
    toolbar.refreshAccent()
    sidebar.setDownloads(progress: lastDownloadProgress)
    logState("theme")
  }

  /// ray://settings/appearance (or chrome://) is Ray's Settings window, not a page.
  private func showNativeSettings(for url: String) -> Bool {
    guard let pane = AddressInput.nativeSettingsPane(for: url) else { return false }
    SettingsWindowController.shared.show(pane: pane)
    return true
  }

  /// A tab that ended up on that page (Chrome's settings navigated itself there, or a link opened it): the window
  /// opens, and the tab goes back to where it was, or closes if it has nowhere to go back to.
  private func leaveNativeSettings(_ tab: RayCoreTab, _ entry: SidebarEntry, pane: String) {
    SettingsWindowController.shared.show(pane: pane)
    if tab.canGoBack {
      tab.goBack()
    } else if entry.kind == .today {
      tab.close()
    } else if let home = entry.pinnedURL, AddressInput.nativeSettingsPane(for: home) == nil {
      tab.loadURL(home, userInitiated: true)
    }
  }

  // MARK: Page zoom

  /// Settings › Page zoom is Ray's own: the engine keeps zoom per host, so Ray sets the default when a navigation
  /// commits on a host the user hasn't zoomed, and remembers the hosts they did zoom (⌘+ / ⌘−) so those keep their
  /// level. Hosts are never logged in a normal run.
  private func zoomHost(of tab: RayCoreTab) -> String? {
    guard let origin = tab.committedOrigin, let components = URLComponents(string: origin),
          let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
          let host = components.host?.lowercased(), !host.isEmpty else { return nil }
    return host
  }

  private func isUserZoomed(_ host: String) -> Bool {
    RaySettings.shared.isZoomed(host) || privateZoomed.contains(host)
  }

  private func setZoom(_ tab: RayCoreTab, to factor: Double) {
    guard abs(tab.zoomFactor - factor) > 0.002 else { return }
    applyingZoom = true
    tab.zoomFactor = factor
    applyingZoom = false
  }

  /// A tab's page just committed, or the default changed: a host the user zoomed keeps its own level, any other
  /// gets the default.
  private func settleZoom(of tab: RayCoreTab) {
    guard !closing, !tab.closed, let host = zoomHost(of: tab) else {
      zoomHosts[tab.tabId] = nil
      return
    }
    zoomHosts[tab.tabId] = host
    if !isUserZoomed(host) { setZoom(tab, to: RaySettings.shared.values.defaultZoom) }
  }

  private func settleZoomOfAllTabs() { tabs.forEach(settleZoom(of:)) }

  /// The engine says a tab's zoom changed. While Ray is setting it, or a navigation is still settling (the host
  /// isn't the one Ray last settled), that's not the user; anything else on a host that isn't marked yet is.
  private func noteZoomChanged(_ tab: RayCoreTab) {
    guard !applyingZoom, !closing, let host = zoomHost(of: tab), zoomHosts[tab.tabId] == host, !isUserZoomed(host),
          abs(tab.zoomFactor - RaySettings.shared.values.defaultZoom) > 0.002 else { return }
    if isPrivate { privateZoomed.insert(host) } else { RaySettings.shared.markZoomed(host) }
    logState("zoom")
  }

  /// A site's Reset in the site controls: back to following the default.
  func resetZoom(of tab: RayCoreTab) {
    guard let host = zoomHost(of: tab) else {
      tab.zoomFactor = 1
      return
    }
    if isPrivate { privateZoomed.remove(host) } else { RaySettings.shared.unmarkZoomed(host) }
    setZoom(tab, to: RaySettings.shared.values.defaultZoom)
    logState("zoom")
  }

  /// View › Zoom In, Zoom Out and Actual Size (⌘+ ⌘− ⌘0), also the test command `zoom in|out|reset`: a step as the
  /// engine takes it, or back to the default, with Arc's "110%" at the top right.
  func zoomCommand(_ word: String) -> Bool {
    guard let tab = activeTab else { return false }
    switch word {
    case "in", "out":
      // The engine reports the new level in tabDidChangeZoom; a step past the limits changes nothing, so the
      // indicator shows the level as it is.
      zoomIndicatorTab = tab
      let before = tab.zoomFactor
      tab.zoomStep(word == "in" ? 1 : -1)
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self, weak tab] in
        guard let self, let tab, self.zoomIndicatorTab === tab else { return }
        if abs(tab.zoomFactor - before) < 0.002 { self.showZoomIndicator(for: tab) }
        self.zoomIndicatorTab = nil
      }
    case "reset":
      resetZoom(of: tab)
      showZoomIndicator(for: tab)
    default: return false
    }
    return true
  }

  /// The tab a zoom command is waiting to hear back from.
  private weak var zoomIndicatorTab: RayCoreTab?

  private func showZoomIndicator(for tab: RayCoreTab) {
    zoomIndicatorTab = nil
    guard tab === activeTab else { return }
    showToast("\(Int((tab.zoomFactor * 100).rounded()))%", figure: true)
  }

  // MARK: Page commands

  /// Chrome's own commands Ray's menus run (chrome/app/chrome_command_ids.h), as Chrome's menus do.
  enum ChromeCommand: Int32 {
    case print = 35003, savePage = 35004, systemPrint = 35007, taskManager = 40006
  }

  /// For tests: the last command run and whether the engine took it.
  private(set) var lastChromeCommand: (name: String, ran: Bool)?

  func runChromeCommand(_ command: ChromeCommand) {
    // Print and Save Page As act on the page; Task Manager only needs the window's profile.
    let ran: Bool
    if let tab = activeTab {
      ran = tab.executeChromeCommand(command.rawValue)
    } else if command == .taskManager {
      ran = coreWindow.executeChromeCommand(command.rawValue, profile: profile)
    } else {
      return
    }
    lastChromeCommand = ("\(command)", ran)
    logState("chromeCommand")
  }

  /// View Source's address for the active page: `view-source:` before a web or file page's own, as in Chrome.
  var viewSourceURL: String? {
    guard let entry = activeEntry, entry.isLive, let scheme = URLComponents(string: entry.currentURL)?.scheme?.lowercased(),
          ["http", "https", "file"].contains(scheme) else { return nil }
    return "view-source:" + entry.currentURL
  }

  /// View › View Source (⌥⌘U): the source in a new tab after the page, as Chrome and Ardia open it.
  func viewSource() {
    guard let url = viewSourceURL else { return }
    openToday(url, after: activeEntry, foreground: true)
  }

  /// An engine page (History, Clear Browsing Data): the tab already showing it, else a new one after the active tab.
  func showPage(_ url: String) {
    let wanted = url.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
    if let open = state.allEntries.first(where: {
      $0.isLive && $0.currentURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased() == wanted
    }) {
      select(open)
    } else {
      openToday(url, after: activeEntry, foreground: true)
    }
  }

  // MARK: State log

  func logState(_ event: String) {
    guard Self.logsState else { return }
    func describe(_ entry: SidebarEntry) -> [String: Any] {
      [
        "id": entry.id.uuidString, "kind": entry.kind.rawValue, "title": entry.displayTitle,
        "url": entry.currentURL, "pinnedURL": entry.pinnedURL ?? NSNull(), "live": entry.isLive,
        "away": entry.isAwayFromPinned, "tab": entry.isLive ? Int(entry.tab!.tabId) : NSNull(),
        "parent": entry.parentID?.uuidString ?? NSNull(), "open": entry.isOpen ?? NSNull(),
      ]
    }
    var state: [String: Any] = [
      "event": event,
      "active": activeTab.map { Int($0.tabId) } ?? NSNull(),
      "activeEntry": self.state.activeEntryID?.uuidString ?? NSNull(),
      "address": sidebar.addressText,
      "addressField": sidebar.addressDebug,
      "sidebarAddressShown": sidebar.addressShown,
      "pages": pages.debugState,
      "cardFrame": NSStringFromRect(pages.frame),
      "windowFrame": NSStringFromRect(window.frame),
      "windowMovable": window.isMovable,
      "windowVisibleOnScreen": window.occlusionState.contains(.visible),
      "windowOnActiveSpace": window.isOnActiveSpace,
      "fullScreen": isFullScreen,
      "toolbar": toolbarShown ? [
        "address": toolbar.addressText, "frame": NSStringFromRect(toolbar.frame), "field": toolbar.addressDebug,
        "navigation": toolbar.showsNavigation, "navigationProgress": toolbar.navigation, "navigationSteps": navigationSteps,
      ] as [String: Any] : NSNull(),
      "private": isPrivate,
      "arcImport": arcImportShown ?? NSNull(),
      "permission": permissions.shown ?? NSNull(),
      "find": findBar.map { bar -> [String: Any] in
        let frame = bar.convert(bar.bounds, to: nil)
        let height = window.contentView?.bounds.height ?? 0
        return ["text": bar.text, "count": bar.matches.count, "active": bar.matches.active,
                "frame": String(format: "%.1f,%.1f,%.1f,%.1f", frame.minX, height - frame.maxY, frame.width, frame.height)]
      } ?? NSNull(),
      "downloads": downloads.items.map { [
        "id": $0.id, "filename": $0.filename, "state": $0.state, "dangerous": $0.dangerous, "path": $0.path,
        "keepReady": downloadsList?.row(for: $0.id)?.keepReady ?? false,
      ] },
      "downloadsOpen": sidebar.downloadsOpen,
      "downloadsButton": {
        let button = sidebar.downloadsAnchor
        guard !button.isHidden, let height = window.contentView?.bounds.height else { return "" }
        let frame = button.convert(button.bounds, to: nil)
        return String(format: "%.1f,%.1f", frame.minX, height - frame.maxY)
      }(),
      "extensions": extensions.items.map { ["id": $0.id, "name": $0.name, "enabled": $0.enabled] },
      "extensionPopup": extensions.popupURL ?? NSNull(),
      "siteControls": siteControls?.state ?? NSNull(),
      "sidebarOverToolbar": (root.subviews.firstIndex(of: sidebar.superview === root ? sidebar : floating) ?? -1)
        > (root.subviews.firstIndex(of: toolbar) ?? 0),
      "installPrompt": extensions.promptState ?? NSNull(),
      "displayAsleep": CGDisplayIsAsleep(window.screen?.displayID ?? CGMainDisplayID()) != 0,
      "pasteboard": Self.pasteboard.string(forType: .string) ?? NSNull(),
      "toast": toast.message,
      "toastTruncated": toast.truncated,
      "realLightsHidden": [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].allSatisfy {
        window.standardWindowButton($0)?.isHidden ?? true
      },
      "toggleCenter": sidebar.debugToggleCenter,
      "sidebarFrames": sidebar.debugFrames,
      "sidebar": [
        "favorites": self.state.favorites.map(describe),
        "pinned": self.state.pinned.map(describe),
        "today": self.state.today.map(describe),
        "hidden": self.state.sidebarHidden,
        "peeking": peeking,
      ] as [String: Any],
      "commandBar": commandBar.map { bar in
        [
          "mode": commandBarMode.rawValue, "query": bar.field.stringValue, "selected": bar.selectedIndex,
          "rowsFullyVisible": bar.rowsFullyVisible,
          "rows": bar.suggestions.map { ["kind": $0.kindName, "title": $0.title, "detail": $0.detail] },
        ] as [String: Any]
      } ?? NSNull(),
      "tabs": tabs.map { tab in
        [
          "id": Int(tab.tabId), "url": tab.url, "title": tab.title,
          "visible": !tab.view.isHidden && tab.view.superview != nil, "zoom": tab.zoomFactor,
        ] as [String: Any]
      },
    ]
    // Settings (test builds only, like the rest of this log).
    func tabID(_ entry: SidebarEntry) -> Any { entry.isLive ? Int(entry.tab!.tabId) : NSNull() }
    state["settings"] = RaySettings.shared.debug
    state["settingsWindow"] = SettingsWindowController.shared.debug
    state["updater"] = Updater.shared.debug
    state["chromeCommand"] = lastChromeCommand.map { ["name": $0.name, "ran": $0.ran] as [String: Any] } ?? NSNull()
    state["safeStorage"] = ["mode": safeStorage.mode.rawValue, "note": safeStorage.note, "moved": safeStorage.moved]
    state["menuKeys"] = [
      "copyURL": MainMenu.keyEquivalent(of: #selector(AppController.copyURL(_:))) ?? NSNull(),
      "toggleSidebar": MainMenu.keyEquivalent(of: #selector(AppController.toggleSidebar(_:))) ?? NSNull(),
      "settings": MainMenu.keyEquivalent(of: #selector(AppController.showSettings(_:))) ?? NSNull(),
      "savePage": MainMenu.keyEquivalent(of: #selector(AppController.savePage(_:))) ?? NSNull(),
    ] as [String: Any]
    state["recentOrder"] = self.state.allEntries.filter { $0.isLive }
      .sorted { $0.lastActive > $1.lastActive }.map(tabID)
    state["tabCycle"] = tabCycle.map { ["order": $0.order.map(tabID), "index": $0.index] as [String: Any] } ?? NSNull()
    guard let data = try? JSONSerialization.data(withJSONObject: state),
          let json = String(data: data, encoding: .utf8) else { return }
    FileHandle.standardError.write("[ray-state] \(json)\n".data(using: .utf8)!)
  }
}

final class FloatingSidebarFrame: NSView {
  private static let radius: CGFloat = 12

  var content: NSView? {
    didSet {
      oldValue?.removeFromSuperview()
      if let content {
        content.frame = bounds
        content.autoresizingMask = [.width, .height]
        content.wantsLayer = true
        content.layer?.cornerRadius = Self.radius
        content.layer?.cornerCurve = .continuous
        content.layer?.masksToBounds = true
        addSubview(content)
      }
    }
  }

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.cornerRadius = Self.radius
    layer?.cornerCurve = .continuous
    layer?.masksToBounds = false
    layer?.borderWidth = 1
    // Arc's peek shadow, measured from a recording (2026-10-27): about 9 % darker at the panel's edge, gone within
    // about 8 pt, a little deeper below. Ardia's (black 0.5, radius 20) read as too heavy.
    layer?.shadowColor = NSColor.black.cgColor
    layer?.shadowRadius = 8
    layer?.shadowOffset = CGSize(width: 0, height: -2)
  }

  required init?(coder: NSCoder) { fatalError() }

  override var wantsUpdateLayer: Bool { true }

  var isPrivate = false {
    didSet { needsDisplay = true }
  }

  override func updateLayer() {
    let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    layer?.backgroundColor = (isPrivate ? SidebarColors.privateBackground : SidebarColors.background).cgColor
    layer?.borderColor = (dark ? NSColor(white: 1, alpha: 0.1) : NSColor(white: 0, alpha: 0.1)).cgColor
    layer?.shadowOpacity = dark ? 0.18 : 0.12
  }

  override func layout() {
    super.layout()
    layer?.shadowPath = CGPath(
      roundedRect: bounds, cornerWidth: Self.radius, cornerHeight: Self.radius, transform: nil)
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    needsDisplay = true
  }
}

private extension NSScreen {
  var displayID: CGDirectDisplayID? { deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID }
}
