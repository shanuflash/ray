import AppKit

final class BrowserWindowController: NSObject, ArdiaCoreWindowDelegate, ArdiaCoreTabDelegate, SidebarViewDelegate,
  CommandBarDelegate
{
  enum CommandBarMode: String {
    case newTab
    case currentTab
  }

  private static let margin: CGFloat = 8
  private static let logsState = environment["LUMEN_LOG_STATE"] == "1"

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
  private static let revealWidth: CGFloat = 14
  private static let outsideReach: CGFloat = 24
  private static let holdSlack: CGFloat = 24
  private static let peekInset: CGFloat = 5
  private static let peekHideDelay: TimeInterval = 0.12
  private var pointerMonitors: [Any] = []
  private lazy var peekSpring = Spring(value: 0, response: 0.185, dampingRatio: 0.77) { [weak self] value in
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
      NotificationCenter.default.addObserver(self, selector: #selector(hostResized), name: name, object: window)
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
    window.title = "Lumen"
    window.minSize = NSSize(width: 720, height: 460)
    window.backgroundColor = SidebarColors.background
    window.isReleasedWhenClosed = false
    window.isRestorable = false
    window.animationBehavior = .none
    window.tabbingMode = .disallowed
    window.acceptsMouseMovedEvents = true
  }

  @objc private func hostResized() { layout() }

  private var isFullScreen: Bool { window.styleMask.contains(.fullScreen) }

  private var trafficLightsCenter: CGFloat {
    guard !isFullScreen, let button = window.standardWindowButton(.closeButton), let content = window.contentView
    else { return 20 }
    let frame = button.convert(button.bounds, to: nil)
    let center = content.bounds.height - frame.midY
    return center > 0 && center < 60 ? center : 20
  }

  private func layout() {
    let bounds = root.bounds
    let margin = Self.margin
    let width = SidebarView.width
    let shown = dockSpring.value
    let peek = peekSpring.value
    let lights = trafficLightsCenter

    if peeking || peek > 0.001 {
      let inset = Self.peekInset
      floating.frame = NSRect(
        x: inset - (width + 24) * (1 - peek), y: inset, width: width, height: bounds.height - inset * 2)
      sidebar.frame = floating.bounds
      sidebar.trafficLightsCenterY = lights - inset
      sidebar.reservesTrafficLights = !isFullScreen
    } else {
      sidebar.frame = NSRect(x: -width * (1 - shown), y: 0, width: width, height: bounds.height)
      sidebar.trafficLightsCenterY = lights
      sidebar.reservesTrafficLights = !isFullScreen
    }
    let cardX = max(margin, width * shown)
    pages.frame = NSRect(
      x: cardX, y: margin, width: max(0, bounds.width - cardX - margin), height: max(0, bounds.height - margin * 2))
    updateTrafficLights()
  }

  private func updateTrafficLights() {
    let visible = !state.sidebarHidden || peeking || dockSpring.isMoving
    for kind: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
      window.standardWindowButton(kind)?.isHidden = !visible
    }
  }

  func present(background: Bool) {
    window.center()
    if background {
      coreWindow.showInactive()
    } else {
      window.makeKeyAndOrderFront(nil)
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

  // MARK: Entries

  private func reloadSidebar() {
    sidebar.show(favorites: state.favorites, pinned: state.pinned, today: state.today, active: activeEntry)
    sidebar.showAddress(activeEntry)
    sidebar.setNavigation(canGoBack: activeTab?.canGoBack ?? false, canGoForward: activeTab?.canGoForward ?? false)
  }

  private func changed(_ event: String) {
    guard !closing else { return }
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
      state.today.removeAll { $0 === entry }
      entry.kind = .pinned
      entry.pinnedURL = entry.currentURL
      state.pinned.append(entry)
    case .unpin:
      guard entry.kind == .pinned else { return }
      state.pinned.removeAll { $0 === entry }
      entry.kind = .today
      entry.pinnedURL = nil
      state.today.insert(entry, at: 0)
    case .addToFavorites:
      guard entry.kind != .favorite else { return }
      state.pinned.removeAll { $0 === entry }
      state.today.removeAll { $0 === entry }
      if entry.pinnedURL == nil { entry.pinnedURL = entry.currentURL }
      entry.kind = .favorite
      state.favorites.append(entry)
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
    state.sidebarHidden.toggle()
    dockSpring.animate(to: state.sidebarHidden ? 0 : 1, in: root)
    layout()
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
    peekSpring.configure(response: 0.185, dampingRatio: 0.77)
    peekSpring.animate(to: 1, in: root)
    layout()
    logState("peek")
  }

  private func schedulePeekEnd() {
    guard peekEndWork == nil else { return }
    let work = DispatchWorkItem { [weak self] in
      self?.peekEndWork = nil
      self?.endPeek(animated: true)
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

  func sidebarNewTab(_ sidebar: SidebarView) { beginNewTab() }
  func sidebarOpenAddress(_ sidebar: SidebarView) { focusAddress() }
  func sidebarToggle(_ sidebar: SidebarView) { toggleSidebar() }
  func sidebarBack(_ sidebar: SidebarView) { activeTab?.goBack() }
  func sidebarForward(_ sidebar: SidebarView) { activeTab?.goForward() }
  func sidebarReload(_ sidebar: SidebarView) { activeTab?.reload() }
  func sidebarClearToday(_ sidebar: SidebarView) { clearToday() }

  func sidebarIcon(for entry: SidebarEntry) -> NSImage? {
    if entry.isLive, let icon = entry.tab?.favicon { return icon }
    let page = entry.pinnedURL ?? entry.url
    if let icon = favicons.image(for: page) ?? favicons.image(for: entry.url) { return icon }
    favicons.load([page, entry.url], profile: profile) { [weak self] in self?.reloadSidebar() }
    return nil
  }

  // MARK: ArdiaCoreWindowDelegate

  func window(_ window: ArdiaCoreWindow, didInsert tab: ArdiaCoreTab, opener: ArdiaCoreTab?, disposition: String) {
    NSLog("[lumen] tab %d inserted (%@)", tab.tabId, disposition)
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

  func tabDidChangeLoading(_ tab: ArdiaCoreTab) {
    pages.updateProgress(for: tab)
    if !tab.loading { NSLog("[lumen] tab %d loaded %@", tab.tabId, tab.url) }
  }

  func tabDidChangeProgress(_ tab: ArdiaCoreTab) {
    pages.updateProgress(for: tab)
  }

  func tab(_ tab: ArdiaCoreTab, didFailLoad url: String, code: Int32, description text: String) {
    NSLog("[lumen] tab %d failed %@ (%d %@)", tab.tabId, url, code, text)
  }

  func tab(
    _ tab: ArdiaCoreTab, didReceivePageMessage kind: String, json: String, frame frameId: String, main: Bool,
    origin: String
  ) {
    if kind == "hello" && main { NSLog("[lumen] page channel ready in tab %d (%@)", tab.tabId, origin) }
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
    FileHandle.standardError.write("[lumen-state] \(json)\n".data(using: .utf8)!)
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
    layer?.shadowColor = NSColor.black.cgColor
    layer?.shadowRadius = 20
    layer?.shadowOffset = CGSize(width: 0, height: -6)
  }

  required init?(coder: NSCoder) { fatalError() }

  override var wantsUpdateLayer: Bool { true }

  override func updateLayer() {
    let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    layer?.backgroundColor = SidebarColors.background.cgColor
    layer?.borderColor = (dark ? NSColor(white: 1, alpha: 0.1) : NSColor(white: 0, alpha: 0.1)).cgColor
    layer?.shadowOpacity = dark ? 0.5 : 0.18
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
