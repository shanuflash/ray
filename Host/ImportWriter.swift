import AppKit

// ImportSession's work: where browsers are read from (and the test hooks), the counts for the "what to bring" step,
// and the run itself, which reads with the importer (Importer/Sources/RayImport) off the main thread and writes into
// Ray: the window's sidebar, and the engine's history, bookmarks, passwords, cookies and autofill.
//
// Secrets (cookie values, passwords, card numbers) go to the engine through `EngineCalls.callWithSecret`, written
// into `SecretBytes` and wiped as soon as the engine has parsed them. Nothing here logs a URL, a title or a secret.

// MARK: Places

/// Where the importer looks, and the only place its test hooks are read. The real app reads ~/Library and asks the
/// Keychain for "<Browser> Safe Storage" (a macOS prompt). A test build reads only RAY_IMPORT_SOURCE_DIR (a fake
/// Application Support) and RAY_IMPORT_SECRET: without them it finds no browser and unlocks none, so a test never
/// reaches a real profile or the login Keychain.
enum ImportPlaces {
  static var applicationSupport: URL? {
    guard TestEnvironment.isTestBuild else {
      return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    }
    guard let dir = TestEnvironment["RAY_IMPORT_SOURCE_DIR"], dir.hasPrefix("/") else { return nil }
    return URL(fileURLWithPath: dir, isDirectory: true)
  }

  /// Safari reads from a home folder: the user's, or in a test build two levels above the fake Application Support
  /// (Ardia's rule: `<home>/Library/Application Support`).
  static var home: URL? {
    guard TestEnvironment.isTestBuild else { return FileManager.default.homeDirectoryForCurrentUser }
    return applicationSupport?.deletingLastPathComponent().deletingLastPathComponent()
  }

  static func discovery() -> BrowserDiscovery? {
    applicationSupport.map { BrowserDiscovery(applicationSupport: $0, locateApp: AppIcons.locate) }
  }

  /// A browser's Safe Storage secret: the Keychain (one macOS prompt), or in a test build RAY_IMPORT_SECRET only.
  static func secret(service: String, account: String) throws -> Data {
    guard TestEnvironment.isTestBuild else { return try SafeStorageKeychain.secret(service: service, account: account) }
    guard let secret = TestEnvironment["RAY_IMPORT_SECRET"], !secret.isEmpty else {
      throw ImportError.locked("No test secret (RAY_IMPORT_SECRET)")
    }
    return Data(secret.utf8)
  }
}

extension ImportItem {
  /// What a browser family can give at all.
  static func supported(by def: BrowserDefinition) -> Set<ImportItem> {
    switch def.family {
    case .arc:
      return Set(allCases)
    case .chromium:
      return [.pinnedTabs, .openTabs, .history, .bookmarks, .passwords, .cookies, .autofill, .extensions]
    case .firefox:
      let common: Set<ImportItem> = [.pinnedTabs, .openTabs, .history, .bookmarks, .passwords, .cookies]
      return def.sidebar == .zen ? common.union([.favorites]) : common
    case .safari:
      return [.openTabs, .history, .bookmarks, .cookies]
    }
  }
}

// MARK: Sources

enum ImportSources {
  /// Safari has no profiles on disk: one stands for all of it.
  static let safariProfile = ImportProfile(id: "Default", name: "Default")
  static let fullDiskAccess = "Needs Full Disk Access"

  static func list() -> [ImportSource] {
    guard let discovery = ImportPlaces.discovery() else { return [] }
    let sources = discovery.list().compactMap { found -> ImportSource? in
      guard let def = BrowserDefinition.find(found.id) else { return nil }
      var profiles = found.profiles.map { ImportProfile(id: $0.id, name: $0.name) }
      var note: String? = found.needsFullDiskAccess ? fullDiskAccess : nil
      if def.family == .safari {
        guard let home = ImportPlaces.home else { return nil }
        if !SafariDirect.hasAccess(home: home) {
          // Safari's folder unreadable: Full Disk Access. Nothing there at all: Safari was never used.
          guard BrowserDiscovery.isAccessDenied(SafariDirect.directory(home: home)) else { return nil }
          note = fullDiskAccess
        }
        profiles = [safariProfile]
      }
      return ImportSource(
        id: def.id, name: found.name, icon: found.appPath.map { NSWorkspace.shared.icon(forFile: $0) },
        profiles: profiles, recommended: def.family == .arc, note: note, items: ImportItem.supported(by: def))
    }
    return sources.sorted { a, b in
      a.recommended != b.recommended ? a.recommended : a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
    }
  }
}

