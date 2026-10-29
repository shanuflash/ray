import AppKit

/// Settings › Privacy: what each site may do, the sites you zoomed, the apps sites may open, and clearing what sites
/// keep. Everything is the normal profile's, read from and written to the engine (`ac_site_settings_*`,
/// `ac_site_data_clear`, `ac_zoom_*`, `ac_external_apps_*`); a private window's sites never show here. Chrome's Site
/// settings pages (`chrome://settings/content`, All sites, a site's details, Zoom levels) and `ray://settings/privacy`
/// open this pane (`AddressInput.nativeSettingsPaths`); Chrome's Privacy and security page stays Chrome's.
final class PrivacyPaneContent: SettingsPaneContent {
  struct Site {
    let origin: String
    let permissions: [(type: String, value: String)]
  }

  struct AppLink {
    let origin: String
    let scheme: String
    let app: String?
    let icon: String?
  }

  var hasContent: Bool { true }

  private let sitesList = SettingsDynamicList()
  private let zoomList = SettingsDynamicList()
  private let appsList = SettingsDynamicList()
  private let dataList = SettingsDynamicList()

  /// nil until the engine has answered once.
  private(set) var sites: [Site]?
  private(set) var zooms: [(host: String, factor: Double)]?
  private(set) var apps: [AppLink]?
  private var opened: Set<String> = []
  private var icons: [String: NSImage] = [:]
  private var generation = 0
  private var reloadWork: DispatchWorkItem?
  private var defaultsShown = false
  private var revealing: String?

  // What tests press, by origin or host.
  private var siteRows: [String: SettingsItemRow] = [:]
  private var popUps: [String: [String: SettingsPopUp]] = [:]
  private var resetButtons: [String: SettingsButton] = [:]
  private var clearButtons: [String: SettingsButton] = [:]
  private var zoomButtons: [String: SettingsButton] = [:]
  private var appButtons: [String: SettingsButton] = [:]
  private var clearDataButton: SettingsButton?

  init() {
    sitesList.onShow = { [weak self] in self?.reload() }
    sitesList.onWindowKey = { [weak self] in self?.reloadSoon() }
    EngineEvents.on("siteSettings.changed") { [weak self] payload in
      if SettingsPages.isNormalProfile(payload) { self?.reloadSoon() }
    }
    EngineEvents.on("zoom.changed") { [weak self] payload in
      if SettingsPages.isNormalProfile(payload) { self?.reloadSoon() }
    }
    showSites()
    showZooms()
    showApps()
    showData()
  }

  func sections() -> [SettingsSection] {
    [
      SettingsSection(
        id: "privacy.sites", title: "Site permissions", place: .top, view: sitesList,
        search: [
          SettingsSearchEntry(
            title: "Site permissions", detail: "Camera, microphone, location, notifications and pop-ups, site by site",
            keywords: ["camera", "microphone", "location", "notifications", "pop-ups", "popups", "javascript", "cookies",
                       "website", "site settings", "permissions", "reset permissions"]),
          SettingsSearchEntry(
            title: "Clear site data", detail: "Cookies and storage of one site",
            keywords: ["cookies", "storage", "sign out", "site data", "delete"]),
        ]),
      SettingsSection(
        id: "privacy.zoom", title: "Zoom levels", place: .top, view: zoomList,
        search: [
          SettingsSearchEntry(
            title: "Sites you zoomed", detail: "Sites that keep their own zoom level, and Reset for each",
            keywords: ["zoom levels", "zoom", "reset zoom", "page size"]),
        ]),
      SettingsSection(
        id: "privacy.apps", title: "Apps allowed to open links", place: .top, view: appsList,
        search: [
          SettingsSearchEntry(
            title: "Apps allowed to open links", detail: "Sites that open another app without asking first",
            keywords: ["external apps", "protocol handlers", "open app", "mailto", "always allow"]),
        ]),
      SettingsSection(
        id: "privacy.data", title: "Browsing data", place: .top, view: dataList,
        search: [
          SettingsSearchEntry(
            title: "Clear browsing data", detail: "History, cookies and cached files, for a time you choose",
            keywords: ["history", "cache", "cookies", "delete", "erase", "browsing data"]),
        ]),
    ]
  }

  // MARK: Loading

