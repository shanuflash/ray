import AppKit

struct Suggestion {
  enum Kind {
    case tab(RayCoreTab)
    case url(String)
    case search(String)
    case history(String)
    case action(BarAction)
  }

  let kind: Kind
  let title: String
  let detail: String
  let icon: NSImage?
  /// A search suggestion from the search engine (not what you typed).
  var suggested = false

  var key: String {
    switch kind {
    case .tab(let tab): return "tab:\(tab.tabId)"
    case .url(let url), .search(let url), .history(let url): return "\(kindName):\(url)"
    case .action(let action): return "action:\(action.id)"
    }
  }

  var kindName: String {
    switch kind {
    case .tab: return "tab"
    case .url: return "url"
    case .search: return "search"
    case .history: return "history"
    case .action: return "action"
    }
  }
}

struct HistoryItem {
  let url: String
  let title: String
  let visits: Int
  let lastVisit: Double
  /// How often and how lately you went there: Chromium's HistoryQuick frequency, the last ten visits each worth its
  /// recency (1 within four days, 0.7 at two weeks, 0.5 at a month, 0.3 at three months, 0.1 at a year). The engine
  /// doesn't hand out visit transitions, so a typed visit counts as any other (Chromium gives it 1.5).
  let frecency: Double
  let titleLower: String
  /// The address as matched: lowercased, without the scheme and "www.".
  let urlLower: String

  init(url: String, title: String, visits: Int, visitTimes: [Double], now: Double) {
    self.url = url
    self.title = title
    self.visits = visits
    lastVisit = visitTimes.max() ?? 0
    frecency = visitTimes.sorted(by: >).prefix(10).reduce(0) { $0 + Self.recency(days: (now - $1) / 86_400_000) }
    titleLower = title.lowercased()
    urlLower = Suggestions.matchable(url)
  }

  /// Chromium's `days_ago_to_recency_score` (scored_history_match.cc), as a fraction.
  static func recency(days: Double) -> Double {
    let d = max(0, days)
    if d <= 4 { return 1 }
    if d <= 14 { return 0.7 + (14 - d) * 0.3 / 10 }
    if d <= 31 { return 0.5 + (31 - d) * 0.2 / 17 }
    if d <= 90 { return 0.3 + (90 - d) * 0.2 / 60 }
    return 0.1 + max(0, 365 - d) * 0.1 / 275
  }
}

final class HistoryCache {
  private(set) var entries: [HistoryItem] = []
  private var byURL: [String: Int] = [:]
  private var loading = false

  /// Frecency of a page by its exact address (0 when it isn't in history).
  func frecency(of url: String) -> Double { byURL[url].map { entries[$0].frecency } ?? 0 }

  func refresh(profile: RayCoreProfile, then done: @escaping () -> Void) {
    if loading { return }
    loading = true
    EngineCalls.call("ac_history_query", profile: profile, args: ["maxUrls": 3000, "maxVisits": 10]) { [weak self] reply in
      guard let self else { return }
      self.loading = false
      guard let rows = reply?["entries"] as? [[String: Any]] else { return }
      let now = Date().timeIntervalSince1970 * 1000
      self.entries = rows.compactMap { row in
        guard let url = row["u"] as? String else { return nil }
        return HistoryItem(
          url: url, title: row["t"] as? String ?? "", visits: row["n"] as? Int ?? 0,
          visitTimes: (row["v"] as? [Double]) ?? [], now: now)
      }
      self.byURL = Dictionary(self.entries.enumerated().map { ($1.url, $0) }, uniquingKeysWith: { first, _ in first })
      done()
    }
  }
}

final class FaviconCache {
  private var images: [String: NSImage] = [:]
  private var missing: Set<String> = []
  private var requested: Set<String> = []

  func image(for page: String) -> NSImage? { images[page] }

  func load(_ pages: [String], profile: RayCoreProfile, then done: @escaping () -> Void) {
    let wanted = pages.filter { images[$0] == nil && !missing.contains($0) && !requested.contains($0) }
    guard !wanted.isEmpty else { return }
    requested.formUnion(wanted)
    EngineCalls.call("ac_favicons_get", profile: profile, args: ["pages": wanted, "size": 32]) { [weak self] reply in
      guard let self else { return }
      let found = reply?["pages"] as? [String: [String: Any]] ?? [:]
      for page in wanted {
        self.requested.remove(page)
        if let png = found[page]?["png"] as? String, let data = Data(base64Encoded: png), let image = NSImage(data: data) {
          self.images[page] = image
        } else {
          self.missing.insert(page)
        }
      }
      if !found.isEmpty { done() }
    }
  }
}

