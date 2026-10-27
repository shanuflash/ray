import AppKit

final class BrowserWindowController: NSObject, ArdiaCoreWindowDelegate, ArdiaCoreTabDelegate, SidebarViewDelegate,
  CommandBarDelegate
{
  enum CommandBarMode: String {
    case newTab
    case currentTab
  }

  let coreWindow: ArdiaCoreWindow
  let profile: ArdiaCoreProfile
  var onClose: (() -> Void)?

  private let root = NSView()
  private let sidebar = SidebarView()
  private let pages = PageContainerView()
  private(set) var tabs: [ArdiaCoreTab] = []
  private(set) var activeTab: ArdiaCoreTab?
  private var commandBar: CommandBarView?
  private var commandBarMode = CommandBarMode.newTab
  private let history = HistoryCache()
  let searches = SearchSuggestions()
  private let favicons = FaviconCache()

  var window: NSWindow { coreWindow.window }

  init(profile: ArdiaCoreProfile) {
    self.profile = profile
    coreWindow = ArdiaCoreWindow(contentRect: NSRect(x: 0, y: 0, width: 1360, height: 860))
    super.init()
    coreWindow.delegate = self
    coreWindow.activeProfile = profile
    configureWindow()
    sidebar.delegate = self
    let host = coreWindow.hostView
    root.frame = host.bounds
    root.autoresizingMask = [.width, .height]
    root.addSubview(sidebar)
    root.addSubview(pages)
    host.addSubview(root)
    layout()
    NotificationCenter.default.addObserver(
      self, selector: #selector(hostResized), name: NSView.frameDidChangeNotification, object: root)
    root.postsFrameChangedNotifications = true
  }

  private func configureWindow() {
    let frame = window.frame
    window.styleMask.insert(.fullSizeContentView)
    if window.frame != frame { window.setFrame(frame, display: false) }
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    window.title = "Lumen"
    window.minSize = NSSize(width: 720, height: 460)
    window.backgroundColor = .windowBackgroundColor
    window.isReleasedWhenClosed = false
    window.isRestorable = false
    window.animationBehavior = .none
    window.tabbingMode = .disallowed
  }

  @objc private func hostResized() { layout() }

  private func layout() {
    let bounds = root.bounds
    let margin: CGFloat = 8
    sidebar.frame = NSRect(x: 0, y: 0, width: SidebarView.width, height: bounds.height)
    pages.frame = NSRect(
      x: SidebarView.width, y: margin,
      width: max(0, bounds.width - SidebarView.width - margin), height: max(0, bounds.height - margin * 2))
  }

  func present(background: Bool) {
    window.center()
    if background {
      coreWindow.showInactive()
    } else {
      window.makeKeyAndOrderFront(nil)
    }
  }

  @discardableResult
  func openTab(_ url: String, foreground: Bool) -> ArdiaCoreTab {
    let tab = coreWindow.openTab(url, profile: profile, foreground: foreground)
    adopt(tab, after: foreground ? activeTab : tabs.last)
    if foreground { activate(tab) }
    return tab
  }

  private func adopt(_ tab: ArdiaCoreTab, after anchor: ArdiaCoreTab?) {
    guard !tabs.contains(where: { $0 === tab }) else { return }
    tab.delegate = self
    let index = anchor.flatMap { a in tabs.firstIndex { $0 === a } }.map { $0 + 1 } ?? tabs.count
    tabs.insert(tab, at: index)
    pages.attach(tab)
    sidebar.setTabs(tabs, active: activeTab)
    logState("insert")
  }

  func activate(_ tab: ArdiaCoreTab) {
    guard tabs.contains(where: { $0 === tab }) else { return }
    pages.show(tab)
    coreWindow.activate(tab)
    let changed = activeTab !== tab
    activeTab = tab
    if commandBar == nil { focusPage(tab) }
    if changed {
      sidebar.select(tab)
      sidebar.showAddress(AddressInput.display(for: tab.url))
      logState("activate")
    }
  }

  private static let logsState = environment["LUMEN_LOG_STATE"] == "1"

  private func logState(_ event: String) {
    guard Self.logsState else { return }
    let state: [String: Any] = [
      "event": event,
      "active": activeTab.map { Int($0.tabId) } ?? NSNull(),
      "address": sidebar.addressField.stringValue,
      "pages": pages.debugState,
      "windowFrame": NSStringFromRect(window.frame),
      "windowMovable": window.isMovable,
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

  func pageContains(windowPoint point: NSPoint) -> Bool {
    pages.bounds.contains(pages.convert(point, from: nil)) && commandBar == nil
  }

  var debugWindowFrame: String { NSStringFromRect(window.frame) }

  private func focusPage(_ tab: ArdiaCoreTab) {
    window.makeFirstResponder(tab.view)
    tab.focus()
  }

  func closeActiveTab() {
    activeTab?.close()
  }

  func cycleTab(by step: Int) {
    guard !tabs.isEmpty else { return }
    let index = activeTab.flatMap { a in tabs.firstIndex { $0 === a } } ?? 0
    activate(tabs[(index + step + tabs.count) % tabs.count])
  }

  func selectTab(number: Int) {
    guard !tabs.isEmpty else { return }
    activate(number >= 9 ? tabs[tabs.count - 1] : tabs[min(number, tabs.count) - 1])
  }

  func beginNewTab() {
    openCommandBar(.newTab, query: "")
  }

  func focusAddress() {
    openCommandBar(.currentTab, query: activeTab?.url ?? "")
  }

  private func openCommandBar(_ mode: CommandBarMode, query: String) {
    commandBarMode = activeTab == nil ? .newTab : mode
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
    let query = commandBarMode == .currentTab && bar.field.stringValue == activeTab?.url ? "" : bar.field.stringValue
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

  func toggleDevTools() {
    guard let tab = activeTab else { return }
    if tab.devToolsView == nil { tab.showDevTools() } else { tab.closeDevTools() }
  }

  // MARK: SidebarViewDelegate

  func sidebar(_ sidebar: SidebarView, didSelect tab: ArdiaCoreTab) { activate(tab) }

  func sidebar(_ sidebar: SidebarView, close tab: ArdiaCoreTab) { tab.close() }

  func sidebarNewTab(_ sidebar: SidebarView) { beginNewTab() }

  func sidebarOpenAddress(_ sidebar: SidebarView) { focusAddress() }

  // MARK: CommandBarDelegate

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
      activate(tab)
      return
    case .url(let target), .search(let target), .history(let target):
      url = target
    }
    if mode == .newTab || activeTab == nil {
      openTab(url, foreground: true)
    } else if let tab = activeTab {
      tab.loadURL(url, userInitiated: true)
      sidebar.showAddress(AddressInput.display(for: url))
      focusPage(tab)
    }
  }

  func commandBarDismiss(_ bar: CommandBarView) {
    closeCommandBar(focus: true)
  }

  // MARK: ArdiaCoreWindowDelegate

  func window(_ window: ArdiaCoreWindow, didInsert tab: ArdiaCoreTab, opener: ArdiaCoreTab?, disposition: String) {
    let known = tabs.contains { $0 === tab }
    adopt(tab, after: opener ?? activeTab)
    NSLog("[lumen] tab %d inserted (%@)", tab.tabId, disposition)
    if !known && disposition != "background_tab" { activate(tab) }
  }

  func window(_ window: ArdiaCoreWindow, didRemove tab: ArdiaCoreTab) {
    guard let index = tabs.firstIndex(where: { $0 === tab }) else { return }
    tabs.remove(at: index)
    pages.detach(tab)
    if tab.delegate === self { tab.delegate = nil }
    if activeTab === tab {
      activeTab = nil
      if !tabs.isEmpty { activate(tabs[min(index, tabs.count - 1)]) }
    }
    sidebar.setTabs(tabs, active: activeTab)
    logState("remove")
    if tabs.isEmpty { coreWindow.close() }
  }

  func window(_ window: ArdiaCoreWindow, didActivate tab: ArdiaCoreTab) {
    if activeTab !== tab { activate(tab) }
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
    DispatchQueue.main.async { [weak self] in self?.onClose?() }
    return true
  }

  // MARK: ArdiaCoreTabDelegate

  func tabDidChangeTitle(_ tab: ArdiaCoreTab) {
    sidebar.refresh(tab)
  }

  func tabDidChangeURL(_ tab: ArdiaCoreTab) {
    sidebar.refresh(tab)
    if tab === activeTab { sidebar.showAddress(AddressInput.display(for: tab.url)) }
    logState("url")
  }

  func tabDidChangeFavicon(_ tab: ArdiaCoreTab) {
    sidebar.refresh(tab)
  }

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
}