// MARK: Shared helpers

enum ImportShape {
  /// Only web pages come across into the sidebar and bookmarks: never javascript:, data:, file: or anything else.
  static func isWeb(_ url: String) -> Bool {
    guard url.utf8.count <= 8192, let scheme = URLComponents(string: url)?.scheme?.lowercased() else { return false }
    return scheme == "https" || scheme == "http"
  }

  /// One line, at most 200 characters: a title as the sidebar shows it.
  static func plain(_ text: String) -> String {
    String(text.components(separatedBy: .newlines).joined(separator: " ").prefix(200))
  }

  static func node(_ tab: ImportedTab) -> ArcImport.Node? {
    isWeb(tab.url) ? .tab(url: tab.url, title: plain(tab.customTitle ?? tab.title)) : nil
  }

  static func nodes(_ bookmarks: [BookmarkNode], depth: Int = 0) -> [ArcImport.Node] {
    guard depth < 32 else { return [] }
    return bookmarks.compactMap { node in
      switch node.type {
      case .url:
        guard let url = node.url, isWeb(url) else { return nil }
        return .tab(url: url, title: plain(node.title))
      case .folder:
        let children = nodes(node.children ?? [], depth: depth + 1)
        return children.isEmpty ? nil : .folder(title: plain(node.title), children: children)
      }
    }
  }

  static func webLinks(_ node: BookmarkNode?, depth: Int = 0) -> Int {
    guard let node, depth < 64 else { return 0 }
    switch node.type {
    case .url: return node.url.map(isWeb) == true ? 1 : 0
    case .folder: return (node.children ?? []).reduce(0) { $0 + webLinks($1, depth: depth + 1) }
    }
  }

  /// The origin a saved password belongs to (scheme, host and port), from its realm or its page; http(s) only.
  static func origin(of credential: Credential) -> String? {
    let realm = credential.realm ?? ""
    let source = realm.lowercased().hasPrefix("http") ? realm : credential.url
    guard let components = URLComponents(string: source), let scheme = components.scheme?.lowercased(),
          scheme == "https" || scheme == "http", let host = components.host, !host.isEmpty else { return nil }
    let shownHost = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
    return "\(scheme)://\(shownHost)" + (components.port.map { ":\($0)" } ?? "")
  }

  static func plural(_ n: Int, _ word: String, _ words: String? = nil) -> String {
    "\(n.formatted()) \(n == 1 ? word : words ?? word + "s")"
  }
}

// MARK: Preview

enum ImportCounter {
  static let maxSidebarBytes = 64 * 1024 * 1024

