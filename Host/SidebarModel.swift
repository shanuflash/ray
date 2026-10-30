import AppKit

final class SidebarEntry: Codable {
  enum Kind: String, Codable {
    case favorite
    case pinned
    case today
    /// A folder: no page of its own, a title, and the items whose `parentID` is its id. In `pinned` it nests; in
    /// `today` it's one level and is a Chrome tab group underneath (`TabGroupSync`).
    case folder
  }

  let id: UUID
  var kind: Kind
  var pinnedURL: String?
  var url: String
  var title: String
  var lastActive: Date
  var tab: RayCoreTab?
  /// The folder this item sits in (in its own section); nil at the top level and for favorites.
  var parentID: UUID?
  /// For folders: whether its items show. Optional so older files still load.
  var isOpen: Bool?
  /// For folders: one of `FolderLook.colors`, nil for none.
  var color: String?
  /// For folders: "sf:<symbol>" or an emoji shown on the folder's flap, nil for none.
  var icon: String?
  /// For Today folders: the Chrome tab group they are now (its id this run), never saved.
  var groupToken: String?

  // MARK: Names and saved fields

  private enum CodingKeys: String, CodingKey {
    case id, kind, pinnedURL, url, title, customTitle, lastActive, parentID, isOpen, color, icon
  }

  /// The tab's own name, from the user's Rename… (or Arc's, on import), shown in place of the page's title. Never
  /// set from a page: page titles go to `title` only. Nil: the page's title shows. Optional so older files still load.
  var customTitle: String?
  static let nameLimit = 200

  /// A name as the user typed it: one line of plain text, trimmed, at most `nameLimit` characters; nil when nothing
  /// is left (the page's title shows again).
  static func name(from text: String) -> String? {
    let scalars = text.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : Character($0) }
    let line = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
    return line.isEmpty ? nil : String(line.prefix(nameLimit))
  }

  var isFolder: Bool { kind == .folder }

  static func folder(_ title: String, in parent: UUID?) -> SidebarEntry {
    let folder = SidebarEntry(kind: .folder, url: "", title: title)
    folder.pinnedURL = nil
    folder.parentID = parent
    folder.isOpen = true
    return folder
  }

  init(kind: Kind, url: String, title: String = "") {
    id = UUID()
    self.kind = kind
    self.url = url
    self.title = title
    pinnedURL = kind == .today ? nil : url
    lastActive = Date()
  }

  var isLive: Bool { tab.map { !$0.closed } ?? false }

  var currentURL: String {
    if let tab, !tab.closed, !tab.url.isEmpty { return tab.url }
    return url
  }

  var displayTitle: String {
    if let customTitle, !isFolder { return customTitle }
    return pageTitle
  }

  /// The page's own title (the last one it had, while unloaded), or its address when it has none.
  var pageTitle: String {
    if let tab, !tab.closed, !tab.title.isEmpty { return tab.title }
    return title.isEmpty ? AddressInput.display(for: currentURL) : title
  }

  var host: String {
    let host = URLComponents(string: currentURL)?.host ?? ""
    return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
  }

  func remember() {
    guard let tab, !tab.closed else { return }
    if !tab.url.isEmpty { url = tab.url }
    if !tab.title.isEmpty { title = tab.title }
  }

  // MARK: Pinned page

  /// Whether a pinned tab or favorite shows another page than its own (the row's "/", Back to Pinned URL). Arc's
  /// rule: the same address up to its path is the pinned page, whatever its query or fragment (`for-you?tab=assigned`
  /// is still `for-you`).
  var isAwayFromPinned: Bool {
    guard let pinnedURL else { return false }
    return Self.page(currentURL) != Self.page(pinnedURL)
  }

  private static func page(_ url: String) -> String {
    var components = URLComponents(string: url)
    components?.query = nil
    components?.fragment = nil
    var text = components?.string ?? url
    if text.hasSuffix("/") { text.removeLast() }
    return text
  }
}

final class SidebarState: Codable {
  static let todayLifetime: TimeInterval = 12 * 60 * 60

  var favorites: [SidebarEntry] = []
  var pinned: [SidebarEntry] = []
  var today: [SidebarEntry] = []
  var activeEntryID: UUID?
  var sidebarHidden = false
  /// Whether the window was full screen, to reopen that way. Optional so older files still load.
  var fullScreen: Bool?
  /// Where View › Show Address Bar on Page used to live. It's `RaySettings.pageAddressBar` now; an older file's
  /// value moves there once on load and is cleared.
  var pageToolbar: Bool?
  /// Where View › Show Full Address used to live. It's `RaySettings.minimalURL` now (minimal = !fullAddress); an
  /// older file's value moves there once on load and is cleared.
  var fullAddress: Bool?

  var allEntries: [SidebarEntry] { favorites + pinned + today }

  func entry(for tab: RayCoreTab) -> SidebarEntry? {
    allEntries.first { $0.tab === tab }
  }

  func entry(id: UUID) -> SidebarEntry? {
    allEntries.first { $0.id == id }
  }

  func remove(_ entry: SidebarEntry) {
    favorites.removeAll { $0 === entry }
    pinned.removeAll { $0 === entry }
    today.removeAll { $0 === entry }
    if activeEntryID == entry.id { activeEntryID = nil }
  }