  private func reloadSoon() {
    reloadWork?.cancel()
    let work = DispatchWorkItem { [weak self] in self?.reload() }
    reloadWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
  }

  /// Asks the engine for every list again. Answers to an older reload are dropped.
  func reload() {
    reloadWork?.cancel()
    guard let profile = SettingsPages.profile else { return }
    generation += 1
    let current = generation
    EngineCalls.call("ac_site_settings_origins", profile: profile) { [weak self] reply in
      guard let self, current == self.generation else { return }
      let origins = Array((reply?["origins"] as? [String] ?? []).filter(Self.isWebOrigin).prefix(500))
      self.loadSites(origins, profile: profile, generation: current)
    }
    EngineCalls.call("ac_zoom_list", profile: profile) { [weak self] reply in
      guard let self, current == self.generation else { return }
      let levels = reply?["levels"] as? [String: Any] ?? [:]
      // Only the hosts the user zoomed (Ray sets the default zoom per host too, which isn't theirs).
      self.zooms = RaySettings.shared.zoomedHosts
        .map { host in (host, pow(1.2, (levels[host] as? NSNumber)?.doubleValue ?? 0)) }
        .sorted { Self.order($0.host) < Self.order($1.host) }
      self.showZooms()
    }
    EngineCalls.call("ac_external_apps_allowances", profile: profile) { [weak self] reply in
      guard let self, current == self.generation else { return }
      self.apps = (reply?["allowances"] as? [[String: Any]] ?? []).compactMap { info in
        guard let origin = info["origin"] as? String, let scheme = info["scheme"] as? String, !scheme.isEmpty else { return nil }
        return AppLink(origin: origin, scheme: scheme, app: info["app"] as? String, icon: info["icon"] as? String)
      }.sorted { (Self.order(Self.host(of: $0.origin)), $0.scheme) < (Self.order(Self.host(of: $1.origin)), $1.scheme) }
      self.showApps()
    }
  }

  /// Each origin's settings that aren't the default, in Site controls' order. Origins left with none are dropped.
  private func loadSites(_ origins: [String], profile: RayCoreProfile, generation current: Int) {
    guard !origins.isEmpty else {
      sites = []
      showSites()
      return
    }
    var found: [String: [(String, String)]] = [:]
    var left = origins.count
    for origin in origins {
      EngineCalls.call("ac_site_settings_get", profile: profile, args: ["origin": origin]) { [weak self] reply in
        guard let self, current == self.generation else { return }
        let settings = reply?["settings"] as? [String: [String: Any]] ?? [:]
        found[origin] = Permission.order.compactMap { type in
          guard let info = settings[type], info["isDefault"] as? Bool == false, let value = info["value"] as? String,
                ["allow", "block", "ask"].contains(value) else { return nil }
          return (type, value)
        }
        left -= 1
        guard left == 0 else { return }
        self.sites = origins.compactMap { origin in
          guard let permissions = found[origin], !permissions.isEmpty else { return nil }
          return Site(origin: origin, permissions: permissions)
        }.sorted { (Self.order(Self.host(of: $0.origin)), $0.origin) < (Self.order(Self.host(of: $1.origin)), $1.origin) }
        self.showSites()
        self.loadIcons()
      }
    }
  }

  private func loadIcons() {
    let pages = Set((sites ?? []).map { $0.origin + "/" } + (zooms ?? []).map { "https://\($0.host)/" })
      .filter { icons[$0] == nil }
    SettingsPages.favicons(for: Array(pages)) { [weak self] found in
      guard let self, !found.isEmpty else { return }
      self.icons.merge(found) { a, _ in a }
      self.showSites()
      self.showZooms()
    }
  }

  // MARK: Site permissions

  private func showSites() {
    siteRows = [:]
    popUps = [:]
    resetButtons = [:]
    clearButtons = [:]
    var rows: [NSView] = []
    if let sites, !sites.isEmpty {
      rows = sites.map(siteRow)
    } else {
      rows.append(SettingsItemRow(
        key: "empty", icon: nil, title: sites == nil ? " " : "No sites yet",
        detail: sites == nil ? " " : "Sites you allow or block show here.", showsIcon: false))
    }
    let more = MoreLine()
    more.expanded = defaultsShown
    more.onClick = { [weak self] in
      guard let self else { return }
      self.defaultsShown.toggle()
      self.showSites()
    }
    rows.append(more)
    if defaultsShown { rows.append(defaultsRow()) }
    sitesList.setRows(rows)
    if let revealing, let row = siteRows[revealing] {
      self.revealing = nil
      DispatchQueue.main.async {
        row.scrollToVisible(row.bounds.insetBy(dx: 0, dy: -24))
        SettingsFlash.run(on: row)
      }
    }
  }