  /// Counts read without the browser's key, so without any Keychain prompt. Secret items get a count only where the
  /// rows can be counted without decrypting them (passwords and cookies of Chromium browsers, Firefox's cookies).
  static func preview(_ source: ImportSource, profile: ImportProfile) -> ImportPreview {
    guard let discovery = ImportPlaces.discovery(), let def = BrowserDefinition.find(source.id) else {
      return ImportPreview()
    }
    var counts: [ImportItem: Int] = [:]
    var spaces: Int?
    let fm = FileManager.default

    if def.family == .safari {
      guard let home = ImportPlaces.home, SafariDirect.hasAccess(home: home) else {
        return ImportPreview(counts: [:], summary: ImportSources.fullDiskAccess)
      }
      let dir = SafariDirect.directory(home: home)
      counts[.openTabs] = SafariDirect.tabs(dir.appendingPathComponent("LastSession.plist")).count
      counts[.bookmarks] = (try? SafariDirect.bookmarks(dir.appendingPathComponent("Bookmarks.plist"))).map { ImportShape.webLinks($0) }
      counts[.history] = rows(dir.appendingPathComponent("History.db"),
                              "SELECT count(*) FROM history_items WHERE url LIKE 'http://%' OR url LIKE 'https://%'")
      return ImportPreview(counts: counts.filter { source.items.contains($0.key) },
                           summary: summary(counts, spaces: nil, profiles: 1))
    }

    guard let dir = try? discovery.profileDirectory(def, profile.id) else { return ImportPreview() }
    let firefox = def.family == .firefox

    // Tabs: Arc's and Zen's spaces, else the last session (without the key: an encrypted one isn't counted).
    var sidebarSpaces: [SpaceSuggestion]?
    var favorites: [ImportedTab]?
    if def.sidebar == .arc {
      let file = discovery.arcSidebarURL()
      if let size = (try? fm.attributesOfItem(atPath: file.path))?[.size] as? Int, size <= maxSidebarBytes,
         let data = try? Data(contentsOf: file), let sidebar = try? ArcSidebar.parse(data) {
        sidebarSpaces = sidebar.spaces.filter { $0.profileId == profile.id }
        favorites = sidebar.favorites[profile.id] ?? []
      }
    } else if def.sidebar == .zen, let zen = try? ZenSidebar.load(profile: dir, profileId: profile.id), !zen.spaces.isEmpty {
      sidebarSpaces = zen.spaces
      favorites = zen.essentials
    }
    if let sidebarSpaces {
      spaces = sidebarSpaces.count
      counts[.pinnedTabs] = sidebarSpaces.reduce(0) { total, space in
        total + space.pinned.reduce(0) { $0 + ImportShape.webLinks($1) }
      }
      counts[.openTabs] = sidebarSpaces.reduce(0) { $0 + $1.tabs.filter { ImportShape.isWeb($0.url) }.count }
      counts[.favorites] = favorites?.filter { ImportShape.isWeb($0.url) }.count
    } else if def.family != .arc {
      let session = firefox ? try? Firefox.loadSession(profile: dir) : try? ChromiumSessions.load(profile: dir, key: nil)
      if let tabs = session?.tabs.filter({ ImportShape.isWeb($0.url) }) {
        counts[.pinnedTabs] = tabs.filter(\.pinned).count
        counts[.openTabs] = tabs.filter { !$0.pinned }.count
      }
    }

    let web = "(url LIKE 'http://%' OR url LIKE 'https://%')"
    if firefox {
      let places = dir.appendingPathComponent("places.sqlite")
      counts[.history] = rows(places, "SELECT count(*) FROM moz_places WHERE hidden = 0 AND visit_count > 0 "
        + "AND last_visit_date IS NOT NULL AND \(web)")
      counts[.bookmarks] = (try? Firefox.bookmarks(places: places)).map { ImportShape.webLinks($0) }
      counts[.cookies] = rows(dir.appendingPathComponent("cookies.sqlite"), "SELECT count(*) FROM moz_cookies")
    } else {
      counts[.history] = rows(dir.appendingPathComponent("History"),
                              "SELECT count(*) FROM urls WHERE hidden = 0 AND last_visit_time > 0 AND \(web)")
      counts[.bookmarks] = (try? ChromiumBookmarks.load(profile: dir)).map { ImportShape.webLinks($0) }
      let logins = ["Login Data", "Login Data For Account"].compactMap {
        rows(dir.appendingPathComponent($0), "SELECT count(*) FROM logins WHERE blacklisted_by_user = 0 "
          + "AND length(password_value) > 0 AND (signon_realm LIKE 'http://%' OR signon_realm LIKE 'https://%')")
      }
      counts[.passwords] = logins.isEmpty ? nil : logins.reduce(0, +)
      counts[.cookies] = ["Network/Cookies", "Cookies"].lazy
        .compactMap { rows(dir.appendingPathComponent($0), "SELECT count(*) FROM cookies") }.first
      counts[.extensions] = ChromiumExtensions.list(profile: dir).count
    }
    let shown = counts.filter { source.items.contains($0.key) }
    return ImportPreview(counts: shown, summary: summary(shown, spaces: spaces, profiles: source.profiles.count))
  }

  /// "3 spaces, 42 pinned tabs, 2 profiles"; "12 open tabs, 340 bookmarks"…
  static func summary(_ counts: [ImportItem: Int], spaces: Int?, profiles: Int) -> String {
    var parts: [String] = []
    if let spaces, spaces > 0 { parts.append(ImportShape.plural(spaces, "space")) }
    // A browser with spaces (Arc, Zen): its spaces and pinned tabs; any other: its tabs and bookmarks.
    let words: [(ImportItem, String)] = spaces != nil
      ? [(.pinnedTabs, "pinned tab")] : [(.pinnedTabs, "pinned tab"), (.openTabs, "open tab"), (.bookmarks, "bookmark")]
    for (item, word) in words {
      if let n = counts[item], n > 0 { parts.append(ImportShape.plural(n, word)) }
    }
    if parts.isEmpty, let n = counts[.history], n > 0 { parts.append(ImportShape.plural(n, "page in history", "pages in history")) }
    if profiles > 1 { parts.append(ImportShape.plural(profiles, "profile")) }
    return parts.joined(separator: ", ")
  }