  // MARK: Pinned folders

  /// `pinned` holds folders and tabs in tree order: each folder is followed by everything inside it. `today` does too,
  /// one level deep.
  func section(of entry: SidebarEntry) -> [SidebarEntry] {
    today.contains { $0 === entry } ? today : pinned
  }

  func isTodayFolder(_ entry: SidebarEntry) -> Bool {
    entry.isFolder && today.contains { $0 === entry }
  }

  var todayFolders: [SidebarEntry] { today.filter(\.isFolder) }

  func depth(of entry: SidebarEntry) -> Int {
    let list = section(of: entry)
    var depth = 0
    var parent = entry.parentID
    while let id = parent, let folder = list.first(where: { $0.id == id }), depth < 64 {
      depth += 1
      parent = folder.parentID
    }
    return depth
  }

  func isInside(_ entry: SidebarEntry, _ folder: SidebarEntry) -> Bool {
    let list = section(of: folder)
    var parent = entry.parentID
    var steps = 0
    while let id = parent, steps < 64 {
      if id == folder.id { return true }
      parent = list.first { $0.id == id }?.parentID
      steps += 1
    }
    return false
  }

  /// The entry and, for a folder, everything inside it.
  func block(of entry: SidebarEntry) -> [SidebarEntry] {
    guard entry.isFolder else { return [entry] }
    return [entry] + section(of: entry).filter { isInside($0, entry) }
  }

  /// Rebuilds a valid tree from parent links, keeping the order items appear in: drops links to missing folders or
  /// to non-folders, breaks cycles, and puts every folder's items right after it.
  func normalizePinned() {
    let folders = Set(pinned.filter(\.isFolder).map(\.id))
    for entry in pinned {
      if entry.kind != .pinned && !entry.isFolder { entry.parentID = nil }
      if let parent = entry.parentID, !folders.contains(parent) || parent == entry.id { entry.parentID = nil }
    }
    for entry in pinned where entry.parentID != nil {
      var seen: Set<UUID> = [entry.id]
      var parent = entry.parentID
      while let id = parent {
        if !seen.insert(id).inserted {
          entry.parentID = nil
          break
        }
        parent = pinned.first { $0.id == id }?.parentID
      }
    }
    var children: [UUID?: [SidebarEntry]] = [:]
    for entry in pinned { children[entry.parentID, default: []].append(entry) }
    var ordered: [SidebarEntry] = []
    func add(_ parent: UUID?) {
      for entry in children[parent] ?? [] {
        ordered.append(entry)
        if entry.isFolder { add(entry.id) }
      }
    }
    add(nil)
    pinned = ordered
  }

  /// Today's folders keep Chrome's rules: one level, each followed by its tabs, and gone once it holds no tab. A tab
  /// whose folder is missing (or isn't a Today folder) moves to the top level.
  func normalizeToday() {
    let folders = Set(today.filter(\.isFolder).map(\.id))
    for entry in today {
      if entry.isFolder || entry.parentID.map({ !folders.contains($0) }) == true { entry.parentID = nil }
      if !entry.isFolder { entry.kind = .today }
    }
    let filled = Set(today.compactMap(\.parentID))
    var ordered: [SidebarEntry] = []
    for entry in today where entry.parentID == nil {
      if entry.isFolder {
        guard filled.contains(entry.id) else { continue }
        ordered.append(entry)
        ordered += today.filter { $0.parentID == entry.id }
      } else {
        ordered.append(entry)
      }
    }
    today = ordered
  }

  func archiveStaleToday(now: Date = Date()) {
    today.removeAll {
      !$0.isFolder && !$0.isLive && $0.id != activeEntryID && now.timeIntervalSince($0.lastActive) > Self.todayLifetime
    }
    normalizeToday()
  }
}

final class SidebarStore {
  /// Nil for a private window: nothing is read or written.
  private let url: URL?
  private var pending: DispatchWorkItem?
  private let queue = DispatchQueue(label: "ray.sidebar.store", qos: .utility)

  init(directory: String?) {
    url = directory.map { URL(fileURLWithPath: $0).appendingPathComponent("Sidebar.json") }
  }

  func load() -> SidebarState? {
    guard let url, let data = try? Data(contentsOf: url),
          let state = try? JSONDecoder().decode(SidebarState.self, from: data) else { return nil }
    state.normalizePinned()
    state.normalizeToday()
    return state
  }

  func save(_ state: SidebarState) {
    guard url != nil else { return }
    pending?.cancel()
    let work = DispatchWorkItem { [weak self] in self?.write(state, now: false) }
    pending = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
  }

  func saveNow(_ state: SidebarState) {
    pending?.cancel()
    pending = nil
    write(state, now: true)
  }

  private func write(_ state: SidebarState, now: Bool) {
    guard let url else { return }
    state.allEntries.forEach { $0.remember() }
    guard let data = try? JSONEncoder().encode(state) else { return }
    if now {
      queue.sync { try? data.write(to: url, options: .atomic) }
    } else {
      queue.async { try? data.write(to: url, options: .atomic) }
    }
  }
}
