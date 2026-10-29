import AppKit

/// Settings › Extensions: what's installed in the normal profile (`ac_extensions_list`), each with its switch and, opened,
/// its site access, private windows, options, reload and Remove; then the Chrome Web Store and, under "More", loading
/// an unpacked folder. Chrome's own chrome://extensions page stays as it is (it isn't a settings page);
/// `ray://settings/extensions` opens this pane. Installing from a Web Store link isn't built: the engine installs only
/// from the store's page or a file.
final class ExtensionsPaneContent: SettingsPaneContent {
  struct Item {
    let id: String
    let name: String
    let version: String
    let description: String
    let enabled: Bool
    let icon: String?
    /// Chrome's `ON_CLICK`, `ON_SPECIFIC_SITES` or `ON_ALL_SITES`; nil for one that asks for no sites.
    let siteAccess: String?
    let sites: [String]
    let optionsURL: String?
    let unpacked: Bool
    let path: String?
    let incognito: Bool
    let mayModify: Bool
    let permissions: [String]
    let errors: [String]
  }

  var hasContent: Bool { true }

  private let installedList = SettingsDynamicList()
  private let addList = SettingsDynamicList()
  /// nil until the engine has answered once.
  private(set) var items: [Item]?
  private var opened: Set<String> = []
  private var problems: [String: String] = [:]
  private var moreShown = false
  private var generation = 0
  private var lastInstall: String?

  // What tests press, by extension id.
  private var rows: [String: SettingsItemRow] = [:]
  private var switches: [String: RaySwitch] = [:]
  private var privateSwitches: [String: RaySwitch] = [:]
  private var accessPopUps: [String: SettingsPopUp] = [:]
  private var optionButtons: [String: SettingsButton] = [:]
  private var reloadButtons: [String: SettingsButton] = [:]
  private var removeButtons: [String: SettingsButton] = [:]
  private var storeButton: SettingsButton?
  private var linkRowShown = false

  static let store = "https://chromewebstore.google.com/category/extensions"

  init() {
    installedList.onShow = { [weak self] in self?.reload() }
    installedList.onWindowKey = { [weak self] in self?.reload() }
    showInstalled()
    showAdd()
  }

  func sections() -> [SettingsSection] {
    var add = [
      SettingsSearchEntry(
        title: "Chrome Web Store", detail: "Find extensions to add to Ray", keywords: ["install extension", "add ons", "store"]),
      SettingsSearchEntry(
        title: "Load unpacked extension", detail: "For developers: a folder with a manifest.json",
        keywords: ["developer mode", "unpacked", "manifest"]),
    ]
    if AnySettingKey.showsUnbuilt {
      add.append(SettingsSearchEntry(
        title: "Add from a link", detail: "A Chrome Web Store link or an extension's ID", keywords: ["install extension", "url", "id"]))
    }
    return [
      SettingsSection(
        id: "extensions.installed", title: "Installed", place: .top, view: installedList,
        search: [
          SettingsSearchEntry(
            title: "Installed extensions", detail: "Turn extensions on or off, their site access, options and Remove",
            keywords: ["add ons", "plugins", "site access", "private windows", "remove extension", "options"]),
        ]),
      SettingsSection(id: "extensions.add", title: "Add extensions", place: .top, view: addList, search: add),
    ]
  }

  // MARK: Installed

