import AppKit

// Chrome's bookmarks, as Ray shows them: the engine keeps them in Chrome's model (imports write there, and so do
// extensions through `chrome.bookmarks`), and Ray reads the whole tree (`ac_bookmarks_tree`), changes it with ops
// (`ac_bookmarks_apply`: add, move, update, remove) and reloads on the engine's `bookmarks.changed` (`ac_bookmarks_watch`).
// Always the normal profile's: Chrome has none for a private window, which shows the same ones.
//
// Shown in three places: the Bookmarks panel from the sidebar's footer (`BookmarksPanel.swift`, ⌥⌘B), the Bookmarks
// menu in the menu bar (`BookmarksMenu`, below) and the command bar's page rows ("Bookmark" on the right).

// MARK: Store

final class Bookmark {
  /// The engine's id: a lowercase UUID, or "bar" / "other" for the two roots.
  let id: String
  let title: String
  /// nil for a folder.
  let url: String?
  let added: Double
  fileprivate(set) var children: [Bookmark] = []
  fileprivate(set) weak var parent: Bookmark?

  init(id: String, title: String, url: String?, added: Double) {
    self.id = id
    self.title = title
    self.url = url
    self.added = added
  }

  var isFolder: Bool { url == nil }
  var isRoot: Bool { id == Bookmarks.barID || id == Bookmarks.otherID }
  /// What a row shows: the title, else the address.
  var shownTitle: String { title.isEmpty ? (url.map(AddressInput.display(for:)) ?? "") : title }
  /// Every page in it, folders inside included, in order.
  var links: [Bookmark] { children.flatMap { $0.isFolder ? $0.links : [$0] } }
  var index: Int { parent?.children.firstIndex { $0 === self } ?? 0 }
  /// Only these open or pin, as Ray opens any address: never `javascript:` (bookmarklets), `data:` or `file:`.
  var opens: Bool { url.map(BrowserWindowController.isPinnable) ?? false }
}

final class Bookmarks {
  static let shared = Bookmarks()
  static let didChange = Notification.Name("RayBookmarksDidChange")
  static let barID = "bar"
  static let otherID = "other"

  /// The bookmarks bar's folder (Chrome's; "Imported from …" lands here) and Other Bookmarks.
  private(set) var bar: Bookmark?
  private(set) var other: Bookmark?
  private(set) var loaded = false
  /// Bumped on every reload, so the menu rebuilds only after a change.
  private(set) var version = 0
  private var byID: [String: Bookmark] = [:]
  private var byURL: [String: Bookmark] = [:]
  private var started = false
  private var reloading = false
  private var reloadAgain = false
  let favicons = FaviconCache()

  var profile: RayCoreProfile? { RayCoreEngine.shared?.defaultProfile }

  /// Reads the tree and follows the engine's changes from now on (once; the first window starts it).
  func start() {
    guard !started, let profile else { return }
    started = true
    EngineEvents.on("bookmarks.changed") { [weak self] payload in
      guard let self, (payload["profile"] as? String).map({ $0 == self.profile?.path }) ?? true else { return }
      self.reload()
    }
    EngineCalls.call("ac_bookmarks_watch", profile: profile) { _ in }
    reload()
  }

  func reload(then done: (() -> Void)? = nil) {
    guard let profile else { return }
    if reloading {
      reloadAgain = true
      return
    }
    reloading = true
    EngineCalls.call("ac_bookmarks_tree", profile: profile) { [weak self] reply in
      guard let self else { return }
      self.reloading = false
      if let reply, let bar = reply["bar"] as? [String: Any], let other = reply["other"] as? [String: Any] {
        self.adopt(bar: bar, other: other)
      }
      done?()
      if self.reloadAgain {
        self.reloadAgain = false
        self.reload()
      }
    }
  }

