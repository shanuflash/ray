import AppKit

final class SidebarEntry: Codable {
  enum Kind: String, Codable {
    case favorite
    case pinned
    case today
    /// A folder in the pinned section: no page of its own, a title, and the pinned items whose `parentID` is its id.
    case folder
  }

  let id: UUID
  var kind: Kind
  var pinnedURL: String?
  var url: String
  var title: String
  var lastActive: Date
  var tab: RayCoreTab?
  /// The pinned folder this item sits in; nil at the top level (and for favorites and today's tabs).
  var parentID: UUID?
  /// For folders: whether its items show. Optional so older files still load.
  var isOpen: Bool?

  // MARK: Names and saved fields

  private enum CodingKeys: String, CodingKey {
    case id, kind, pinnedURL, url, title, customTitle, lastActive, parentID, isOpen
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
  /// View › Show Address Bar on Page (on unless turned off).
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

  /// `pinned` holds folders and tabs in tree order: each folder is followed by everything inside it.
  func depth(of entry: SidebarEntry) -> Int {
    var depth = 0
    var parent = entry.parentID
    while let id = parent, let folder = pinned.first(where: { $0.id == id }), depth < 64 {
      depth += 1
      parent = folder.parentID
    }
    return depth
  }

  func isInside(_ entry: SidebarEntry, _ folder: SidebarEntry) -> Bool {
    var parent = entry.parentID
    var steps = 0
    while let id = parent, steps < 64 {
      if id == folder.id { return true }
      parent = pinned.first { $0.id == id }?.parentID
      steps += 1
    }
    return false
  }

  /// The entry and, for a folder, everything inside it.
  func block(of entry: SidebarEntry) -> [SidebarEntry] {
    guard entry.isFolder else { return [entry] }
    return [entry] + pinned.filter { isInside($0, entry) }
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

  func archiveStaleToday(now: Date = Date()) {
    today.removeAll { !$0.isLive && $0.id != activeEntryID && now.timeIntervalSince($0.lastActive) > Self.todayLifetime }
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