  /// Now, and again a moment later: the engine reloads an extension after some changes (private windows, Reload), and
  /// there's no event for when it's back.
  private func reloadTwice() {
    reload()
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.reload() }
  }

  func reload(then done: (() -> Void)? = nil) {
    guard let profile = SettingsPages.profile else { return }
    generation += 1
    let current = generation
    EngineCalls.call("ac_extensions_list", profile: profile) { [weak self] reply in
      guard let self, current == self.generation else { return }
      let list = reply?["extensions"] as? [[String: Any]] ?? []
      self.items = list.compactMap(Self.item).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
      self.showInstalled()
      done?()
    }
  }

  private static func item(_ info: [String: Any]) -> Item? {
    guard let id = info["id"] as? String, id.count == 32, let name = info["name"] as? String else { return nil }
    let options = (info["optionsUrl"] as? String).flatMap { $0.hasPrefix("chrome-extension://\(id)/") ? $0 : nil }
    return Item(
      id: id, name: name, version: info["version"] as? String ?? "", description: info["description"] as? String ?? "",
      enabled: info["enabled"] as? Bool ?? false, icon: info["icon"] as? String, siteAccess: info["siteAccess"] as? String,
      sites: info["sites"] as? [String] ?? [], optionsURL: options, unpacked: info["location"] as? String == "UNPACKED",
      path: info["path"] as? String, incognito: info["incognito"] as? Bool ?? false,
      mayModify: (info["mayModify"] as? Bool ?? true) && !(info["blockedByPolicy"] as? Bool ?? false),
      permissions: info["permissions"] as? [String] ?? [], errors: info["errors"] as? [String] ?? [])
  }

  private func showInstalled() {
    rows = [:]
    switches = [:]
    privateSwitches = [:]
    accessPopUps = [:]
    optionButtons = [:]
    reloadButtons = [:]
    removeButtons = [:]
    guard let items, !items.isEmpty else {
      installedList.setRows([SettingsItemRow(
        key: "empty", icon: nil, title: items == nil ? " " : "No extensions yet",
        detail: items == nil ? " " : "Add some from the Chrome Web Store.",
        showsIcon: false)])
      return
    }
    installedList.setRows(items.map(row))
  }

  private func row(_ item: Item) -> SettingsItemRow {
    let id = item.id
    let toggle = RaySwitch()
    toggle.isOn = item.enabled
    toggle.isEnabled = item.mayModify
    toggle.setAccessibilityLabel("\(item.name) on")
    toggle.onChange = { [weak self, weak toggle] on in
      guard let toggle, toggle.isEnabled else { toggle?.isOn = !on; return }
      self?.setEnabled(id, on)
    }
    switches[id] = toggle

    var details: [NSView] = []
    if let access = item.siteAccess {
      let popUp = SettingsPopUp(
        [("On click", "onClick"), ("On specific sites", "specificSites"), ("On all sites", "allSites")],
        selected: Self.accessValue(access))
      popUp.isEnabled = item.mayModify
      popUp.setAccessibilityLabel("Site access for \(item.name)")
      popUp.onChoose = { [weak self] value in self?.configure(id, ["siteAccess": value]) }
      accessPopUps[id] = popUp
      let sites = item.sites.prefix(5).joined(separator: ", ") + (item.sites.count > 5 ? "…" : "")
      let detail = access == "ON_SPECIFIC_SITES" && !sites.isEmpty
        ? "Reads and changes \(sites)."
        : access == "ON_CLICK" ? "Reads and changes a site only after you click it." : "Which sites it can read and change."
      details.append(SettingsDetailRow(title: "Site access", detail: detail, control: popUp))
    }
    let privately = RaySwitch()
    privately.isOn = item.incognito
    privately.isEnabled = item.mayModify
    privately.setAccessibilityLabel("Allow \(item.name) in private windows")
    privately.onChange = { [weak self, weak privately] on in
      guard let privately, privately.isEnabled else { privately?.isOn = !on; return }
      self?.configure(id, ["incognito": on])
    }
    privateSwitches[id] = privately
    details.append(SettingsDetailRow(
      title: "Allow in private windows", detail: "It can see what you do there.",
      control: privately))
    if !item.permissions.isEmpty {
      details.append(SettingsDetailRow(
        title: "What it can do", detail: item.permissions.prefix(8).joined(separator: "\n"), control: nil))
    }
    if !item.errors.isEmpty {
      details.append(SettingsDetailRow(title: "Errors", detail: item.errors.prefix(3).joined(separator: "\n"), control: nil))
    }
    var buttons: [NSView] = []
    if let options = item.optionsURL {
      let button = SettingsButton("Options") { SettingsPages.open(options) }
      optionButtons[id] = button
      buttons.append(button)
    }
    if item.unpacked {
      let button = SettingsButton("Reload") { [weak self] in self?.reloadExtension(id) }
      reloadButtons[id] = button
      buttons.append(button)
    }
    let remove = SettingsButton("Remove…", destructive: true) { [weak self, weak installedList] in
      self?.confirmRemove(item, in: installedList?.window)
    }
    remove.isEnabled = item.mayModify
    removeButtons[id] = remove
    buttons.append(remove)
    details.append(SettingsButtonRow(buttons))
    details.append(SettingsDetailRow(
      title: "ID \(id)", detail: item.unpacked ? "Unpacked from \(item.path ?? "a folder")" : "", control: nil))
    let body = SettingsDynamicList()
    body.setRows(details)

    var line = item.version.isEmpty ? "" : "Version \(item.version)"
    if let problem = problems[id] {
      line = problem
    } else if !item.enabled, let error = item.errors.first {
      line = error
    } else if !item.description.isEmpty {
      line += (line.isEmpty ? "" : " · ") + item.description
    }
    let icon = item.icon.flatMap(ExtensionsController.image(fromDataURL:))
      ?? NSImage(systemSymbolName: "puzzlepiece.extension", accessibilityDescription: nil)
    let made = SettingsItemRow(
      key: id, icon: icon, title: item.name, detail: line, controls: [toggle], body: body, open: opened.contains(id))
    made.dimmed = !item.enabled
    made.onToggle = { [weak self] open in
      if open { self?.opened.insert(id) } else { self?.opened.remove(id) }
    }
    rows[id] = made
    return made
  }

  private static func accessValue(_ chrome: String) -> String {
    switch chrome {
    case "ON_CLICK": return "onClick"
    case "ON_SPECIFIC_SITES": return "specificSites"
    default: return "allSites"
    }
  }

  private func setEnabled(_ id: String, _ on: Bool) {
    guard let profile = SettingsPages.profile else { return }
    problems[id] = nil
    EngineCalls.call("ac_extensions_set_enabled", profile: profile, args: ["id": id, "enabled": on]) { [weak self] reply in
      if let error = reply?["error"] as? String { self?.problems[id] = Self.plain(error) }
      self?.reloadTwice()
    }
  }

  private func configure(_ id: String, _ args: [String: Any]) {
    guard let profile = SettingsPages.profile else { return }
    EngineCalls.call("ac_extensions_configure", profile: profile, args: args.merging(["id": id]) { a, _ in a }) {
      [weak self] reply in
      if let error = reply?["error"] as? String { self?.problems[id] = Self.plain(error) }
      self?.reloadTwice()
    }
  }

  private func reloadExtension(_ id: String) {
    guard let profile = SettingsPages.profile else { return }
    EngineCalls.call("ac_extensions_reload", profile: profile, args: ["id": id]) { [weak self] _ in self?.reloadTwice() }
  }

  private func confirmRemove(_ item: Item, in window: NSWindow?) {
    let name = Self.plain(item.name)
    SettingsConfirm.ask(
      "Remove “\(name)”?",
      detail: "Its settings and data go too. ID \(item.id)",
      action: "Remove", in: window) { [weak self] in self?.remove(item.id) }
  }

  private func remove(_ id: String) {
    guard let profile = SettingsPages.profile else { return }
    EngineCalls.call("ac_extensions_uninstall", profile: profile, args: ["id": id]) { [weak self] reply in
      if let error = reply?["error"] as? String { self?.problems[id] = Self.plain(error) }
      self?.opened.remove(id)
      self?.reload()
    }
  }

  // MARK: Adding

  private func showAdd() {
    let store = SettingsButton("Open Web Store") { SettingsPages.open(Self.store) }
    storeButton = store
    var rows: [NSView] = [SettingsItemRow(
      key: "store", icon: nil, title: "Chrome Web Store",
      detail: "Add to Chrome installs in Ray.", controls: [store], showsIcon: false)]
    let more = MoreLine()
    more.expanded = moreShown
    more.onClick = { [weak self] in
      guard let self else { return }
      self.moreShown.toggle()
      self.showAdd()
    }
    rows.append(more)
    linkRowShown = false
    if moreShown {
      let choose = SettingsButton("Choose Folder…") { [weak self, weak addList] in self?.chooseFolder(in: addList?.window) }
      rows.append(SettingsItemRow(
        key: "unpacked", icon: nil, title: "Load unpacked extension",
        detail: lastInstall ?? "For developers: a folder with a manifest.json.", controls: [choose], showsIcon: false))
      // Not built: the engine can't install by a Web Store ID yet. Test builds show the row, as for unbuilt settings.
      if AnySettingKey.showsUnbuilt {
        let field = NSTextField(string: "")
        field.placeholderString = "chromewebstore.google.com/detail/…"
        field.isEnabled = false
        field.frame.size = NSSize(width: 210, height: 22)
        let add = SettingsButton("Add")
        add.isEnabled = false
        rows.append(SettingsItemRow(
          key: "link", icon: nil, title: "Add from a link", detail: "A store link or an extension ID.",
          controls: [FixedSize(field, NSSize(width: 210, height: 22)), add], showsIcon: false))
        linkRowShown = true
      }
    }
    addList.setRows(rows)
  }

  private func chooseFolder(in window: NSWindow?) {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.prompt = "Load"
    panel.message = "Choose an extension's folder (the one with its manifest.json)."
    let done: (NSApplication.ModalResponse) -> Void = { [weak self] response in
      guard response == .OK, let url = panel.url else { return }
      self?.install(url.path)
    }
    if let window { panel.beginSheetModal(for: window, completionHandler: done) } else { done(panel.runModal()) }
  }

  /// Chrome's Load unpacked: the folder's extension installs (or reloads, if it already is) and opens in the list.
  private func install(_ path: String) {
    guard let profile = SettingsPages.profile, path.hasPrefix("/") else { return }
    EngineCalls.call("ac_extensions_install", profile: profile, args: ["path": path]) { [weak self] reply in
      guard let self else { return }
      if let id = reply?["id"] as? String {
        self.lastInstall = nil
        self.opened.insert(id)
      } else {
        self.lastInstall = "Couldn't load it: " + Self.plain(reply?["error"] as? String ?? "not an extension")
      }
      self.showAdd()
      self.reload()
    }
  }

  // MARK: Helpers

  /// Text from an extension or the engine, on one line and not too long.
  private static func plain(_ text: String, limit: Int = 120) -> String {
    let single = text.components(separatedBy: .newlines).joined(separator: " ")
    return single.count > limit ? String(single.prefix(limit)) + "…" : single
  }

  // MARK: Tests

  /// `extpane list|reload|open <id>|toggle <id>|access <id> <onClick|specificSites|allSites>|private <id>|options <id>|
  /// reload <id>|remove <id>|confirm accept|cancel|store|more|unpacked <path>`: the list as JSON, or a press as a click
  /// would make it (`unpacked` stands for the folder picker's answer).
  static func test(_ argument: String) -> String {
    guard let pane = SettingsPanes.content(for: .extensions) as? ExtensionsPaneContent else { return "no pane" }
    let words = argument.split(separator: " ", maxSplits: 2).map(String.init)
    func ok(_ done: Bool) -> String { done ? "ok" : "no such control" }
    let id = words.count > 1 ? words[1] : ""
    switch words.first {
    case "list": return SettingsPages.json(pane.debug)
    case "refresh": pane.reload()
    case "open":
      guard let row = pane.rows[id] else { return "no such extension" }
      if !row.isOpen { row.toggle() }
    case "toggle":
      guard let toggle = pane.switches[id], toggle.isEnabled else { return "no such control" }
      toggle.press()
    case "access":
      guard words.count == 3 else { return "usage: extpane access <id> onClick|specificSites|allSites" }
      return ok(pane.accessPopUps[id]?.choose(words[2]) ?? false)
    case "private":
      guard let toggle = pane.privateSwitches[id], toggle.isEnabled else { return "no such control" }
      toggle.press()
    case "options": return ok(pane.optionButtons[id]?.press() ?? false)
    case "reload": return ok(pane.reloadButtons[id]?.press() ?? false)
    case "remove": return ok(pane.removeButtons[id]?.press() ?? false)
    case "confirm":
      guard words.count == 2 else { return SettingsPages.json(SettingsConfirm.debug ?? [:]) }
      return SettingsConfirm.answer(accept: words[1] == "accept")
    case "store": return ok(pane.storeButton?.press() ?? false)
    case "more":
      if !pane.moreShown {
        pane.moreShown = true
        pane.showAdd()
      }
    case "unpacked":
      guard words.count >= 2 else { return "usage: extpane unpacked <path>" }
      pane.install(words.dropFirst().joined(separator: " "))
    default: return "usage: extpane list|refresh|open|toggle|access|private|options|reload|remove|confirm|store|more|unpacked"
    }
    return "ok"
  }

  private var debug: [String: Any] {
    let empty = (installedList.rows.first as? SettingsItemRow).flatMap { $0.key == "empty" ? "\($0.title) \($0.detail)" : nil }
    return [
      "loaded": items != nil,
      "extensions": (items ?? []).map { item -> [String: Any] in
        [
          "id": item.id, "name": item.name, "version": item.version, "description": item.description,
          "enabled": item.enabled, "switchOn": switches[item.id]?.isOn ?? NSNull(),
          "hasIcon": item.icon.flatMap(ExtensionsController.image(fromDataURL:)) != nil,
          "siteAccess": item.siteAccess ?? NSNull(), "access": accessPopUps[item.id]?.selectedValue ?? NSNull(),
          "incognito": item.incognito, "options": item.optionsURL != nil, "unpacked": item.unpacked,
          "open": rows[item.id]?.isOpen ?? false, "detail": rows[item.id]?.detail ?? "",
          "removable": removeButtons[item.id]?.isEnabled ?? false,
        ]
      },
      "empty": empty ?? NSNull(),
      "more": moreShown, "linkRow": linkRowShown, "lastInstall": lastInstall ?? NSNull(),
      "confirm": SettingsConfirm.debug ?? NSNull(),
    ]
  }
}

/// A view that keeps the size it was given (a text field, which would otherwise size itself to its text).
final class FixedSize: NSView {
  private let size: NSSize

  init(_ view: NSView, _ size: NSSize) {
    self.size = size
    super.init(frame: NSRect(origin: .zero, size: size))
    view.frame = bounds
    view.autoresizingMask = [.width, .height]
    addSubview(view)
  }

  required init?(coder: NSCoder) { fatalError() }

  override var fittingSize: NSSize { size }
}