  private func adopt(bar: [String: Any], other: [String: Any]) {
    var byID: [String: Bookmark] = [:]
    var byURL: [String: Bookmark] = [:]
    func node(_ value: [String: Any], id forced: String?, depth: Int) -> Bookmark? {
      guard depth < 64, let id = forced ?? value["id"] as? String else { return nil }
      let folder = value["k"] as? String == "f"
      let made = Bookmark(id: id, title: value["t"] as? String ?? "", url: folder ? nil : value["u"] as? String ?? "",
                              added: value["a"] as? Double ?? 0)
      if folder {
        made.children = (value["c"] as? [[String: Any]] ?? []).compactMap { node($0, id: nil, depth: depth + 1) }
        made.children.forEach { $0.parent = made }
      } else if let url = made.url, byURL[url] == nil {
        byURL[url] = made
      }
      byID[id] = made
      return made
    }
    self.bar = node(bar, id: Self.barID, depth: 0)
    self.other = node(other, id: Self.otherID, depth: 0)
    self.byID = byID
    self.byURL = byURL
    loaded = true
    version += 1
    NotificationCenter.default.post(name: Self.didChange, object: self)
  }

  func node(_ id: String) -> Bookmark? { byID[id] }
  /// The first bookmark of a page (an exact address).
  func bookmark(for url: String) -> Bookmark? { byURL[url] }
  /// Every page bookmarked, the bar's first, then Other Bookmarks'.
  var allLinks: [Bookmark] { (bar?.links ?? []) + (other?.links ?? []) }

  /// The pages the command bar matches (only ones Ray opens), made once per change. Private windows too, as Chrome's
  /// incognito omnibox offers bookmarks (not history).
  var barItems: [BookmarkItem] {
    if barItemsVersion != version {
      barItemsVersion = version
      cachedBarItems = allLinks.filter(\.opens).compactMap { node in node.url.map { BookmarkItem(url: $0, title: node.title) } }
    }
    return cachedBarItems
  }
  private var cachedBarItems: [BookmarkItem] = []
  private var barItemsVersion = -1

  // MARK: Changes

  /// Sends ops to the engine, then reads the tree again (`done` after that, with the new tree in place).
  func apply(_ ops: [[String: Any]], then done: (() -> Void)? = nil) {
    guard let profile, !ops.isEmpty else { return }
    EngineCalls.call("ac_bookmarks_apply", profile: profile, args: ["ops": ops]) { [weak self] _ in
      self?.reload(then: done)
    }
  }

  static func newID() -> String { UUID().uuidString.lowercased() }

  @discardableResult
  func add(url: String, title: String, in parent: String = Bookmarks.barID, at index: Int? = nil,
           then done: ((String) -> Void)? = nil) -> String {
    let id = Self.newID()
    var op: [String: Any] = ["op": "add", "id": id, "parent": parent, "k": "u", "u": url, "t": title]
    if let index { op["index"] = index }
    apply([op]) { done?(id) }
    return id
  }

  /// A folder, with pages in it (`links`: address and title).
  @discardableResult
  func addFolder(_ title: String, in parent: String = Bookmarks.barID, links: [(url: String, title: String)] = [],
                 then done: ((String) -> Void)? = nil) -> String {
    let id = Self.newID()
    var ops: [[String: Any]] = [["op": "add", "id": id, "parent": parent, "k": "f", "t": title]]
    for link in links {
      ops.append(["op": "add", "id": Self.newID(), "parent": id, "k": "u", "u": link.url, "t": link.title])
    }
    apply(ops) { done?(id) }
    return id
  }

  func rename(_ id: String, to title: String) {
    guard let node = node(id), !node.isRoot, node.title != title else { return }
    apply([["op": "update", "id": id, "t": title]])
  }

  func move(_ id: String, to parent: String, at index: Int) {
    apply([["op": "move", "id": id, "parent": parent, "index": index]])
  }

  /// What a delete took away, to put back (same ids, same place) for Undo.
  struct Removed {
    let ops: [[String: Any]]
    let title: String
  }

  func remove(_ id: String) -> Removed? {
    guard let node = node(id), !node.isRoot, let parent = node.parent else { return nil }
    var ops: [[String: Any]] = []
    func readd(_ node: Bookmark, in parent: String, at index: Int?) {
      var op: [String: Any] = ["op": "add", "id": node.id, "parent": parent, "t": node.title, "a": node.added,
                               "k": node.isFolder ? "f" : "u"]
      if let url = node.url { op["u"] = url }
      if let index { op["index"] = index }
      ops.append(op)
      node.children.forEach { readd($0, in: node.id, at: nil) }
    }
    readd(node, in: parent.id, at: node.index)
    apply([["op": "remove", "id": id]])
    return Removed(ops: ops, title: node.shownTitle)
  }

