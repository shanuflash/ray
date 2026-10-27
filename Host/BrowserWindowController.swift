import AppKit

final class BrowserWindowController: NSObject, ArdiaCoreWindowDelegate, ArdiaCoreTabDelegate, SidebarViewDelegate,
  CommandBarDelegate
{
  enum CommandBarMode: String {
    case newTab
    case currentTab
  }

  private static let margin: CGFloat = 8
  private static let logsState = TestEnvironment["RAY_LOG_STATE"] == "1"

  let coreWindow: ArdiaCoreWindow
  let profile: ArdiaCoreProfile
  var onClose: (() -> Void)?

  private let root = WindowDragArea()
  private let sidebar = SidebarView()
  private let floating = FloatingSidebarFrame()
  private let pages = PageContainerView()
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

  var activeTab: ArdiaCoreTab? { activeEntry.flatMap { $0.isLive ? $0.tab : nil } }

  var tabs: [ArdiaCoreTab] { state.allEntries.compactMap { $0.isLive ? $0.tab : nil } }

  init(profile: ArdiaCoreProfile, store: SidebarStore) {
    self.profile = profile
    self.store = store
    state = store.load() ?? SidebarState()
    state.archiveStaleToday()
    coreWindow = ArdiaCoreWindow(contentRect: NSRect(x: 0, y: 0, width: 1360, height: 860))
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
    reloadSidebar()
    layout()
    installPointerMonitors()
  }

  deinit {
    pointerMonitors.forEach(NSEvent.removeMonitor)
  }

  private func configureWindow() {
    let frame = window.frame
    window.styleMask.insert(.fullSizeContentView)
    if window.frame != frame { window.setFrame(frame, display: false) }
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    window.title = "Ray"
    window.minSize = NSSize(width: 720, height: 460)
    window.backgroundColor = SidebarColors.background
    window.isReleasedWhenClosed = false
    window.isRestorable = false
    window.animationBehavior = .none
    window.tabbingMode = .disallowed
    window.acceptsMouseMovedEvents = true
  }

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
    let bottom = edge.rounded(), top = (bounds.height - edge).rounded()
    pages.frame = NSRect(x: left, y: bottom, width: max(0, right - left), height: max(0, top - bottom))
    pages.cornerRadius = isFullScreen ? PageContainerView.radius * shown : PageContainerView.radius
    updateTrafficLights()
  }

  private func updateTrafficLights() {
    for kind: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
      window.standardWindowButton(kind)?.isHidden = !isFullScreen
    }
  }

  func present(background: Bool) {
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
    if let entry = activeEntry ?? state.today.first ?? state.pinned.first {
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

  private func bind(_ entry: SidebarEntry, _ tab: ArdiaCoreTab) {
    entry.tab = tab
    tab.delegate = self
    pages.attach(tab)
  }

  func select(_ entry: SidebarEntry) {
    load(entry, foreground: true)
    guard let tab = entry.tab, !tab.closed else { return }
    pages.show(tab)
    coreWindow.activate(tab)
    let switched = state.activeEntryID != entry.id
    state.activeEntryID = entry.id
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

  func closeActive() {
    guard let entry = activeEntry else { return }
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
      move(entry, to: .pinned(state.pinned.count))
      return
    case .unpin:
      guard entry.kind == .pinned else { return }
      move(entry, to: .today(0))
      return
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

  /// Moves an entry to a section and place; pinning keeps the page it's on as its pinned URL.
  func move(_ entry: SidebarEntry, to target: SidebarDropTarget) {
    guard state.entry(id: entry.id) === entry else { return }
    state.favorites.removeAll { $0 === entry }
    state.pinned.removeAll { $0 === entry }
    state.today.removeAll { $0 === entry }
    switch target {
    case .favorites(let index):
      if entry.pinnedURL == nil { entry.pinnedURL = entry.currentURL }
      entry.kind = .favorite
      state.favorites.insert(entry, at: min(index, state.favorites.count))
    case .pinned(let index):
      if entry.pinnedURL == nil { entry.pinnedURL = entry.currentURL }
      entry.kind = .pinned
      state.pinned.insert(entry, at: min(index, state.pinned.count))
    case .today(let index):
      entry.kind = .today
      entry.pinnedURL = nil
      state.today.insert(entry, at: min(index, state.today.count))
    }
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

  func selectTab(number: Int) {
    let entries = state.allEntries
    guard !entries.isEmpty else { return }
    select(number >= 9 ? entries[entries.count - 1] : entries[min(number, entries.count) - 1])
  }

  // MARK: Sidebar visibility

  func toggleSidebar() {
    endPeek(animated: false)
    peekForced = false
    state.sidebarHidden.toggle()
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
    root.addSubview(floating, positioned: .above, relativeTo: pages)
    peekSpring.configure(response: Self.peekResponse, dampingRatio: Self.peekDamping)
    peekSpring.animate(to: 1, in: root)
    layout()
    logState("peek")
  }

  private func schedulePeekEnd() {
    guard peekEndWork == nil, !forcedOpen, !sidebar.isDragging else { return }
    let work = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.peekEndWork = nil
      if self.sidebar.isDragging { return }
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
    root.addSubview(sidebar, positioned: .above, relativeTo: pages)
    layout()
  }

  // MARK: Command bar

  func beginNewTab() {
    openCommandBar(.newTab, query: "")
  }

  func focusAddress() {
    openCommandBar(.currentTab, query: activeEntry?.currentURL ?? "")
  }

  /// ⇧⌘C, as in Arc and Chrome: the current page's full URL to the clipboard, and a moment of "Copied URL".
  func copyURL() {
    guard let url = activeEntry?.currentURL, !url.isEmpty else { return }
    let pasteboard = Self.pasteboard
    pasteboard.clearContents()
    pasteboard.setString(url, forType: .string)
    sidebar.flashAddress("Copied URL")
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
    history.refresh(profile: profile) { [weak self] in self?.refreshSuggestions() }
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

  private func focusPage(_ tab: ArdiaCoreTab) {
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

  // MARK: ArdiaCoreWindowDelegate

  func window(_ window: ArdiaCoreWindow, didInsert tab: ArdiaCoreTab, opener: ArdiaCoreTab?, disposition: String) {
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

  func window(_ window: ArdiaCoreWindow, didRemove tab: ArdiaCoreTab) {
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

  func window(_ window: ArdiaCoreWindow, didActivate tab: ArdiaCoreTab) {
    if let entry = state.entry(for: tab), entry.id != state.activeEntryID { select(entry) }
  }

  func window(_ window: ArdiaCoreWindow, devToolsDidChangeFor tab: ArdiaCoreTab, view devToolsView: NSView?) {
    if tab === activeTab { pages.setDevTools(devToolsView) }
    logState("devTools")
  }

  func window(_ window: ArdiaCoreWindow, preHandleKeyEvent event: NSEvent) -> Bool {
    Shortcuts.isReserved(event) && (NSApp.mainMenu?.performKeyEquivalent(with: event) ?? false)
  }

  func window(_ window: ArdiaCoreWindow, handleKeyEvent event: NSEvent) -> Bool {
    event.type == .keyDown && (NSApp.mainMenu?.performKeyEquivalent(with: event) ?? false)
  }

  func windowShouldClose(_ window: ArdiaCoreWindow) -> Bool {
    prepareForQuit()
    DispatchQueue.main.async { [weak self] in self?.onClose?() }
    return true
  }

  // MARK: ArdiaCoreTabDelegate

  private func tabChanged(_ tab: ArdiaCoreTab, event: String) {
    guard !closing, let entry = state.entry(for: tab) else { return }
    entry.remember()
    sidebar.refresh(entry)
    if entry.id == state.activeEntryID {
      sidebar.showAddress(entry)
      sidebar.setNavigation(canGoBack: tab.canGoBack, canGoForward: tab.canGoForward)
    }
    store.save(state)
    logState(event)
  }

  func tabDidChangeTitle(_ tab: ArdiaCoreTab) { tabChanged(tab, event: "title") }
  func tabDidChangeURL(_ tab: ArdiaCoreTab) { tabChanged(tab, event: "url") }
  func tabDidChangeFavicon(_ tab: ArdiaCoreTab) { tabChanged(tab, event: "favicon") }
  func tabDidChangeNavigationState(_ tab: ArdiaCoreTab) { tabChanged(tab, event: "navigation") }
  func tabDidChangeSecurity(_ tab: ArdiaCoreTab) { tabChanged(tab, event: "security") }

  func tabDidChangeLoading(_ tab: ArdiaCoreTab) {
    pages.updateProgress(for: tab)
    if !tab.loading { TestEnvironment.log("tab \(tab.tabId) loaded \(tab.url)") }
  }

  func tabDidChangeProgress(_ tab: ArdiaCoreTab) {
    pages.updateProgress(for: tab)
  }

  func tab(_ tab: ArdiaCoreTab, didFailLoad url: String, code: Int32, description text: String) {
    TestEnvironment.log("tab \(tab.tabId) failed \(url) (\(code) \(text))")
  }

  func tab(
    _ tab: ArdiaCoreTab, didReceivePageMessage kind: String, json: String, frame frameId: String, main: Bool,
    origin: String
  ) {
    if kind == "hello" && main { TestEnvironment.log("page channel ready in tab \(tab.tabId) (\(origin))") }
  }

  // MARK: State log

  func logState(_ event: String) {
    guard Self.logsState else { return }
    func describe(_ entry: SidebarEntry) -> [String: Any] {
      [
        "id": entry.id.uuidString, "kind": entry.kind.rawValue, "title": entry.displayTitle,
        "url": entry.currentURL, "pinnedURL": entry.pinnedURL ?? NSNull(), "live": entry.isLive,
        "away": entry.isAwayFromPinned, "tab": entry.isLive ? Int(entry.tab!.tabId) : NSNull(),
      ]
    }
    let state: [String: Any] = [
      "event": event,
      "active": activeTab.map { Int($0.tabId) } ?? NSNull(),
      "activeEntry": self.state.activeEntryID?.uuidString ?? NSNull(),
      "address": sidebar.addressText,
      "pages": pages.debugState,
      "cardFrame": NSStringFromRect(pages.frame),
      "windowFrame": NSStringFromRect(window.frame),
      "windowMovable": window.isMovable,
      "windowVisibleOnScreen": window.occlusionState.contains(.visible),
      "windowOnActiveSpace": window.isOnActiveSpace,
      "fullScreen": isFullScreen,
      "displayAsleep": CGDisplayIsAsleep(window.screen?.displayID ?? CGMainDisplayID()) != 0,
      "pasteboard": Self.pasteboard.string(forType: .string) ?? NSNull(),
      "addressShown": sidebar.addressLabel,
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
          "rows": bar.suggestions.map { ["kind": $0.kindName, "title": $0.title] },
        ] as [String: Any]
      } ?? NSNull(),
      "tabs": tabs.map { tab in
        [
          "id": Int(tab.tabId), "url": tab.url, "title": tab.title,
          "visible": !tab.view.isHidden && tab.view.superview != nil,
        ] as [String: Any]
      },
    ]
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

  override func updateLayer() {
    let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    layer?.backgroundColor = SidebarColors.background.cgColor
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