final class SearchSuggestions {
  static let endpoint = TestEnvironment["RAY_SUGGEST_URL"]
    ?? "https://suggestqueries.google.com/complete/search?client=firefox&q=%s"
  static var userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/156.0.0.0 Safari/537.36"
  private static let minimumInterval: TimeInterval = 0.1
  private static let warmInterval: TimeInterval = 30

  private let session: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieAcceptPolicy = .never
    configuration.httpShouldSetCookies = false
    configuration.timeoutIntervalForRequest = 5
    configuration.httpMaximumConnectionsPerHost = 4
    return URLSession(configuration: configuration)
  }()
  private var cache: [String: [String]] = [:]
  private var shown: (query: String, results: [String]) = ("", [])
  private var lastRequest = Date.distantPast
  private var scheduled: DispatchWorkItem?
  private var wanted = ""

  func current(for query: String) -> [String] {
    let key = query.lowercased()
    if let exact = cache[key] { return exact }
    guard !shown.query.isEmpty, key.hasPrefix(shown.query) else { return [] }
    return shown.results.filter { $0.lowercased().hasPrefix(key) }
  }

  func warm() {
    guard Date().timeIntervalSince(lastRequest) > Self.warmInterval else { return }
    lastRequest = Date()
    send("", then: nil)
  }

  func fetch(_ query: String, then done: @escaping () -> Void) {
    let key = query.lowercased()
    wanted = key
    scheduled?.cancel()
    guard !key.isEmpty, cache[key] == nil else { return }
    let wait = Self.minimumInterval - Date().timeIntervalSince(lastRequest)
    let work = DispatchWorkItem { [weak self] in
      guard let self, self.wanted == key else { return }
      self.lastRequest = Date()
      self.send(key, then: done)
    }
    scheduled = work
    if wait <= 0 {
      work.perform()
    } else {
      DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: work)
    }
  }

  private func send(_ key: String, then done: (() -> Void)?) {
    let encoded = key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=?#"))) ?? key
    guard let url = URL(string: Self.endpoint.replacingOccurrences(of: "%s", with: encoded)) else { return }
    var request = URLRequest(url: url)
    request.assumesHTTP3Capable = true
    request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
    request.setValue(Locale.preferredLanguages.prefix(3).joined(separator: ","), forHTTPHeaderField: "Accept-Language")
    session.dataTask(with: request) { [weak self] data, _, _ in
      guard let done, let data,
            let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
            json.count > 1, let list = json[1] as? [String] else { return }
      DispatchQueue.main.async {
        guard let self else { return }
        self.cache[key] = list
        if self.wanted.hasPrefix(key), key.count >= self.shown.query.count || !self.wanted.hasPrefix(self.shown.query) {
          self.shown = (key, list)
        }
        if self.wanted.hasPrefix(key) { done() }
      }
    }.resume()
  }
}

/// The command bar's rows, ranked as Arc ranks them: a page you go to often that matches what you typed leads (Enter
/// opens it), then what you typed, then the other pages, and the search engine's suggestions only to fill what's left
/// of the five rows the bar shows at once.
enum Suggestions {
  /// Rows in all; the bar shows `visibleRows` of them at once and scrolls to the rest.
  static let limit = 10
  static let visibleRows = 5
  private static let globe = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
  private static let clock = NSImage(systemSymbolName: "clock", accessibilityDescription: nil)
  private static let magnifier = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
  private static let command = NSImage(systemSymbolName: "command", accessibilityDescription: nil)

  static let maxSearchSuggestions = 2
  static let emptyQueryRows = 5
  /// A page takes the first row from this many typed characters (Chromium autocompletes titles from 3).
  static let leadMinimumLength = 3
  /// ... and only one you go to: two visits in the last four days, or one in a tab that's open (Chromium promotes a
  /// history match to the default row only once it was typed more than once).
  static let leadFrecency = 1.5
  /// What being open counts for, in visits (Ardia ranks open tabs a little up).
  private static let openTabFrecency = 1.0

  /// A page that matched what you typed: an open tab or a history entry.
  private struct Page {
    let row: Suggestion
    let url: String
    let match: Double
    /// Every word matched at a word start in the title or the address (Chromium's HistoryQuick only matches there).
    let strong: Bool
    let frecency: Double
    var rank: Double { match + 12 * min(frecency, 10) }
  }

