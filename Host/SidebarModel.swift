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
  // MARK: Tab use

  /// A tab a page opened behind it and never shown since, as Ardia's `unseen`: a close and the command bar pass it over
  /// until it's shown, and ⌃Tab puts it right after its opener (`switcherOrder`). Never saved.
  var unseen = false
  /// The tab whose page opened this one (a link, ⌘-click, `window.open`): Back with no history of its own closes this
  /// tab and goes back there (Ardia's "Close Tab and Go Back"). Dropped when the user types an address into it.
  /// Never saved.
  var openerID: UUID?

  /// When the tab was last used, for the command bar's open tabs: never, while it's unseen.
  var lastUsed: Date { unseen ? .distantPast : lastActive }

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

  /// `id`: a new one, or (an undo bringing a row back) the one it had.
  init(kind: Kind, url: String, title: String = "", id: UUID = UUID()) {
    self.id = id
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

  // MARK: Duplicate

  /// Duplicate's copy: a new id in the same place, with the page it's on, its pinned page, name and look; never
  /// the tab (the caller gives it the engine's duplicate) or a Chrome group.
  func duplicate() -> SidebarEntry {
    let copy = SidebarEntry(kind: kind, url: isFolder ? url : currentURL, title: title)
    if let tab, !tab.closed, !tab.title.isEmpty { copy.title = tab.title }
    copy.pinnedURL = pinnedURL
    copy.parentID = parentID
    copy.isOpen = isOpen
    copy.color = color
    copy.icon = icon
    copy.customTitle = customTitle
    return copy
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

  /// The Spaces, in the footer's order: never empty. Each has its own pinned tabs, folders and Today (Arc's).
  var spaces: [Space] = [Space(name: Space.firstName)]
  /// The Space the window shows.
  var currentSpaceID: UUID
  /// The default profile's favorites, shared by every Space on it (Arc's).
  var defaultFavorites: [SidebarEntry] = []
  /// Favorites of the other profiles, by profile directory: Arc's favorites belong to a profile, so Spaces on the same
  /// profile share them.
  var profileFavorites: [String: [SidebarEntry]] = [:]
  /// Every profile's name and colour, the default one first (`ProfileInfo`); kept in step with the Spaces'.
  var profiles: [ProfileInfo] = [ProfileInfo(directory: nil, name: ProfileInfo.defaultName)]
  var sidebarHidden = false
  /// Whether the window was full screen, to reopen that way. Optional so older files still load.
  var fullScreen: Bool?
  /// Where View › Show Address Bar on Page used to live. It's `RaySettings.pageAddressBar` now; an older file's
  /// value moves there once on load and is cleared.
  var pageToolbar: Bool?
  /// Where View › Show Full Address used to live. It's `RaySettings.minimalURL` now (minimal = !fullAddress); an
  /// older file's value moves there once on load and is cleared.
  var fullAddress: Bool?

  init() {
    currentSpaceID = spaces[0].id
  }

  /// Spaces on a profile.
  func spaces(on directory: String?) -> [Space] { spaces.filter { $0.profile == directory } }

  // MARK: Spaces

  /// The Space shown now.
  var current: Space { spaces.first { $0.id == currentSpaceID } ?? spaces[0] }

  func space(id: UUID) -> Space? { spaces.first { $0.id == id } }

  /// The Space an entry's row is in; nil for favorites (shared) and for entries that are gone.
  func space(of entry: SidebarEntry) -> Space? {
    spaces.first { space in space.pinned.contains { $0 === entry } || space.today.contains { $0 === entry } }
  }

  /// The current Space's lists: everything that edits "the" sidebar edits the Space on screen.
  var pinned: [SidebarEntry] {
    get { current.pinned }
    set { current.pinned = newValue }
  }

  var today: [SidebarEntry] {
    get { current.today }
    set { current.today = newValue }
  }

  /// The active tab of the Space on screen (each Space remembers its own, Arc's).
  var activeEntryID: UUID? {
    get { current.activeEntryID }
    set { current.activeEntryID = newValue }
  }

  /// The favorites the current Space shows: its profile's.
  var favorites: [SidebarEntry] {
    get { favorites(profile: current.profile) }
    set { setFavorites(newValue, profile: current.profile) }
  }

  func favorites(profile: String?) -> [SidebarEntry] {
    guard let profile else { return defaultFavorites }
    return profileFavorites[profile] ?? []
  }

  func setFavorites(_ list: [SidebarEntry], profile: String?) {
    if let profile { profileFavorites[profile] = list } else { defaultFavorites = list }
  }

  var allFavorites: [SidebarEntry] { defaultFavorites + profileFavorites.keys.sorted().flatMap { profileFavorites[$0] ?? [] } }

  /// Every Space's Today, for what spans them (Chrome's tab groups).
  var allToday: [SidebarEntry] { spaces.flatMap(\.today) }

  /// Everything in every Space, favorites first.
  var allEntries: [SidebarEntry] { allFavorites + spaces.flatMap { $0.pinned + $0.today } }

  /// What the Space on screen holds, with its favorites.
  var shownEntries: [SidebarEntry] { favorites + pinned + today }

  /// The profile an entry's page loads in: its Space's, or for a favorite the profile whose list holds it.
  func profileDirectory(of entry: SidebarEntry) -> String? {
    if let space = space(of: entry) { return space.profile }
    return profileFavorites.first { $0.value.contains { $0 === entry } }?.key
  }

  func entry(for tab: RayCoreTab) -> SidebarEntry? {
    allEntries.first { $0.tab === tab }
  }

  func entry(id: UUID) -> SidebarEntry? {
    allEntries.first { $0.id == id }
  }

  func remove(_ entry: SidebarEntry) {
    defaultFavorites.removeAll { $0 === entry }
    for key in profileFavorites.keys { profileFavorites[key]?.removeAll { $0 === entry } }
    for space in spaces {
      space.pinned.removeAll { $0 === entry }
      space.today.removeAll { $0 === entry }
      if space.activeEntryID == entry.id { space.activeEntryID = nil }
    }
  }

  // MARK: Saved form

  private enum CodingKeys: String, CodingKey {
    case spaces, currentSpaceID, favorites, profileFavorites, profiles, sidebarHidden, fullScreen, pageToolbar, fullAddress
    // Before Spaces: one list of each, now the first Space's.
    case pinned, today, activeEntryID
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    defaultFavorites = try c.decodeIfPresent([SidebarEntry].self, forKey: .favorites) ?? []
    profileFavorites = try c.decodeIfPresent([String: [SidebarEntry]].self, forKey: .profileFavorites) ?? [:]
    profiles = (try? c.decodeIfPresent([ProfileInfo].self, forKey: .profiles)) ?? []
    sidebarHidden = try c.decodeIfPresent(Bool.self, forKey: .sidebarHidden) ?? false
    fullScreen = try c.decodeIfPresent(Bool.self, forKey: .fullScreen)
    pageToolbar = try c.decodeIfPresent(Bool.self, forKey: .pageToolbar)
    fullAddress = try c.decodeIfPresent(Bool.self, forKey: .fullAddress)
    let saved = (try? c.decodeIfPresent([Space].self, forKey: .spaces)) ?? nil
    if let saved, !saved.isEmpty {
      spaces = saved
    } else {
      // A file from before Spaces: everything goes into one Space.
      let first = Space(name: Space.firstName)
      first.pinned = try c.decodeIfPresent([SidebarEntry].self, forKey: .pinned) ?? []
      first.today = try c.decodeIfPresent([SidebarEntry].self, forKey: .today) ?? []
      first.activeEntryID = try c.decodeIfPresent(UUID.self, forKey: .activeEntryID)
      spaces = [first]
    }
    // A Space id seen twice (a hand-edited file) keeps its first.
    var seen = Set<UUID>()
    spaces = spaces.filter { seen.insert($0.id).inserted }
    let wanted = try c.decodeIfPresent(UUID.self, forKey: .currentSpaceID)
    let list = spaces
    currentSpaceID = wanted.flatMap { id in list.first { $0.id == id }?.id } ?? list[0].id
    // Favorites of a profile no Space uses any more stay (the profile's data does too); entries of a kind that
    // doesn't belong in a list move where they do.
    for space in spaces {
      for entry in space.pinned where entry.kind == .favorite { entry.kind = .pinned }
    }
    tidyProfiles()
  }

  /// The default profile first, one entry per directory, each valid and named, and an entry for every directory a
  /// Space uses (a file from before profiles had names: the first Space on it names it).
  func tidyProfiles() {
    var seen = Set<String>()
    var tidy = [profiles.first { $0.directory == nil } ?? ProfileInfo(directory: nil, name: ProfileInfo.defaultName)]
    for var info in profiles {
      guard let directory = info.directory.flatMap(Space.validProfile), seen.insert(directory).inserted else { continue }
      info.directory = directory
      info.name = ProfileInfo.name(from: info.name) ?? "Profile"
      info.color = info.color.flatMap(Space.validHex)
      tidy.append(info)
    }
    for space in spaces {
      guard let directory = space.profile, seen.insert(directory).inserted else { continue }
      tidy.append(ProfileInfo(directory: directory, name: space.name, color: space.color))
    }
    tidy[0].name = ProfileInfo.name(from: tidy[0].name) ?? ProfileInfo.defaultName
    tidy[0].color = tidy[0].color.flatMap(Space.validHex)
    tidy[0].source = nil
    profiles = tidy
  }

  func profileInfo(_ directory: String?) -> ProfileInfo? { profiles.first { $0.directory == directory } }

  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(spaces, forKey: .spaces)
    try c.encode(currentSpaceID, forKey: .currentSpaceID)
    try c.encode(defaultFavorites, forKey: .favorites)
    if !profileFavorites.isEmpty { try c.encode(profileFavorites, forKey: .profileFavorites) }
    try c.encode(profiles, forKey: .profiles)
    try c.encode(sidebarHidden, forKey: .sidebarHidden)
    try c.encodeIfPresent(fullScreen, forKey: .fullScreen)
    try c.encodeIfPresent(pageToolbar, forKey: .pageToolbar)
    try c.encodeIfPresent(fullAddress, forKey: .fullAddress)
  }

  // MARK: Pinned folders

  /// `pinned` holds folders and tabs in tree order: each folder is followed by everything inside it. `today` does too,
  /// one level deep.
  func section(of entry: SidebarEntry) -> [SidebarEntry] {
    let space = self.space(of: entry) ?? current
    return space.today.contains { $0 === entry } ? space.today : space.pinned
  }

  func isTodayFolder(_ entry: SidebarEntry) -> Bool {
    entry.isFolder && allToday.contains { $0 === entry }
  }

  /// Today's folders in every Space (each is a Chrome tab group).
  var todayFolders: [SidebarEntry] { allToday.filter(\.isFolder) }

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
    for space in spaces { space.pinned = Self.normalizedPinned(space.pinned) }
  }

  private static func normalizedPinned(_ pinned: [SidebarEntry]) -> [SidebarEntry] {
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
    return ordered
  }

  /// Today's folders keep Chrome's rules: one level, each followed by its tabs, and gone once it holds no tab. A tab
  /// whose folder is missing (or isn't a Today folder) moves to the top level.
  func normalizeToday() {
    for space in spaces { space.today = Self.normalizedToday(space.today) }
  }

  private static func normalizedToday(_ today: [SidebarEntry]) -> [SidebarEntry] {
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
    return ordered
  }

  func archiveStaleToday(now: Date = Date()) {
    for space in spaces {
      space.today.removeAll {
        !$0.isFolder && !$0.isLive && $0.id != space.activeEntryID
          && now.timeIntervalSince($0.lastActive) > Self.todayLifetime
      }
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