  private func siteRow(_ site: Site) -> SettingsItemRow {
    let origin = site.origin
    var details: [NSView] = []
    var choices: [String: SettingsPopUp] = [:]
    for (type, value) in site.permissions {
      let permission = Permission(type)
      var options: [(title: String, value: String)] = [("Allow", "allow"), ("Block", "block")]
      if Permission.askable.contains(type) { options.append(("Ask", "ask")) }
      options += [("", "-"), ("Default", "default")]
      let popUp = SettingsPopUp(options, selected: value)
      popUp.setAccessibilityLabel("\(permission.title) for \(Self.display(origin))")
      popUp.onChoose = { [weak self] value in self?.set(type, of: origin, to: value) }
      choices[type] = popUp
      details.append(SettingsDetailRow(title: permission.title, symbol: permission.symbol, control: popUp))
    }
    let reset = SettingsButton("Reset Permissions") { [weak self] in self?.reset(origin) }
    let clear = SettingsButton("Clear Site Data…") { [weak self, weak sitesList] in self?.confirmClear(origin, in: sitesList?.window) }
    details.append(SettingsButtonRow([reset, clear]))
    let body = SettingsDynamicList()
    body.setRows(details)
    let summary = site.permissions.map { "\(Permission($0.type).title): \(Permission.label($0.value))" }.joined(separator: " · ")
    let row = SettingsItemRow(
      key: origin, icon: icons[origin + "/"] ?? NSImage(systemSymbolName: "globe", accessibilityDescription: nil),
      title: Self.display(origin), detail: summary, body: body, open: opened.contains(origin), titleElidesHead: true)
    row.onToggle = { [weak self] open in
      if open { self?.opened.insert(origin) } else { self?.opened.remove(origin) }
    }
    siteRows[origin] = row
    popUps[origin] = choices
    resetButtons[origin] = reset
    clearButtons[origin] = clear
    return row
  }

  /// Chrome's defaults for every site (ask before the camera, block pop-ups…) are its own pages: a rare row opens
  /// the one you pick, in a tab of the normal window.
  private func defaultsRow() -> NSView {
    let pages: [(title: String, value: String)] = [
      ("Camera", "camera"), ("Microphone", "microphone"), ("Location", "location"), ("Notifications", "notifications"),
      ("Pop-ups and Redirects", "popups"), ("Sound", "sound"), ("JavaScript", "javascript"), ("Images", "images"),
      ("Automatic Downloads", "automaticDownloads"), ("Clipboard", "clipboard"),
    ]
    let menu = SettingsPopUp(pages, selected: nil, pullsDown: true, title: "Open…")
    menu.setAccessibilityLabel("Defaults for every site")
    menu.onChoose = { page in SettingsPages.open("chrome://settings/content/\(page)") }
    return SettingsItemRow(
      key: "defaults", icon: nil, title: "Defaults for every site",
      detail: "Opens Chrome's settings.", controls: [menu],
      showsIcon: false)
  }

  private func set(_ type: String, of origin: String, to value: String) {
    guard let profile = SettingsPages.profile, Permission.order.contains(type),
          ["allow", "block", "ask", "default"].contains(value) else { return }
    opened.insert(origin)
    EngineCalls.call("ac_site_settings_set", profile: profile, args: ["origin": origin, "type": type, "value": value]) {
      [weak self] _ in self?.reload()
    }
  }

  private func reset(_ origin: String) {
    guard let profile = SettingsPages.profile else { return }
    EngineCalls.call("ac_site_settings_reset", profile: profile, args: ["origin": origin]) { [weak self] _ in self?.reload() }
  }

  private func confirmClear(_ origin: String, in window: NSWindow?) {
    SettingsConfirm.ask(
      "Clear cookies and site data for \(origin)?",
      detail: "Deletes all it keeps, subdomains too, and signs you out.",
      action: "Clear", in: window) { [weak self] in self?.clear(origin) }
  }