  /// The rows for `raw`. `active` is this window's own tab: it's never offered (switching to it does nothing, and its
  /// page is the one you're on), though another tab on the same address is.
  static func build(
    query raw: String, tabs: [RayCoreTab], active: RayCoreTab?, history: [HistoryItem], searches: [String],
    actions: () -> [BarAction] = { [] }, frecency: (String) -> Double = { _ in 0 },
    favicon: (String) -> NSImage? = { _ in nil }
  ) -> [Suggestion] {
    let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    let others = tabs.filter { $0 !== active }
    let openURLs = Set(tabs.map(\.url))
    if query.isEmpty {
      let open = others.prefix(limit).map(tabSuggestion)
      let frequent = history
        .filter { !openURLs.contains($0.url) && $0.url.hasPrefix("http") }
        .sorted { ($0.visits, $0.lastVisit) > ($1.visits, $1.lastVisit) }
        .prefix(max(0, emptyQueryRows - open.count))
        .map { historySuggestion($0, favicon: favicon) }
      return Array((open + frequent).prefix(limit))
    }
    let lower = query.lowercased()
    // A typed scheme or "www." is matched as pages are: without it.
    let needle = matchable(lower).isEmpty ? lower : matchable(lower)
    let tokens = needle.split(separator: " ").map(String.init)
    var pages: [Page] = []
    for tab in others {
      guard let match = match(tokens, query: needle, title: tab.title.lowercased(), url: matchable(tab.url)) else { continue }
      pages.append(Page(
        row: tabSuggestion(tab), url: tab.url, match: match.score, strong: match.strong,
        frecency: frecency(tab.url) + openTabFrecency))
    }
    // The current page's history entry goes with its tab (it's open), so it never comes back as a history row.
    for entry in history where !openURLs.contains(entry.url) {
      guard let match = match(tokens, query: needle, title: entry.titleLower, url: entry.urlLower) else { continue }
      pages.append(Page(
        row: historySuggestion(entry, favicon: favicon), url: entry.url, match: match.score, strong: match.strong,
        frecency: entry.frecency))
    }
    pages.sort { $0.rank > $1.rank }
    if pages.count > limit { pages.removeSubrange(limit...) }

    let typed = typedSuggestion(query)
    let typedHost: String? = {
      if case .url(let url)? = typed?.kind { return host(of: url) }
      return nil
    }()
    let autocomplete = pages.first { page in
      AddressInput.autocompletes(candidateHost: host(of: page.url), typedHost: typedHost, query: lower)
    }?.row
    // Menu commands right after what you typed (Ardia: after the first row and the search). An exact name ("zoom in")
    // leads, so Enter runs it, but never over a host the field autocompletes, and an address never matches one.
    var actionRows: [Suggestion] = []
    var leading: Suggestion?
    if typedHost == nil {
      for (index, match) in BarActions.matches(query, in: actions()).enumerated() {
        let row = actionSuggestion(match.action)
        if index == 0, match.exact, match.action.leads, autocomplete == nil { leading = row } else { actionRows.append(row) }
      }
    }
    // With nothing else to lead, the best page you go to leads over a search for what you typed (Arc; Chromium's
    // "allowed to be default match"): only for a search (a typed address still goes there), from three characters,
    // matched at word starts, and never an old search results page (Enter would run that search, not yours).
    var rows: [Suggestion] = []
    if let first = autocomplete ?? leading {
      rows.append(first)
    } else if case .search? = typed?.kind, query.count >= leadMinimumLength,
              let page = pages.first(where: { $0.strong && $0.frecency >= leadFrecency && !AddressInput.isSearch($0.url) }) {
      rows.append(page.row)
    }
    if let typed { rows.append(typed) }
    rows += actionRows
    rows += pages.map(\.row).filter { row in !rows.contains { same($0, row) } }
    // Search suggestions only fill what's left of the rows the bar shows at once, two at most, after the pages.
    let room = min(maxSearchSuggestions, max(0, visibleRows - rows.count))
    rows += searches
      .filter { $0.lowercased() != lower }
      .prefix(room)
      .compactMap(searchSuggestion)
    return Array(rows.prefix(limit))
  }

  /// How well `tokens` match a page: nil when one of them is in neither the title nor the address. A word scores most
  /// at the start of the title or the host, then at a word start, least inside a word; the whole query starting the
  /// title adds a little (Chromium autocompletes titles that start with what you typed).
  private static func match(
    _ tokens: [String], query: String, title: String, url: String
  ) -> (score: Double, strong: Bool)? {
    var total = 0.0
    var strong = true
    for token in tokens {
      let inTitle = grade(token, in: title)
      let inURL = grade(token, in: url)
      if inTitle == 0 && inURL == 0 { return nil }
      if max(inTitle, inURL) < 2 { strong = false }
      total += [0, 10, 25, 40][inTitle] + [0, 10, 25, 50][inURL]
    }
    var score = total / Double(max(1, tokens.count))
    if title.hasPrefix(query) { score += 20 }
    return (score, strong)
  }