  func restore(_ removed: Removed) { apply(removed.ops) }
}

// MARK: Menu

/// The menu bar's Bookmarks menu: its commands (AppController's, so Settings › Shortcuts and the command bar list
/// them), then the bookmarks bar's pages and folders and Other Bookmarks, each folder a submenu ending with "Open All"
/// and "Add to Pinned". Filled when it opens, rebuilt only after the bookmarks change.
final class BookmarksMenu: NSObject, NSMenuDelegate, NSMenuItemValidation {
  static let shared = BookmarksMenu()
  /// The menu bar's Bookmarks menu, and how many commands at its top stay.
  private weak var top: NSMenu?
  private var fixedCount = 0
  private var builtVersion = -1
  private let iconSize = NSSize(width: 16, height: 16)

  func install(in menu: NSMenu) {
    top = menu
    fixedCount = menu.items.count
    menu.delegate = self
  }

  private var current: BrowserWindowController? { AppController.shared.current }

  func menuNeedsUpdate(_ menu: NSMenu) {
    if menu === top {
      fillTop(menu)
    } else if let id = folderID(of: menu), let folder = Bookmarks.shared.node(id) {
      fill(menu, with: folder)
    }
  }

  /// Keys: only the commands at the top have any. Answering here keeps AppKit from filling every folder's submenu to
  /// look for keys on each key press that reaches the menu.
  func menuHasKeyEquivalent(_ menu: NSMenu, for event: NSEvent, target: AutoreleasingUnsafeMutablePointer<AnyObject?>,
                            action: UnsafeMutablePointer<Selector?>) -> Bool {
    guard menu === top, let pressed = KeyCombo(event: event) else { return false }
    for item in menu.items.prefix(fixedCount) where KeyCombo(item: item) == pressed {
      guard (item.target as? NSMenuItemValidation)?.validateMenuItem(item) ?? true else { return false }
      target.pointee = item.target
      action.pointee = item.action
      return true
    }
    return false
  }

  private var folderIDs: [ObjectIdentifier: String] = [:]
  private func folderID(of menu: NSMenu) -> String? { folderIDs[ObjectIdentifier(menu)] }

  private func fillTop(_ menu: NSMenu) {
    let store = Bookmarks.shared
    guard builtVersion != store.version || menu.items.count == fixedCount else { return }
    builtVersion = store.version
    while menu.items.count > fixedCount { menu.removeItem(at: fixedCount) }
    folderIDs = [:]
    let bar = store.bar?.children ?? []
    let other = store.other
    guard !bar.isEmpty || other?.children.isEmpty == false else { return }
    menu.addItem(.separator())
    bar.forEach { menu.addItem(item(for: $0)) }
    if let other, !other.children.isEmpty {
      if !bar.isEmpty { menu.addItem(.separator()) }
      menu.addItem(item(for: other, title: "Other Bookmarks"))
    }
    loadIcons(bar)
  }