  private func clear(_ origin: String) {
    guard let profile = SettingsPages.profile else { return }
    EngineCalls.call("ac_site_data_clear", profile: profile, args: ["origin": origin]) { [weak self] reply in
      self?.lastCleared = [origin: reply?["storage"] as? Bool ?? false]
      self?.reload()
    }
  }

  private var lastCleared: [String: Bool] = [:]

  /// Site controls' "Site Settings…": this pane, that site opened and flashed (once the list has it).
  func reveal(_ origin: String) {
    opened.insert(origin)
    revealing = origin
    reload()
  }

  // MARK: Zoom levels

  private func showZooms() {
    zoomButtons = [:]
    guard let zooms, !zooms.isEmpty else {
      zoomList.setRows([SettingsItemRow(
        key: "empty", icon: nil, title: zooms == nil ? " " : "No zoomed sites",
        detail: zooms == nil ? " " : "Sites you zoom with ⌘+ or ⌘− show here.",
        showsIcon: false)])
      return
    }
    zoomList.setRows(zooms.map { zoom in
      let host = zoom.host
      let reset = SettingsButton("Reset") { [weak self] in self?.resetZoom(host) }
      reset.setAccessibilityLabel("Reset zoom for \(host)")
      zoomButtons[host] = reset
      return SettingsItemRow(
        key: host, icon: icons["https://\(host)/"] ?? NSImage(systemSymbolName: "plus.magnifyingglass", accessibilityDescription: nil),
        title: host, detail: "\(Int((zoom.factor * 100).rounded()))%", controls: [reset], titleElidesHead: true)
    })
  }

  /// Back to following Settings › Page zoom, as Site controls' Reset does: the host is no longer the user's own, and
  /// the engine's level for it becomes the default.
  private func resetZoom(_ host: String) {
    guard let profile = SettingsPages.profile else { return }
    RaySettings.shared.unmarkZoomed(host)
    let level = log(RaySettings.shared[.defaultZoom]) / log(1.2)
    EngineCalls.call("ac_zoom_set", profile: profile, args: ["host": host, "level": level.isFinite ? level : 0]) { [weak self] _ in
      self?.reload()
    }
  }

  // MARK: Apps

  private func showApps() {
    appButtons = [:]
    guard let apps, !apps.isEmpty else {
      appsList.setRows([SettingsItemRow(
        key: "empty", icon: nil, title: apps == nil ? " " : "No apps yet",
        detail: apps == nil ? " " : "Sites you let open apps show here.",
        showsIcon: false)])
      return
    }
    appsList.setRows(apps.map { link in
      let remove = SettingsButton("Remove") { [weak self] in self?.removeApp(link) }
      appButtons["\(link.origin) \(link.scheme)"] = remove
      let icon = link.icon.flatMap(ExtensionsController.image(fromDataURL:))
        ?? NSImage(systemSymbolName: "app", accessibilityDescription: nil)
      return SettingsItemRow(
        key: "\(link.origin) \(link.scheme)", icon: icon, title: Self.display(link.origin),
        detail: "Opens \(link.scheme): links in \(link.app ?? "an app that's no longer installed")", controls: [remove],
        titleElidesHead: true)
    })
  }

  private func removeApp(_ link: AppLink) {
    guard let profile = SettingsPages.profile else { return }
    EngineCalls.call("ac_external_apps_remove", profile: profile, args: ["origin": link.origin, "scheme": link.scheme]) {
      [weak self] _ in self?.reload()
    }
  }

  // MARK: Browsing data

  private func showData() {
    let button = SettingsButton("Clear…") { SettingsPages.show("ray://settings/clearBrowserData") }
    clearDataButton = button
    dataList.setRows([SettingsItemRow(
      key: "clear", icon: nil, title: "Clear browsing data",
      detail: "", controls: [button], showsIcon: false)])
  }

  // MARK: Helpers

  private static func isWebOrigin(_ origin: String) -> Bool {
    guard let components = URLComponents(string: origin), let scheme = components.scheme?.lowercased() else { return false }
    return (scheme == "http" || scheme == "https") && !(components.host ?? "").isEmpty
  }

  static func host(of origin: String) -> String { URLComponents(string: origin)?.host?.lowercased() ?? origin }