  /// 3: `text` starts with `token`; 2: a word in it does; 1: it's inside a word; 0: it isn't there.
  private static func grade(_ token: String, in text: String) -> Int {
    if text.hasPrefix(token) { return 3 }
    var found = 0
    var from = text.startIndex
    while let range = text.range(of: token, range: from..<text.endIndex) {
      if range.lowerBound == text.startIndex { return 3 }
      let before = text[text.index(before: range.lowerBound)]
      if !before.isLetter && !before.isNumber { return 2 }
      found = 1
      from = text.index(after: range.lowerBound)
    }
    return found
  }

  /// An address as matched: lowercased, without the scheme and "www.".
  static func matchable(_ url: String) -> String {
    var text = url.lowercased()
    for prefix in ["https://", "http://"] where text.hasPrefix(prefix) {
      text.removeFirst(prefix.count)
      break
    }
    if text.hasPrefix("www.") { text.removeFirst(4) }
    return text
  }

  /// A page's address as a row shows it after the title, like Arc: the host, then the end of the path, the middle
  /// elided ("github.com…ng-config/pull/644"). A long host loses its start instead, so the part that says whose site it
  /// is stays. No scheme, no query, no credentials; the path stays percent-encoded.
  static func shortAddress(_ url: String) -> String {
    guard let components = URLComponents(string: url), var host = components.host, !host.isEmpty,
          let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https"
    else { return AddressInput.display(for: url) }
    host = host.lowercased()
    if host.hasPrefix("www.") { host.removeFirst(4) }
    if let port = components.port { host += ":\(port)" }
    var path = components.percentEncodedPath
    while path.hasSuffix("/") { path.removeLast() }
    let full = host + path
    // Arc keeps about 16 characters of the path's end ("…job/configupdate") and some 30 in all.
    let budget = 32
    if full.count <= budget { return full }
    let head = host.count <= 20 ? host : "…" + host.suffix(15)
    if path.isEmpty { return head }
    let tail = path.suffix(max(16, budget - head.count - 1))
    return head + "…" + tail.drop { $0 == "/" }
  }

  private static func typedSuggestion(_ query: String) -> Suggestion? {
    guard let url = AddressInput.url(for: query) else { return nil }
    if AddressInput.isSearch(url) {
      return Suggestion(kind: .search(url), title: query, detail: "Search Google", icon: magnifier)
    }
    return Suggestion(kind: .url(url), title: AddressInput.display(for: url), detail: "Open", icon: globe)
  }

  private static func actionSuggestion(_ action: BarAction) -> Suggestion {
    Suggestion(
      kind: .action(action), title: action.title, detail: action.shortcut,
      icon: NSImage(systemSymbolName: action.symbol, accessibilityDescription: nil) ?? command)
  }

  private static func searchSuggestion(_ text: String) -> Suggestion? {
    let query = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=?#"))) ?? text
    let url = AddressInput.searchTemplate.replacingOccurrences(of: "%s", with: query)
    return Suggestion(kind: .search(url), title: text, detail: "", icon: magnifier, suggested: true)
  }

  static func wantsSearchSuggestions(for raw: String) -> Bool {
    let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty, query.count <= 200, let url = AddressInput.url(for: query) else { return false }
    return AddressInput.isSearch(url)
  }

  /// A page row: its title, then its short address (only the full address when it has no title).
  private static func pageSuggestion(kind: Suggestion.Kind, url: String, title: String, icon: NSImage?) -> Suggestion {
    Suggestion(
      kind: kind, title: title.isEmpty ? AddressInput.display(for: url) : title,
      detail: title.isEmpty ? "" : shortAddress(url), icon: icon)
  }

  private static func tabSuggestion(_ tab: RayCoreTab) -> Suggestion {
    pageSuggestion(kind: .tab(tab), url: tab.url, title: tab.title, icon: tab.favicon ?? globe)
  }

  private static func historySuggestion(_ entry: HistoryItem, favicon: (String) -> NSImage?) -> Suggestion {
    pageSuggestion(kind: .history(entry.url), url: entry.url, title: entry.title, icon: favicon(entry.url) ?? clock)
  }

  private static func host(of url: String) -> String { AddressInput.host(of: url) }

  private static func same(_ a: Suggestion, _ b: Suggestion) -> Bool {
    switch (a.kind, b.kind) {
    case let (.tab(x), .tab(y)): return x === y
    case let (.history(x), .history(y)): return x == y
    default: return false
    }
  }
}