  /// One number from a copy of a SQLite file (never the browser's own file, which it may hold open).
  static func rows(_ file: URL, _ sql: String) -> Int? {
    guard FileManager.default.fileExists(atPath: file.path), let db = try? SQLiteSnapshot(copying: file),
          let count = try? db.scalar(sql) else { return nil }
    return Int(count)
  }
}

// MARK: Run

/// One import, from `ImportSession.run`. Reads on its own thread, writes on the main thread (the sidebar and every
/// engine call), one item after another, and waits for each write so a big history goes in steadily, in batches,
/// without holding the main thread.
final class ImportRun: @unchecked Sendable {
  static let historyBatch = 1000
  static let bookmarkBatch = 500
  static let cookieBatch = 500
  static let autofillBatch = 500
  /// The longest one engine call may take before the item counts as failed.
  static let engineDeadline: TimeInterval = 60

  private let source: ImportSource
  private let profileId: String
  private let items: Set<ImportItem>
  private let importer: Importer
  private let controller: BrowserWindowController
  private let profile: RayCoreProfile
  private let isPrivate: Bool
  private let onEvent: (ImportEvent) -> Void
  /// Only touched on the run's own thread; handed to the main thread at the end.
  private var summary = ImportSummary()
  private var started = Set<ImportItem>()

  init(source: ImportSource, profileId: String, items: Set<ImportItem>, importer: Importer,
       controller: BrowserWindowController, event: @escaping (ImportEvent) -> Void) {
    self.source = source
    self.profileId = profileId
    self.items = items
    self.importer = importer
    self.controller = controller
    profile = controller.profile
    isPrivate = controller.isPrivate
    onEvent = event
  }

  func start(completion: @escaping (ImportSummary) -> Void) {
    Thread.detachNewThread { [self] in
      work()
      importer.forgetKeys()
      let summary = self.summary
      DispatchQueue.main.async { [controller] in
        controller.noteImport(summary: summary)
        completion(summary)
      }
    }
  }

  // MARK: Run: events

  /// An item's work begins: `.started`, once per item.
  private func begin(_ items: [ImportItem]) {
    for item in items where started.insert(item).inserted { emit(.started(item)) }
  }

  private func emit(_ event: ImportEvent) {
    switch event {
    case .started: break
    case .finished(let item, let count):
      begin([item])
      summary.imported[item] = count
    case .failed(let item, let reason):
      begin([item])
      summary.failed[item] = reason
    }
    DispatchQueue.main.async { [controller, onEvent] in
      controller.noteImport(event: event)
      onEvent(event)
    }
  }

  private func fail(_ items: [ImportItem], _ reason: String) {
    for item in items { emit(.failed(item, reason: reason)) }
  }

  private static func describe(_ error: Error) -> String {
    (error as? ImportError)?.description ?? error.localizedDescription
  }

  // MARK: Run: steps

  private func work() {
    let chosen = ImportItem.allCases.filter(items.contains)
    guard let def = BrowserDefinition.find(source.id) else {
      return fail(chosen, "\(source.name) wasn't found")
    }
    guard !isPrivate else { return fail(chosen, "Nothing is imported into a private window") }
    let supported = ImportItem.supported(by: def)
    let unsupported = chosen.filter { !supported.contains($0) }
    fail(unsupported, "\(source.name) has none to import")
    let wanted = chosen.filter(supported.contains)
    if def.family == .safari { return safari(wanted) }

    // One unlock for the run, before anything is read: the macOS prompt comes first, then the import runs alone.
    // Denied, only passwords and cookies fail (addresses still come, cards don't).
    var locked: String?
    if wanted.contains(where: \.needsUnlock) {
      do {
        try importer.unlock(browserId: def.id, primaryPassword: "", secret: ImportPlaces.secret)
      } catch {
        locked = Self.describe(error)
      }
    }

    let sidebarItems = wanted.filter { [.pinnedTabs, .favorites, .openTabs].contains($0) }
    if !sidebarItems.isEmpty { sidebar(sidebarItems, def) }
    for item in wanted where !sidebarItems.contains(item) {
      begin([item])
      switch item {
      case .history: history()
      case .bookmarks: bookmarks()
      case .passwords: if let locked { fail([item], locked) } else { passwords() }
      case .cookies: if let locked { fail([item], locked) } else { cookies() }
      case .autofill: autofill()
      // Listed only (the preview counts them): the engine installs unpacked folders and .crx files, not Web Store
      // ids, so none come in yet.
      case .extensions: emit(.finished(.extensions, count: 0))
      case .pinnedTabs, .favorites, .openTabs: break
      }
    }
  }