  /// An origin as the list shows it: https is the usual, so only http keeps its scheme; a port stays.
  static func display(_ origin: String) -> String {
    origin.hasPrefix("https://") ? String(origin.dropFirst(8)) : origin
  }

  /// Sites sort by their registrable domain, then the full host (www. and the bare domain together).
  private static func order(_ host: String) -> String {
    let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    let isAddress = bare.allSatisfy { $0.isNumber || $0 == "." } || bare.contains(":")
    return (isAddress ? bare : AddressInput.registrableDomain(bare)) + " " + bare
  }

  // MARK: Tests

  /// `privacy list|reload|open <origin>|set <origin> <type> <value>|reset <origin>|clear <origin>|confirm accept|cancel|
  /// zoomreset <host>|appremove <origin> <scheme>|clearbrowsing|defaults`: the pane's lists as JSON, or a press as a click
  /// would make it.
  static func test(_ argument: String) -> String {
    guard let pane = SettingsPanes.content(for: .privacy) as? PrivacyPaneContent else { return "no pane" }
    let words = argument.split(separator: " ").map(String.init)
    func ok(_ done: Bool) -> String { done ? "ok" : "no such control" }
    switch words.first {
    case "list": return SettingsPages.json(pane.debug)
    case "reload": pane.reload()
    case "open":
      guard words.count == 2, let row = pane.siteRows[words[1]] else { return "no such site" }
      if !row.isOpen { row.toggle() }
    case "set":
      guard words.count == 4 else { return "usage: privacy set <origin> <type> <value>" }
      return ok(pane.popUps[words[1]]?[words[2]]?.choose(words[3]) ?? false)
    case "reset":
      guard words.count == 2 else { return "usage: privacy reset <origin>" }
      return ok(pane.resetButtons[words[1]]?.press() ?? false)
    case "clear":
      guard words.count == 2 else { return "usage: privacy clear <origin>" }
      return ok(pane.clearButtons[words[1]]?.press() ?? false)
    case "confirm":
      guard words.count == 2 else { return SettingsPages.json(SettingsConfirm.debug ?? [:]) }
      return SettingsConfirm.answer(accept: words[1] == "accept")
    case "zoomreset":
      guard words.count == 2 else { return "usage: privacy zoomreset <host>" }
      return ok(pane.zoomButtons[words[1]]?.press() ?? false)
    case "appremove":
      guard words.count == 3 else { return "usage: privacy appremove <origin> <scheme>" }
      return ok(pane.appButtons["\(words[1]) \(words[2])"]?.press() ?? false)
    case "clearbrowsing": return ok(pane.clearDataButton?.press() ?? false)
    case "defaults":
      pane.defaultsShown = true
      pane.showSites()
    case "reveal":
      guard words.count == 2 else { return "usage: privacy reveal <origin>" }
      pane.reveal(words[1])
    default:
      return "usage: privacy list|reload|open|set|reset|clear|confirm|zoomreset|appremove|clearbrowsing|defaults|reveal"
    }
    return "ok"
  }

  private var debug: [String: Any] {
    func emptyText(_ list: SettingsDynamicList) -> Any {
      guard let row = list.rows.first as? SettingsItemRow, row.key == "empty" else { return NSNull() }
      return "\(row.title) \(row.detail)"
    }
    return [
      "loaded": sites != nil && zooms != nil && apps != nil,
      "sites": (sites ?? []).map { site -> [String: Any] in
        [
          "origin": site.origin, "title": Self.display(site.origin), "open": siteRows[site.origin]?.isOpen ?? false,
          "permissions": Dictionary(uniqueKeysWithValues: site.permissions.map { ($0.type, $0.value) }),
          "hasIcon": icons[site.origin + "/"] != nil,
        ]
      },
      "zoom": (zooms ?? []).map { ["host": $0.host, "percent": Int(($0.factor * 100).rounded())] },
      "apps": (apps ?? []).map { ["origin": $0.origin, "scheme": $0.scheme, "app": ($0.app as Any?) ?? NSNull()] as [String: Any] },
      "empty": ["sites": emptyText(sitesList), "zoom": emptyText(zoomList), "apps": emptyText(appsList)],
      "defaultsShown": defaultsShown,
      "cleared": lastCleared,
      "confirm": SettingsConfirm.debug ?? NSNull(),
    ]
  }
}
