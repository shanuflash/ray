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
  /// The profile of the Space on screen (`// MARK: Spaces`): the default one, another Space's own, or a private
  /// window's off-the-record side.
  private(set) var profile: RayCoreProfile
  var onClose: (() -> Void)?

  private let root = WindowDragArea()
  /// The window's colour under everything: the Space's Window colour, cross-fading on a switch.
  private let themeBackdrop = ThemeBackdropView()
  private let sidebar = SidebarView()
  private let floating = FloatingSidebarFrame()
  private let pages = PageContainerView()
  private let toolbar = PageToolbarView()
  /// For tests: frames laid out mid-way through the last sidebar toggle, with the address bar's buttons part way in.
  private var navigationSteps = 0
  /// Settings › Show the address bar above the page (View › Show Address Bar on Page): one value for every window.
  var toolbarShown: Bool { RaySettings.shared[.pageAddressBar] }
  private var commandBar: CommandBarView?
  private var commandBarMode = CommandBarMode.newTab
  private let history = HistoryCache()
  let searches = SearchSuggestions()
  private let favicons = FaviconCache()
  private let store: SidebarStore
  private(set) var state: SidebarState
  /// Today folders as Chrome tab groups.
  private(set) var groups: TabGroupSync!
  /// A Today folder's New Tab in Folder: the next tab the command bar opens goes into it.
  private var newTabFolder: UUID?
  private var loadingEntry: SidebarEntry?
  private var peeking = false
  private var peekEndWork: DispatchWorkItem?
  /// ⌃Tab through recently used tabs (`TabSwitcher.swift`), and the pictures of pages its cards show.
  private(set) lazy var tabSwitcher = makeTabSwitcher()
  private let tabPictures = TabPictures()
  /// The switcher is switching itself (so `select` doesn't take that for the user going elsewhere).
  private var switcherChoosing = false
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
  // Near the window's edge only, as Arc (Crest's 14 pt strip opened it reaching for the page's left side).
  private static let revealWidth: CGFloat = 5
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
  /// Where an extension's popup hangs: the sliders button in the sidebar's address field, or the page address bar's.
  var extensionsAnchor: NSView { siteControlsInSidebar ? sidebar.siteButton : toolbar.siteButton }

  var activeTab: RayCoreTab? { activeEntry.flatMap { $0.isLive ? $0.tab : nil } }

  var tabs: [RayCoreTab] { state.allEntries.compactMap { $0.isLive ? $0.tab : nil } }

  /// The normal profile behind this window: itself, or for a private window the profile it's the private side of.
  let mainProfile: RayCoreProfile
  var isPrivate: Bool { profile.offTheRecord }
  /// What ⇧⌘T walks back through: the normal window's list outlives the window; a private window's is its own.
  let closedTabs: ClosedTabs
  /// Tabs the user is closing (⌘W, the row's close button, Clear), by entry: they're remembered once the engine has
  /// removed them, with the key their history went to the engine's tab restore service under.
  private var userClosing: [UUID: (key: String?, favicon: NSImage?, batch: UUID?)] = [:]

  init(profile: RayCoreProfile, mainProfile: RayCoreProfile, store: SidebarStore) {
    self.profile = profile
    self.mainProfile = mainProfile
    self.store = store
    closedTabs = profile.offTheRecord ? ClosedTabs() : ClosedTabs.main
    state = store.load() ?? SidebarState()
    state.archiveStaleToday()
    coreWindow = RayCoreWindow(contentRect: NSRect(x: 0, y: 0, width: 1360, height: 860))
    super.init()
    groups = TabGroupSync(
      profile: profile, windowID: { [weak self] in self.map { $0.coreWindow.chromeWindowId(for: $0.isPrivate ? $0.profile : $0.mainProfile) } ?? -1 },
      state: { [weak self] in self?.state ?? SidebarState() })
    groups.onAdopt = { [weak self] event in self?.changed(event) }
    coreWindow.delegate = self
    coreWindow.activeProfile = profile
    configureWindow()
    sidebar.delegate = self
    sidebar.onExternalDrag = { [weak self] over in self?.externalDragChanged(over: over) }
    let host = coreWindow.hostView
    root.frame = host.bounds
    root.autoresizingMask = [.width, .height]
    root.wantsLayer = true
    themeBackdrop.frame = root.bounds
    themeBackdrop.autoresizingMask = [.width, .height]
    themeBackdrop.wantsLayer = true
    themeBackdrop.onAppearance = { [weak self] in self?.refreshBackdrop() }
    root.addSubview(themeBackdrop)
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
    observeSettings()
    center.addObserver(self, selector: #selector(profileColorChanged), name: ProfileColor.didChange, object: nil)
    center.addObserver(self, selector: #selector(spaceLookChanged), name: SpaceLook.didChange, object: nil)
    startSpaces()
    center.addObserver(self, selector: #selector(windowResignedKey), name: NSWindow.didResignKeyNotification, object: window)
    // Zoom levels the engine already holds are the user's own; the default zoom only touches the rest.
    RaySettings.shared.adoptExistingZoom(profile: mainProfile) { [weak self] in self?.settleZoomOfAllTabs() }
    closedTabs.watchHistory(profile: profile)
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
    // Leaving the window's full screen by hand (the green button, ⌃⌘F) takes the page out of its full screen too.
    if !isFullScreen, let tab = pageFullscreenTab {
      fullScreenForPage = false
      tab.exitFullscreen()
    }
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
    // A page in full screen (`// MARK: Page full screen`) fills the window: nothing of Ray's around it.
    let fullPage = pageFillsWindow
    sidebar.isHidden = fullPage
    let width = sidebarWidth
    let shown = dockSpring.value
    let peek = peekSpring.value

    if peeking || peek > 0.001 {
      // A peeking sidebar being docked (⌘S) stays where it is: its card flattens against the window's edge while the
      // page makes room beside it.
      let flat = dockingFromPeek ? min(max(shown, 0), 1) : 0
      let inset = (Self.peekInset * (1 - flat)).rounded()
      floating.flatten = flat
      floating.frame = NSRect(
        x: inset - (width + 12) * (1 - peek), y: inset, width: width, height: bounds.height - inset * 2)
      if dockingFromPeek {
        dockFrames += 1
        dockLeftmost = min(dockLeftmost, floating.frame.minX)
      }
      sidebar.frame = floating.bounds
      sidebar.trafficLightsCenterY = isFullScreen ? Self.fullScreenRowCenter : Self.windowedRowCenter
      sidebar.reservesTrafficLights = !isFullScreen
    } else {
      sidebar.frame = NSRect(x: -width * (1 - shown), y: 0, width: width, height: bounds.height)
      sidebar.trafficLightsCenterY = isFullScreen ? Self.fullScreenRowCenter : Self.windowedRowCenter
      sidebar.reservesTrafficLights = !isFullScreen
    }
    layoutResizeHandle(docked: peek <= 0.001 && shown >= 0.999)
    if fullPage { resizeHandle.isHidden = true }
    layoutDropEdge()
    let edge = isFullScreen ? margin * shown : margin
    let cardX = max(edge, width * shown)
    // Whole points only: Chrome's content layer follows the page by CALayer autoresizing, which rounds each
    // step to a point, so fractional sizes made the page creep a little further on every ⌘S.
    let left = cardX.rounded(), right = (bounds.width - edge).rounded()
    let bottom = edge.rounded()
    var top = (bounds.height - edge).rounded()
    toolbar.isHidden = !toolbarShown || fullPage
    sidebar.showsAddress = !toolbarShown || (sidebar.superview === floating && !dockingFromPeek)
    sidebar.showsSiteButton = !toolbarShown
    toolbar.showsFullAddress = fullAddressShown
    toolbar.showsLoadingWash = RaySettings.shared[.loadingProgress]
    // One load indicator: the page's own line only when the address bar above it is off, and neither when Settings
    // turns progress off.
    pages.showsProgress = !toolbarShown && RaySettings.shared[.loadingProgress]
    if toolbarShown {
      // The address bar sits above the card, at the window's top edge, across the card's width.
      let height = PageToolbarView.height
      toolbar.frame = NSRect(x: left, y: bounds.height - height, width: max(0, right - left), height: height)
      toolbar.navigation = 1 - shown
      if toolbar.navigation > 0.05 && toolbar.navigation < 0.95 { navigationSteps += 1 }
      top = (bounds.height - height).rounded()
    }
    pages.frame = fullPage ? bounds
      : NSRect(x: left, y: bottom, width: max(0, right - left), height: max(0, top - bottom))
    // Hidden pages sit out the frames of ⌘S and of a drag of the sidebar's edge, and take the size it settles at.
    pages.defersHiddenPages = dockSpring.isMoving || widthSpring.isMoving || resizeStart != nil
    pages.cornerRadius = fullPage ? 0 : isFullScreen ? PageContainerView.radius * shown : PageContainerView.radius
    if fullPage { pages.showsProgress = false }
    if let crashed = crashedPages.view, crashed.superview != nil {
      crashed.frame = pages.frame
      crashed.layer?.cornerRadius = pages.cornerRadius
    }
    shareIndicators.layout()
    permissions.update()
    layoutSiteControls()
    if let findBar {
      let size = FindBarView.size
      findBar.frame = NSRect(x: pages.frame.maxX - size.width - 12, y: pages.frame.maxY - size.height - 12,
                             width: size.width, height: size.height)
    }
    layoutNotes()
    layoutTabSwitcher()
    updateTrafficLights()
    if dockingFromPeek, !dockSpring.isMoving, shown >= 0.999 { finishDockFromPeek() }
  }

  private func updateTrafficLights() {
    for kind: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
      window.standardWindowButton(kind)?.isHidden = !isFullScreen
    }
  }

  // MARK: Page full screen

  /// The tab whose page asked for full screen (a video's button, YouTube's F): while it's the one shown it fills the
  /// window with nothing of Ray's around it (Chrome's and Ardia's), and the window goes full screen if it wasn't,
  /// coming back out when the page leaves it. Escape, a tab switch or leaving the window's full screen end it.
  private(set) var pageFullscreenTab: RayCoreTab?
  /// Ray took the window full screen for the page, so it takes it out again.
  private var fullScreenForPage = false
  /// For the state log: what happened, in order (entered, left, windowIn, windowOut).
  private var pageFullscreenSteps: [String] = []

  private var pageFillsWindow: Bool { pageFullscreenTab != nil && pageFullscreenTab === activeTab }

  func window(_ window: RayCoreWindow, tab: RayCoreTab, didChangeFullscreen fullscreen: Bool) {
    if fullscreen {
      guard tab === activeTab else { return tab.exitFullscreen() }
      pageFullscreenTab = tab
      pageFullscreenSteps.append("entered")
      closeCommandBar(focus: false)
      panels.close()
      if peeking { endPeek(animated: false) }
      // Test instances stay out of the window's full screen: it would take over the screen.
      if !isFullScreen, !launchedInBackground {
        fullScreenForPage = true
        pageFullscreenSteps.append("windowIn")
        self.window.toggleFullScreen(nil)
      }
    } else if pageFullscreenTab === tab {
      pageFullscreenTab = nil
      pageFullscreenSteps.append("left")
      if fullScreenForPage {
        fullScreenForPage = false
        if isFullScreen {
          pageFullscreenSteps.append("windowOut")
          self.window.toggleFullScreen(nil)
        }
      }
    }
    layout()
    updateForcedPeek()
    logState("pageFullscreen")
  }

  /// Escape leaves a page's full screen before the page sees the key, as Chrome's does.
  func exitPageFullscreen(on event: NSEvent) -> Bool {
    guard event.type == .keyDown, event.keyCode == 53, let tab = pageFullscreenTab else { return false }
    tab.exitFullscreen()
    return true
  }

  private var pageFullscreenDebug: [String: Any] {
    ["tab": pageFullscreenTab.map { Int($0.tabId) } ?? NSNull(), "fillsWindow": pageFillsWindow,
     "windowForPage": fullScreenForPage, "steps": pageFullscreenSteps,
     "pages": NSStringFromRect(pages.frame), "root": NSStringFromRect(root.bounds), "sidebarHidden": sidebar.isHidden,
     "toolbarHidden": toolbar.isHidden]
  }

  // MARK: Extensions and downloads

  private(set) lazy var extensions: ExtensionsController = {
    let controller = ExtensionsController(profile: profile, coreWindow: coreWindow)
    controller.onChange = { [weak self, weak controller] in
      guard let self, let controller else { return }
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
      sizeDownloadsList()
      downloadsPanel?.contentChanged()
    }
    if newlyWaiting {
      // A held download needs an answer: open the list where it can be given.
      showDownloads()
    } else if let started = items.first, started.active, !downloadsOpen, started.received == 0,
              notedDownload != started.id {
      notedDownload = started.id
      notes.show(downloadNote(started))
    }
    updateDownloadNote(items)
    logState("downloads")
  }

  /// The download the bottom-left note follows: its progress while it runs, then "Downloaded".
  private var notedDownload: String?
  private static let byteCount: ByteCountFormatter = {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    return formatter
  }()

  /// Bottom left, next to the sidebar's downloads button.
  private func downloadNote(_ item: DownloadsController.Item) -> Note {
    let show = NoteAction("Show") { [weak self] in self?.showDownloads() }
    if item.state == "finished" {
      return Note(item.filename, detail: "Downloaded", icon: .done, actions: [show], spot: .bottomLeading, key: "download")
    }
    let detail = item.total > 0
      ? "\(Self.byteCount.string(fromByteCount: Int64(item.received))) of \(Self.byteCount.string(fromByteCount: Int64(item.total)))"
      : "Downloading"
    return Note(item.filename, detail: detail, icon: .progress(item.fraction), actions: [show], spot: .bottomLeading,
                lasts: .held, key: "download")
  }

  private func updateDownloadNote(_ items: [DownloadsController.Item]) {
    guard let id = notedDownload else { return }
    guard let item = items.first(where: { $0.id == id }), item.active || item.state == "finished" else {
      notedDownload = nil
      return notes.dismiss(key: "download")
    }
    if !item.active { notedDownload = nil }
    notes.update(key: "download") { $0 = downloadNote(item) }
  }

  /// The downloads panel slides up from the sidebar's footer; with the sidebar hidden, the sidebar comes out first
  /// and stays out while the panel is open.
  /// The downloads list as a panel above the sidebar's downloads button (over the sidebar; a peeking sidebar stays
  /// out while it's open).
  private var downloadsPanel: PanelHandle?
  var downloadsOpen: Bool { downloadsPanel?.isOpen == true }
  static let downloadsWidth: CGFloat = 280

  func showDownloads() {
    guard !downloadsOpen else { return }
    notes.dismiss(key: "download")
    downloads.loadHistory()
    if state.sidebarHidden && !peeking { beginPeek() }
    sidebar.layoutSubtreeIfNeeded()
    let list = DownloadsListView(frame: .zero)
    list.width = Self.downloadsWidth
    list.controller = downloads
    list.onClose = { [weak self] in self?.closeDownloads() }
    list.show(downloads.items)
    downloadsList = list
    sizeDownloadsList()
    let button = sidebar.downloadsAnchor
    let anchor = PanelAnchor(rect: { [weak self] in
      guard let self else { return .zero }
      let button = self.sidebar.downloadsAnchor
      return button.convert(button.bounds, to: self.root)
    }, below: false, align: .leading, button: button, hold: { [weak button] held in (button as? HoverIconButton)?.isHeld = held })
    downloadsPanel = panels.open(PanelSpec(
      name: "downloads", content: list, anchor: anchor, closesOn: [.outsideClick, .escape, .windowInactive],
      overSidebar: true, onClose: { [weak self, weak list] in
        guard let self, self.downloadsList === list else { return }
        self.downloadsList = nil
        self.downloadsPanel = nil
        self.logState("downloads")
      }))
    logState("downloads")
  }

  /// As tall as its rows, up to the window's height less some room.
  private func sizeDownloadsList() {
    guard let list = downloadsList else { return }
    list.setFrameSize(NSSize(width: Self.downloadsWidth, height: min(list.fittingSize.height, max(160, root.bounds.height - 140))))
  }

  func closeDownloads() {
    downloadsPanel?.close()
  }

  func toggleDownloads() {
    downloadsOpen ? closeDownloads() : showDownloads()
  }

  // MARK: Bookmarks

  /// The bookmarks panel above the sidebar's bookmark button, over the sidebar as the downloads list is
  /// (`BookmarksPanel.swift`); a peeking sidebar stays out while it's open.
  private var bookmarksPanel: PanelHandle?
  private(set) var bookmarksList: BookmarksPanelView?
  var bookmarksOpen: Bool { bookmarksPanel?.isOpen == true }
  /// For the state log: what the panel and the menu last opened, and how many tabs Open All last asked about.
  private var lastBookmarkOpened: [String: Any]?
  private var openAllAsked: Int?
  /// Open All's question while it's up (tests answer it).
  private(set) weak var openAllQuestion: PanelQuestion?

  /// Opens the panel (or, already open, keeps it); `reveal` shows that bookmark, `rename` starts its name field.
  func showBookmarks(reveal id: String? = nil, rename: Bool = false) {
    Bookmarks.shared.start()
    if let list = bookmarksList, bookmarksOpen {
      if let id { list.reveal(id, rename: rename) }
      return
    }
    if state.sidebarHidden && !peeking { beginPeek() }
    sidebar.layoutSubtreeIfNeeded()
    let list = BookmarksPanelView(frame: .zero)
    list.maxHeight = max(220, root.bounds.height - 120)
    list.canPin = !isPrivate
    list.canBookmarkTab = { [weak self] in self?.bookmarkableURL != nil }
    list.onOpen = { [weak self] node, foreground in
      guard let self, let url = node.url else { return }
      if foreground { self.closeBookmarks() }
      self.openBookmark(url, foreground: foreground)
    }
    list.onOpenAll = { [weak self] folder in
      self?.closeBookmarks()
      self?.openBookmarks(folder)
    }
    list.onPin = { [weak self] node in
      self?.closeBookmarks()
      self?.pinBookmark(node)
    }
    list.onCopy = { [weak self] url in
      let pasteboard = Self.pasteboard
      pasteboard.clearContents()
      pasteboard.setString(url, forType: .string)
      self?.notes.show(.copied("Copied Link") { button in
        guard let link = URL(string: url) else { return }
        NSSharingServicePicker(items: [link]).show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
      })
    }
    list.onDelete = { [weak self] removed in
      self?.notes.show(Note("Deleted “\(BookmarksMenu.menuTitle(removed.title))”", icon: .symbol("trash"),
                            actions: [NoteAction("Undo") { Bookmarks.shared.restore(removed) }], key: "bookmarkDeleted"))
    }
    list.onBookmarkTab = { [weak self] in self?.bookmarkTab() }
    list.onManager = { [weak self] in
      self?.closeBookmarks()
      AppController.shared.openPage("ray://bookmarks")
    }
    list.onClose = { [weak self] in self?.closeBookmarks() }
    list.onResize = { [weak self] in self?.bookmarksPanel?.contentChanged() }
    list.onChange = { [weak self] in self?.logState("bookmarks") }
    bookmarksList = list
    let button = sidebar.bookmarksAnchor
    // Its leading edge on the footer's (the downloads button's), as the downloads list's: over the sidebar.
    let anchor = PanelAnchor(rect: { [weak self] in
      guard let self else { return .zero }
      let marks = self.sidebar.bookmarksAnchor, footer = self.sidebar.downloadsAnchor
      return marks.convert(marks.bounds, to: self.root).union(footer.convert(footer.bounds, to: self.root))
    }, below: false, align: .leading, button: button, hold: { [weak button] held in (button as? HoverIconButton)?.isHeld = held })
    bookmarksPanel = panels.open(PanelSpec(
      name: "bookmarks", content: list, anchor: anchor, closesOn: [.outsideClick, .tabSwitch, .windowInactive],
      overSidebar: true, onClose: { [weak self, weak list] in
        guard let self, self.bookmarksList === list else { return }
        list?.endRename(commit: true)
        self.bookmarksList = nil
        self.bookmarksPanel = nil
        self.logState("bookmarks")
      }))
    // Typing searches at once; Escape clears it, then closes (the panel's own keys, not Panels').
    window.makeFirstResponder(list.field)
    if let id { list.reveal(id, rename: rename) }
    logState("bookmarks")
  }

  func closeBookmarks() { bookmarksPanel?.close() }

  func toggleBookmarks() { bookmarksOpen ? closeBookmarks() : showBookmarks() }

  /// For tests: a click on the sidebar's bookmark button.
  func pressBookmarksButton() -> Bool {
    guard let button = sidebar.bookmarksAnchor as? NSButton, !button.isHiddenOrHasHiddenAncestor else { return false }
    button.performClick(nil)
    return true
  }

  /// The active tab's address, when it's one a bookmark can keep (http(s), chrome:, about:).
  var bookmarkableURL: String? {
    guard let url = activeEntry?.currentURL, !url.isEmpty, Self.isPinnable(url) else { return nil }
    return url
  }

  /// Bookmarks › Bookmark This Tab…: at the end of the bookmarks bar, its name ready to type, in the panel; a page
  /// already bookmarked is shown there instead (Chrome's star opens its bookmark).
  func bookmarkTab() {
    guard let url = bookmarkableURL, let entry = activeEntry else { return }
    Bookmarks.shared.start()
    if let existing = Bookmarks.shared.bookmark(for: url) { return showBookmarks(reveal: existing.id) }
    let title = entry.isLive ? (entry.tab?.title ?? entry.displayTitle) : entry.displayTitle
    Bookmarks.shared.add(url: url, title: title) { [weak self] id in self?.showBookmarks(reveal: id, rename: true) }
  }

  /// Bookmarks › Bookmark All Tabs…: Today's tabs into a new folder at the end of the bar, its name ready to type.
  func bookmarkAllTabs() {
    let links = state.today.filter { !$0.isFolder && Self.isPinnable($0.currentURL) }
      .map { (url: $0.currentURL, title: $0.displayTitle) }
    guard !links.isEmpty else { return }
    Bookmarks.shared.start()
    Bookmarks.shared.addFolder("Saved Tabs", links: links) { [weak self] id in self?.showBookmarks(reveal: id, rename: true) }
  }

  /// A bookmark in a new Today tab (`foreground`: switched to). Only addresses Ray opens anyway (never javascript:).
  func openBookmark(_ url: String, foreground: Bool) {
    guard Self.isPinnable(url) else { return }
    lastBookmarkOpened = ["url": url, "foreground": foreground]
    if showNativeSettings(for: url) { return }
    _ = openToday(url, after: nil, foreground: foreground)
  }

  /// Chrome asks before opening more than this many at once (`bookmarks::kNumBookmarkUrlsBeforePrompting`).
  static let openAllWithoutAsking = 15

  /// Open All: a folder's pages (folders inside too) as new Today tabs, the first one shown; over 15 asks first.
  func openBookmarks(_ folder: Bookmark, confirmed: Bool = false) {
    let links = folder.links.filter(\.opens).compactMap(\.url)
    guard !links.isEmpty else { return }
    if links.count > Self.openAllWithoutAsking, !confirmed {
      openAllAsked = links.count
      var close: (() -> Void)?
      let question = PanelQuestion(
        title: "Open \(links.count) tabs?", message: "", answers: [("Cancel", false, false), ("Open", true, false)]
      ) { [weak self] index in
        close?()
        if index == 1 { self?.openBookmarks(folder, confirmed: true) }
      }
      let handle = panels.open(PanelSpec(
        name: "openAllBookmarks", content: question, anchor: questionAnchor, closesOn: [.escape, .windowInactive],
        asks: true, onReturn: { [weak self] in
          close?()
          self?.openBookmarks(folder, confirmed: true)
        }))
      close = { handle.close() }
      openAllQuestion = question
      logState("bookmarks")
      return
    }
    lastBookmarkOpened = ["folder": folder.id, "count": links.count]
    let entries = links.map { openToday($0, after: nil, foreground: false) }
    if let first = entries.first { select(first) }
  }

  /// Add to Pinned: the bookmark, or the folder with what's in it (closed), at the end of Pinned, asleep until
  /// opened. A page already pinned or a favorite isn't added twice (one open in Today is: pinning keeps it); only pages
  /// Ray opens. The bookmarks stay.
  func pinBookmark(_ node: Bookmark) {
    guard !isPrivate else { return }
    var known = Set((state.favorites + state.pinned).filter { !$0.isFolder }.map { $0.pinnedURL ?? $0.url })
    var added: [SidebarEntry] = []
    func add(_ node: Bookmark, in parent: UUID?) {
      if let url = node.url {
        guard node.opens, known.insert(url).inserted else { return }
        let entry = SidebarEntry(kind: .pinned, url: url, title: node.title)
        entry.parentID = parent
        added.append(entry)
        return
      }
      let folder = SidebarEntry.folder(BookmarkRowView.title(of: node), in: parent)
      folder.isOpen = false
      added.append(folder)
      let before = added.count
      node.children.forEach { add($0, in: folder.id) }
      // Nothing new inside: no empty folder.
      if added.count == before { added.removeLast() }
    }
    add(node, in: nil)
    guard !added.isEmpty else {
      notes.show(Note("Already in Pinned", icon: .symbol("pin"), key: "bookmarkPinned"))
      return
    }
    state.pinned += added
    state.normalizePinned()
    changed("pinBookmark")
  }

  var bookmarksState: [String: Any] {
    [
      "open": bookmarksOpen, "panel": bookmarksList?.debug ?? NSNull(), "loaded": Bookmarks.shared.loaded,
      "count": Bookmarks.shared.allLinks.count, "lastOpened": lastBookmarkOpened ?? NSNull(),
      "openAllAsked": openAllAsked ?? NSNull(),
      "button": {
        let button = sidebar.bookmarksAnchor
        guard !button.isHidden, let height = window.contentView?.bounds.height else { return "" }
        let frame = button.convert(button.bounds, to: nil)
        return String(format: "%.1f,%.1f,%.1f,%.1f", frame.minX, height - frame.maxY, frame.width, frame.height)
      }(),
    ]
  }

  // MARK: Test snapshots

  /// For tests: the sidebar drawn from its layers (folder icons are layer-only) into `<path>-light.png` and
  /// `<path>-dark.png` at 2×, to look at rows, folders and Change Icon's panel.
  func snapshotSidebar(to path: String) -> Bool {
    for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
      let old = sidebar.appearance
      sidebar.appearance = NSAppearance(named: appearance)
      defer { sidebar.appearance = old }
      sidebar.layoutSubtreeIfNeeded()
      sidebar.displayIfNeeded()
      CATransaction.flush()
      guard let layer = sidebar.layer else { return false }
      // Change Icon's panel reaches past the sidebar: wide enough for it.
      let pickerFrame = iconPicker.map { sidebar.convert($0.bounds, from: $0) }
      let size = NSSize(width: max(sidebar.bounds.width, (pickerFrame?.maxX ?? 0) + 8), height: sidebar.bounds.height)
      guard let context = CGContext(data: nil, width: Int(size.width * 2), height: Int(size.height * 2), bitsPerComponent: 8,
                                    bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
      context.scaleBy(x: 2, y: 2)
      sidebar.effectiveAppearance.performAsCurrentDrawingAppearance {
        context.setFillColor(SidebarColors.background.cgColor)
      }
      context.fill(CGRect(origin: .zero, size: size))
      if sidebar.isFlipped {
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
      }
      layer.render(in: context)
      if let picker = iconPicker, let pickerLayer = picker.layer, let pickerFrame {
        picker.appearance = NSAppearance(named: appearance)
        picker.layoutSubtreeIfNeeded()
        picker.displayIfNeeded()
        CATransaction.flush()
        context.saveGState()
        context.translateBy(x: pickerFrame.minX, y: pickerFrame.minY)
        pickerLayer.render(in: context)
        context.restoreGState()
        picker.appearance = nil
      }
      guard let image = context.makeImage(),
            let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]),
            (try? png.write(to: URL(fileURLWithPath: "\(path)-\(name).png"))) != nil else { return false }
    }
    return true
  }

  /// For tests: draws the page toolbar into a PNG (light appearance), to look at its design.
  /// For tests: whether `url` fits the page bar's address field without being cut short (nil: no page bar).
  func toolbarAddressFits(_ url: String) -> Bool? {
    toolbarShown ? toolbar.addressFits(url) : nil
  }

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

  /// For tests: draws the open command bar's panel into a PNG (light appearance, on a grey page), to look at its design.
  func snapshotCommandBar(to path: String) -> Bool {
    guard let bar = commandBar else { return false }
    let old = bar.appearance
    bar.appearance = NSAppearance(named: .aqua)
    defer { bar.appearance = old }
    bar.layoutSubtreeIfNeeded()
    bar.displayIfNeeded()
    let rect = bar.panelFrame.insetBy(dx: -16, dy: -16).intersection(bar.bounds)
    guard !rect.isEmpty, let rep = bar.bitmapImageRepForCachingDisplay(in: rect) else { return false }
    bar.cacheDisplay(in: rect, to: rep)
    let image = NSImage(size: rect.size)
    image.lockFocus()
    NSColor(white: 0.9, alpha: 1).setFill()
    NSRect(origin: .zero, size: rect.size).fill()
    rep.draw(in: NSRect(origin: .zero, size: rect.size))
    image.unlockFocus()
    guard let tiff = image.tiffRepresentation,
          let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return false }
    return (try? png.write(to: URL(fileURLWithPath: path))) != nil
  }

  /// For tests: a burst of the page toolbar's address field, `count` PNGs `interval` seconds apart into `folder`
  /// (`field-00.png`, …), in the dark appearance (Dia's recordings are dark), to compare the loading sweep's motion
  /// frame by frame. Hidden test windows can't be screen recorded; this draws the layers' presentation instead.
  func snapshotAddressBurst(to folder: String, count: Int, interval: TimeInterval) -> Bool {
    guard toolbarShown, count > 0 else { return false }
    try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    let old = toolbar.appearance
    toolbar.appearance = NSAppearance(named: .darkAqua)
    var taken = 0
    Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] timer in
      guard let self else { return timer.invalidate() }
      _ = self.toolbar.snapshotAddress(to: (folder as NSString).appendingPathComponent(String(format: "field-%02d.png", taken)))
      taken += 1
      if taken >= count {
        timer.invalidate()
        self.toolbar.appearance = old
        TestEnvironment.log("field burst done (\(taken))")
      }
    }
    return true
  }

  /// For tests: draws the open downloads list into a PNG, to look at its design.
  func snapshotDownloads(to path: String) -> Bool {
    guard let panel = downloadsList else { return false }
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
    let pinned = arc.spaces.count == 1
      ? arc.spaces[0].pinned : arc.spaces.map { ArcImport.Node.folder(title: $0.name, children: $0.pinned) }
    addImported(favorites: arc.favorites, pinned: pinned, today: [], event: "arcImport")
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

  // MARK: Browser import

  /// The last import into this window (ImportSession), for the test state log: its events so far, then the summary.
  private var importLog: [String: Any]?

  /// Adds imported sidebar items (File › Import from Arc…, ImportSession): favorites, pinned tabs and folders, and
  /// Today's tabs, all closed until clicked. Nothing already in the sidebar comes in twice, and a folder with nothing
  /// new inside is left out. Returns how many tabs of each kind came in, and how many were already there (folders not
  /// counted).
  @discardableResult
  func addImported(
    favorites: [ArcImport.Node], pinned: [ArcImport.Node], today: [ArcImport.Node], spaces imported: [ImportedSpace] = [],
    event: String = "import"
  ) -> SidebarImportCounts {
    var known = Set(state.allEntries.filter { !$0.isFolder }.map { $0.pinnedURL ?? $0.url })
    var counts = SidebarImportCounts()
    func tabs(_ nodes: [ArcImport.Node]) -> [(url: String, title: String, name: String?)] {
      nodes.flatMap { node -> [(url: String, title: String, name: String?)] in
        switch node {
        case .tab(let url, let title, let name): [(url, title, name)]
        case .folder(_, let children): tabs(children)
        }
      }
    }
    // The other browser's own name for a tab (Arc's Rename) stays its name here; the page's title stays its title.
    func entry(_ kind: SidebarEntry.Kind, _ url: String, _ title: String, _ name: String?) -> SidebarEntry {
      let entry = SidebarEntry(kind: kind, url: url, title: title)
      entry.customTitle = name.flatMap(SidebarEntry.name(from:)).flatMap { $0 == title ? nil : $0 }
      return entry
    }
    for tab in tabs(favorites) {
      guard known.insert(tab.url).inserted else { counts.alreadyFavorites += 1; continue }
      state.favorites.append(entry(.favorite, tab.url, tab.title, tab.name))
      counts.favorites += 1
    }
    var added: [SidebarEntry] = []
    func add(_ nodes: [ArcImport.Node], in parent: UUID?) {
      for node in nodes {
        switch node {
        case .tab(let url, let title, let name):
          guard known.insert(url).inserted else { counts.alreadyPinned += 1; continue }
          let pinned = entry(.pinned, url, title, name)
          pinned.parentID = parent
          added.append(pinned)
          counts.pinned += 1
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
    add(pinned, in: nil)
    state.pinned += added
    func addToday(_ nodes: [ArcImport.Node], to space: Space) {
      for tab in tabs(nodes) {
        guard known.insert(tab.url).inserted else { counts.alreadyToday += 1; continue }
        space.today.append(entry(.today, tab.url, tab.title, tab.name))
        counts.today += 1
      }
    }
    addToday(today, to: state.current)
    // Each of the other browser's Spaces a Space here: the one of that name if there is one, else a new one (a
    // private window has none, so its Spaces' tabs join its lists).
    for space in imported {
      let target: Space
      if isPrivate {
        target = state.current
      } else if let same = state.spaces.first(where: { $0.name.lowercased() == space.name.lowercased() }) {
        target = same
      } else if state.spaces.count == 1, state.current.pinned.isEmpty, state.current.today.isEmpty, state.current.icon == nil,
                state.current.color == nil {
        // A first import into a new Ray: its first Space takes the empty one's place.
        target = state.current
        target.name = Space.name(from: space.name) ?? target.name
      } else {
        target = Space(name: Space.name(from: space.name) ?? "Imported")
        state.spaces.append(target)
      }
      // Each Space keeps its own pins: a page pinned in two of the other browser's Spaces is pinned in both here.
      known = Set((state.allFavorites + target.pinned + target.today).filter { !$0.isFolder }.map { $0.pinnedURL ?? $0.url })
      if target.icon == nil { target.icon = space.rayIcon }
      // Arc's theme as Ray's Window colour (its first gradient colour, else its mid tone). The accent stays the
      // profile colour, so the colour picked in the welcome after an import still shows; Edit Space… sets one.
      if target.color == nil,
         let hex = space.colors.lazy.compactMap(Space.validHex).first ?? space.color.flatMap(Space.validHex) {
        target.color = hex
      }
      added = []
      add(space.pinned, in: nil)
      target.pinned += added
      addToday(space.today, to: target)
    }
    state.normalizePinned()
    if !isPrivate { SpaceLook.apply(state.current) }
    changed(event)
    return counts
  }

  /// ImportSession reports each event and the final summary here, for the state log only.
  func noteImport(event: ImportEvent? = nil, summary: ImportSummary? = nil) {
    var log = importLog ?? [:]
    if event != nil, log["done"] as? Bool == true { log = [:] }
    var events = log["events"] as? [[String: Any]] ?? []
    switch event {
    case .started(let item): events.append(["started": item.rawValue])
    case .finished(let item, let count, let existing):
      events.append(["finished": item.rawValue, "count": count, "existing": existing])
    case .failed(let item, let reason): events.append(["failed": item.rawValue, "reason": reason])
    case nil: break
    }
    log["events"] = events
    log["done"] = summary != nil
    if let summary {
      log["imported"] = Dictionary(uniqueKeysWithValues: summary.imported.map { ($0.key.rawValue, $0.value) })
      log["existing"] = Dictionary(uniqueKeysWithValues: summary.existing.map { ($0.key.rawValue, $0.value) })
      log["failed"] = Dictionary(uniqueKeysWithValues: summary.failed.map { ($0.key.rawValue, $0.value) })
    }
    importLog = log
    logState("import")
  }

  // MARK: Onboarding

  private(set) var onboarding: OnboardingView?

  /// The first run's welcome, or File › Import from Browser…: an overlay over the whole window, above everything the
  /// window shows (it lives in the host view, over the root). Panels close first; focus comes back to the page after.
  func showOnboarding(_ mode: OnboardingMode) {
    guard onboarding == nil, !isPrivate else { return }
    closeCommandBar(focus: false)
    panels.close()
    let host = coreWindow.hostView
    let view = OnboardingView(mode: mode, browser: self)
    view.frame = host.bounds
    view.autoresizingMask = [.width, .height]
    view.onChange = { [weak self] in self?.logState("onboarding") }
    view.onClose = { [weak self, weak view] in
      guard let self, self.onboarding === view else { return }
      self.onboarding = nil
      // An empty window after the welcome opens the command bar, as a new window does.
      if let tab = self.activeTab { self.focusPage(tab) } else if !self.isPrivate { self.beginNewTab() }
      self.logState("onboarding")
    }
    host.addSubview(view, positioned: .above, relativeTo: nil)
    onboarding = view
    view.present()
    logState("onboarding")
  }

  /// For tests: the window with the onboarding over it, as PNGs (light and dark). Chrome's pages don't draw into a
  /// snapshot, so the page card is empty in them.
  func snapshotOnboarding(to path: String) -> Bool {
    guard onboarding != nil else { return false }
    let view = coreWindow.hostView
    for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
      let old = window.appearance
      window.appearance = NSAppearance(named: appearance)
      defer { window.appearance = old }
      view.layoutSubtreeIfNeeded()
      view.displayIfNeeded()
      guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
      view.cacheDisplay(in: view.bounds, to: rep)
      let image = NSImage(size: view.bounds.size)
      image.lockFocus()
      view.effectiveAppearance.performAsCurrentDrawingAppearance { SidebarColors.background.setFill() }
      NSRect(origin: .zero, size: view.bounds.size).fill()
      rep.draw(in: NSRect(origin: .zero, size: view.bounds.size))
      image.unlockFocus()
      guard let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
      else { return false }
      guard (try? png.write(to: URL(fileURLWithPath: path.replacingOccurrences(of: ".png", with: "-\(name).png")))) != nil
      else { return false }
    }
    return true
  }

  // MARK: Permission prompts

  private(set) lazy var permissions: PermissionPrompts = {
    let prompts = PermissionPrompts()
    prompts.host = { [unowned self] in (self.root, self.pages.frame, self.activeTab) }
    prompts.onChange = { [weak self] in self?.logState("permission") }
    return prompts
  }()

  // MARK: Password prompts

  /// "Save password?" and "Update password?" (`PasswordPrompt.swift`), one per tab, shown over its own tab.
  private(set) lazy var passwords: PasswordPrompts = {
    let prompts = PasswordPrompts(controller: self)
    prompts.onChange = { [weak self] in self?.logState("passwordPrompt") }
    return prompts
  }()

  /// The page card's frame in the root view, for prompts that hang from its corners.
  var pageFrame: NSRect { pages.frame }

  /// The last fill dropdown Chrome showed (its own popup), for tests: how many rows of which kinds, never their text.
  private var autofillSuggestions: [String: Any]?

  func window(_ window: RayCoreWindow, passwordPrompt prompt: [String: Any], for tab: RayCoreTab) {
    passwords.add(prompt, tab: tab)
  }

  // MARK: Autofill prompts

  /// "Save address?", "Update address?" and "Save card?" (`AutofillPrompt.swift`), one per tab, over its own tab.
  private(set) lazy var autofill: AutofillPrompts = {
    let prompts = AutofillPrompts(controller: self)
    prompts.onChange = { [weak self] in self?.logState("autofillPrompt") }
    return prompts
  }()

  func window(_ window: RayCoreWindow, autofillPrompt prompt: [String: Any], for tab: RayCoreTab) {
    autofill.add(prompt, tab: tab)
  }

  /// After a prompt is answered (its panel closing), the active tab's other one, if it has one waiting.
  func showPagePrompts() {
    DispatchQueue.main.async { [weak self] in
      self?.passwords.update()
      self?.autofill.update()
    }
  }

  func tab(_ tab: RayCoreTab, didShowAutofillSuggestions items: [[String: String]]) {
    autofillSuggestions = ["count": items.count, "types": items.map { $0["type"] ?? "" }, "tab": Int(tab.tabId)]
    logState("autofillSuggestions")
  }

  // MARK: Page prompts

  /// "Open “App”?" and "Page not responding" (`PagePrompts.swift`), one at a time over their own tab.
  private(set) lazy var pageQuestions: PageQuestions = {
    let questions = PageQuestions(controller: self)
    questions.onChange = { [weak self] in self?.logState("pageQuestion") }
    return questions
  }()

  /// "Pop-up blocked" notes (`PagePrompts.swift`).
  private(set) lazy var popups: BlockedPopups = {
    let popups = BlockedPopups(controller: self)
    popups.onChange = { [weak self] in self?.logState("blockedPopups") }
    return popups
  }()

  /// The crashed page's view (`CrashedPage.swift`).
  private(set) lazy var crashedPages: CrashedPages = {
    let pages = CrashedPages(controller: self)
    pages.onChange = { [weak self] in self?.logState("crashedPage") }
    return pages
  }()

  /// The crashed page's view goes right over the page card, under the toolbar, panels and notes.
  func placeCrashedPage(_ view: CrashedPageView) {
    if view.superview !== root { root.addSubview(view, positioned: .above, relativeTo: pages) }
    view.frame = pages.frame
    view.layer?.cornerRadius = pages.cornerRadius
  }

  func tab(_ tab: RayCoreTab, externalAppRequest request: [String: Any]) {
    pageQuestions.appLink(request, tab: tab)
  }

  func tabBecameUnresponsive(_ tab: RayCoreTab) { pageQuestions.unresponsive(tab) }
  func tabBecameResponsive(_ tab: RayCoreTab) { pageQuestions.responsive(tab) }

  func tab(_ tab: RayCoreTab, didBlockPopup popup: [String: String]) {
    popups.blocked(popup, tab: tab)
  }

  func tab(_ tab: RayCoreTab, rendererGone status: String, code: Int32) {
    TestEnvironment.log("tab \(tab.tabId) renderer gone (\(status) \(code))")
    crashedPages.rendererGone(tab, status: status, code: Int(code))
  }

  /// Quitting (or closing the last private window) would cancel downloads: Ray asks first (`CloseWarnings`).
  func window(_ window: RayCoreWindow, confirmCloseWithDownloads count: Int32, completion: @escaping (Bool) -> Void) {
    CloseWarnings.confirmDownloads(Int(count), quitting: AppController.shared.quitting, on: self, then: completion)
  }

  // MARK: Screen sharing

  /// Ray's screen-sharing picker (`SharePicker.swift`), over the tab that asked.
  private(set) lazy var sharePicker: SharePicker = {
    let picker = SharePicker(controller: self)
    picker.onChange = { [weak self] in self?.logState("screenShare") }
    return picker
  }()

  /// The note, the shared page's ring and the rows' marks while a share runs (`ScreenShare.swift`).
  private(set) lazy var shareIndicators: ShareIndicators = {
    let indicators = ShareIndicators(controller: self)
    indicators.onChange = { [weak self] in self?.logState("screenShare") }
    return indicators
  }()

  /// The engine says whether a tab captures a tab, a window or a screen (`screen`); camera and microphone too.
  func tab(_ tab: RayCoreTab, didChangeMediaAccess access: [String: NSNumber]) {
    ScreenShares.shared.accessChanged(tab, screen: access["screen"]?.boolValue == true)
  }

  /// The ring goes right over the page card (above a crashed page's view), under the toolbar, panels and notes.
  func placeSharedPageRing(_ ring: SharedPageRing) {
    if ring.superview !== root { root.addSubview(ring, positioned: .above, relativeTo: crashedPages.view?.superview === root ? crashedPages.view : pages) }
    ring.frame = pages.frame
    ring.layer?.cornerRadius = pages.cornerRadius
    ring.needsLayout = true
  }

  /// The ⌃Tab switcher's picture of a tab, for the picker's cards.
  func tabPicture(of entry: SidebarEntry) -> CGImage? { tabPictures.picture(of: entry) }

  func refreshRow(_ entry: SidebarEntry) { sidebar.refresh(entry) }

  /// For tests: a click on the share mark of an entry's row; false when the row shows none.
  func pressShareMark(of id: UUID) -> Bool { sidebar.pressShareMark(of: id) }

  // MARK: Panels

  /// This window's panel over the page (`Panels.swift`): one at a time, from a button.
  private(set) lazy var panels: Panels = {
    let panels = Panels(host: root) { [weak self] in self?.floating }
    panels.onChange = { [weak self] in
      self?.logState("panels")
      // The share note gives the top centre to a panel and comes back when it's gone.
      if self?.panels.isOpen == false { self?.shareIndicators.refresh() }
    }
    panels.onOpen = { [weak self] frame in self?.notes.dismiss(overlapping: frame) }
    panels.onTabSwitch = { [weak self] in
      // A hovered link's address belongs to the tab left.
      self?.linkPreview.hide()
      self?.swipeIndicator.hide()
      // The tab shown now (once it's the active one): its share picker, the share note's words and the ring.
      DispatchQueue.main.async {
        self?.sharePicker.update()
        self?.shareIndicators.refresh()
      }
    }
    return panels
  }()

  /// Where a question drops from (an install prompt, a warning): the page's top centre, under the address bar, as a
  /// sheet would.
  var questionAnchor: PanelAnchor {
    PanelAnchor(rect: { [weak self] in
      guard let self else { return .zero }
      return NSRect(x: self.pages.frame.midX, y: self.pages.frame.maxY - 10 + Panels.gap, width: 0, height: 0)
    }, below: true, align: .center)
  }

  // MARK: Notes

  /// This window's notes over the page (`Notes.swift`): `notes.show(Note(…))` from any feature.
  private(set) lazy var notes: Notes = {
    let notes = Notes(host: root)
    notes.onChange = { [weak self] in
      self?.linkPreview.notesChanged()
      self?.logState("notes")
    }
    return notes
  }()

  /// Six spots on the page card; the top-right one keeps below the find bar while that's open.
  private func layoutNotes() {
    let clearance = findBar.map { $0.frame.height + 12 - Notes.inset + 8 } ?? 0
    notes.layout(in: pages.frame, topTrailingClearance: max(0, clearance))
    linkPreview.layout(in: pages.frame)
    swipeIndicator.layout(in: pages.frame, radius: pages.cornerRadius)
  }

  // MARK: Link preview

  /// The address of the link under the pointer, at the page's bottom left (`LinkPreview.swift`), over a download's
  /// note in that corner rather than under it.
  private(set) lazy var linkPreview: LinkPreview = {
    let preview = LinkPreview(host: root, below: { [weak self] in self?.floating }) { [weak self] trailing in
      self?.notes.settledFrame(at: trailing ? .bottomTrailing : .bottomLeading)
    }
    preview.onChange = { [weak self] in self?.logState("linkPreview") }
    return preview
  }()

  func tab(_ tab: RayCoreTab, didChangeStatusText text: String) {
    guard !closing, tab === activeTab else { return }
    linkPreview.status(text)
  }

  // MARK: Swipe indicator

  /// The back/forward swipe's chip over the page (`SwipeIndicator.swift`), fed by Chrome's swiper.
  private(set) lazy var swipeIndicator: SwipeIndicator = {
    let indicator = SwipeIndicator(host: root) { [weak self] in self?.floating }
    indicator.onChange = { [weak self] in self?.logState("swipeIndicator") }
    indicator.layout(in: pages.frame, radius: pages.cornerRadius)
    return indicator
  }()

  #if RAY_TEST_HOOKS
  /// The active tab's page view, where Chrome's swiper puts its overlay.
  var activePageView: NSView? { activeTab?.view }
  #endif

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
      bar.animateIn()
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
    layoutNotes()
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
  private var siteControlsPanel: PanelHandle?
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
    let level = ConnectionLook.level(tab.securityInfo) ?? "none"
    let isInternal = URLComponents(string: AddressInput.innerURL(of: tab.url))?.scheme.map { ["chrome", AddressInput.internalScheme].contains($0) } ?? false
    let panel = SiteControlsView(
      origin: tab.committedOrigin, url: tab.url, profile: profile, security: level, isInternal: isInternal, extensions: items,
      zoom: tab.zoomFactor, defaultZoom: RaySettings.shared[.defaultZoom],
      resetZoom: { [weak self, weak tab] in if let tab { self?.resetZoom(of: tab) } })
    panel.onAction = { [weak self, weak tab] action in
      guard let self, let tab, !tab.closed else { return }
      self.siteControlsAction(action, tab: tab)
    }
    panel.onClose = { [weak self] in self?.closeSiteControls() }
    if siteAnchor.superview !== root { root.addSubview(siteAnchor) }
    siteControls = panel
    layoutSiteControls()
    // Under the sliders button: the page address bar's right end, or the sidebar's address field (the panel opens to
    // its right, over the page); with neither on screen, the page's top right.
    let inSidebar = siteControlsInSidebar
    let button: HoverIconButton = inSidebar ? sidebar.siteButton : toolbar.siteButton
    let anchor = PanelAnchor(rect: { [weak self] in self?.siteControlsAnchor ?? .zero }, below: true,
                             align: inSidebar ? .leading : .trailing, button: button,
                             hold: { [weak button] held in button?.isHeld = held })
    let handle = panels.open(PanelSpec(
      name: "siteControls", content: panel, anchor: anchor,
      closesOn: [.outsideClick, .escape, .tabSwitch, .windowInactive, .otherSite], origin: tab.committedOrigin,
      overSidebar: inSidebar,
      onClose: { [weak self, weak panel] in
        guard let self, self.siteControls === panel else { return }
        self.siteControls = nil
        self.siteControlsPanel = nil
        self.logState("siteControls")
      }))
    siteControlsPanel = handle
    panel.onResize = { handle.contentChanged() }
    panel.onPage = { [weak panel] page in
      guard let panel else { return }
      handle.show(page ?? panel)
    }
    logState("siteControls")
  }

  func closeSiteControls() {
    guard siteControls != nil else { return }
    siteControlsPanel?.close()
  }

  /// Site controls hang from the sidebar's address field: the page address bar is off and the sidebar is out.
  private var siteControlsInSidebar: Bool {
    !toolbarShown && sidebar.showsAddress && (!state.sidebarHidden || peeking) && !sidebar.siteButton.isHidden
  }

  /// The sliders button's frame: the sidebar's, or the address bar's right end 2 pt above its bottom, or (neither on
  /// screen) the page's top right.
  private var siteControlsAnchor: NSRect {
    if siteControlsInSidebar || siteControls != nil && panels.holdsSidebar {
      let button = sidebar.siteButton
      return button.convert(button.bounds, to: root)
    }
    let right = toolbarShown ? toolbar.frame.maxX - 4 : pages.frame.maxX - 8
    let top = toolbarShown ? toolbar.frame.minY - 2 + Panels.gap : pages.frame.maxY - 8 + Panels.gap
    return NSRect(x: right - 28, y: top, width: 28, height: 1)
  }

  /// Where things the panel opens hang (share's menu, an extension's popup) once it has gone; panels follow too.
  private func layoutSiteControls() {
    let anchor = siteControlsAnchor
    siteAnchor.frame = NSRect(x: anchor.minX, y: anchor.minY - Panels.gap - 1, width: anchor.width, height: 1)
    panels.layout()
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
      if !tab.showCastDialog() { notes.show(Note("Casting isn't available on this page", icon: .warning, spot: .bottom)) }
    case .addExtension: openToday("https://chromewebstore.google.com/category/extensions", after: nil, foreground: true)
    case .runExtension(let id): extensions.run(id, on: tab, anchor: siteAnchor)
    case .siteSettings:
      // Settings › Privacy (Chrome's site details page stands for it), at this site; a private window's sites aren't there.
      SettingsWindowController.shared.show(pane: SettingPane.privacy.rawValue)
      if let origin, !isPrivate { (SettingsPanes.content(for: .privacy) as? PrivacyPaneContent)?.reveal(origin) }
    case .developerTools: toggleDevTools()
    case .clearData:
      // Already confirmed on the panel's own page (SiteControlsView.confirmClearData).
      guard let origin, URLComponents(string: origin)?.host != nil else { return }
      EngineCalls.call("ac_site_data_clear", profile: profile, args: ["origin": origin, "offTheRecord": isPrivate]) { [weak self, weak tab] _ in
        tab?.userReload()
        self?.notes.show(Note("Cleared Site Data", icon: .done, spot: .top))
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
      panel.effectiveAppearance.performAsCurrentDrawingAppearance { SurfaceBackdrop.solidFill.setFill() }
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

  /// `fresh`: Settings › When Ray quits › Start fresh, so a new tab (or the start page) rather than a pinned one.
  func restore(startURL: String?, fresh: Bool = false) {
    // A Space on a profile of its own: its tabs open once the engine has that profile.
    if !isPrivate, let directory = state.current.profile, spaceProfiles[directory] == nil {
      withProfile(directory) { [weak self] _ in self?.restore(startURL: startURL, fresh: fresh) }
      return
    }
    if !fresh, let entry = activeEntry ?? state.today.first ?? state.pinned.first(where: { !$0.isFolder }) {
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
    sidebar.show(favorites: state.favorites, pinned: state.pinned, today: state.today, active: activeEntry,
                 space: isPrivate ? nil : sidebarSpace(state.current), spaces: isPrivate ? [] : state.spaces.map(sidebarSpace),
                 spaceIndex: currentSpaceIndex)
    sidebar.showAddress(activeEntry)
    sidebar.setNavigation(canGoBack: canGoBack, canGoForward: canGoForward, backToolTip: backToolTip)
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
    state.normalizeToday()
    groups.push()
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

  private func insertToday(_ entry: SidebarEntry, after opener: SidebarEntry?, in chosen: Space? = nil) {
    // A tab a page opened goes into its opener's Space (a tab left playing in another Space can open one there).
    let space = chosen ?? opener.flatMap(state.space(of:)) ?? state.current
    // A tab opened from a tab in a Today folder joins that folder, as Chrome's tab groups do. New Tab in Folder's tab
    // joins its folder.
    if let opener, opener.kind == .today, let parent = opener.parentID {
      entry.parentID = parent
    } else if opener == nil, let folder = newTabFolder.flatMap({ id in space.today.first { $0.isFolder && $0.id == id } }) {
      newTabFolder = nil
      entry.parentID = folder.id
      space.today.insert(entry, at: (space.today.firstIndex { $0 === folder } ?? 0) + state.block(of: folder).count)
      return
    }
    var opener = opener
    // Settings › Open new tabs next to the active tab: one with no opener goes right after the active one (when
    // that is in Today; otherwise at the top as usual). Not into its folder: past the folder's tabs instead.
    if opener == nil, RaySettings.shared[.newTabNextToActive], let active = activeEntry, active.kind == .today {
      opener = active.parentID.flatMap { id in space.today.filter { $0.parentID == id }.last } ?? active
    }
    if let opener, opener.kind == .today, let index = space.today.firstIndex(where: { $0 === opener }) {
      space.today.insert(entry, at: index + 1)
    } else {
      space.today.insert(entry, at: 0)
    }
  }

  private func load(_ entry: SidebarEntry, foreground: Bool) {
    guard !entry.isLive else { return }
    if entry.kind != .today { closedTabs.forget(entry: entry.id) }
    loadingEntry = entry
    let tab = coreWindow.openTab(entry.url, profile: coreProfile(for: entry), foreground: foreground)
    loadingEntry = nil
    if entry.tab !== tab { bind(entry, tab) }
  }

  private func bind(_ entry: SidebarEntry, _ tab: RayCoreTab) {
    entry.tab = tab
    tab.delegate = self
    pages.attach(tab)
  }

  /// `fromEngine`: the engine already made it its active tab (its `didActivate`): it isn't told again. Two tabs opened
  /// in front at once leave a stale activation of each in flight, and echoing them made the two flip forever.
  func select(_ entry: SidebarEntry, fromEngine: Bool = false) {
    if entry.isFolder {
      perform(.toggleFolder, on: entry)
      return
    }
    // A tab in another Space (Switch to Tab, ⌃Tab, Recently Closed): its Space comes first, as Arc's.
    if let space = state.space(of: entry), space !== state.current {
      guard enterSpace(space, then: { [weak self, weak entry] in
        if let self, let entry { self.select(entry) }
      }) else { return }
      // Its Space may remember this very tab: it's still a switch.
      state.activeEntryID = nil
    }
    load(entry, foreground: true)
    guard let tab = entry.tab, !tab.closed else { return }
    // The page left, pictured while it's still shown, for the ⌃Tab switcher's card.
    if let left = activeEntry, left !== entry { tabPictures.capture(left) }
    pages.show(tab)
    if !fromEngine { coreWindow.activate(tab) }
    let switched = state.activeEntryID != entry.id
    // Going to a tab by any other way ends a Ctrl+Tab in progress.
    if switched, !switcherChoosing { tabSwitcher.cancel("other switch") }
    if switched, findTab != nil, findTab !== tab { closeFind() }
    if switched { panels.tabSwitched() }
    if switched, let full = pageFullscreenTab, full !== tab { full.exitFullscreen() }
    // A click on another tab while the bar is open (the sidebar takes clicks through it, as Arc's) closes it.
    if switched, commandBar != nil { closeCommandBar(focus: false) }
    if switched { iconPicker?.close() }
    // An extension's popup belongs to the tab it opened over.
    if switched { extensions.closePopup() }
    state.activeEntryID = entry.id
    if switched { permissions.update() }
    if switched { passwords.update() }
    if switched { pageQuestions.update() }
    if switched { popups.tabSwitched() }
    if switched { crashedPages.tabSwitched() }
    entry.lastActive = Date()
    entry.unseen = false
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

  /// The tab to show when the active one closes: Back's "Close Tab and Go Back" target, else the tab used before it,
  /// as Arc and Ardia do: never one asleep while one is awake, one opened behind and never shown only when nothing
  /// else is open, and never one closing with it; the nearest neighbour breaks ties.
  private func successor(closing entry: SidebarEntry) -> SidebarEntry? {
    let preferred = closingTo
    closingTo = nil
    if let preferred, state.entry(id: preferred.id) === preferred, !preferred.isFolder, preferred !== entry { return preferred }
    // Only tabs of the Space on screen (and its favorites): closing never takes you to another Space.
    let list = state.shownEntries.contains(where: { $0 === entry }) ? state.shownEntries : state.allEntries
    let index = list.firstIndex { $0 === entry } ?? 0
    let excluded = closingTogether.union([entry.id])
    let open = list.indices.sorted { abs($0 - index) < abs($1 - index) }.map { list[$0] }
      .filter { $0.isLive && !$0.isFolder && !excluded.contains($0.id) }
    // `max(by:)` keeps the first of equals: the nearest.
    return open.filter { !$0.unseen }.max(by: { $0.lastActive < $1.lastActive }) ?? open.first
  }

  /// Set just before Back closes a tab a link opened: the tab to go back to.
  private var closingTo: SidebarEntry?
  /// Tabs closing together (a selection, a folder's Close Tabs): none of them is shown after.
  private var closingTogether: Set<UUID> = []

  // MARK: Closing

  /// ⌘W: closes the active tab, or every selected tab (as Arc does); with no tab open, the window (as Chrome and Arc
  /// do).
  func closeActive() {
    if sidebar.selection.count > 1 { return performOnSelection(.close) }
    guard let entry = activeEntry else {
      window.performClose(nil)
      return
    }
    if entry.isLive {
      closeByUser(entry)
    } else if entry.kind == .today {
      rememberClosed(entry, key: nil, favicon: nil)
      state.remove(entry)
      changed("remove")
    }
  }

  // MARK: Row actions

  /// What a row's menu item (or its close button, or a test's `rowaction`) does to an entry.
  func perform(_ action: SidebarRowAction, on entry: SidebarEntry) {
    // Changes that move rows around slide them there (and drop new ones in) rather than jump.
    switch action {
    case .newFolder, .moveToFolder, .removeFromFolder, .deleteFolder, .pinFolder, .unpinFolder, .pin, .unpin,
         .closeFolderTabs, .newNestedFolder, .moveToPinned, .moveToToday, .duplicate:
      sidebar.animateNextChange()
    default: break
    }
    switch action {
    case .close, .unload:
      // Both are the row's Close Tab (a pinned or favorite row stays, unloaded): either can be reopened with ⇧⌘T.
      if entry.isLive {
        closeByUser(entry)
      } else if entry.kind == .today {
        rememberClosed(entry, key: nil, favicon: nil)
        state.remove(entry)
        changed("remove")
      }
      return
    case .copyLinks:
      copyLinks(entry.isFolder ? state.block(of: entry) : [entry])
      return
    case .shareFolder:
      shareLinks(of: entry)
      return
    case .duplicate:
      duplicate(entry)
      return
    case .toggleMute:
      guard let tab = entry.tab, entry.isLive else { return }
      tab.muted = !tab.muted
      logState("mute")
      return
    case .stopSharing:
      guard let tab = entry.tab, entry.isLive else { return }
      _ = ScreenShares.shared.stopSharing(tab)
      return
    case .moveToPinned:
      move(entry, to: .pinned(state.pinned.count, parent: nil))
      return
    case .moveToToday:
      move(entry, to: .today(0, parent: nil))
      return
    case .moveToSpace(let id):
      move(entry, toSpace: id)
      return
    case .replacePinnedURL, .editPinnedURL, .setPinnedURL:
      editPinnedPage(entry, action)
      return
    case .backToPinned:
      if let target = entry.pinnedURL, let tab = entry.tab, entry.isLive {
        tab.userLoad(target)
      }
      return
    case .pin:
      guard entry.kind == .today else { return }
      move(entry, to: .pinned(state.pinned.count, parent: nil))
      return
    case .unpin:
      guard entry.kind == .pinned else { return }
      move(entry, to: .today(0, parent: nil))
      return
    case .pinFolder:
      guard state.isTodayFolder(entry) else { return }
      move(entry, to: .pinned(state.pinned.count, parent: nil))
      return
    case .unpinFolder:
      guard entry.isFolder, !state.isTodayFolder(entry) else { return }
      move(entry, to: .today(0, parent: nil))
      return
    case .renameFolder:
      sidebar.beginRename(entry)
      return
    case .changeIcon:
      showIconPicker(for: entry)
      return
    case .setColor(let color):
      guard entry.isFolder else { return }
      entry.color = color.flatMap { FolderLook.colors.contains($0) ? $0 : nil }
    case .setIcon(let icon):
      // A folder's glyph on its flap; a tab's in place of its favicon (nil: the favicon again).
      entry.icon = FolderLook.validIcon(icon)
    case .toggleFolder:
      guard entry.isFolder else { return }
      entry.isOpen = !(entry.isOpen ?? true)
    case .newFolder:
      // Around this tab: a new folder where it is, with the tab inside, ready to name. In Today it's a Chrome tab
      // group too, and takes the colour Chrome would give a new group.
      if entry.kind == .today {
        let folder = SidebarEntry.folder("New Folder", in: nil)
        folder.color = FolderLook.nextColor(avoiding: state.todayFolders.map(\.color))
        state.today.insert(folder, at: state.today.firstIndex { $0 === entry } ?? 0)
        move(entry, to: .folder(folder.id))
        sidebar.beginRename(folder)
        return
      }
      let folder = SidebarEntry.folder("New Folder", in: entry.kind == .pinned ? entry.parentID : nil)
      let at = entry.kind == .pinned ? state.pinned.firstIndex { $0 === entry } ?? state.pinned.count : state.pinned.count
      state.pinned.insert(folder, at: at)
      move(entry, to: .folder(folder.id))
      sidebar.beginRename(folder)
      return
    case .newNestedFolder:
      guard entry.isFolder, !state.isTodayFolder(entry) else { return }
      let folder = SidebarEntry.folder("New Folder", in: entry.id)
      entry.isOpen = true
      state.pinned.append(folder)
      state.normalizePinned()
      changed("sidebar")
      sidebar.beginRename(folder)
      return
    case .newTabInFolder:
      guard state.isTodayFolder(entry) else { return }
      entry.isOpen = true
      beginNewTab()
      newTabFolder = entry.id
      return
    case .closeFolderTabs:
      guard state.isTodayFolder(entry) else { return }
      let tabs = state.today.filter { $0.parentID == entry.id }
      closingTogether = Set(tabs.map(\.id))
      defer { closingTogether = [] }
      for tab in tabs.reversed() {
        if tab.isLive {
          closeByUser(tab)
        } else {
          rememberClosed(tab, key: nil, favicon: nil)
          state.remove(tab)
        }
      }
    case .moveToFolder(let id):
      move(entry, to: .folder(id))
      return
    case .removeFromFolder:
      guard let parentID = entry.parentID, let parent = state.entry(id: parentID) else { return }
      if state.isTodayFolder(parent) {
        let end = (state.today.firstIndex { $0 === parent } ?? 0) + state.block(of: parent).count
        let at = end - (state.today.firstIndex { $0 === entry }.map { $0 < end ? 1 : 0 } ?? 0)
        move(entry, to: .today(at, parent: nil))
        return
      }
      let end = (state.pinned.firstIndex { $0 === parent } ?? 0) + state.block(of: parent).count
      move(entry, to: .pinned(end, parent: parent.parentID))
      return
    case .deleteFolder:
      // As in Crest: the folder goes, what was inside moves up a level. A Today folder's group is taken apart.
      guard entry.isFolder else { return }
      if state.isTodayFolder(entry) {
        groups.release(entry)
        for child in state.today where child.parentID == entry.id { child.parentID = nil }
        state.today.removeAll { $0 === entry }
      } else {
        for child in state.pinned where child.parentID == entry.id { child.parentID = entry.parentID }
        state.pinned.removeAll { $0 === entry }
        state.normalizePinned()
      }
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
  /// everything inside it. Today folders are one level: nothing but tabs goes into one, and a pinned folder that
  /// comes to Today brings the tabs of the folders inside it into itself. A Today folder that's pinned stops being a
  /// Chrome tab group (Chrome never lets a pinned tab be in one).
  func move(_ entry: SidebarEntry, to target: SidebarDropTarget) {
    guard state.entry(id: entry.id) === entry else { return }
    let fromToday = state.today.contains { $0 === entry }
    let block = entry.isFolder || entry.kind == .pinned ? state.block(of: entry) : [entry]
    var parent: UUID?
    switch target {
    case .pinned(_, let id), .today(_, let id): parent = id
    case .folder(let id): parent = id
    case .favorites: if entry.isFolder { return }
    }
    if let parent, parent == entry.id || block.contains(where: { $0.id == parent }) { return }
    let todayFolder = parent.flatMap { id in state.todayFolders.first { $0.id == id } }
    if let parent, todayFolder == nil, state.pinned.first(where: { $0.id == parent })?.isFolder != true { return }
    switch target {
    case .today: if parent != nil && (todayFolder == nil || entry.isFolder) { return }
    case .pinned: if todayFolder != nil { return }
    case .folder: if todayFolder != nil && entry.isFolder { return }
    case .favorites: break
    }
    let leavesToday: Bool = {
      if case .today = target { return false }
      if case .folder = target, todayFolder != nil { return false }
      return true
    }()
    if entry.isFolder, fromToday, leavesToday { groups.release(entry) }
    state.favorites.removeAll { $0 === entry }
    state.pinned.removeAll { item in block.contains { $0 === item } }
    state.today.removeAll { item in block.contains { $0 === item } }
    entry.parentID = nil
    switch target {
    case .favorites(let index):
      if entry.pinnedURL == nil { entry.pinnedURL = entry.currentURL }
      entry.kind = .favorite
      state.favorites.insert(entry, at: min(index, state.favorites.count))
    case .pinned(let index, let parent):
      pin(block, at: index, in: parent)
    case .folder(let id):
      if let folder = todayFolder {
        folder.isOpen = true
        entry.kind = .today
        entry.pinnedURL = nil
        entry.parentID = id
        state.today.insert(entry, at: (state.today.firstIndex { $0 === folder } ?? 0) + state.block(of: folder).count)
      } else {
        let folder = state.pinned.first { $0.id == id }!
        folder.isOpen = true
        pin(block, at: (state.pinned.firstIndex { $0 === folder } ?? 0) + state.block(of: folder).count, in: id)
      }
    case .today(let index, let parent):
      var items = [entry]
      if entry.isFolder {
        // Its tabs, and the tabs of the folders inside it, straight inside it.
        items += block.filter { !$0.isFolder && $0 !== entry }
        for tab in items.dropFirst() { tab.parentID = entry.id }
      } else {
        entry.parentID = parent
      }
      for item in items where !item.isFolder {
        item.kind = .today
        item.pinnedURL = nil
      }
      state.today.insert(contentsOf: items, at: min(index, state.today.count))
    }
    changed("sidebar")
  }

  private func pin(_ block: [SidebarEntry], at index: Int, in parent: UUID?) {
    guard let entry = block.first else { return }
    for item in block where !item.isFolder && item.kind != .pinned {
      if item.pinnedURL == nil { item.pinnedURL = item.currentURL }
      item.kind = .pinned
    }
    for item in block where item.isFolder { item.groupToken = nil }
    entry.parentID = parent
    state.pinned.insert(contentsOf: block, at: min(index, state.pinned.count))
    state.normalizePinned()
  }

  // MARK: Sidebar commands

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

  /// Clear Today (⇧⌘K), as Arc's: every Today tab but the one you're on and those playing sound; ⇧⌘T (or ⌘Z) brings
  /// the whole clear back.
  func clearToday() {
    let batch = UUID()
    for entry in state.today where !entry.isFolder {
      if entry.id == state.activeEntryID || entry.isLive && entry.tab?.audible == true { continue }
      if entry.isLive {
        closeByUser(entry, batch: batch)
      } else {
        rememberClosed(entry, key: nil, favicon: nil, batch: batch)
        state.remove(entry)
      }
    }
    changed("clear")
  }

  func cycleTab(by step: Int) {
    let live = state.allEntries.filter { $0.isLive }
    guard !live.isEmpty else { return }
    let index = live.firstIndex { $0.id == state.activeEntryID } ?? 0
    select(live[(index + step + live.count) % live.count])
  }

  func selectTab(number: Int) {
    let entries = state.allEntries.filter { !$0.isFolder }
    guard !entries.isEmpty else { return }
    select(number >= 9 ? entries[entries.count - 1] : entries[min(number, entries.count) - 1])
  }

  // MARK: Tab switcher

  /// ⌃Tab and ⌃⇧Tab. With Settings › Switch tabs in recently used order on, Arc's switcher (`TabSwitcher`): the
  /// recently used tabs as cards while Control is held, switching when it's let go. Off, it's the sidebar's order,
  /// like ⇧⌘] and ⇧⌘[, with no switcher.
  func cycleTabWithControl(by step: Int) {
    guard RaySettings.shared[.recentTabCycling] else { return cycleTab(by: step) }
    if tabSwitcher.isOpen { return tabSwitcher.step(step, order: [], cards: 0, held: true) }
    let live = state.allEntries.filter { $0.isLive && !$0.isFolder }
    // Most recently used first, the current tab on top; ties keep the sidebar's order.
    var order = live.enumerated().sorted { ($0.element.lastUsed, $1.offset) > ($1.element.lastUsed, $0.offset) }.map(\.element)
    if let active = activeEntry, let at = order.firstIndex(where: { $0 === active }) {
      order.remove(at: at)
      order.insert(active, at: 0)
    }
    tabPictures.keep(Set(live.map(\.id)))
    if let active = activeEntry { tabPictures.capture(active) }
    // From a menu click nothing is held, and the walk switches at once.
    let event = NSApp.currentEvent
    let held = event?.type == .keyDown && event?.modifierFlags.contains(.control) == true
    tabSwitcher.step(step, order: order, cards: TabSwitcherView.cards(fitting: root.bounds.width), held: held)
  }

  /// Control was let go: the switcher switches to the card it reached.
  func endTabCycle() { tabSwitcher.commit("release") }

  @objc private func windowResignedKey() { tabSwitcher.cancel("resigned") }

  private func makeTabSwitcher() -> TabSwitcher {
    let switcher = TabSwitcher()
    switcher.describe = { [weak self] entry in
      TabSwitcherView.Card(title: entry.displayTitle, icon: self?.sidebarIcon(for: entry),
                           picture: self?.tabPictures.picture(of: entry))
    }
    switcher.onShow = { [weak self, weak switcher] in
      guard let self, let view = switcher?.view else { return }
      // Over the page and the docked sidebar, under a peeking one, centred on the whole window as Arc's.
      self.root.addSubview(view, positioned: .below, relativeTo: self.floating)
      self.layoutTabSwitcher()
    }
    switcher.onHide = { [weak switcher] in switcher?.view.removeFromSuperview() }
    switcher.onChange = { [weak self] in self?.logState("tabSwitcher") }
    switcher.onCommit = { [weak self] entry in
      guard let self else { return }
      self.switcherChoosing = true
      self.select(entry)
      self.switcherChoosing = false
    }
    switcher.onClose = { [weak self] entry in
      guard let self else { return }
      // Closing the active tab shows the one used before it; that switch is the walk's own, not another.
      self.switcherChoosing = true
      self.closeByUser(entry)
      self.switcherChoosing = false
    }
    tabPictures.onChange = { [weak switcher] id in switcher?.pictureChanged(id) }
    return switcher
  }

  private func layoutTabSwitcher() {
    let view = tabSwitcher.view
    guard view.superview === root else { return }
    let size = view.frame.size
    view.setFrameOrigin(NSPoint(x: ((root.bounds.width - size.width) / 2).rounded(.down),
                                y: ((root.bounds.height - size.height) / 2).rounded(.down)))
  }


  // MARK: Recently closed

  /// The user closes a live tab. In a normal window its back/forward list goes to the engine's tab restore service
  /// (as Chrome's own closes do) under a key of its own, so ⇧⌘T can ask for exactly that tab back; it's remembered
  /// once the engine has removed it (`window(_:didRemove:)`), at the place it had then.
  private func closeByUser(_ entry: SidebarEntry, batch: UUID? = nil) {
    guard let tab = entry.tab, !tab.closed else { return }
    // The tab to show is picked and shown first: closed while active, Chrome would show its own pick (the opener or
    // the next tab in its strip) before Ray hears of the close.
    if entry.id == state.activeEntryID, let next = successor(closing: entry) { select(next) }
    var key: String?
    if !isPrivate, Self.isReopenable(entry.currentURL) {
      let tag = "ray-closed-" + UUID().uuidString
      EngineCalls.call("ac_tab_restore_tag", profile: coreProfile(for: entry), args: ["tab": Int(tab.tabId), "key": tag]) { _ in }
      key = tag
    }
    userClosing[entry.id] = (key, tab.favicon, batch)
    tab.close()
  }

  /// A blank tab leaves nothing to reopen (Chrome keeps no entry for one either). The address is the engine's own
  /// for the tab (never one a page reported); `javascript:` can't be one, and is never loaded anyway.
  private static func isReopenable(_ url: String) -> Bool {
    !url.isEmpty && url != "about:blank" && !url.lowercased().hasPrefix("javascript:")
  }

  /// Remembers a closed entry with its place in its section, before it leaves the sidebar (Today) or goes back to its
  /// pinned address (pinned and favorites).
  private func rememberClosed(_ entry: SidebarEntry, key: String?, favicon: NSImage?, batch: UUID? = nil) {
    let url = entry.currentURL
    let space = state.space(of: entry) ?? state.current
    let section = entry.kind == .today ? space.today
      : entry.kind == .favorite ? state.favorites(profile: state.profileDirectory(of: entry)) : space.pinned
    guard Self.isReopenable(url), !entry.isFolder, let index = section.firstIndex(where: { $0 === entry }) else { return }
    closedTabs.add(ClosedTab(
      entryID: entry.id, kind: entry.kind, index: index, parentID: entry.parentID, pinnedURL: entry.pinnedURL,
      url: url, title: entry.title, customTitle: entry.customTitle, favicon: favicon ?? favicons.image(for: url),
      restoreKey: key, batch: batch, spaceID: entry.kind == .favorite ? nil : space.id))
  }

  /// Settings › General › When Ray quits › Start fresh, as the launch's first window opens: last time's Today tabs
  /// close as if closed by hand (⇧⌘T and History › Recently Closed bring them back, on their last page), pinned tabs
  /// and favorites stay, and nothing is active. Ardia's "Start fresh" keeps them in Recently Closed too.
  func startFresh() {
    let closing = state.allToday.filter { !$0.isFolder }
    guard !closing.isEmpty || state.spaces.contains(where: { $0.activeEntryID != nil }) else { return }
    // The last Today tab first, so ⇧⌘T brings back the top one first, each to its old place (every Space's).
    for entry in closing.reversed() { rememberClosed(entry, key: nil, favicon: nil) }
    for entry in closing { state.remove(entry) }
    state.normalizeToday()
    for space in state.spaces { space.activeEntryID = nil }
    store.saveNow(state)
  }

  /// ⇧⌘T, or a History › Recently Closed item: the newest closed tab (or that one) back where it was, with its
  /// back/forward list, and active. A pinned or favorite row that's open again by now has nothing to bring back, so
  /// ⇧⌘T goes on to the tab closed before it.
  func reopenClosedTab(_ id: UUID? = nil) {
    while let closed = closedTabs.take(id) {
      // A whole Clear Today comes back at once, each tab to its place, behind the tab you're on (which it kept).
      if id == nil, let batch = closed.batch {
        var reopened = reopen(closed, shows: false)
        while let next = closedTabs.takeNext(inBatch: batch) { reopened = reopen(next, shows: false) || reopened }
        if reopened { return }
        continue
      }
      if reopen(closed) || id != nil { return }
    }
  }

  /// `shows`: the reopened tab becomes the active one (all but the rest of a Clear Today's tabs).
  private func reopen(_ closed: ClosedTab, shows: Bool = true) -> Bool {
    let entry: SidebarEntry
    if let existing = state.entry(id: closed.entryID) {
      // A pinned or favorite row (closing only unloaded it): the same row comes back to life.
      guard !existing.isLive, !existing.isFolder else { return false }
      entry = existing
    } else {
      // A Today tab, or a row deleted since: a new entry in the same place.
      entry = SidebarEntry(kind: closed.kind, url: closed.url, title: closed.title)
      entry.customTitle = closed.customTitle
      // Back into the Space it closed in, while that Space is still there.
      let space = closed.spaceID.flatMap(state.space(id:)) ?? state.current
      switch closed.kind {
      case .today:
        space.today.insert(entry, at: min(closed.index, space.today.count))
      case .favorite:
        entry.pinnedURL = closed.pinnedURL ?? closed.url
        state.favorites.insert(entry, at: min(closed.index, state.favorites.count))
      case .pinned:
        entry.pinnedURL = closed.pinnedURL ?? closed.url
        entry.parentID = closed.parentID
        space.pinned.insert(entry, at: min(closed.index, space.pinned.count))
        state.normalizePinned()
      case .folder:
        return false
      }
    }
    entry.url = closed.url
    if !closed.title.isEmpty { entry.title = closed.title }
    guard let key = closed.restoreKey else {
      if shows { select(entry) }
      changed("reopen")
      return true
    }
    changed("reopen")
    EngineCalls.call("ac_tab_restore_take", profile: coreProfile(for: entry), args: ["key": key]) { [weak self] reply in
      guard let self, !self.closing, self.state.entry(id: entry.id) === entry, !entry.isLive else { return }
      if let saved = reply?["state"] as? String, !saved.isEmpty {
        self.loadingEntry = entry
        let tab = self.coreWindow.restoreTab(saved, profile: self.coreProfile(for: entry), foreground: shows)
        self.loadingEntry = nil
        if let tab, entry.tab !== tab { self.bind(entry, tab) }
      }
      // Without its history (the engine no longer had it), the tab opens on the page it was on.
      if shows { self.select(entry) } else { self.load(entry, foreground: false) }
      self.logState("reopen")
    }
    return true
  }

  // MARK: Tab names

  /// A tab's own name, from its row's Rename… or a double click on its title: shown in place of the page's title in
  /// the sidebar, the command bar and Recently Closed, kept across navigations and relaunches. An empty name, or the
  /// page's own title, clears it (the page's title shows again).
  func setName(_ entry: SidebarEntry, to text: String) {
    guard !entry.isFolder, state.entry(id: entry.id) === entry else { return }
    var name = SidebarEntry.name(from: text)
    if name == entry.pageTitle { name = nil }
    guard name != entry.customTitle else { return }
    entry.customTitle = name
    changed("rename")
  }

  func sidebar(_ sidebar: SidebarView, name entry: SidebarEntry, as name: String) { setName(entry, to: name) }

  /// For tests: `rename <id> <text>` commits what the inline field would, for a folder or a tab.
  func renameEntry(_ entry: SidebarEntry, to text: String) {
    // As typing it into the open field and pressing Return would: the field closes without committing its own text.
    sidebar.cancelRename(entry)
    if entry.isFolder { rename(entry, to: text) } else { setName(entry, to: text) }
  }

  /// For tests: an entry's context menu, as its titles.
  func menuTitles(for entry: SidebarEntry) -> [String] { sidebar.debugMenuTitles(for: entry) }


  // MARK: Row menus

  /// Duplicate: a copy right after it in the same place. A live tab's copy is the engine's duplicate (its history
  /// too, as Chrome's Duplicate) and becomes the active tab; an unloaded one's opens on its page when clicked.
  @discardableResult
  func duplicate(_ entry: SidebarEntry, select: Bool = true) -> SidebarEntry? {
    guard state.entry(id: entry.id) === entry else { return nil }
    if entry.isFolder {
      duplicateFolder(entry)
      return nil
    }
    let copy = entry.duplicate()
    switch entry.kind {
    case .favorite:
      state.favorites.insert(copy, at: (state.favorites.firstIndex { $0 === entry } ?? state.favorites.count - 1) + 1)
    case .pinned:
      state.pinned.insert(copy, at: (state.pinned.firstIndex { $0 === entry } ?? state.pinned.count - 1) + 1)
      state.normalizePinned()
    case .today, .folder:
      state.today.insert(copy, at: (state.today.firstIndex { $0 === entry } ?? -1) + 1)
    }
    if let tab = entry.tab, entry.isLive {
      loadingEntry = copy
      let made = coreWindow.duplicate(tab, profile: coreProfile(for: entry), foreground: select)
      loadingEntry = nil
      if let made, copy.tab !== made { bind(copy, made) }
      if select { self.select(copy) }
    }
    changed("duplicate")
    return copy
  }

  /// A folder's copy, right after it: the same name, look and tabs (unloaded), nested folders too.
  private func duplicateFolder(_ folder: SidebarEntry) {
    let block = state.block(of: folder)
    var ids: [UUID: UUID] = [:]
    let copies = block.map { item -> SidebarEntry in
      let copy = item.duplicate()
      ids[item.id] = copy.id
      return copy
    }
    for copy in copies.dropFirst() { copy.parentID = copy.parentID.map { ids[$0] ?? $0 } }
    if state.isTodayFolder(folder) {
      state.today.insert(contentsOf: copies, at: (state.today.firstIndex { $0 === folder } ?? 0) + block.count)
    } else {
      state.pinned.insert(contentsOf: copies, at: (state.pinned.firstIndex { $0 === folder } ?? 0) + block.count)
      state.normalizePinned()
    }
    changed("duplicate")
  }

  /// Share Folder…: macOS's share picker with the folder's links, beside its icon.
  private func shareLinks(of folder: SidebarEntry) {
    let urls = state.block(of: folder).filter { !$0.isFolder }.compactMap { URL(string: $0.currentURL) }
    guard !urls.isEmpty, let frame = sidebar.iconFrame(of: folder, in: root) else { return }
    lastShared = urls.count
    logState("share")
    // Test instances record it only: a picker over the hidden window would wait for a click no check makes.
    if TestEnvironment.isTestBuild, TestEnvironment["RAY_TEST_COMMANDS"] != nil { return }
    NSSharingServicePicker(items: urls).show(relativeTo: frame, of: root, preferredEdge: .maxX)
  }

  /// For tests: how many links the last Share Folder… offered.
  private(set) var lastShared = 0

  /// Edit Pinned Page ›: Replace Pinned URL with Current (the page it's on now), and Edit…, the pinned address in
  /// the row's field. What's typed goes through `AddressInput` as the address bar's does, and only a web page or one
  /// of the engine's own (never a file, data or script) can be pinned. A tab that was on its pinned page follows it
  /// there; an unloaded one opens there next.
  private func editPinnedPage(_ entry: SidebarEntry, _ action: SidebarRowAction) {
    guard !entry.isFolder, entry.kind != .today, entry.pinnedURL != nil, state.entry(id: entry.id) === entry else { return }
    switch action {
    case .replacePinnedURL:
      guard entry.isLive, Self.isPinnable(entry.currentURL), entry.currentURL != entry.pinnedURL else { return }
      entry.pinnedURL = entry.currentURL
    case .editPinnedURL:
      sidebar.beginEditPinnedURL(entry)
      return
    case .setPinnedURL(let text):
      guard let url = AddressInput.url(for: text), Self.isPinnable(url), url != entry.pinnedURL else { return }
      let wasHome = !entry.isAwayFromPinned
      entry.pinnedURL = url
      if !entry.isLive {
        entry.url = url
      } else if wasHome {
        entry.tab?.userLoad(url)
      }
    default:
      return
    }
    changed("pinnedURL")
  }

  static func isPinnable(_ url: String) -> Bool {
    guard let scheme = URLComponents(string: url)?.scheme?.lowercased() else { return false }
    return ["http", "https", "chrome", "about"].contains(scheme)
  }

  /// For tests: a row menu item chosen by its title (`rowmenu <id> press <title>`).
  func pressMenuItem(_ path: String, for entry: SidebarEntry) -> Bool { sidebar.debugPressMenuItem(path, for: entry) }

  // MARK: Page toolbar

  private func updateToolbar() {
    let entry = activeEntry
    let level = entry.flatMap { $0.isLive ? $0.tab.flatMap { ConnectionLook.level($0.securityInfo) } : nil }
    toolbar.show(url: entry?.currentURL ?? "", security: level,
                 canGoBack: canGoBack, canGoForward: canGoForward, backToolTip: backToolTip)
    updateToolbarLoading()
  }

  /// The active tab's load in the reload button, and its navigation's sweep (`LoadSweeps`) in the address field;
  /// other tabs' loads aren't drawn.
  private func updateToolbarLoading() {
    let tab = activeTab
    toolbar.showLoading(tab?.loading ?? false, sweep: tab.map { LoadSweeps.shared.sweep(for: $0) } ?? .init(),
                        progress: tab?.progress ?? 0, tab: tab.map { Int($0.tabId) } ?? -1)
  }

  /// Settings › Minimal URL in the address bar, the other way round.
  var fullAddressShown: Bool { !RaySettings.shared[.minimalURL] }

  /// View › Show Full Address: the same setting as Settings › Minimal URL in the address bar. Its change comes back
  /// through `observeSettings`, in every window.
  func toggleFullAddress() {
    RaySettings.shared.set(.minimalURL, !RaySettings.shared[.minimalURL])
  }

  /// View › Show Address Bar on Page: the same setting as Settings › Show the address bar above the page, so every
  /// window follows (as Chrome's View menu flips its bookmarks bar and full URLs everywhere, and View › Show Full
  /// Address does in Ray). The change comes back through `observeSettings`.
  func toggleToolbar() {
    RaySettings.shared.set(.pageAddressBar, !toolbarShown)
  }

  func toolbarToggleSidebar(_ toolbar: PageToolbarView) { toggleSidebar() }
  func toolbarBack(_ toolbar: PageToolbarView) { goBack() }
  func toolbarForward(_ toolbar: PageToolbarView) { goForward() }
  func toolbarHistoryInNewTab(_ toolbar: PageToolbarView, forward: Bool) { openHistoryInNewTab(forward: forward) }
  func toolbarReload(_ toolbar: PageToolbarView) { activeTab?.userReload() }
  func toolbarStop(_ toolbar: PageToolbarView) { activeTab?.stop() }
  func toolbarEditAddress(_ toolbar: PageToolbarView) { focusAddress() }
  func toolbarCopyLink(_ toolbar: PageToolbarView) { copyURL() }
  func toolbarSiteControls(_ toolbar: PageToolbarView) { toggleSiteControls() }

  /// For tests: the toolbar's reload (or, while loading, stop) button.
  func pressToolbarReload() { toolbar.pressReload() }

  // MARK: Tab sound

  /// Sound started or stopped (2 s after it goes quiet), or the tab was muted: the row's and tile's sound mark.
  func tabDidChangeAudio(_ tab: RayCoreTab) {
    guard !closing, let entry = state.entry(for: tab) else { return }
    sidebar.refresh(entry)
    logState("audio")
  }

  /// For tests: a click on the sound mark of an entry's row.
  func pressSound(of id: UUID) -> Bool { sidebar.pressSound(of: id) }

  // MARK: Picture in picture

  /// What Chrome's picture-in-picture window did for this window's tabs, newest last (the state log's
  /// `pictureInPicture`): opened or closed, a video's or a document's, whether its tab was the one shown and whether
  /// Chrome's automatic picture in picture (`AutoPictureInPicture`) holds it.
  private var pictureInPictureSteps: [[String: Any]] = []

  /// Chrome opened or closed a picture-in-picture window for a tab: by the page, by hand, or automatically when the
  /// tab or the window was left (Settings › Tabs › Automatic Picture in Picture). Chrome's window is all the UI.
  func tab(_ tab: RayCoreTab, didChangePictureInPicture change: [String: Any]) {
    guard !closing, let entry = state.entry(for: tab) else { return }
    let step: [String: Any] = [
      "entry": entry.id.uuidString, "kind": change["kind"] as? String ?? "", "active": change["active"] as? Bool ?? false,
      "tabShown": tab === pages.shown && pages.windowSeen, "auto": tab.autoPictureInPictureIsChromes,
    ]
    pictureInPictureSteps = Array((pictureInPictureSteps + [step]).suffix(20))
    logState("pictureInPicture")
  }

  /// For tests: the window as the user would see it (`true`), not see it (covered, on another Space), or `nil` as it is.
  func fakeWindowSight(_ seen: Bool?) {
    pages.fakeSight = seen
    logState("windowSight")
  }

  // MARK: Back and forward

  /// The tab Back closes and goes back to (Ardia's "Close Tab and Go Back", PR #1401): on a Today tab a page opened,
  /// with no history of its own, the tab that opened it, while that is still in this window.
  private func backCloses(_ entry: SidebarEntry?) -> SidebarEntry? {
    guard let entry, entry.kind == .today, entry.isLive, entry.tab?.canGoBack == false, let id = entry.openerID,
          let opener = state.entry(id: id), opener !== entry, !opener.isFolder else { return nil }
    return opener
  }

  /// Whether Back does something: the page before, or closing a tab a link opened.
  var canGoBack: Bool { activeTab?.canGoBack == true || backCloses(activeEntry) != nil }
  var canGoForward: Bool { activeTab?.canGoForward == true }

  /// Back (⌘[, both Back buttons): the page before; on a tab a link opened that has none, the tab closes and the one
  /// that opened it shows.
  func goBack() {
    guard let tab = activeTab else { return }
    if tab.canGoBack { return tab.userGoBack() }
    guard let entry = activeEntry, let opener = backCloses(entry) else { return }
    closingTo = opener
    closeByUser(entry)
    logState("closeAndGoBack")
  }

  func goForward() { activeTab?.userGoForward() }

  /// ⌘-click or a middle click on Back or Forward: that page in a new tab behind this one, as Arc and Chrome do
  /// (http(s) pages only, as the history list's ⌘-click).
  func openHistoryInNewTab(forward: Bool) {
    guard let entry = activeEntry, let tab = activeTab,
          let item = HistoryList.items(tab.navigationEntries, forward: forward).first,
          let url = URL(string: item.url).flatMap(AddressInput.link(fromOtherApp:)) else { return }
    let opened = openToday(url, after: entry, foreground: false)
    opened.unseen = true
    notes.show(Note("Opened in Background Tab", icon: .symbol("plus.square.on.square"), key: "backgroundTab"))
    logState("historyInNewTab")
  }

  /// Back's tooltip says when it closes the tab, as Ardia's does.
  private var backToolTip: String { activeTab?.canGoBack == false && backCloses(activeEntry) != nil ? "Close Tab and Go Back" : "Back" }

  // MARK: History list

  private var historyList: HistoryListView?
  private var historyPanel: PanelHandle?
  private var historyButton: HistoryButton?
  private var historyForward = false

  func toolbarHistory(_ toolbar: PageToolbarView, forward: Bool, from button: HistoryButton) {
    toggleHistoryList(forward: forward, from: button, inSidebar: false)
  }

  func sidebarHistory(_ sidebar: SidebarView, forward: Bool, from button: HistoryButton) {
    toggleHistoryList(forward: forward, from: button, inSidebar: true)
  }

  /// Back's or forward's history list (`HistoryList.swift`) under its button, or closed when it's already open from
  /// that button.
  func toggleHistoryList(forward: Bool, from button: HistoryButton, inSidebar: Bool) {
    if historyList != nil, historyButton === button {
      historyPanel?.close()
      return
    }
    guard let entry = activeEntry, entry.isLive, let tab = entry.tab, !tab.closed else { return }
    let items = HistoryList.items(tab.navigationEntries, forward: forward)
    guard !items.isEmpty else { return }
    let key = Self.menuItem(for: #selector(AppController.showHistory(_:))).flatMap(KeyCombo.init(item:))?.display
    let list = HistoryListView(items: items, fullHistoryKey: key, showsFullHistory: !isPrivate)
    list.onChoose = { [weak self, weak tab, weak entry] choice in
      guard let self, let tab, let entry else { return }
      self.historyPanel?.close()
      self.chooseHistory(choice, tab: tab, entry: entry)
    }
    let anchor = PanelAnchor(rect: { [weak self, weak button] in
      guard let self, let button else { return .zero }
      return button.convert(button.bounds, to: self.root)
    }, below: true, align: .leading, button: button, hold: { [weak button] held in button?.isHeld = held })
    historyList = list
    historyButton = button
    historyForward = forward
    historyPanel = panels.open(PanelSpec(
      name: forward ? "forwardHistory" : "backHistory", content: list, anchor: anchor,
      closesOn: [.outsideClick, .escape, .tabSwitch, .windowInactive], overSidebar: inSidebar,
      onReturn: { [weak list] in list?.returnPressed() },
      onClose: { [weak self, weak list] in
        list?.stop()
        guard let self, self.historyList === list else { return }
        self.historyList = nil
        self.historyPanel = nil
        self.historyButton = nil
        self.logState("historyList")
      }))
    HistoryList.favicons.load(items.map(\.url), profile: profile) { [weak self, weak list] in
      list?.reloadIcons()
      self?.logState("historyList")
    }
    logState("historyList")
  }

  private func chooseHistory(_ choice: HistoryListView.Choice, tab: RayCoreTab, entry: SidebarEntry) {
    switch choice {
    case .fullHistory:
      AppController.shared.showHistory(nil)
    case let .item(item, newTab):
      // The tab's history may have moved on since the list opened: only the page it showed.
      let entries = tab.navigationEntries
      guard !tab.closed, let current = entries.firstIndex(where: { $0["current"] as? Bool == true }),
            entries.indices.contains(current + item.offset),
            entries[current + item.offset]["url"] as? String == item.url else { return }
      if newTab, let url = URL(string: item.url).flatMap(AddressInput.link(fromOtherApp:)) {
        openToday(url, after: entry, foreground: false)
      } else {
        tab.userGoToOffset(item.offset)
      }
    }
    logState("historyList")
  }

  private static func menuItem(for action: Selector, in menu: NSMenu? = NSApp.mainMenu) -> NSMenuItem? {
    for item in menu?.items ?? [] {
      if item.action == action { return item }
      if let found = menuItem(for: action, in: item.submenu) { return found }
    }
    return nil
  }

  /// For tests: back's or forward's list opened as a press would open it, the toolbar's or the sidebar's.
  func openHistoryList(forward: Bool, inSidebar: Bool) -> Bool {
    guard let button = inSidebar ? sidebar.historyButton(forward: forward) : toolbar.historyButton(forward: forward) else { return false }
    toggleHistoryList(forward: forward, from: button, inSidebar: inSidebar)
    return historyList != nil
  }

  /// For tests: a press on back or forward (`HistoryButton.simulatePress`).
  func pressHistoryButton(forward: Bool, inSidebar: Bool, how: String) -> Bool {
    guard let button = inSidebar ? sidebar.historyButton(forward: forward) : toolbar.historyButton(forward: forward) else { return false }
    return button.simulatePress(how)
  }

  /// For tests: the open list's row `index` clicked (⌘-clicked with `newTab`), or ↑ ↓ ⏎.
  func historyListAction(_ action: String, index: Int = 0, newTab: Bool = false) -> Bool {
    guard let list = historyList else { return false }
    switch action {
    case "pick": list.choose(index, newTab: newTab)
    case "up": list.move(-1)
    case "down": list.move(1)
    case "return": list.returnPressed()
    default: return false
    }
    logState("historyList")
    return true
  }

  var historyListState: [String: Any] {
    var state: [String: Any] = ["open": historyList != nil, "lastPress": HistoryButton.lastPress]
    guard let list = historyList else { return state }
    state["forward"] = historyForward
    state["inSidebar"] = historyButton.map { $0.isDescendant(of: sidebar) } ?? false
    state["items"] = list.items.map { ["title": $0.title, "url": $0.url, "offset": $0.offset] }
    state["highlighted"] = list.highlighted ?? -1
    state["icons"] = list.iconsShown
    state["fullHistory"] = list.subviews.contains { ($0 as? HistoryRowView)?.accessibilityLabel() == "Show Full History" }
    return state
  }

  // MARK: Sidebar width

  /// This window's width as it is now: the remembered one, a drag's (past a limit it stretches, Ardia's rubber band)
  /// or the spring's on its way back. Whole points, as the page's frame must be.
  private lazy var widthSpring = Spring(value: RaySettings.shared.sidebarWidth, response: Spring.response,
                                        dampingRatio: Spring.dampingRatio) { [weak self] _ in
    self?.layout()
    self?.noteResizeFrame()
  }
  /// The strip on the sidebar's edge that drags its width (`SidebarResize.swift`): over the sidebar and the page's
  /// edge, under a peeking sidebar, panels and notes.
  private let resizeHandle = SidebarResizeHandle()
  /// The width the drag in progress started from.
  private var resizeStart: CGFloat?
  /// A peeking sidebar stays out while its edge is dragged.
  private var isResizingSidebar: Bool { resizeStart != nil }
  /// For tests: the last drag's steps (each lays the window out), the longest one, and frames laid out off whole points.
  private var resizeSteps = 0
  private var resizeLongestStep: Double = 0
  private var resizeOffGrid = 0
  private var resizeSweep: [String: Any]?

  private var sidebarWidth: CGFloat {
    let value = widthSpring.value
    if resizeStart != nil || widthSpring.isMoving { return value.rounded() }
    // A narrow window lowers the maximum without changing what's remembered.
    return SidebarWidth.clamp(value, windowWidth: root.bounds.width)
  }

  /// The strip sits on the edge of a docked sidebar or a peeking one (not one sliding in or out), right above it:
  /// under the panels and notes that go over the sidebar.
  private func layoutResizeHandle(docked: Bool) {
    if resizeHandle.onBegin == nil { installResizeHandle() }
    let holder: NSView = peeking ? floating : sidebar
    resizeHandle.isHidden = !(peeking || docked)
    guard !resizeHandle.isHidden, holder.superview === root else { return }
    let views = root.subviews
    if let at = views.firstIndex(of: holder), !(at + 1 < views.count && views[at + 1] === resizeHandle) {
      root.addSubview(resizeHandle, positioned: .above, relativeTo: holder)
    }
    resizeHandle.frame = NSRect(x: (holder.frame.maxX - SidebarResizeHandle.inside).rounded(), y: holder.frame.minY,
                                width: SidebarResizeHandle.inside + SidebarResizeHandle.outside, height: holder.frame.height)
  }

  private func installResizeHandle() {
    resizeHandle.onBegin = { [weak self] in self?.beginResize() }
    resizeHandle.onDrag = { [weak self] dx in self?.resize(by: dx) }
    resizeHandle.onEnd = { [weak self] in self?.endResize() }
    resizeHandle.onDoubleClick = { [weak self] in self?.settleWidth(SidebarWidth.standard, remember: true) }
    resizeHandle.onScroll = { [weak self] event in
      // Scrolling over the strip scrolls the list beside it.
      guard let self, let parent = self.sidebar.superview else { return }
      let y = parent.convert(event.locationInWindow, from: nil).y
      let under = self.sidebar.hitTest(NSPoint(x: self.sidebar.frame.maxX - 16, y: y))
      ((under as? NSScrollView) ?? under?.enclosingScrollView)?.scrollWheel(with: event)
    }
    NotificationCenter.default.addObserver(
      self, selector: #selector(sidebarWidthChanged(_:)), name: RaySettings.sidebarWidthDidChange, object: nil)
  }

  private func beginResize() {
    guard resizeStart == nil else { return }
    let shown = sidebarWidth
    // A press on an edge still springing back takes it from where it is.
    widthSpring.jump(to: shown)
    resizeStart = SidebarWidth.unstretched(shown, windowWidth: root.bounds.width)
    resizeSteps = 0
    resizeLongestStep = 0
    resizeOffGrid = 0
    logState("sidebarResize")
  }

  private func resize(by dx: CGFloat) {
    guard let start = resizeStart else { return }
    let width = SidebarWidth.stretched(start + dx, windowWidth: root.bounds.width).rounded()
    guard width != widthSpring.value else { return }
    let began = CACurrentMediaTime()
    widthSpring.jump(to: width)
    resizeSteps += 1
    resizeLongestStep = max(resizeLongestStep, (CACurrentMediaTime() - began) * 1000)
  }

  private func endResize() {
    guard resizeStart != nil else { return }
    resizeStart = nil
    settleWidth(widthSpring.value, remember: true)
  }

  /// The width goes to the nearest allowed one, on the sidebar's spring when it has to move, and (unless this is a
  /// private window, which never writes to Settings.json) becomes every window's.
  private func settleWidth(_ width: CGFloat, remember: Bool) {
    let target = SidebarWidth.clamp(width, windowWidth: root.bounds.width)
    if remember, !isPrivate { RaySettings.shared.rememberSidebarWidth(target, from: self) }
    if window.occlusionState.contains(.visible), abs(widthSpring.value - target) >= 0.5 {
      widthSpring.animate(to: target, in: root)
    } else {
      widthSpring.jump(to: target)
    }
    logState("sidebarResize")
  }

  @objc private func sidebarWidthChanged(_ note: Notification) {
    guard note.object as AnyObject? !== self, !closing, resizeStart == nil else { return }
    settleWidth(RaySettings.shared.sidebarWidth, remember: false)
  }

  private func noteResizeFrame() {
    let frames = [pages.frame, sidebar.frame, resizeHandle.frame]
    if frames.contains(where: { $0 != $0.integral }) { resizeOffGrid += 1 }
  }

  var sidebarResizeState: [String: Any] {
    let limits = SidebarWidth.limits(windowWidth: root.bounds.width)
    return [
      "width": Double(sidebarWidth), "remembered": Double(RaySettings.shared.sidebarWidth),
      "min": Double(limits.lowerBound), "max": Double(limits.upperBound),
      "dragging": resizeStart != nil, "settling": widthSpring.isMoving,
      "handle": NSStringFromRect(resizeHandle.frame), "handleShown": !resizeHandle.isHidden,
      "handleOnTop": (root.subviews.firstIndex(of: resizeHandle) ?? -1) > (root.subviews.firstIndex(of: pages) ?? 0),
      "sidebarFrame": NSStringFromRect(sidebar.frame),
      "steps": resizeSteps, "longestStepMs": resizeLongestStep, "offGrid": resizeOffGrid,
      "cursorSets": resizeHandle.cursorSets, "sweep": resizeSweep ?? NSNull(),
    ]
  }

  #if RAY_TEST_HOOKS
  private var sweep: SidebarResizeSweep?

  /// `sidebarwidth <n> | drag <dx> [hold] | release | double | sweep <dx> <frames>`: the edge's strip, as the mouse
  /// drives it.
  func testResize(_ argument: String) -> String {
    let parts = argument.split(separator: " ").map(String.init)
    guard !resizeHandle.isHidden else { return "no edge" }
    let x = resizeHandle.frame.midX
    switch parts.first {
    case "drag":
      guard parts.count >= 2, let dx = Double(parts[1]) else { return "usage: sidebarwidth drag <dx> [hold]" }
      resizeHandle.press(at: x)
      resizeHandle.drag(to: x + CGFloat(dx))
      if parts.last != "hold" { resizeHandle.release() }
    case "release": resizeHandle.release()
    case "double": resizeHandle.doubleClick()
    case "sweep":
      guard parts.count == 3, let dx = Double(parts[1]), let frames = Int(parts[2]), sweep == nil else {
        return "usage: sidebarwidth sweep <dx> <frames>"
      }
      resizeSweep = nil
      resizeHandle.press(at: x)
      let sweep = SidebarResizeSweep(frames: frames, step: { [weak self] along in
        self?.resizeHandle.drag(to: x + CGFloat(dx) * along)
      }, done: { [weak self] result in
        guard let self else { return }
        self.resizeHandle.release()
        self.sweep = nil
        self.resizeSweep = result
        self.logState("sidebarResize")
      })
      self.sweep = sweep
      sweep.start(in: root)
    default:
      guard parts.count == 1, let width = Double(parts[0]) else {
        return "usage: sidebarwidth <n>|drag <dx> [hold]|release|double|sweep <dx> <frames>"
      }
      resizeHandle.press(at: x)
      resizeHandle.drag(to: x + CGFloat(width) - sidebarWidth)
      resizeHandle.release()
    }
    logState("sidebarResize")
    return "ok"
  }
  #endif

  // MARK: Sidebar visibility

  /// ⌘S on a peeking sidebar docks it in place (owner 2026-11-12): it's on its way from the floating card to the docked sidebar,
  /// still in `floating` until the dock spring settles.
  private var dockingFromPeek = false
  /// For tests: frames laid out during the last dock in place, and the furthest left the sidebar's edge went.
  private var dockFrames = 0
  private var dockLeftmost: CGFloat = 0

  private func finishDockFromPeek() {
    guard dockingFromPeek else { return }
    dockingFromPeek = false
    floating.flatten = 0
    // The card is flat against the window now: the sidebar goes back into the window where it already is.
    peekSpring.jump(to: 0)
    logState("sidebar")
  }

  func toggleSidebar() {
    resizeHandle.release()
    // A second ⌘S on the way: the sidebar is docked from here.
    finishDockFromPeek()
    if state.sidebarHidden, peeking {
      cancelPeekEnd()
      peeking = false
      dockingFromPeek = true
      dockFrames = 0
      dockLeftmost = floating.frame.minX
      // Beside the page's own address bar the sidebar's goes: the rows slide up into its place.
      if toolbarShown, sidebar.showsAddress { sidebar.animateNextChange() }
    } else {
      endPeek(animated: false)
    }
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
    guard state.sidebarHidden, !peeking, !pageFillsWindow else { return }
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
    guard peekEndWork == nil, !forcedOpen, !sidebar.isDragging, !sidebar.hasExternalDrag, !isResizingSidebar, !downloadsOpen, !panels.holdsSidebar else { return }
    let work = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.peekEndWork = nil
      if self.sidebar.isDragging || self.sidebar.hasExternalDrag || self.isResizingSidebar || self.downloadsOpen || self.panels.holdsSidebar { return }
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
      // Past the edge counts on this window's screen only, not a display beside it (Ardia's LeftEdgeWatcher).
      guard let screen = window.screen, screenPoint.x >= screen.frame.minX else {
        if peeking { schedulePeekEnd() }
        return
      }
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
      let holdRight = Self.peekInset + sidebarWidth + Self.holdSlack
      if point.x >= -reach && point.x < holdRight { cancelPeekEnd() } else { schedulePeekEnd() }
    } else if point.x >= -reach && point.x < Self.revealWidth {
      beginPeek()
    }
  }

  func endPeek(animated: Bool) {
    cancelPeekEnd()
    guard peeking else { return }
    resizeHandle.release()
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
    guard !peeking, !dockingFromPeek, sidebar.superview !== root else { return }
    floating.isHidden = true
    sidebar.removeFromSuperview()
    sidebar.layer?.cornerRadius = 0
    sidebar.layer?.masksToBounds = false
    root.addSubview(sidebar, positioned: .above, relativeTo: toolbar)
    layout()
  }

  // MARK: Drag to peek

  /// The hidden sidebar's edge as a drop target (`SidebarDropEdge`): a drag from a page, Finder or anywhere that
  /// reaches the window's left edge brings the sidebar out, which then takes the drop and stays out while the drag is
  /// over it (Arc's). Pointer moves never reach Ray during a drag, so the peek's own watch can't see it.
  private lazy var dropEdge: SidebarDropEdge = {
    let edge = SidebarDropEdge(frame: .zero)
    edge.onEnter = { [weak self] in self?.dragReachedEdge() }
    return edge
  }()
  static let dropEdgeWidth: CGFloat = 8
  /// For tests: peeks a drag brought.
  private var dragPeeks = 0

  private func layoutDropEdge() {
    let shows = state.sidebarHidden && !peeking && !pageFillsWindow && dockSpring.value < 0.001
    if shows, dropEdge.superview !== root { root.addSubview(dropEdge, positioned: .above, relativeTo: toolbar) }
    dropEdge.isHidden = !shows
    dropEdge.frame = NSRect(x: 0, y: 0, width: Self.dropEdgeWidth, height: root.bounds.height)
  }

  func dragReachedEdge() {
    guard state.sidebarHidden, !peeking else { return }
    beginPeek()
    if peeking { dragPeeks += 1 }
  }

  private func externalDragChanged(over: Bool) {
    guard peeking else { return }
    if over {
      cancelPeekEnd()
    } else if launchedInBackground {
      schedulePeekEnd()
    } else {
      // Dropped, or the drag left: where the pointer is now decides, as for any peek.
      pointerMoved(screenPoint: NSEvent.mouseLocation)
    }
  }

  /// For tests: which view takes a drag at a window point (top left), and the drop edge.
  func dragDestination(at point: NSPoint) -> String {
    SidebarView.debugDragDestination(in: window, at: point) ?? "none"
  }
  var dragPeekState: [String: Any] {
    ["edgeShown": dropEdge.superview === root && !dropEdge.isHidden, "edge": NSStringFromRect(dropEdge.frame),
     "peeks": dragPeeks, "peeking": peeking, "overSidebar": sidebar.hasExternalDrag]
  }

  // MARK: Command bar

  /// ⌘T (`toggles`: a second ⌘T closes the bar, as Arc's), New Tab, New Tab in Folder.
  func beginNewTab(toggles: Bool = false) {
    openCommandBar(.newTab, query: "", toggles: toggles)
  }

  /// ⌘L (`toggles`: a second ⌘L closes it), or a click on the address.
  func focusAddress(toggles: Bool = false) {
    openCommandBar(.currentTab, query: activeEntry.map { AddressInput.display(for: $0.currentURL) } ?? "", toggles: toggles)
  }

  /// ⇧⌘C, as in Arc and Chrome: the current page's full URL to the clipboard, and Arc's "Copied Current URL" note
  /// with a share button.
  func copyURL() {
    // With several tabs selected, all their links, as in Arc.
    if sidebar.selection.count > 1 { return copyLinks(sidebar.selection) }
    guard let url = activeEntry?.currentURL, !url.isEmpty else { return }
    let pasteboard = Self.pasteboard
    pasteboard.clearContents()
    pasteboard.setString(url, forType: .string)
    notes.show(.copied("Copied Current URL") { button in
      guard let link = URL(string: url) else { return }
      NSSharingServicePicker(items: [link]).show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    })
    logState("copyURL")
  }

  /// Edit › Copy URL as Markdown (⇧⌥⌘C, Arc's): `[title](url)`.
  func copyURLAsMarkdown() {
    guard let entry = activeEntry, !entry.currentURL.isEmpty else { return }
    let title = (entry.displayTitle.isEmpty ? AddressInput.display(for: entry.currentURL) : entry.displayTitle)
      .components(separatedBy: .newlines).joined(separator: " ")
    let escaped = title.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "[", with: "\\[")
      .replacingOccurrences(of: "]", with: "\\]")
    let url = entry.currentURL.replacingOccurrences(of: "(", with: "%28").replacingOccurrences(of: ")", with: "%29")
    let pasteboard = Self.pasteboard
    pasteboard.clearContents()
    pasteboard.setString("[\(escaped)](\(url))", forType: .string)
    notes.show(Note("Copied URL as Markdown", icon: .symbol("link"), lasts: .seconds(3)))
    logState("copyURL")
  }

  /// File › Paste URL as New Tab (⌥⌘V, Arc's): what's on the clipboard, as if typed in ⌘T's bar and entered.
  func pasteURLAsNewTab() {
    guard let text = Self.pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
          !text.isEmpty, text.count <= 8_192, let url = AddressInput.url(for: text) else { return }
    closeCommandBar(focus: false)
    if showNativeSettings(for: url) { return }
    openToday(url, after: nil, foreground: true)
  }

  /// Several tabs' links, one per line, in sidebar order.
  func copyLinks(_ entries: [SidebarEntry]) {
    let links = entries.filter { !$0.isFolder }.map(\.currentURL).filter { !$0.isEmpty }
    guard !links.isEmpty else { return }
    let pasteboard = Self.pasteboard
    pasteboard.clearContents()
    pasteboard.setString(links.joined(separator: "\n"), forType: .string)
    notes.show(.copied(links.count == 1 ? "Copied Link" : "Copied \(links.count) Links") { button in
      let urls = links.compactMap(URL.init(string:))
      NSSharingServicePicker(items: urls).show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    })
    logState("copyURL")
  }

  /// Test instances copy to a pasteboard of their own so checks never touch the user's clipboard.
  static let pasteboard = TestEnvironment["RAY_PASTEBOARD"].map { NSPasteboard(name: .init($0)) } ?? .general

  private func openCommandBar(_ mode: CommandBarMode, query: String, toggles: Bool = false) {
    // Nothing opens under the onboarding's veil (⌘T there would type into a bar you can't see).
    guard onboarding == nil else { return }
    let mode = activeEntry == nil ? .newTab : mode
    if toggles, commandBar != nil, commandBarMode == mode { return closeCommandBar(focus: true) }
    commandBarMode = mode
    let bar = commandBar ?? CommandBarView(frame: root.bounds)
    if commandBar == nil {
      bar.autoresizingMask = [.width, .height]
      bar.delegate = self
      bar.onSelectionChange = { [weak self] in self?.logState("commandBarSelection") }
      // A site search of the user's has no brand colour: its site's icon's.
      bar.iconColor = { [weak self] scope in self?.favicons.accent(for: Self.siteRoot(of: scope)) }
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

  /// ⌘L's bar still holding the page's own address, untouched: no rows (Ardia's), and Return reloads (Arc's).
  private var addressUnchanged: Bool {
    guard let bar = commandBar, commandBarMode == .currentTab, bar.scope == nil, let url = activeEntry?.currentURL else { return false }
    return bar.typed == url || bar.typed == AddressInput.display(for: url)
  }

  private func refreshSuggestions() {
    guard let bar = commandBar else { return }
    if addressUnchanged {
      bar.show([])
      bar.offer(nil)
      logState("commandBar")
      return
    }
    let query = bar.typed
    // Scoped to a site search: only that search, nothing from tabs, history or the engine's suggestions.
    if let scope = bar.scope {
      bar.show(Suggestions.scoped(scope, query: query))
      bar.offer(nil)
      logState("commandBar")
      return
    }
    let wantsSearches = Suggestions.wantsSearchSuggestions(for: query)
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    Suggestions.spaceName = { [weak self] tab in
      guard let self, let entry = self.state.entry(for: tab), let space = self.state.space(of: entry),
            space !== self.state.current else { return nil }
      return space.name
    }
    let rows = Suggestions.build(
      query: query, tabs: tabs, active: activeTab, history: history.entries,
      searches: wantsSearches ? searches.current(for: trimmed) : [], bookmarks: Bookmarks.shared.barItems,
      actions: BarActions.available,
      settings: SettingsSearch.barMatches, frecency: history.frecency(of:), favicon: favicons.image(for:),
      name: { [weak self] tab in self?.state.entry(for: tab)?.customTitle },
      lastUsed: { [weak self] tab in self?.state.entry(for: tab)?.lastUsed ?? .distantPast })
    bar.show(rows)
    let offered = SearchEngines.offer(for: query, use: history.use(ofHost:))
    bar.offer(offered)
    preconnect(to: rows.first)
    var pages = rows.compactMap { row -> String? in
      if case .history(let url) = row.kind { return url }
      if case .bookmark(let url) = row.kind { return url }
      return nil
    }
    // An offered site search of the user's: its icon, for its colour once scoped.
    if let offered, offered.brand == nil { pages.append(Self.siteRoot(of: offered)) }
    favicons.load(pages, profile: profile) { [weak self] in self?.refreshSuggestions() }
    logState("commandBar")
  }

  /// For the state log: the bar's scope, its colour and the text on it.
  private static func debugScope(of bar: CommandBarView) -> [String: Any]? {
    guard let scope = bar.scope else { return nil }
    let look = bar.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) ?? .aqua
    var logged: [String: Any] = ["name": scope.name, "keyword": scope.keyword, "brand": scope.brand ?? NSNull()]
    if let fill = bar.scopeFill {
      logged["fill"] = ProfileColor.hex(of: fill, appearance: look)
      logged["ink"] = ProfileColor.hex(of: CommandBarView.brandInk(on: fill), appearance: look)
    }
    return logged
  }

  /// A site search's front page (its template's scheme and host), whose icon gives its colour.
  private static func siteRoot(of scope: SearchScope) -> String {
    guard let components = URLComponents(string: scope.template.replacingOccurrences(of: "%s", with: "")),
          let scheme = components.scheme, let host = components.host else { return scope.template }
    return "\(scheme)://\(host)/"
  }

  private func requestSearchSuggestions() {
    guard let bar = commandBar, bar.scope == nil else { return }
    let query = bar.typed.trimmingCharacters(in: .whitespacesAndNewlines)
    guard Suggestions.wantsSearchSuggestions(for: query) else { return }
    searches.fetch(query) { [weak self] in self?.refreshSuggestions() }
  }

  private func closeCommandBar(focus: Bool) {
    guard let bar = commandBar else { return }
    commandBar = nil
    bar.removeFromSuperview()
    preconnected.removeAll()
    sidebar.setNewTabActive(false)
    newTabFolder = nil
    if focus, let tab = activeTab { focusPage(tab) }
    logState("commandBar")
  }

  func commandBar(_ bar: CommandBarView, queryChanged query: String) {
    refreshSuggestions()
    requestSearchSuggestions()
  }

  /// For tests: Return in the bar with these modifiers (`enter cmd`), as the keyboard's ⌘↩ arrives.
  func commandBarReturn(command: Bool) -> Bool {
    guard let bar = commandBar else { return false }
    bar.returnPressed(modifiers: command ? .command : [])
    return true
  }

  func commandBarReturnWithoutRow(_ bar: CommandBarView, newTab: Bool) {
    guard addressUnchanged, let entry = activeEntry, let tab = activeTab else { return }
    let url = entry.currentURL
    closeCommandBar(focus: false)
    if newTab {
      openToday(url, after: entry, foreground: true)
    } else {
      tab.userReload()
      focusPage(tab)
    }
  }

  func commandBar(_ bar: CommandBarView, passesClickAt point: NSPoint) -> Bool {
    // The sidebar, docked or peeking: a click there switches tabs (closing the bar) or opens a folder.
    guard !sidebar.isHidden, sidebar.window != nil else { return false }
    let local = sidebar.convert(point, from: nil)
    guard sidebar.bounds.contains(local) else { return false }
    return sidebar.superview === floating ? peeking : dockSpring.value > 0.5
  }

  func commandBar(_ bar: CommandBarView, choose suggestion: Suggestion, newTab: Bool) {
    let mode = commandBarMode
    let folder = newTabFolder
    closeCommandBar(focus: false)
    // New Tab in Folder: the tab this opens goes into the folder; anything else forgets it.
    newTabFolder = mode == .newTab ? folder : nil
    defer { newTabFolder = nil }
    let url: String
    switch suggestion.kind {
    case .tab(let tab):
      if let entry = state.entry(for: tab) { select(entry) }
      return
    case .action(let action):
      // The menu command, in this window: the bar closed first, so what it opens (Find, a panel) takes the focus.
      if let tab = activeTab { focusPage(tab) }
      AppController.shared.noteFocused(self)
      BarActions.run(action)
      return
    case .setting(let target):
      // Ray's Settings window, at that pane, scrolled to the row, which flashes.
      if let tab = activeTab { focusPage(tab) }
      SettingsWindowController.shared.reveal(target)
      return
    case .url(let target), .search(let target), .history(let target), .bookmark(let target):
      url = target
    }
    // ray://settings/appearance is Ray's own Settings window, never a page.
    if showNativeSettings(for: url) { return }
    if newTab, mode == .currentTab, let entry = activeEntry {
      // ⌘↩ from ⌘L: a new tab beside this one.
      openToday(url, after: entry, foreground: true)
    } else if mode == .newTab || activeTab == nil || newTab {
      openToday(url, after: nil, foreground: true)
    } else if let tab = activeTab {
      // A page the user goes to by hand is no longer one a link opened: Back won't close it.
      activeEntry?.openerID = nil
      tab.userLoad(url)
      focusPage(tab)
    }
  }

  func commandBarDismiss(_ bar: CommandBarView) {
    closeCommandBar(focus: true)
  }

  // MARK: Links from other apps

  /// Links and files from other apps (LinksFromApps), already through AddressInput: each a new Today tab, as if
  /// opened one after another, the last one active. A command bar in the way closes, so the page shows and has the
  /// focus, as Chrome's omnibox gives it up for them.
  func openFromOtherApps(_ urls: [String]) {
    guard !urls.isEmpty else { return }
    closeCommandBar(focus: false)
    for (index, url) in urls.enumerated() {
      openToday(url, after: nil, foreground: index == urls.count - 1)
    }
  }

  // MARK: Preconnect

  /// Sites the open command bar has preconnected to (scheme, host and port), so each goes once per bar session.
  private var preconnected: Set<String> = []
  /// Test builds' state log: each preconnect asked for, and whether the engine started it.
  private var preconnects: [[String: Any]] = []

  /// Chrome's omnibox preconnects its default match while you type, so a site's first visit has DNS, connect and TLS
  /// done by Enter. The bar's top row does the same when it's a page or a typed address (`ac_preconnect`, engine-ray
  /// fixup 0006, gated on network prediction as Chrome's is); never in a private window, as Chrome has no loading
  /// predictor there.
  private func preconnect(to row: Suggestion?) {
    guard !isPrivate, let row else { return }
    let address: String
    switch row.kind {
    case .url(let url), .history(let url), .bookmark(let url): address = url
    default: return
    }
    guard var parts = URLComponents(string: address), let scheme = parts.scheme?.lowercased(),
      scheme == "http" || scheme == "https", let host = parts.host, !host.isEmpty
    else { return }
    parts.user = nil
    parts.password = nil
    parts.path = "/"
    parts.query = nil
    parts.fragment = nil
    guard let origin = parts.string, preconnected.insert(origin).inserted else { return }
    EngineCalls.call("ac_preconnect", profile: profile, args: ["url": origin]) { [weak self] reply in
      guard let self, Self.logsState else { return }
      self.preconnects.append(["origin": origin, "started": reply?["started"] as? Bool ?? NSNull()])
      self.logState("preconnect")
    }
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

  /// For tests: the sidebar's list scrolled (`sidebarlist`), and a double click on its empty space.
  func scrollSidebarList(to y: Double) { sidebar.debugScroll(to: CGFloat(y)) }
  func doubleClickSidebarSpace() -> Bool { sidebar.debugDoubleClickEmpty() }
  func dropOnSidebar(_ items: [SidebarDroppedItem], at point: NSPoint) -> Bool { sidebar.debugDrop(items, atWindowPoint: point) }

  // MARK: SidebarViewDelegate

  func sidebar(_ sidebar: SidebarView, select entry: SidebarEntry) { select(entry) }

  func sidebar(_ sidebar: SidebarView, perform action: SidebarRowAction, on entry: SidebarEntry) {
    perform(action, on: entry)
  }

  func sidebar(_ sidebar: SidebarView, move entry: SidebarEntry, to target: SidebarDropTarget) {
    move(entry, to: target)
  }

  // MARK: Pop-up windows

  /// Tabs on their way here from a pop-up window, by tab: the entry each binds to when the engine inserts it.
  private var popupAdoptions: [ObjectIdentifier: SidebarEntry] = [:]

  /// A pop-up window's page as a Today tab (its Open as Tab, or a tab it opened), right after `openerID`'s tab.
  func adoptFromPopup(_ tab: RayCoreTab, after openerID: UUID?, foreground: Bool, in space: Space? = nil) {
    guard !tab.closed, !closing else { return }
    let entry = SidebarEntry(kind: .today, url: tab.url, title: tab.title)
    entry.openerID = openerID
    insertToday(entry, after: openerID.flatMap { state.entry(id: $0) }, in: space)
    popupAdoptions[ObjectIdentifier(tab)] = entry
    coreWindow.adoptTab(tab)
    // The engine may insert it later (adopting from inside a tab strip notification is put off).
    DispatchQueue.main.async { [weak self, weak tab] in
      guard let self, let tab, !tab.closed else { return }
      if let waiting = self.popupAdoptions.removeValue(forKey: ObjectIdentifier(tab)), waiting.tab == nil { self.bind(waiting, tab) }
      guard self.state.entry(id: entry.id) === entry else { return }
      if foreground { self.select(entry) } else {
        entry.unseen = true
        self.changed("insert")
      }
    }
    changed("insert")
  }

  // MARK: Sidebar drops

  /// ⌥-drag (Arc's): a copy, with the tab's history, goes where the tab was dropped; the tab stays where it was. The
  /// target was measured without the dragged tab in its list, so a place below it in the same list moves one on.
  func sidebar(_ sidebar: SidebarView, duplicate entry: SidebarEntry, to target: SidebarDropTarget) {
    func after(_ list: [SidebarEntry], _ index: Int) -> Int {
      (list.firstIndex { $0 === entry }).map { $0 < index ? index + 1 : index } ?? index
    }
    var adjusted = target
    switch target {
    case .today(let index, let parent): adjusted = .today(after(state.today, index), parent: parent)
    case .pinned(let index, let parent): adjusted = .pinned(after(state.pinned, index), parent: parent)
    case .favorites(let index): adjusted = .favorites(after(state.favorites, index))
    case .folder: break
    }
    sidebar.animateNextChange()
    guard let copy = duplicate(entry, select: false) else { return }
    move(copy, to: adjusted)
    logState("dropCopy")
  }

  /// Links, files and text dropped on the sidebar (Arc's): each a tab where it landed, the first one shown. Links
  /// only http(s) (`AddressInput.link(fromOtherApp:)`), files only the documents Ray opens from Finder, text as
  /// typed in the command bar but only an http(s) page or a search: never `javascript:`, `data:` or `file:`.
  func sidebar(_ sidebar: SidebarView, drop items: [SidebarDroppedItem], to target: SidebarDropTarget) -> Bool {
    let urls: [String] = items.compactMap { item in
      switch item {
      case .link(let text): return URL(string: text).flatMap(AddressInput.link(fromOtherApp:))
      case .file(let url): return AddressInput.document(fromOtherApp: url)
      case .text(let text):
        guard let url = AddressInput.url(for: text), let scheme = URLComponents(string: url)?.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        return url
      }
    }
    guard !urls.isEmpty else { return false }
    sidebar.animateNextChange()
    var placed: [SidebarEntry] = []
    for url in urls.reversed() {
      // Each one in at the same place, last first, so they end up in the order dropped.
      let entry = SidebarEntry(kind: .today, url: url)
      state.today.insert(entry, at: 0)
      move(entry, to: target)
      if state.entry(id: entry.id) !== entry {
        state.remove(entry)
        continue
      }
      placed.insert(entry, at: 0)
    }
    guard let first = placed.first else {
      changed("drop")
      return false
    }
    select(first)
    lastDrop = placed.map(\.url)
    logState("drop")
    return true
  }

  /// For the state log: the addresses the last drop opened.
  private var lastDrop: [String] = []

  // MARK: Selection

  func sidebar(_ sidebar: SidebarView, perform action: SidebarRowAction, onAll entries: [SidebarEntry]) {
    let tabs = entries.filter { !$0.isFolder && state.entry(id: $0.id) === $0 }
    guard let first = tabs.first else { return }
    switch action {
    case .newFolder:
      // A folder where the first one is, all of them inside it, ready to name.
      perform(.newFolder, on: first)
      guard let folder = first.parentID else { return }
      sidebar.animateNextChange()
      for tab in tabs.dropFirst() { move(tab, to: .folder(folder)) }
    case .moveToFolder, .pin, .unpin, .moveToPinned:
      sidebar.animateNextChange()
      for tab in tabs { perform(action, on: tab) }
    case .moveToToday:
      // Each goes to Today's top: the last first, so they keep their order.
      sidebar.animateNextChange()
      for tab in tabs.reversed() { perform(action, on: tab) }
    case .duplicate:
      sidebar.animateNextChange()
      for tab in tabs { duplicate(tab, select: tab === tabs.last) }
    case .close:
      // The tab shown after is one that isn't closing with them.
      closingTogether = Set(tabs.map(\.id))
      defer { closingTogether = [] }
      for tab in tabs.reversed() { perform(.close, on: tab) }
    case .copyLinks:
      copyLinks(tabs)
    default:
      for tab in tabs { perform(action, on: tab) }
    }
  }

  /// Several selected tabs dragged together: the held one lands at the target, the rest right after it, in order.
  func sidebar(_ sidebar: SidebarView, move entries: [SidebarEntry], to target: SidebarDropTarget) {
    guard let held = entries.first else { return }
    move(held, to: target)
    var previous = held
    for entry in entries.dropFirst() where state.entry(id: entry.id) === entry && !entry.isFolder {
      if case .folder(let id) = target {
        move(entry, to: .folder(id))
      } else if let at = state.favorites.firstIndex(where: { $0 === previous }) {
        let mine = state.favorites.firstIndex { $0 === entry }
        move(entry, to: .favorites(at + 1 - (mine.map { $0 < at ? 1 : 0 } ?? 0)))
      } else if let at = state.pinned.firstIndex(where: { $0 === previous }) {
        let mine = state.pinned.firstIndex { $0 === entry }
        move(entry, to: .pinned(at + 1 - (mine.map { $0 < at ? 1 : 0 } ?? 0), parent: previous.parentID))
      } else if let at = state.today.firstIndex(where: { $0 === previous }) {
        let mine = state.today.firstIndex { $0 === entry }
        move(entry, to: .today(at + 1 - (mine.map { $0 < at ? 1 : 0 } ?? 0), parent: previous.parentID))
      }
      previous = entry
    }
  }

  func sidebarSelectionChanged(_ sidebar: SidebarView) { logState("selection") }

  /// For tests: the selected tabs, and a selection menu item pressed.
  var selectedEntries: [SidebarEntry] { sidebar.selection }
  func performOnSelection(_ action: SidebarRowAction) {
    let entries = sidebar.selection
    sidebar.clearSelection()
    sidebar(sidebar, perform: action, onAll: entries)
  }

  /// For tests: a click on a row with modifier keys, as the sidebar takes one (a plain one selects the tab).
  func clickRow(_ entry: SidebarEntry, flags: NSEvent.ModifierFlags) -> Bool {
    if sidebar.select(entry, with: flags) { return true }
    guard !entry.isFolder else { return false }
    sidebar.clearSelection()
    select(entry)
    return true
  }

  func sidebar(_ sidebar: SidebarView, rename entry: SidebarEntry, to title: String) {
    rename(entry, to: title)
  }

  // MARK: Folder icon

  /// Change Icon…'s panel, while it's open.
  private(set) var iconPicker: FolderIconPicker?

  /// Right-click a folder, tab or favorite › Change Icon…: Arc's icon panel under its icon, over the sidebar and page.
  func showIconPicker(for folder: SidebarEntry) {
    iconPicker?.close()
    guard sidebar.iconFrame(of: folder, in: root) != nil else { return }
    let picker = FolderIconPicker(chosen: folder.icon)
    picker.onPick = { [weak self, weak folder] icon in
      guard let self, let folder else { return }
      self.perform(.setIcon(icon), on: folder)
    }
    // Its leading edge a little left of the icon, as Arc's hangs.
    let anchor = PanelAnchor(rect: { [weak self, weak folder] in
      guard let self, let folder, let frame = self.sidebar.iconFrame(of: folder, in: self.root) else { return .zero }
      return frame.offsetBy(dx: -12, dy: 0)
    }, below: true, align: .leading)
    let handle = panels.open(PanelSpec(
      name: "iconPicker", content: picker, anchor: anchor, overSidebar: true,
      onClose: { [weak self, weak picker] in
        guard let self, self.iconPicker === picker else { return }
        self.iconPicker = nil
        FolderIconPicker.animations += 1
        self.logState("iconPicker")
      }))
    picker.requestClose = { handle.close() }
    iconPicker = picker
    if !Panels.reduceMotion { FolderIconPicker.animations += 1 }
    window.makeFirstResponder(picker)
    logState("iconPicker")
  }

  func sidebarSiteControls(_ sidebar: SidebarView) { toggleSiteControls() }

  func sidebarDownloads(_ sidebar: SidebarView, anchor: NSView) {
    toggleDownloads()
  }

  func sidebarBookmarks(_ sidebar: SidebarView, anchor: NSView) {
    toggleBookmarks()
  }

  func sidebarNewTab(_ sidebar: SidebarView) { beginNewTab() }
  func sidebarOpenAddress(_ sidebar: SidebarView) { focusAddress() }
  func sidebarToggle(_ sidebar: SidebarView) { toggleSidebar() }
  func sidebarBack(_ sidebar: SidebarView) { goBack() }
  func sidebarForward(_ sidebar: SidebarView) { goForward() }
  func sidebarHistoryInNewTab(_ sidebar: SidebarView, forward: Bool) { openHistoryInNewTab(forward: forward) }
  func sidebarReload(_ sidebar: SidebarView) { activeTab?.userReload() }

  func sidebarIcon(for entry: SidebarEntry) -> NSImage? {
    // Change Icon…'s pick stands in for the favicon.
    if let icon = FolderLook.tabIcon(entry.icon) { return icon }
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
    // A tab coming from a pop-up window (Open as Tab, or a link the pop-up opened): its entry is waiting.
    if let entry = popupAdoptions.removeValue(forKey: ObjectIdentifier(tab)) {
      if entry.tab == nil { bind(entry, tab) }
      return
    }
    // A page's sized pop-up (`PopupWindow`): its own small window, never a tab here.
    if disposition == "popup", let opener {
      PopupWindow.open(tab, from: self, opener: state.entry(for: opener))
      return
    }
    let entry = SidebarEntry(kind: .today, url: tab.url)
    bind(entry, tab)
    let openerEntry = opener.flatMap(state.entry(for:))
    entry.openerID = openerEntry?.id
    insertToday(entry, after: openerEntry)
    if disposition == "background_tab" {
      // Not used until it's shown: ⌃Tab and a close go to the tabs you were on first.
      entry.unseen = true
      changed("insert")
      // A link the page opened behind it (⌘-click, a middle click) says so, as Crest does; another one updates the note.
      if opener != nil {
        notes.show(Note("Opened in Background Tab", icon: .symbol("plus.square.on.square"), key: "backgroundTab"))
      }
    } else {
      select(entry)
    }
  }

  func window(_ window: RayCoreWindow, didRemove tab: RayCoreTab) {
    if tab === pageFullscreenTab { self.window(window, tab: tab, didChangeFullscreen: false) }
    ScreenShares.shared.forget(tab)
    LoadSweeps.shared.forget(tab)
    guard let entry = state.entry(for: tab) else { return }
    if closing {
      pages.detach(tab)
      if tab.delegate === self { tab.delegate = nil }
      return
    }
    pages.detach(tab)
    if tab.delegate === self { tab.delegate = nil }
    entry.remember()
    entry.tab = nil
    tabPictures.drop(entry.id)
    tabSwitcher.removed(entry)
    zoomHosts[tab.tabId] = nil
    if let closing = userClosing.removeValue(forKey: entry.id) {
      rememberClosed(entry, key: closing.key, favicon: closing.favicon, batch: closing.batch)
    }
    // Still active: closed without Ray picking first (by its page, an extension, Chrome), so pick now, while the
    // entry still has its place for the nearest-neighbour tie.
    let next = state.activeEntryID == entry.id ? successor(closing: entry) : nil
    let wasActive = state.activeEntryID == entry.id
    if entry.kind == .today {
      state.remove(entry)
    } else if let pinnedURL = entry.pinnedURL {
      entry.url = pinnedURL
    }
    if wasActive {
      if let next { select(next) } else { showNothing() }
    }
    changed("remove")
    crashedPages.update()
    sharePicker.update()
  }

  func window(_ window: RayCoreWindow, didActivate tab: RayCoreTab) {
    // Chrome's own pick after a close can be a tab of another Space: never a reason to change Space.
    if let entry = state.entry(for: tab), entry.id != state.activeEntryID,
       state.space(of: entry).map({ $0 === state.current }) ?? true {
      select(entry, fromEngine: true)
    }
  }

  func window(_ window: RayCoreWindow, devToolsDidChangeFor tab: RayCoreTab, view devToolsView: NSView?) {
    if tab === activeTab { pages.setDevTools(devToolsView) }
    logState("devTools")
  }

  func window(_ window: RayCoreWindow, preHandleKeyEvent event: NSEvent) -> Bool {
    if exitPageFullscreen(on: event) { return true }
    return Shortcuts.isReserved(event) && (NSApp.mainMenu?.performKeyEquivalent(with: event) ?? false)
  }

  func window(_ window: RayCoreWindow, handleKeyEvent event: NSEvent) -> Bool {
    event.type == .keyDown && (NSApp.mainMenu?.performKeyEquivalent(with: event) ?? false)
  }

  func windowShouldClose(_ window: RayCoreWindow) -> Bool {
    // Settings › General › Warn before closing a window with several tabs: its sheet closes the window again.
    guard CloseWarnings.allowsClose(self) else { return false }
    prepareForQuit()
    DispatchQueue.main.async { [weak self] in self?.onClose?() }
    return true
  }

  func windowDidCancelClose(_ window: RayCoreWindow) {
    guard !AppController.shared.quitting, self.window.isVisible else { return }
    resumeAfterCancelledQuit()
    AppController.shared.windowCloseCancelled(self)
  }

  // MARK: RayCoreTabDelegate

  private func tabChanged(_ tab: RayCoreTab, event: String) {
    guard !closing, let entry = state.entry(for: tab) else { return }
    entry.remember()
    sidebar.refresh(entry)
    if entry.id == state.activeEntryID {
      // A navigation to another site leaves the panel showing the old one's settings.
      panels.navigated(to: tab.committedOrigin)
      sidebar.showAddress(entry)
      sidebar.setNavigation(canGoBack: canGoBack, canGoForward: canGoForward, backToolTip: backToolTip)
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
    tabChanged(tab, event: "url")
  }
  func tabDidChangeFavicon(_ tab: RayCoreTab) { tabChanged(tab, event: "favicon") }
  func tabDidChangeNavigationState(_ tab: RayCoreTab) { tabChanged(tab, event: "navigation") }
  func tabDidChangeSecurity(_ tab: RayCoreTab) { tabChanged(tab, event: "security") }

  func tabDidCommitDocument(_ tab: RayCoreTab) {
    // A document the page navigated to by itself gets its sweep from here.
    LoadSweeps.shared.documentCommitted(tab)
    popups.committed(tab)
    if tab === activeTab { updateToolbarLoading() }
    // JumpCloud's login page, with Settings › Passwords' JumpCloud Go relay on: never from a private window.
    if !isPrivate { JumpCloudRelay.shared.documentCommitted(tab, in: self) }
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
    LoadSweeps.shared.loadingChanged(tab)
    crashedPages.loading(tab)
    pages.updateProgress(for: tab)
    // After the sweep knows of the load: the address shown with it is drawn mid-sweep, never as a load without one.
    showPendingAddress(of: tab)
    if tab === activeTab { updateToolbarLoading() }
    if !tab.loading { TestEnvironment.log("tab \(tab.tabId) loaded \(tab.url)") }
    if tab === activeTab { logState("loading") }
  }

  /// A navigation's address shows from its start, as Chrome's omnibox shows it (a typed address, a new tab's first
  /// page; a link in the same tab keeps the old address until it commits, as the engine's visible URL does): the
  /// engine says the URL changed only when a navigation finishes. A load starting or its progress (reset when another
  /// navigation starts mid-load) is when to look.
  private func showPendingAddress(of tab: RayCoreTab) {
    guard tab.loading, let entry = state.entry(for: tab), !tab.url.isEmpty, tab.url != entry.url else { return }
    tabChanged(tab, event: "url")
  }

  func tabDidChangeProgress(_ tab: RayCoreTab) {
    LoadSweeps.shared.progressChanged(tab)
    pages.updateProgress(for: tab)
    showPendingAddress(of: tab)
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
    if kind == "displayMedia" { sharePicker.asked(json, tab: tab, frame: frameId, origin: origin) }
  }

  // MARK: Settings

  /// An older Sidebar.json kept View › Show Full Address and View › Show Address Bar on Page; they're Settings ›
  /// Minimal URL and Settings › Show the address bar above the page now. Moved once, then cleared.
  private func migrateLegacySettings() {
    guard !isPrivate, state.fullAddress != nil || state.pageToolbar != nil else { return }
    if state.fullAddress == false { RaySettings.shared.set(.minimalURL, true) }
    if state.pageToolbar == false { RaySettings.shared.set(.pageAddressBar, false) }
    state.fullAddress = nil
    state.pageToolbar = nil
    store.save(state)
  }

  private var settingObservations: [SettingsObservation] = []

  /// Every window follows the one set of settings.
  private func observeSettings() {
    let settings = RaySettings.shared
    PasswordPrompts.followSetting()
    AutoPictureInPicture.start()
    settingObservations = [
      settings.observe([.minimalURL, .loadingProgress]) { [weak self] in
        guard let self else { return }
        self.layout()
        self.updateToolbarLoading()
        if let tab = self.activeTab { self.pages.updateProgress(for: tab) }
      },
      settings.observe(.pageAddressBar) { [weak self] _ in
        guard let self else { return }
        self.layout()
        self.updateToolbar()
        self.logState("toolbar")
      },
      settings.observe(.showSidebarButton) { [weak self] _ in self?.applySidebarButton() },
      settings.observe(.fadeUnloadedTabs) { [weak self] _ in self?.reloadSidebar() },
      settings.observe(.defaultZoom) { [weak self] _ in self?.settleZoomOfAllTabs() },
      settings.observe(.recentTabCycling) { [weak self] _ in self?.endTabCycle() },
      settings.observe(AnySettingKey.all) { [weak self] in self?.logState("settings") },
    ]
    applySidebarButton()
  }

  /// Settings › Show the sidebar button, in the sidebar's top row and the page's address bar.
  private func applySidebarButton() {
    let shown = RaySettings.shared[.showSidebarButton]
    sidebar.showsToggle = shown
    toolbar.showsSidebarButton = shown
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
    if !isUserZoomed(host) { setZoom(tab, to: RaySettings.shared[.defaultZoom]) }
  }

  private func settleZoomOfAllTabs() { tabs.forEach(settleZoom(of:)) }

  /// The engine says a tab's zoom changed. While Ray is setting it, or a navigation is still settling (the host
  /// isn't the one Ray last settled), that's not the user; anything else on a host that isn't marked yet is.
  private func noteZoomChanged(_ tab: RayCoreTab) {
    guard !applyingZoom, !closing, let host = zoomHost(of: tab), zoomHosts[tab.tabId] == host, !isUserZoomed(host),
          abs(tab.zoomFactor - RaySettings.shared[.defaultZoom]) > 0.002 else { return }
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
    setZoom(tab, to: RaySettings.shared[.defaultZoom])
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
    notes.show(.zoom(tab.zoomFactor))
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

  // MARK: Spaces

  /// Profiles other Spaces load in, by directory, once the engine has them.
  private var spaceProfiles: [String: RayCoreProfile] = [:]
  private var loadingProfiles: [String: [(RayCoreProfile?) -> Void]] = [:]
  /// The form New Space and Edit Space… show over the sidebar, and what Cancel puts back.
  private var spaceEditor: SpaceEditorView?
  private var spaceEditing: (space: Space, original: SpaceDraft, previous: UUID?)?
  /// For the state log: Space switches, and the last Space question.
  private var spaceSwitches = 0
  private var spaceQuestion: PanelQuestion?
  private var lastSpaceQuestion: [String: Any]?

  var currentSpaceIndex: Int { state.spaces.firstIndex { $0 === state.current } ?? 0 }

  private func startSpaces() {
    guard !isPrivate else { return }
    themeBackdrop.layer?.backgroundColor = nil
    SpaceLook.apply(state.current)
    // The profiles of other Spaces load now, so going there is instant; the shown Space's before its tab opens.
    for directory in Set(state.spaces.compactMap(\.profile)) { withProfile(directory) { _ in } }
    if let directory = state.current.profile {
      withProfile(directory) { [weak self] loaded in
        guard let self, let loaded, self.state.current.profile == directory else { return }
        self.profile = loaded
        self.coreWindow.activeProfile = loaded
      }
    }
  }

  @objc private func spaceLookChanged() {
    guard !isPrivate else { return }
    let color = SpaceLook.background
    themeBackdrop.layer.map { layer in
      var resolved = color.cgColor
      themeBackdrop.effectiveAppearance.performAsCurrentDrawingAppearance { resolved = color.cgColor }
      let old = layer.presentation()?.backgroundColor ?? layer.backgroundColor
      if spaceLookAnimates, let old, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
        let fade = CABasicAnimation(keyPath: "backgroundColor")
        fade.fromValue = old
        fade.toValue = resolved
        fade.duration = 0.3
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(fade, forKey: "spaceColor")
      }
      layer.backgroundColor = resolved
    }
    spaceLookAnimates = false
    window.backgroundColor = color
    floating.needsDisplay = true
    spaceEditor?.needsDisplay = true
    logState("spaceLook")
  }

  private var spaceLookAnimates = false

  /// The window's colour under everything, refreshed when the appearance changes (it's resolved, a layer colour).
  private func refreshBackdrop() {
    guard !isPrivate else { return }
    spaceLookChanged()
  }

  private func sidebarSpace(_ space: Space) -> SidebarSpace {
    SidebarSpace(id: space.id, name: space.name, icon: SpaceIcon.image(for: space, size: 15),
                 template: space.icon?.hasPrefix("sf:") == true)
  }

  /// The engine profile an entry's page loads in: its Space's (or its favorites' profile).
  func coreProfile(for entry: SidebarEntry) -> RayCoreProfile {
    guard !isPrivate, let directory = state.profileDirectory(of: entry) else { return isPrivate ? profile : mainProfile }
    return spaceProfiles[directory] ?? mainProfile
  }

  private func coreProfile(of space: Space) -> RayCoreProfile? {
    guard let directory = space.profile else { return mainProfile }
    return spaceProfiles[directory]
  }

  /// A Space's own profile, loaded (made, the first time) by the engine; nil if it couldn't be.
  private func withProfile(_ directory: String, _ done: @escaping (RayCoreProfile?) -> Void) {
    if let loaded = spaceProfiles[directory] { return done(loaded) }
    if loadingProfiles[directory] != nil {
      loadingProfiles[directory]?.append(done)
      return
    }
    loadingProfiles[directory] = [done]
    guard let engine = RayCoreEngine.shared else {
      loadingProfiles[directory] = nil
      return done(nil)
    }
    engine.loadProfile(directory) { [weak self] loaded in
      DispatchQueue.main.async {
        guard let self else { return }
        if let loaded { self.spaceProfiles[directory] = loaded }
        let waiting = self.loadingProfiles.removeValue(forKey: directory) ?? []
        waiting.forEach { $0(loaded) }
        self.logState("spaceProfile")
      }
    }
  }

  /// Makes a Space the one on screen without choosing its tab; with its profile not loaded yet, does it once it is
  /// and calls `then` (false: not switched yet).
  @discardableResult
  private func enterSpace(_ space: Space, then: @escaping () -> Void) -> Bool {
    guard !isPrivate, state.spaces.contains(where: { $0 === space }) else { return false }
    if let directory = space.profile, spaceProfiles[directory] == nil {
      withProfile(directory) { [weak self, weak space] loaded in
        guard let self, let space, loaded != nil, self.state.spaces.contains(where: { $0 === space }) else { return }
        self.enterSpace(space, then: then)
        then()
      }
      return false
    }
    guard space !== state.current else { return true }
    if let left = activeEntry { tabPictures.capture(left) }
    state.currentSpaceID = space.id
    profile = coreProfile(of: space) ?? mainProfile
    coreWindow.activeProfile = profile
    closeCommandBar(focus: false)
    panels.close()
    tabSwitcher.cancel("space")
    spaceSwitches += 1
    spaceLookAnimates = true
    SpaceLook.apply(space)
    return true
  }

  /// Goes to a Space and shows the tab it was on (none: nothing, as an empty Space in Arc).
  func switchSpace(to space: Space) {
    guard !isPrivate, space !== state.current else { return }
    if enterSpace(space, then: { [weak self] in self?.showSpaceTab() }) { showSpaceTab() }
  }

  private func showSpaceTab() {
    let space = state.current
    let shown = state.shownEntries
    let remembered = space.activeEntryID.flatMap { id in shown.first { $0.id == id && !$0.isFolder } }
    space.activeEntryID = nil
    if let entry = remembered ?? space.today.first(where: { !$0.isFolder }) {
      select(entry)
    } else {
      pages.showNothing()
      changed("space")
    }
  }

  func switchSpace(number: Int) {
    guard !isPrivate, !state.spaces.isEmpty else { return }
    let index = number >= 9 ? state.spaces.count - 1 : number - 1
    guard state.spaces.indices.contains(index) else { return }
    switchSpace(to: state.spaces[index])
  }

  /// ⌥⌘→ / ⌥⌘←: the next or previous Space, stopping at the ends (Arc's).
  func cycleSpace(by step: Int) {
    let index = currentSpaceIndex + step
    guard state.spaces.indices.contains(index) else { return }
    switchSpace(to: state.spaces[index])
  }

  var hasSpaces: Bool { !isPrivate }
  var spaceCount: Int { state.spaces.count }

  func sidebar(_ sidebar: SidebarView, selectSpace index: Int) {
    guard state.spaces.indices.contains(index) else { return }
    switchSpace(to: state.spaces[index])
  }

  func sidebarNewSpace(_ sidebar: SidebarView) { newSpace() }

  func sidebarSpaceLists(_ sidebar: SidebarView, index: Int) -> SidebarSpaceLists? {
    guard state.spaces.indices.contains(index) else { return nil }
    let space = state.spaces[index]
    let favorites = state.favorites(profile: space.profile)
    let active = space.activeEntryID.flatMap { id in (favorites + space.pinned + space.today).first { $0.id == id } }
    return SidebarSpaceLists(space: sidebarSpace(space), favorites: favorites, pinned: space.pinned, today: space.today,
                             active: active)
  }

  /// A swipe on its way: the window's colour follows the fingers from one Space's to the other's.
  func sidebar(_ sidebar: SidebarView, slideFrom from: Int, to: Int, progress: CGFloat) {
    guard state.spaces.indices.contains(from), state.spaces.indices.contains(to), let layer = themeBackdrop.layer else { return }
    var a: CGColor?, b: CGColor?
    themeBackdrop.effectiveAppearance.performAsCurrentDrawingAppearance {
      a = SpaceLook.windowColor(state.spaces[from].color).cgColor
      b = SpaceLook.windowColor(state.spaces[to].color).cgColor
    }
    guard let a, let b, let mixed = SpaceLook.blend(a, b, progress) else { return }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    layer.removeAnimation(forKey: "spaceColor")
    layer.backgroundColor = mixed
    CATransaction.commit()
  }

  // Menus: the footer's icons and the Space's name.
  func sidebarSpaceMenu(_ sidebar: SidebarView, index: Int) -> NSMenu? {
    guard state.spaces.indices.contains(index) else { return nil }
    let space = state.spaces[index]
    let menu = NSMenu()
    menu.autoenablesItems = false
    func add(_ title: String, _ action: String, enabled: Bool = true) {
      let item = NSMenuItem(title: title, action: #selector(spaceMenuAction(_:)), keyEquivalent: "")
      item.target = self
      item.representedObject = [action, space.id.uuidString]
      item.isEnabled = enabled
      menu.addItem(item)
    }
    add("Edit Space…", "edit")
    menu.addItem(.separator())
    add("Move Left", "left", enabled: index > 0)
    add("Move Right", "right", enabled: index < state.spaces.count - 1)
    menu.addItem(.separator())
    add("New Space…", "new")
    add("Delete Space…", "delete", enabled: state.spaces.count > 1)
    return menu
  }

  @objc private func spaceMenuAction(_ item: NSMenuItem) {
    guard let parts = item.representedObject as? [String], parts.count == 2, let id = UUID(uuidString: parts[1]),
          let space = state.space(id: id) else { return }
    spaceAction(parts[0], space)
  }

  @discardableResult
  func spaceAction(_ action: String, _ space: Space) -> Bool {
    switch action {
    case "edit": editSpace(space)
    case "left", "right":
      guard let index = state.spaces.firstIndex(where: { $0 === space }) else { return false }
      let to = index + (action == "left" ? -1 : 1)
      guard state.spaces.indices.contains(to) else { return false }
      state.spaces.swapAt(index, to)
      changed("spaceMoved")
    case "new": newSpace()
    case "delete": askDeleteSpace(space)
    default: return false
    }
    return true
  }

  // MARK: Space editor

  /// New Space (Arc's): a Space made at once and gone to, its sidebar the form; Cancel takes it away again.
  func newSpace() {
    guard !isPrivate, spaceEditor == nil else { return }
    let previous = state.current.id
    let used = Set(state.spaces.compactMap(\.color))
    let pick = SpaceTheme.windows.indices.first { !used.contains(SpaceTheme.windows[$0]) } ?? state.spaces.count % SpaceTheme.windows.count
    let space = Space(name: "New Space")
    space.color = SpaceTheme.windows[pick]
    space.accent = SpaceTheme.accents[pick]
    space.profile = state.current.profile
    state.spaces.append(space)
    switchSpace(to: space)
    let draft = SpaceDraft(name: "", icon: nil, color: space.color, accent: space.accent, profile: space.profile)
    showSpaceEditor(space, draft: draft, original: draft, isNew: true, previous: previous)
  }

  func editSpace(_ space: Space) {
    guard !isPrivate, spaceEditor == nil else { return }
    if space !== state.current { switchSpace(to: space) }
    let draft = SpaceDraft(name: space.name, icon: space.icon, color: space.color, accent: space.accent, profile: space.profile)
    showSpaceEditor(space, draft: draft, original: draft, isNew: false, previous: nil)
  }

  /// Every profile a Space uses, Default first, each named by its Spaces.
  private func profileChoices() -> [SpaceProfileChoice] {
    var choices = [SpaceProfileChoice(directory: nil, title: "Default")]
    var seen = Set<String>()
    for space in state.spaces {
      guard let directory = space.profile, seen.insert(directory).inserted else { continue }
      let names = state.spaces.filter { $0.profile == directory }.map(\.name).joined(separator: ", ")
      choices.append(SpaceProfileChoice(directory: directory, title: "Same as \(names)"))
    }
    return choices
  }

  private func showSpaceEditor(_ space: Space, draft: SpaceDraft, original: SpaceDraft, isNew: Bool, previous: UUID?) {
    if state.sidebarHidden { toggleSidebar() }
    let editor = SpaceEditorView(draft: draft, isNew: isNew, profiles: profileChoices())
    spaceEditor = editor
    spaceEditing = (space, original, previous)
    editor.onChange = { [weak self, weak space] draft in
      guard let self, let space else { return }
      self.preview(draft, on: space)
    }
    editor.onFinish = { [weak self] keep in self?.finishSpaceEditor(keep: keep) }
    sidebar.showEditor(editor)
    editor.focusName()
    logState("spaceEditor")
  }

  /// The draft on the window at once: name, icon and both colours (its profile changes only on Create).
  private func preview(_ draft: SpaceDraft, on space: Space) {
    space.name = Space.name(from: draft.name) ?? (spaceEditing?.original.name.isEmpty == false ? spaceEditing!.original.name : "New Space")
    space.icon = draft.icon
    space.color = draft.color
    space.accent = draft.accent
    if space === state.current { SpaceLook.apply(space) }
    reloadSidebar()
    logState("spaceEditor")
  }

  private func finishSpaceEditor(keep: Bool) {
    guard let editor = spaceEditor, let editing = spaceEditing else { return }
    spaceEditor = nil
    spaceEditing = nil
    sidebar.showEditor(nil)
    let space = editing.space
    if keep {
      let draft = editor.draft
      preview(draft, on: space)
      if draft.profile != editing.original.profile {
        changeProfile(of: space, to: draft.profile == SpaceEditorView.newProfile ? Space.newProfileDirectory() : draft.profile)
      }
    } else if editor.isNew {
      // A new Space cancelled is gone, with nothing in it yet; back to the Space you were on.
      let back = editing.previous.flatMap(state.space(id:)) ?? state.spaces.first { $0 !== space }
      if let back { switchSpace(to: back) }
      state.spaces.removeAll { $0 === space }
    } else {
      preview(editing.original, on: space)
    }
    changed(keep ? "spaceSaved" : "spaceCancelled")
    if let tab = activeTab { focusPage(tab) }
  }

  /// A Space onto another profile: its open tabs close (a tab can't change profile) and reopen there when used;
  /// favorites become that profile's.
  private func changeProfile(of space: Space, to directory: String?) {
    for entry in space.pinned + space.today where entry.isLive {
      entry.remember()
      entry.tab?.close()
    }
    space.profile = directory
    guard let directory else {
      if space === state.current {
        profile = mainProfile
        coreWindow.activeProfile = mainProfile
      }
      return
    }
    withProfile(directory) { [weak self, weak space] loaded in
      guard let self, let space, let loaded, space === self.state.current else { return }
      self.profile = loaded
      self.coreWindow.activeProfile = loaded
      self.changed("spaceProfile")
    }
  }

  // MARK: Deleting a Space

  private func askDeleteSpace(_ space: Space) {
    guard !isPrivate, state.spaces.count > 1, spaceQuestion == nil else { return }
    let tabs = (space.pinned + space.today).filter { !$0.isFolder }.count
    let title = "Delete “\(space.name)”?"
    let message = tabs == 0 ? "" : "Its \(tabs == 1 ? "tab closes" : "\(tabs) tabs close"). ⇧⌘T brings them back."
    var close: (() -> Void)?
    let question = PanelQuestion(title: title, message: message, answers: [("Cancel", false, false), ("Delete", false, true)],
                                 wait: 0.5) { [weak self, weak space] index in
      close?()
      guard let self else { return }
      self.spaceQuestion = nil
      self.lastSpaceQuestion?["answer"] = index == 1 ? "delete" : "cancel"
      if index == 1, let space { self.deleteSpace(space) }
      self.logState("spaceQuestion")
    }
    spaceQuestion = question
    lastSpaceQuestion = ["title": title, "message": message, "answer": NSNull()]
    let handle = panels.open(PanelSpec(
      name: "deleteSpace", content: question, anchor: questionAnchor, closesOn: [.escape, .windowInactive], asks: true,
      onClose: { [weak self] in
        self?.spaceQuestion = nil
        self?.logState("spaceQuestion")
      }))
    close = { handle.close() }
    logState("spaceQuestion")
  }

  /// Gone, with its tabs in Recently Closed (one batch: ⇧⌘T brings them all back, into the Space you're on).
  func deleteSpace(_ space: Space) {
    guard state.spaces.count > 1, let index = state.spaces.firstIndex(where: { $0 === space }) else { return }
    if space === state.current {
      switchSpace(to: state.spaces[index > 0 ? index - 1 : index + 1])
    }
    let batch = UUID()
    let entries = (space.pinned + space.today).filter { !$0.isFolder }
    for entry in entries.reversed() { rememberClosed(entry, key: nil, favicon: nil, batch: batch) }
    state.spaces.removeAll { $0 === space }
    for entry in entries where entry.isLive {
      guard let tab = entry.tab else { continue }
      pages.detach(tab)
      if tab.delegate === self { tab.delegate = nil }
      entry.tab = nil
      tab.close()
    }
    changed("spaceDeleted")
  }

  // MARK: Move to Space

  /// Move to › a Space: a tab or Today folder to the top of its Today, a pinned tab or folder to the end of its pinned.
  /// Across profiles an open tab closes first (it can't change profile) and opens there on its next use.
  func move(_ entry: SidebarEntry, toSpace id: UUID) {
    guard let target = state.space(id: id), let from = state.space(of: entry), from !== target else { return }
    let block = state.block(of: entry)
    let wasToday = from.today.contains { $0 === entry }
    let wasActive = block.contains { $0.id == from.activeEntryID }
    let next = wasActive && from === state.current ? successor(closing: entry) : nil
    if target.profile != from.profile {
      for item in block where item.isLive {
        item.remember()
        item.tab?.close()
      }
    }
    from.pinned.removeAll { item in block.contains { $0 === item } }
    from.today.removeAll { item in block.contains { $0 === item } }
    entry.parentID = nil
    if wasToday {
      target.today.insert(contentsOf: block, at: 0)
    } else {
      target.pinned.append(contentsOf: block)
    }
    state.normalizePinned()
    if wasActive {
      from.activeEntryID = nil
      if from === state.current {
        if let next, !block.contains(where: { $0 === next }) { select(next) } else { pages.showNothing() }
      }
    }
    sidebar.animateNextChange()
    changed("movedToSpace")
  }

  /// Open in ‹Space› for a page that can't move there (another profile): a new tab at the top of its Today, shown.
  func openInSpace(_ url: String, _ space: Space) {
    let entry = SidebarEntry(kind: .today, url: url)
    space.today.insert(entry, at: 0)
    select(entry)
    if state.entry(id: entry.id) == nil { return }
    changed("insert")
  }

  // MARK: Space tests

  private func spacesDebug(_ describe: (SidebarEntry) -> [String: Any]) -> [String: Any] {
    [
      "current": currentSpaceIndex,
      "list": state.spaces.map { space -> [String: Any] in
        ["id": space.id.uuidString, "name": space.name, "icon": space.icon ?? NSNull(), "color": space.color ?? NSNull(),
         "accent": space.accent ?? NSNull(), "profile": space.profile ?? NSNull(),
         "pinned": space.pinned.map(describe), "today": space.today.map(describe),
         "active": space.activeEntryID?.uuidString ?? NSNull()]
      },
      "profileFavorites": state.profileFavorites.mapValues { $0.map(describe) },
      "loadedProfiles": spaceProfiles.keys.sorted(),
      "windowProfile": profile === mainProfile ? NSNull() : profile.name as Any,
      "switches": spaceSwitches,
      "header": sidebar.spaceHeaderTitle,
      "dockShown": sidebar.spaceDockShown,
      "slides": sidebar.slideCount, "slideSteps": sidebar.slideSteps, "sliding": sidebar.isSliding,
      "swipeCommits": sidebar.swipeCommits, "swipeCancels": sidebar.swipeCancels,
      "look": ["window": SpaceLook.windowHex as Any? ?? NSNull(), "accent": ProfileColor.spaceAccentHex as Any? ?? NSNull()],
      "editor": spaceEditor?.debug ?? NSNull(),
      "question": lastSpaceQuestion ?? NSNull(),
    ]
  }

  /// Test command `space …` (see TestCommands).
  func spaceCommand(_ words: [String]) -> String {
    let rest = words.dropFirst()
    switch words.first {
    case "switch":
      guard let n = rest.first.flatMap(Int.init) else { return "usage: space switch <n>" }
      switchSpace(number: n)
    case "click":
      guard let n = rest.first.flatMap(Int.init), sidebar.pressSpaceCell(n - 1) else { return "no such space" }
    case "next": cycleSpace(by: 1)
    case "previous": cycleSpace(by: -1)
    case "new": newSpace()
    case "edit": editSpace(state.current)
    case "delete": askDeleteSpace(state.current)
    case "deletenow": deleteSpace(state.current)
    case "menu":
      guard let n = rest.first.flatMap(Int.init), let menu = sidebarSpaceMenu(sidebar, index: n - 1) else { return "no such space" }
      if rest.count > 1 {
        let title = rest.dropFirst().joined(separator: " ")
        guard let item = menu.items.first(where: { $0.title == title }), item.isEnabled else { return "no item \(title)" }
        spaceMenuAction(item)
      } else {
        return menu.items.map { $0.isSeparatorItem ? "-" : ($0.isEnabled ? "" : "~") + $0.title }.joined(separator: "|")
      }
    case "swipe":
      guard let distance = rest.first.flatMap(Double.init) else { return "usage: space swipe <dx> [steps] [hold]" }
      let steps = rest.dropFirst().first.flatMap(Int.init) ?? 8
      sidebar.debugSwipe(by: CGFloat(distance), steps: steps, release: !rest.contains("hold"))
    case "release":
      sidebar.debugSwipe(by: 0, steps: 1, release: true)
    case "editor":
      guard let editor = spaceEditor else { return "no editor" }
      switch rest.first {
      case "name": editor.setName(rest.dropFirst().joined(separator: " "))
      case "icon":
        guard let n = rest.dropFirst().first.flatMap(Int.init), editor.choose(iconAt: n) else { return "no icon" }
      case "window": editor.choose(window: rest.dropFirst().first.flatMap(Int.init), accent: nil)
      case "accent": editor.choose(window: nil, accent: rest.dropFirst().first.flatMap(Int.init))
      case "custom":
        guard rest.count == 3, editor.pickCustom(String(rest[rest.startIndex + 1]), hex: String(rest[rest.startIndex + 2]))
        else { return "usage: space editor custom window|accent #RRGGBB" }
      case "profile":
        guard let n = rest.dropFirst().first.flatMap(Int.init), editor.chooseProfile(n) else { return "no profile" }
      case "confirm": editor.confirmButton.onClick?()
      case "cancel": editor.cancelButton.onClick?()
      default: return "usage: space editor name|icon|window|accent|custom|profile|confirm|cancel"
      }
    case "question":
      guard let question = spaceQuestion else { return "no question" }
      let index = rest.first == "delete" ? 1 : 0
      guard question.buttons.indices.contains(index), question.buttons[index].isEnabled else { return "not ready" }
      question.buttons[index].onClick?()
    case "move":
      guard rest.count == 2, let id = UUID(uuidString: String(rest[rest.startIndex])),
            let n = Int(rest[rest.startIndex + 1]), state.spaces.indices.contains(n - 1),
            let entry = state.entry(id: id) else { return "usage: space move <entry> <n>" }
      perform(.moveToSpace(state.spaces[n - 1].id), on: entry)
    case "state": break
    default:
      return "usage: space switch|click|next|previous|new|edit|delete|deletenow|menu|swipe|release|editor|question|move|state"
    }
    logState("space")
    return "ok"
  }

  // MARK: State log

  func logState(_ event: String) {
    guard Self.logsState else { return }
    func describe(_ entry: SidebarEntry) -> [String: Any] {
      [
        "id": entry.id.uuidString, "kind": entry.kind.rawValue, "title": entry.displayTitle,
        "customTitle": entry.customTitle ?? NSNull(), "pageTitle": entry.isFolder ? NSNull() : entry.pageTitle,
        "url": entry.currentURL, "pinnedURL": entry.pinnedURL ?? NSNull(), "live": entry.isLive,
        "away": entry.isAwayFromPinned, "tab": entry.isLive ? Int(entry.tab!.tabId) : NSNull(),
        "parent": entry.parentID?.uuidString ?? NSNull(), "open": entry.isOpen ?? NSNull(),
        "color": entry.color ?? NSNull(), "icon": entry.icon ?? NSNull(), "group": entry.groupToken ?? NSNull(),
        "muted": entry.isLive && entry.tab?.muted == true,
        "audible": entry.isLive && entry.tab?.audible == true,
      ]
    }
    var state: [String: Any] = [
      "event": event,
      "active": activeTab.map { Int($0.tabId) } ?? NSNull(),
      "activeEntry": self.state.activeEntryID?.uuidString ?? NSNull(),
      "sharedLinks": lastShared,
      "preconnects": preconnects,
      "address": sidebar.addressText,
      "addressField": sidebar.addressDebug,
      "sidebarAddressShown": sidebar.addressShown,
      "sidebarSiteButton": !sidebar.siteButton.isHidden,
      "pages": pages.debugState,
      "cardFrame": NSStringFromRect(pages.frame),
      "windowFrame": NSStringFromRect(window.frame),
      "windowNumber": window.windowNumber,
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
      "import": importLog ?? NSNull(),
      "permission": permissions.shown ?? NSNull(),
      "passwordPrompt": passwords.state,
      "autofillPrompt": autofill.state,
      "pageQuestion": pageQuestions.state,
      "blockedPopups": popups.state,
      "crashedPage": crashedPages.state,
      "pictureInPicture": ["steps": pictureInPictureSteps, "windowSeen": pages.windowSeen],
      "screenShare": [
        "picker": sharePicker.state, "shares": ScreenShares.shared.state, "window": shareIndicators.state,
      ] as [String: Any],
      "autofillSuggestions": autofillSuggestions ?? NSNull(),
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
      "downloadsOpen": downloadsOpen,
      "downloadAnswer": downloads.lastAnswer ?? NSNull(),
      "bookmarks": bookmarksState,
      "downloadsButton": {
        let button = sidebar.downloadsAnchor
        guard !button.isHidden, let height = window.contentView?.bounds.height else { return "" }
        let frame = button.convert(button.bounds, to: nil)
        return String(format: "%.1f,%.1f", frame.minX, height - frame.maxY)
      }(),
      "extensions": extensions.items.map { ["id": $0.id, "name": $0.name, "enabled": $0.enabled] },
      "extensionPopup": extensions.popupURL ?? NSNull(),
      "extensionPopupView": extensions.popupViewState ?? NSNull(),
      "siteControls": siteControls?.state ?? NSNull(),
      "sidebarOverToolbar": (root.subviews.firstIndex(of: sidebar.superview === root ? sidebar : floating) ?? -1)
        > (root.subviews.firstIndex(of: toolbar) ?? 0),
      "installPrompt": extensions.promptState ?? NSNull(),
      "engine": ["chromium": RayCoreEngine.shared?.chromiumVersion ?? ""],
      "displayAsleep": CGDisplayIsAsleep(window.screen?.displayID ?? CGMainDisplayID()) != 0,
      // A password or card number copied from Settings is concealed: never in this log.
      "pasteboard": (SettingsPasteboard.isConcealed ? "<concealed>" : Self.pasteboard.string(forType: .string)) ?? NSNull(),
      "notes": notes.state,
      "linkPreview": linkPreview.debug,
      "swipeIndicator": swipeIndicator.debug,
      "historyList": historyListState,
      "panels": panels.state,
      "noteText": notes.text,
      "realLightsHidden": [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].allSatisfy {
        window.standardWindowButton($0)?.isHidden ?? true
      },
      "toggleCenter": sidebar.debugToggleCenter,
      "sidebarFrames": sidebar.debugFrames,
      "sidebarResize": sidebarResizeState,
      "sidebar": [
        "favorites": self.state.favorites.map(describe),
        "pinned": self.state.pinned.map(describe),
        "today": self.state.today.map(describe),
        "spaces": spacesDebug(describe),
        "selection": sidebar.selection.map(\.id.uuidString),
        "tabGroups": groups.debug,
        "folderIcons": sidebar.debugFolderIcons,
        "iconPicker": iconPicker?.debug ?? NSNull(),
        "iconPickerAnimations": FolderIconPicker.animations,
        "changesAnimated": SidebarView.changesAnimated, "iconSets": RowSymbols.sets,
        "activeInView": sidebar.debugActiveInView, "emptyDoubleClicks": sidebar.emptyDoubleClicks,
        "hidden": self.state.sidebarHidden,
        "peeking": peeking,
        "dockFromPeek": ["docking": dockingFromPeek, "frames": dockFrames, "leftmost": Double(dockLeftmost)] as [String: Any],
      ] as [String: Any],
      "commandBar": commandBar.map { bar in
        [
          "mode": commandBarMode.rawValue, "query": bar.typed, "field": bar.field.stringValue, "completion": bar.inlineCompletion ?? NSNull(), "selected": bar.selectedIndex,
          "filledRow": bar.filledRow ?? NSNull(),
          "scope": Self.debugScope(of: bar) ?? NSNull(),
          "offered": bar.offered.map { ["name": $0.name, "keyword": $0.keyword] } ?? NSNull(),
          "hint": bar.hintText ?? NSNull(), "pulses": bar.pulses, "lineOffsets": bar.lineOffsets,
          "rowsFullyVisible": bar.rowsFullyVisible,
          "firstVisibleRow": bar.shownRows.first, "visibleRows": bar.shownRows.count,
          "work": [
            "builds": Suggestions.work.builds, "scanned": Suggestions.work.scanned, "matched": Suggestions.work.matched,
            "rowsMade": Suggestions.work.rowsMade, "parses": Suggestions.work.parses, "ms": Suggestions.work.ms,
            "maxMs": Suggestions.work.maxMs,
          ] as [String: Any],
          "rows": bar.suggestions.map { row -> [String: Any] in
            var logged: [String: Any] = ["kind": row.kindName, "title": row.title, "detail": row.detail]
            if row.suggested { logged["suggested"] = true }
            if case .tab(let tab) = row.kind { logged["tab"] = Int(tab.tabId) }
            if case .search(let url) = row.kind { logged["url"] = url }
            if case .history(let url) = row.kind { logged["url"] = url }
            if case .bookmark(let url) = row.kind { logged["url"] = url }
            if case .url(let url) = row.kind { logged["url"] = url }
            return logged
          },
        ] as [String: Any]
      } ?? NSNull(),
      "tabs": tabs.map { tab in
        [
          "id": Int(tab.tabId), "url": tab.url, "title": tab.title, "security": ConnectionLook.level(tab.securityInfo) ?? NSNull(),
          "visible": !tab.view.isHidden && tab.view.superview != nil, "zoom": tab.zoomFactor, "canGoBack": tab.canGoBack,
        ] as [String: Any]
      },
    ]
    // Settings (test builds only, like the rest of this log).
    func tabID(_ entry: SidebarEntry) -> Any { entry.isLive ? Int(entry.tab!.tabId) : NSNull() }
    state["settings"] = RaySettings.shared.debug
    state["settingsWindow"] = SettingsWindowController.shared.debug
    state["passwordsPane"] = PasswordsPaneContent.shared.debug
    state["autofillPane"] = AutofillPaneContent.shared.debug
    state["updater"] = Updater.shared.debug
    state["general"] = GeneralSystem.shared.debug
    state["defaultBrowserAsk"] = DefaultBrowserAsk.shared.debug
    state["onboarding"] = onboarding?.debug ?? NSNull()
    state["jumpCloudRelay"] = JumpCloudRelay.shared.debug
    state["chromeCommand"] = lastChromeCommand.map { ["name": $0.name, "ran": $0.ran] as [String: Any] } ?? NSNull()
    state["safeStorage"] = ["mode": safeStorage.mode.rawValue, "note": safeStorage.note, "moved": safeStorage.moved]
    state["menuKeys"] = [
      "copyURL": MainMenu.keyEquivalent(of: #selector(AppController.copyURL(_:))) ?? NSNull(),
      "toggleSidebar": MainMenu.keyEquivalent(of: #selector(AppController.toggleSidebar(_:))) ?? NSNull(),
      "settings": MainMenu.keyEquivalent(of: #selector(AppController.showSettings(_:))) ?? NSNull(),
      "savePage": MainMenu.keyEquivalent(of: #selector(AppController.savePage(_:))) ?? NSNull(),
      "openLittleRayInRay": MainMenu.keyEquivalent(of: #selector(AppController.openLittleRayInRay(_:))) ?? NSNull(),
    ] as [String: Any]
    state["shortcuts"] = MenuShortcuts.debug
    state["welcomeAgainItem"] = MainMenu.alternateInfo(of: #selector(AppController.showWelcomeAgain(_:))) ?? NSNull()
    state["pageFullscreen"] = pageFullscreenDebug
    state["lastDrop"] = lastDrop
    state["dragPeek"] = dragPeekState
    state["popupWindows"] = PopupWindow.all.map(\.debug)
    state["littleRays"] = LittleRay.all.map(\.debug)
    state["littleRaySteps"] = LittleRay.steps
    state["linkActivationRestores"] = LinkActivationOrder.shared.restores
    state["back"] = ["enabled": canGoBack, "tooltip": backToolTip, "lastPress": HistoryButton.lastPress]
    state["recentOrder"] = self.state.allEntries.filter { $0.isLive }
      .sorted { $0.lastUsed > $1.lastUsed }.map(tabID)
    state["recentlyClosed"] = ClosedTabsMenu.shared.debug(for: self)
    state["looks"] = AppLook.debug.merging([
      "window": window.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? "dark" : "light",
    ]) { _, new in new }
    state["undo"] = UndoCloseTab.shared.debug
    state["hapticTicks"] = SidebarView.hapticTicks
    state["tabSwitcher"] = tabSwitcher.debug.merging(["pictureCopies": tabPictures.copies]) { $1 }
    state["tabPictures"] = tabPictures.ids.map(\.uuidString)
    guard let data = try? JSONSerialization.data(withJSONObject: state),
          let json = String(data: data, encoding: .utf8) else { return }
    FileHandle.standardError.write("[ray-state] \(json)\n".data(using: .utf8)!)
  }
}

final class FloatingSidebarFrame: NSView {
  private static let radius: CGFloat = 12
  /// 0 as the floating card, 1 flat against the window (a peeking sidebar being docked): the corners, edge and shadow go.
  var flatten: CGFloat = 0 {
    didSet {
      guard oldValue != flatten else { return }
      let radius = Self.radius * (1 - flatten)
      layer?.cornerRadius = radius
      content?.layer?.cornerRadius = radius
      layer?.borderWidth = 1 - flatten
      needsDisplay = true
      needsLayout = true
    }
  }

  var content: NSView? {
    didSet {
      oldValue?.removeFromSuperview()
      if let content {
        content.frame = bounds
        content.autoresizingMask = [.width, .height]
        content.wantsLayer = true
        content.layer?.cornerRadius = Self.radius * (1 - flatten)
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
    layer?.backgroundColor = (isPrivate ? SidebarColors.privateBackground : SpaceLook.background).cgColor
    layer?.borderColor = (dark ? NSColor(white: 1, alpha: 0.1) : NSColor(white: 0, alpha: 0.1)).cgColor
    layer?.shadowOpacity = (dark ? 0.18 : 0.12) * Float(1 - flatten)
  }

  override func layout() {
    super.layout()
    let radius = min(Self.radius * (1 - flatten), bounds.width / 2, bounds.height / 2)
    layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    needsDisplay = true
  }
}

private extension NSScreen {
  var displayID: CGDirectDisplayID? { deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID }
}