  private func read(_ kinds: [ImportKind], options: ImportOptions = .init(), observer: ImportObserver = .silent,
                    cancellation: Cancellation = .init()) -> Result<ImportResult, Error> {
    Result {
      try importer.importData(browserId: source.id, profileId: profileId, kinds: kinds, options: options,
                              observer: observer, cancellation: cancellation)
    }
  }

  /// Why the importer couldn't read a kind it was asked for; nil when it read it (an empty one included).
  private static func failure(_ kind: ImportKind, in result: ImportResult) -> String? {
    guard result.failed.contains(kind) else { return nil }
    return result.warnings.first { $0.kind == kind && $0.code != "empty" }?.message ?? "Couldn't read it"
  }

  /// Pinned tabs, favorites and open tabs: read once, then added to the sidebar in one go. Arc's and Zen's spaces
  /// each become a pinned folder named after the space (Ray has no Spaces yet), unless there's only one.
  private func sidebar(_ wanted: [ImportItem], _ def: BrowserDefinition) {
    begin(wanted)
    let spacesFamily = def.sidebar != nil
    var kinds: [ImportKind] = []
    if spacesFamily {
      if wanted.contains(.pinnedTabs) { kinds.append(.pinnedTabs) }
      if wanted.contains(.openTabs) { kinds.append(.tabs) }
      if wanted.contains(.favorites) { kinds.append(.favorites) }
    } else {
      kinds = [.tabs]
    }
    let result: ImportResult
    switch read(kinds) {
    case .failure(let error): return fail(wanted, Self.describe(error))
    case .success(let read): result = read
    }
    var failures: [ImportItem: String] = [:]
    var pinned: [ArcImport.Node] = []
    var today: [ArcImport.Node] = []
    var favorites: [ArcImport.Node] = []
    if spacesFamily {
      if wanted.contains(.pinnedTabs) {
        if let reason = Self.failure(.pinnedTabs, in: result) {
          failures[.pinnedTabs] = reason
        } else {
          let spaces = result.spaces.map { (name: $0.name, nodes: ImportShape.nodes($0.pinned)) }.filter { !$0.nodes.isEmpty }
          pinned = spaces.count == 1
            ? spaces[0].nodes : spaces.map { .folder(title: ImportShape.plain($0.name), children: $0.nodes) }
        }
      }
      if wanted.contains(.openTabs) {
        if let reason = Self.failure(.tabs, in: result) { failures[.openTabs] = reason } else {
          today = result.tabs.compactMap(ImportShape.node)
        }
      }
      if wanted.contains(.favorites) {
        if let reason = Self.failure(.favorites, in: result) { failures[.favorites] = reason } else {
          favorites = result.favorites.compactMap(ImportShape.node)
        }
      }
    } else if let reason = Self.failure(.tabs, in: result) {
      for item in wanted { failures[item] = reason }
    } else {
      if wanted.contains(.pinnedTabs) { pinned = result.tabs.filter(\.pinned).compactMap(ImportShape.node) }
      if wanted.contains(.openTabs) { today = result.tabs.filter { !$0.pinned }.compactMap(ImportShape.node) }
    }
    let counts = DispatchQueue.main.sync { [controller] in
      controller.addImported(favorites: favorites, pinned: pinned, today: today)
    }
    for item in wanted {
      if let reason = failures[item] { emit(.failed(item, reason: reason)); continue }
      switch item {
      case .pinnedTabs: emit(.finished(item, count: counts.pinned))
      case .favorites: emit(.finished(item, count: counts.favorites))
      default: emit(.finished(item, count: counts.today))
      }
    }
  }