  private func fill(_ menu: NSMenu, with folder: Bookmark) {
    menu.removeAllItems()
    folder.children.forEach { menu.addItem(item(for: $0)) }
    if folder.children.isEmpty {
      let empty = NSMenuItem(title: "Empty", action: nil, keyEquivalent: "")
      empty.isEnabled = false
      menu.addItem(empty)
    }
    let links = folder.links.filter(\.opens)
    if !links.isEmpty {
      menu.addItem(.separator())
      menu.addItem(command("Open All (\(links.count))", #selector(openAll(_:)), folder.id))
      if current?.isPrivate == false { menu.addItem(command("Add to Pinned", #selector(pinFolder(_:)), folder.id)) }
    }
    loadIcons(folder.children)
  }

  private func item(for node: Bookmark, title: String? = nil) -> NSMenuItem {
    let entry = NSMenuItem(title: Self.menuTitle(title ?? node.shownTitle), action: nil, keyEquivalent: "")
    if node.isFolder {
      let submenu = NSMenu(title: entry.title)
      submenu.delegate = self
      folderIDs[ObjectIdentifier(submenu)] = node.id
      entry.submenu = submenu
      entry.image = Self.folderImage
    } else {
      entry.action = #selector(open(_:))
      entry.target = self
      entry.representedObject = node.id
      // The host only: a path or query can carry what a page put there.
      entry.toolTip = node.url.map(AddressInput.host(of:)).flatMap { $0.isEmpty ? nil : $0 }
      entry.image = node.url.flatMap(Bookmarks.shared.favicons.image(for:)).map(menuIcon) ?? Self.globe
    }
    return entry
  }

  private func command(_ title: String, _ action: Selector, _ id: String) -> NSMenuItem {
    let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
    entry.target = self
    entry.representedObject = id
    return entry
  }

  /// Favicons for the pages shown; items already in the menu take theirs when they come.
  private func loadIcons(_ nodes: [Bookmark]) {
    guard let profile = Bookmarks.shared.profile else { return }
    let pages = nodes.compactMap(\.url)
    Bookmarks.shared.favicons.load(pages, profile: profile) { [weak self] in
      // The next time the menu opens, its items have them.
      self?.builtVersion = -1
    }
  }

  private func menuIcon(_ image: NSImage) -> NSImage {
    let sized = NSImage(size: iconSize, flipped: false) { rect in
      image.draw(in: rect)
      return true
    }
    return sized
  }

  private static let globe: NSImage? = {
    let image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)?
      .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
    image?.isTemplate = true
    return image
  }()
  private static let folderImage: NSImage? = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)?
    .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))

  /// One line, at most 60 characters (Chrome's menu cuts titles near there).
  static func menuTitle(_ title: String) -> String {
    let line = title.components(separatedBy: .newlines).joined(separator: " ")
    return line.count > 60 ? String(line.prefix(59)) + "…" : line
  }

  /// A bookmarklet (or any address Ray never opens) stays greyed.
  func validateMenuItem(_ item: NSMenuItem) -> Bool {
    guard item.action == #selector(open(_:)) else { return true }
    return (item.representedObject as? String).flatMap(Bookmarks.shared.node)?.opens ?? false
  }

  @objc func open(_ sender: NSMenuItem) {
    guard let id = sender.representedObject as? String, let node = Bookmarks.shared.node(id), node.opens,
          let url = node.url else { return }
    let controller = current ?? AppController.shared.openMainWindow()
    controller?.openBookmark(url, foreground: true)
  }

  @objc func openAll(_ sender: NSMenuItem) {
    guard let id = sender.representedObject as? String, let node = Bookmarks.shared.node(id) else { return }
    let controller = current ?? AppController.shared.openMainWindow()
    controller?.openBookmarks(node)
  }

  @objc func pinFolder(_ sender: NSMenuItem) {
    guard let id = sender.representedObject as? String, let node = Bookmarks.shared.node(id) else { return }
    current?.pinBookmark(node)
  }

  /// For tests: the menu's titles as the user would see them ("~" greyed, "Title > a|b" for a submenu, one level).
  func debugItems() -> [String] {
    guard let menu = top else { return [] }
    menuNeedsUpdate(menu)
    return menu.items.map { item in
      if item.isSeparatorItem { return "-" }
      let enabled = item.submenu != nil || item.action == nil
        ? item.isEnabled : (item.target as? NSMenuItemValidation)?.validateMenuItem(item) ?? true
      var title = (enabled ? "" : "~") + item.title
      if let submenu = item.submenu {
        menuNeedsUpdate(submenu)
        title += " > " + submenu.items.map { $0.isSeparatorItem ? "-" : $0.title }.joined(separator: "|")
      }
      return title
    }
  }

  /// For tests: chooses a bookmark item by its path ("Imported from Chrome > Linear").
  func debugPress(_ path: String) -> Bool {
    guard var menu = top else { return false }
    menuNeedsUpdate(menu)
    let parts = path.components(separatedBy: " > ")
    for (index, part) in parts.enumerated() {
      guard let item = menu.items.first(where: { $0.title == part }) else { return false }
      if index == parts.count - 1 {
        guard let action = item.action, (item.target as? NSMenuItemValidation)?.validateMenuItem(item) ?? true else { return false }
        return NSApp.sendAction(action, to: item.target, from: item)
      }
      guard let submenu = item.submenu else { return false }
      menuNeedsUpdate(submenu)
      menu = submenu
    }
    return false
  }
}