  private final class Tally: @unchecked Sendable {
    var count = 0
    var error: String?
  }

  /// Streams the history in batches: each is written (and answered) before the importer reads the next.
  private func history() {
    let tally = Tally()
    let cancellation = Cancellation()
    let observer = ImportObserver(chunkSize: Self.historyBatch, history: { [self] chunk in
      guard tally.error == nil else { return }
      switch writeHistory(chunk) {
      case .success(let n): tally.count += n
      case .failure(let error):
        tally.error = error.message
        cancellation.cancel()
      }
    })
    let outcome = read([.history], options: ImportOptions(streamHistory: true), observer: observer,
                       cancellation: cancellation)
    if let error = tally.error { return emit(.failed(.history, reason: error)) }
    switch outcome {
    case .failure(let error): emit(.failed(.history, reason: Self.describe(error)))
    case .success(let result):
      if let reason = Self.failure(.history, in: result) { return emit(.failed(.history, reason: reason)) }
      emit(.finished(.history, count: tally.count))
    }
  }

  private func bookmarks() {
    switch read([.bookmarks]) {
    case .failure(let error): emit(.failed(.bookmarks, reason: Self.describe(error)))
    case .success(let result):
      if let reason = Self.failure(.bookmarks, in: result) { return emit(.failed(.bookmarks, reason: reason)) }
      finish(.bookmarks, writeBookmarks(result.bookmarks))
    }
  }

  private func passwords() {
    switch read([.passwords]) {
    case .failure(let error): emit(.failed(.passwords, reason: Self.describe(error)))
    case .success(var result):
      if let reason = Self.failure(.passwords, in: result) { return emit(.failed(.passwords, reason: reason)) }
      let credentials = result.credentials
      result.credentials = []
      finish(.passwords, writePasswords(credentials))
    }
  }

  private func cookies() {
    switch read([.cookies]) {
    case .failure(let error): emit(.failed(.cookies, reason: Self.describe(error)))
    case .success(let result):
      if let reason = Self.failure(.cookies, in: result) { return emit(.failed(.cookies, reason: reason)) }
      finish(.cookies, writeCookies(result.cookies))
    }
  }

  private func autofill() {
    switch read([.autofill]) {
    case .failure(let error): emit(.failed(.autofill, reason: Self.describe(error)))
    case .success(let result):
      if let reason = Self.failure(.autofill, in: result) { return emit(.failed(.autofill, reason: reason)) }
      finish(.autofill, writeAutofill(addresses: result.addresses, cards: result.cards))
    }
  }

  /// Safari, read directly from ~/Library/Safari (Full Disk Access): open tabs, history, bookmarks and cookies.
  private func safari(_ wanted: [ImportItem]) {
    guard let home = ImportPlaces.home, SafariDirect.hasAccess(home: home) else {
      return fail(wanted, "Ray needs Full Disk Access to read Safari's data")
    }
    let data: SafariExport
    do { data = try SafariDirect.load(home: home) } catch { return fail(wanted, Self.describe(error)) }
    let codes: [ImportItem: String] = [
      .openTabs: "unreadableTabs", .history: "unreadableHistory", .bookmarks: "unreadableBookmarks",
      .cookies: "unreadableCookies",
    ]
    for item in wanted {
      begin([item])
      if let warning = data.warnings.first(where: { $0.code == codes[item] }) {
        emit(.failed(item, reason: warning.message))
        continue
      }
      switch item {
      case .openTabs:
        let today = data.tabs.compactMap(ImportShape.node)
        let counts = DispatchQueue.main.sync { [controller] in controller.addImported(favorites: [], pinned: [], today: today) }
        emit(.finished(item, count: counts.today))
      case .history:
        let entries = data.profiles.first { $0.name == nil }?.history ?? data.profiles.first?.history ?? []
        var written = 0
        var failure: String?
        for start in stride(from: 0, to: entries.count, by: Self.historyBatch) {
          switch writeHistory(Array(entries[start..<min(start + Self.historyBatch, entries.count)])) {
          case .success(let n): written += n
          case .failure(let error): failure = error.message
          }
          if failure != nil { break }
        }
        if let failure { emit(.failed(item, reason: failure)) } else { emit(.finished(item, count: written)) }
      case .bookmarks: finish(item, writeBookmarks(data.bookmarks))
      case .cookies: finish(item, writeCookies(data.cookies))
      default: emit(.failed(item, reason: "\(source.name) has none to import"))
      }
    }
  }

  private func finish(_ item: ImportItem, _ outcome: Result<Int, WriteError>) {
    switch outcome {
    case .success(let count): emit(.finished(item, count: count))
    case .failure(let error): emit(.failed(item, reason: error.message))
    }
  }

  // MARK: Run: writing

  struct WriteError: Error {
    let message: String
  }

  private final class Reply: @unchecked Sendable {
    private let lock = NSLock()
    private let done = DispatchSemaphore(value: 0)
    private var value: [String: Any]?

    func put(_ reply: [String: Any]) {
      lock.withLock { value = value ?? reply }
      done.signal()
    }

    func wait(_ seconds: TimeInterval) -> [String: Any]? {
      guard done.wait(timeout: .now() + seconds) == .success else { return nil }
      return lock.withLock { value }
    }
  }

  /// One engine call on the main thread, waited for here (with a deadline). A missing call or no answer comes back
  /// as `["error": …]`.
  private func engine(_ call: @escaping (RayCoreProfile, @escaping ([String: Any]?) -> Void) -> Void) -> [String: Any] {
    let reply = Reply()
    DispatchQueue.main.async { [profile] in
      call(profile) { reply.put($0 ?? ["error": "The engine didn't take it"]) }
    }
    return reply.wait(Self.engineDeadline) ?? ["error": "The engine didn't answer in time"]
  }

  private static func number(_ reply: [String: Any], _ key: String) -> Int { (reply[key] as? NSNumber)?.intValue ?? 0 }

  /// `ac_history_import`: url, title, visit count and last visit (ms since 1970) per row, serialised here.
  private func writeHistory(_ entries: [HistoryEntry]) -> Result<Int, WriteError> {
    let rows: [[String: Any]] = entries.compactMap { entry in
      guard entry.lastVisit > 0, ImportShape.isWeb(entry.url) else { return nil }
      return ["u": entry.url, "t": String(entry.title.prefix(1024)), "n": max(1, entry.visits), "l": entry.lastVisit]
    }
    guard !rows.isEmpty else { return .success(0) }
    guard let json = try? JSONSerialization.data(withJSONObject: ["rows": rows]) else {
      return .failure(WriteError(message: "Couldn't write the history"))
    }
    let reply = engine { EngineCalls.call("ac_history_import", profile: $0, json: json, completion: $1) }
    if let error = reply["error"] as? String { return .failure(WriteError(message: error)) }
    return .success(rows.count)
  }

  /// Into Chrome's bookmark model (`ac_bookmarks_apply`), all under one "Imported from <Browser>" folder on the
  /// bookmarks bar, as Chrome's own importer does: the bar's items directly inside it, every other root as a folder.
  /// Web links only (no bookmarklets); folders with none are left out.
  private func writeBookmarks(_ root: BookmarkNode?) -> Result<Int, WriteError> {
    guard let root, ImportShape.webLinks(root) > 0 else { return .success(0) }
    var ops: [[String: Any]] = []
    var links = 0
    func id() -> String { UUID().uuidString.lowercased() }
    func addFolder(_ title: String, in parent: String) -> String {
      let folder = id()
      ops.append(["op": "add", "k": "f", "id": folder, "parent": parent, "t": ImportShape.plain(title)])
      return folder
    }
    func add(_ nodes: [BookmarkNode], in parent: String, depth: Int) {
      guard depth < 32 else { return }
      for node in nodes {
        switch node.type {
        case .url:
          guard let url = node.url, ImportShape.isWeb(url) else { continue }
          var op: [String: Any] = ["op": "add", "k": "u", "id": id(), "parent": parent, "t": node.title, "u": url]
          if let added = node.dateAdded, added > 0 { op["a"] = added }
          ops.append(op)
          links += 1
        case .folder:
          guard ImportShape.webLinks(node) > 0 else { continue }
          add(node.children ?? [], in: addFolder(node.title, in: parent), depth: depth + 1)
        }
      }
    }
    let top = addFolder("Imported from \(source.name)", in: "bar")
    for child in root.children ?? [] {
      if child.type == .folder, child.role == "toolbar" {
        add(child.children ?? [], in: top, depth: 1)
      } else {
        add([child], in: top, depth: 1)
      }
    }
    var applied = 0
    for start in stride(from: 0, to: ops.count, by: Self.bookmarkBatch) {
      let batch = Array(ops[start..<min(start + Self.bookmarkBatch, ops.count)])
      guard let json = try? JSONSerialization.data(withJSONObject: ["ops": batch]) else {
        return .failure(WriteError(message: "Couldn't write the bookmarks"))
      }
      let reply = engine { EngineCalls.call("ac_bookmarks_apply", profile: $0, json: json, completion: $1) }
      if let error = reply["error"] as? String { return .failure(WriteError(message: error)) }
      let links = batch.filter { $0["k"] as? String == "u" }.count
      let folders = batch.count - links
      let invalid = (reply["invalid"] as? [Any])?.count ?? 0
      if Self.number(reply, "skipped") == 0 {
        applied += links - invalid
      } else {
        // The engine stops at the first op it can't apply: count what went in, and stop too.
        applied += max(0, Self.number(reply, "applied") - folders)
        break
      }
    }
    return .success(min(applied, links))
  }

  /// `ac_passwords_add`, one login per call (the engine waits until each has landed). A login already saved counts as
  /// there; a password never sits in a String this side longer than the importer left it.
  private func writePasswords(_ credentials: [Credential]) -> Result<Int, WriteError> {
    var saved = 0
    var present = 0
    var lastError: String?
    for credential in credentials {
      guard let origin = ImportShape.origin(of: credential), !credential.password.isEmpty else { continue }
      let writer = SecretWriter(capacity: 256)
      writer.append("{\"origin\":")
      JSON.string(origin, to: writer)
      writer.append(",\"username\":")
      JSON.string(credential.username, to: writer)
      writer.append(",\"password\":")
      JSON.string(credential.password, to: writer)
      writer.append(UInt8(ascii: "}"))
      writer.append(0)
      let json = writer.finish()
      let reply = engine { EngineCalls.callWithSecret("ac_passwords_add", profile: $0, json: json, completion: $1) }
      json.wipe()
      if let error = reply["error"] as? String {
        if error.contains("already saved") { present += 1 } else { lastError = error }
      } else {
        saved += 1
      }
    }
    if saved == 0, present == 0, let lastError { return .failure(WriteError(message: lastError)) }
    return .success(saved + present)
  }

  /// `ac_cookies_import` in batches of 500, written by `CookieWire` straight into wiped buffers. Cookies Ray already
  /// has count as there.
  private func writeCookies(_ cookies: [Cookie]) -> Result<Int, WriteError> {
    guard !cookies.isEmpty else { return .success(0) }
    let wire = CookieWire.batches(cookies, size: Self.cookieBatch)
    defer { wire.batches.forEach { $0.wipe() } }
    var count = 0
    for batch in wire.batches {
      let reply = engine { EngineCalls.callWithSecret("ac_cookies_import", profile: $0, json: batch, completion: $1) }
      if let error = reply["error"] as? String { return .failure(WriteError(message: error)) }
      count += Self.number(reply, "imported") + Self.number(reply, "existing")
    }
    return .success(count)
  }

  /// `ac_autofill_import`: addresses and cards, up to 500 of each per call.
  private func writeAutofill(addresses: [ImportedAddress], cards: [ImportedCard]) -> Result<Int, WriteError> {
    var count = 0
    var start = 0
    while start < max(addresses.count, cards.count) {
      let someAddresses = Array(addresses[min(start, addresses.count)..<min(start + Self.autofillBatch, addresses.count)])
      let someCards = Array(cards[min(start, cards.count)..<min(start + Self.autofillBatch, cards.count)])
      start += Self.autofillBatch
      let json = AutofillWire.batch(addresses: someAddresses, cards: someCards)
      let reply = engine { EngineCalls.callWithSecret("ac_autofill_import", profile: $0, json: json, completion: $1) }
      json.wipe()
      if let error = reply["error"] as? String { return .failure(WriteError(message: error)) }
      count += Self.number(reply, "addresses") + Self.number(reply, "cards")
    }
    return .success(count)
  }
}
