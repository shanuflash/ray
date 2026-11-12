import AppKit

struct Suggestion {
  enum Kind {
    case tab(RayCoreTab)
    case url(String)
    case search(String)
    case history(String)
    /// A bookmarked page ("Bookmark" on the right), visited or not.
    case bookmark(String)
    case action(BarAction)
    /// A pane, setting or section of Ray's Settings window ("Settings: …").
    case setting(SettingsTarget)
  }

  let kind: Kind
  let title: String
  let detail: String
  let icon: NSImage?
  /// A search suggestion from the search engine (not what you typed).
  var suggested = false
  /// The leading row's host, which the field completes inline after what was typed (Chrome's and Arc's inline
  /// autocomplete): "shanu" shows "shanu.surveysparrow.com" with the rest selected.
  var completion: String?

  var key: String {
    switch kind {
    case .tab(let tab): return "tab:\(tab.tabId)"
    case .url(let url), .search(let url), .history(let url), .bookmark(let url): return "\(kindName):\(url)"
    case .action(let action): return "action:\(action.id)"
    case .setting(let target): return "setting:\(target.id)"
    }
  }

  /// What ↑ ↓ or Tab to this row puts in the bar's field (Chrome's temporary text): a search its query, a page its
  /// address (the engine's, through `AddressInput.display`: no `user:pass@`, percent-encoded). Nil keeps what was typed:
  /// menu commands and settings (Chrome's actions keep it too), and an address the bar doesn't show
  /// (`javascript:`, `data:`, `file:`).
  var fieldText: String? {
    switch kind {
    case .search: return title
    case .tab(let tab): return Self.fieldAddress(tab.url)
    case .url(let url), .history(let url), .bookmark(let url): return Self.fieldAddress(url)
    case .action, .setting: return nil
    }
  }

  private static func fieldAddress(_ url: String) -> String? {
    guard !url.isEmpty, BrowserWindowController.isPinnable(AddressInput.innerURL(of: url)) else { return nil }
    return AddressInput.display(for: url)
  }

  var kindName: String {
    switch kind {
    case .tab: return "tab"
    case .url: return "url"
    case .search: return "search"
    case .history: return "history"
    case .bookmark: return "bookmark"
    case .action: return "action"
    case .setting: return "setting"
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
  /// The address's host, registrable domain and whether it is its site's front page (`Suggestions.facts`), read once
  /// here: the bar asks for them on every key.
  let site: Suggestions.Site

  init(url: String, title: String, visits: Int, visitTimes: [Double], now: Double) {
    self.url = url
    self.title = title
    self.visits = visits
    lastVisit = visitTimes.max() ?? 0
    frecency = visitTimes.sorted(by: >).prefix(10).reduce(0) { $0 + Self.recency(days: (now - $1) / 86_400_000) }
    titleLower = title.lowercased()
    urlLower = Suggestions.matchable(url)
    site = Suggestions.facts(url)
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

/// A bookmark as the bar matches it (`Bookmarks.barItems`).
struct BookmarkItem {
  let url: String
  let title: String
  let titleLower: String
  let urlLower: String

  init(url: String, title: String) {
    self.url = url
    self.title = title
    titleLower = title.lowercased()
    urlLower = Suggestions.matchable(url)
  }
}

final class HistoryCache {
  private(set) var entries: [HistoryItem] = []
  private var byURL: [String: Int] = [:]
  private var loading = false

  private var byHost: [String: Double] = [:]

  /// Frecency of a page by its exact address (0 when it isn't in history).
  func frecency(of url: String) -> Double { byURL[url].map { entries[$0].frecency } ?? 0 }

  /// How much you use a site: its pages' frecency added up, by host without "www." (the bar's site search offer).
  func use(ofHost host: String) -> Double { byHost[host] ?? 0 }

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
      self.byHost = self.entries.reduce(into: [:]) { use, entry in
        let host = entry.urlLower.prefix { !"/:?#".contains($0) }
        use[String(host), default: 0] += entry.frecency
      }
      done()
    }
  }
}

/// An icon's main colour, as Arc's FaviconDominantColorFetcher and Ardia's `iconAccent`: the heaviest band of hues
/// (24 bins, a bin and its neighbours) among the saturated, bright pixels, averaged; nil when under 8% of the icon has
/// colour (a black or grey logo).
enum IconAccent {
  static func color(of image: NSImage) -> NSColor? {
    let side = 24
    guard let bitmap = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
      isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: side * 4, bitsPerPixel: 32),
      let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
    NSGraphicsContext.restoreGraphicsState()
    guard let data = bitmap.bitmapData else { return nil }
    var bins = [(weight: Double, r: Double, g: Double, b: Double)](repeating: (0, 0, 0, 0), count: 24)
    var opaque = 0.0, colourful = 0.0
    for i in 0..<(side * side) {
      let a = Double(data[i * 4 + 3]) / 255
      guard a > 0.5 else { continue }
      // Premultiplied: back to the colour itself.
      let r = Double(data[i * 4]) / 255 / a, g = Double(data[i * 4 + 1]) / 255 / a, b = Double(data[i * 4 + 2]) / 255 / a
      opaque += 1
      let high = max(r, g, b), low = min(r, g, b)
      guard high > 0.35, high - low > 0.35 * high else { continue }
      colourful += 1
      var hue: Double
      if high == r { hue = (g - b) / (high - low) } else if high == g { hue = 2 + (b - r) / (high - low) } else { hue = 4 + (r - g) / (high - low) }
      hue = (hue / 6).truncatingRemainder(dividingBy: 1)
      if hue < 0 { hue += 1 }
      let bin = min(23, Int(hue * 24))
      bins[bin].weight += 1
      bins[bin].r += r
      bins[bin].g += g
      bins[bin].b += b
    }
    guard opaque > 0, colourful / opaque >= 0.08 else { return nil }
    let window = { (i: Int) in bins[(i + 23) % 24].weight + bins[i].weight + bins[(i + 1) % 24].weight }
    guard let best = (0..<24).max(by: { window($0) < window($1) }) else { return nil }
    var total = (w: 0.0, r: 0.0, g: 0.0, b: 0.0)
    for i in [(best + 23) % 24, best, (best + 1) % 24] {
      total.w += bins[i].weight
      total.r += bins[i].r
      total.g += bins[i].g
      total.b += bins[i].b
    }
    guard total.w > 0 else { return nil }
    return NSColor(srgbRed: min(1, total.r / total.w), green: min(1, total.g / total.w), blue: min(1, total.b / total.w), alpha: 1)
  }
}

final class FaviconCache {
  private var images: [String: NSImage] = [:]
  private var missing: Set<String> = []
  private var requested: Set<String> = []

  func image(for page: String) -> NSImage? { images[page] }

  private var accents: [String: NSColor?] = [:]

  /// A page's icon's main colour, nil for a grey icon or none loaded (`IconAccent`), kept per page.
  func accent(for page: String) -> NSColor? {
    if let known = accents[page] { return known }
    guard let image = images[page] else { return nil }
    let accent = IconAccent.color(of: image)
    accents[page] = accent
    return accent
  }

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

/// The default engine's suggestions as you type (`SearchEngines.suggestURL`): nothing is sent when Settings › Search
/// suggestions is off or the engine has none, and what one engine said is never shown for another.
final class SearchSuggestions {
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
  /// The endpoint the cache is from.
  private var cachedFrom: String?

  /// The endpoint to ask now, with the cache emptied when it changed (another engine, suggestions turned off).
  private func endpoint() -> String? {
    let now = SearchEngines.suggestURL
    if now != cachedFrom {
      cachedFrom = now
      cache = [:]
      shown = ("", [])
    }
    return now
  }

  func current(for query: String) -> [String] {
    guard endpoint() != nil else { return [] }
    let key = query.lowercased()
    if let exact = cache[key] { return exact }
    guard !shown.query.isEmpty, key.hasPrefix(shown.query) else { return [] }
    return shown.results.filter { $0.lowercased().hasPrefix(key) }
  }

  func warm() {
    guard endpoint() != nil, Date().timeIntervalSince(lastRequest) > Self.warmInterval else { return }
    lastRequest = Date()
    send("", then: nil)
  }

  func fetch(_ query: String, then done: @escaping () -> Void) {
    let key = query.lowercased()
    wanted = key
    scheduled?.cancel()
    guard endpoint() != nil, !key.isEmpty, cache[key] == nil else { return }
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
    guard let endpoint = endpoint(), let url = URL(string: AddressInput.searchURL(endpoint, query: key)) else { return }
    var request = URLRequest(url: url)
    request.assumesHTTP3Capable = true
    request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
    request.setValue(Locale.preferredLanguages.prefix(3).joined(separator: ","), forHTTPHeaderField: "Accept-Language")
    session.dataTask(with: request) { [weak self] data, _, _ in
      guard let done, let data,
            let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
            json.count > 1, let list = json[1] as? [String] else { return }
      DispatchQueue.main.async {
        // An answer from an engine that is no longer the one asked is dropped.
        guard let self, self.endpoint() == endpoint else { return }
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
/// opens it), then what you typed, then the other pages, and the search engine's suggestions to fill what's left of
/// the five rows the bar shows at once (all ten, scrolling, when nothing of yours matches).
enum Suggestions {
  /// Rows in all; the bar shows `visibleRows` of them at once and scrolls to the rest.
  static let limit = 10
  static let visibleRows = 5
  private static let globe = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
  private static let clock = NSImage(systemSymbolName: "clock", accessibilityDescription: nil)
  private static let magnifier = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
  private static let command = NSImage(systemSymbolName: "command", accessibilityDescription: nil)

  static let emptyQueryRows = 5
  /// A page takes the first row from this many typed characters (Chromium autocompletes titles from 3).
  static let leadMinimumLength = 3
  /// ... and only one you go to: two visits in the last four days, or one in a tab that's open (Chromium promotes a
  /// history match to the default row only once it was typed more than once).
  static let leadFrecency = 1.5
  /// What being open counts for, in visits (Ardia ranks open tabs a little up).
  private static let openTabFrecency = 1.0
  /// ... and being bookmarked (Chrome and Ardia rank bookmarks up): one recent visit then lets it lead.
  private static let bookmarkFrecency = 1.0

  /// A page that matched what you typed: an open tab, a history entry or a bookmark. Its row is made only once it is
  /// one of the few shown: a letter matches most of history, and a row costs an address to shorten and an icon.
  private struct Page {
    enum Source {
      case tab(RayCoreTab, name: String?)
      case history(HistoryItem)
      case bookmark(BookmarkItem)
    }

    let source: Source
    let url: String
    let site: Site
    let match: Double
    /// Every word matched at a word start in the title or the address (Chromium's HistoryQuick only matches there).
    let strong: Bool
    let frecency: Double
    let rank: Double

    init(_ source: Source, url: String, site: Site, match: Double, strong: Bool, frecency: Double) {
      self.source = source
      self.url = url
      self.site = site
      self.match = match
      self.strong = strong
      self.frecency = frecency
      rank = match + 12 * min(frecency, 10)
    }

    var isTab: Bool {
      if case .tab = source { return true }
      return false
    }

    var isHistory: Bool {
      if case .history = source { return true }
      return false
    }

    func row(favicon: (String) -> NSImage?) -> Suggestion {
      Suggestions.work.rowsMade += 1
      switch source {
      case .tab(let tab, let name): return tabSuggestion(tab, name: name)
      case .history(let entry): return historySuggestion(entry, favicon: favicon)
      case .bookmark(let bookmark): return bookmarkSuggestion(bookmark, favicon: favicon)
      }
    }
  }

  /// What an address says about its site: the host (no "www."), its registrable domain, and whether the address is the
  /// site's front page (no path but "/", no query).
  struct Site {
    let host: String
    let domain: String
    let isRoot: Bool
  }

  /// `Site` of an address, parsed once and kept (main thread only): history's addresses come back on every key.
  static func facts(_ url: String) -> Site {
    if let known = sites[url] { return known }
    work.parses += 1
    let components = URLComponents(string: url)
    var host = components?.host?.lowercased() ?? ""
    if host.hasPrefix("www.") { host.removeFirst(4) }
    let isRoot = components.map { ($0.path.isEmpty || $0.path == "/") && $0.query == nil } ?? false
    let site = Site(host: host, domain: AddressInput.registrableDomain(host), isRoot: isRoot)
    if sites.count >= 20_000 { sites.removeAll(keepingCapacity: true) }
    sites[url] = site
    return site
  }
  private static var sites: [String: Site] = [:]

  /// For the state log and the check `bar-key-work`: what the last `build` cost. `matched` pages of `scanned` history
  /// entries, `rowsMade` page rows made (a few, however many matched), `parses` addresses parsed (none once seen),
  /// `ms` on the main thread.
  struct Work {
    var builds = 0
    var scanned = 0
    var matched = 0
    var rowsMade = 0
    var parses = 0
    var ms = 0.0
    var maxMs = 0.0
  }
  static var work = Work()

  /// The rows for `raw`. `active` is this window's own tab: it's never offered (switching to it does nothing, and its
  /// page is the one you're on), though another tab on the same address is.
  static func build(
    query raw: String, tabs: [RayCoreTab], active: RayCoreTab?, history: [HistoryItem], searches: [String],
    bookmarks: [BookmarkItem] = [], actions: () -> [BarAction] = { [] },
    settings: (String) -> [(target: SettingsTarget, exact: Bool)] = { _ in [] }, frecency: (String) -> Double = { _ in 0 },
    favicon: (String) -> NSImage? = { _ in nil }, name: (RayCoreTab) -> String? = { _ in nil }
  ) -> [Suggestion] {
    let started = DispatchTime.now().uptimeNanoseconds
    work.builds += 1
    work.scanned = 0
    work.matched = 0
    work.rowsMade = 0
    work.parses = 0
    defer {
      work.ms = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6
      work.maxMs = max(work.maxMs, work.ms)
    }
    let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    let others = tabs.filter { $0 !== active }
    let openURLs = Set(tabs.map(\.url))
    if query.isEmpty {
      let open = others.prefix(limit).map { tabSuggestion($0, name: name($0)) }
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
    let tokens = needle.split(separator: " ").map(Token.init)
    var pages: [Page] = []
    for tab in others {
      // A renamed tab shows its own name, and is found by it or by its page's title.
      let own = name(tab)
      let url = tab.url
      let address = matchable(url)
      var best = match(tokens, query: needle, title: tab.title.lowercased(), url: address)
      if let own, let named = match(tokens, query: needle, title: own.lowercased(), url: address),
         best.map({ $0.score <= named.score }) ?? true {
        best = named
      }
      guard let match = best else { continue }
      pages.append(Page(
        .tab(tab, name: own), url: url, site: facts(url), match: match.score, strong: match.strong,
        frecency: frecency(url) + openTabFrecency))
    }
    // The current page's history entry goes with its tab (it's open), so it never comes back as a history row. A
    // bookmarked page is one row, its bookmark's (found by either title), ranked with its visits and a bookmark's
    // lift; one never visited still shows.
    let marked = Dictionary(bookmarks.map { ($0.url, $0) }) { first, _ in first }
    var seenBookmarks = Set<String>()
    work.scanned = history.count
    for entry in history where !openURLs.contains(entry.url) {
      let bookmark = marked.isEmpty ? nil : marked[entry.url]
      var best = match(tokens, query: needle, title: entry.titleLower, url: entry.urlLower)
      if let bookmark, let named = match(tokens, query: needle, title: bookmark.titleLower, url: entry.urlLower),
         best.map({ $0.score <= named.score }) ?? true {
        best = named
      }
      guard let match = best else { continue }
      if let bookmark {
        seenBookmarks.insert(bookmark.url)
        pages.append(Page(
          .bookmark(bookmark), url: entry.url, site: entry.site, match: match.score, strong: match.strong,
          frecency: entry.frecency + bookmarkFrecency))
      } else {
        pages.append(Page(
          .history(entry), url: entry.url, site: entry.site, match: match.score, strong: match.strong,
          frecency: entry.frecency))
      }
    }
    for bookmark in bookmarks where !openURLs.contains(bookmark.url) && seenBookmarks.insert(bookmark.url).inserted {
      guard let match = match(tokens, query: needle, title: bookmark.titleLower, url: bookmark.urlLower) else { continue }
      pages.append(Page(
        .bookmark(bookmark), url: bookmark.url, site: facts(bookmark.url), match: match.score, strong: match.strong,
        frecency: bookmarkFrecency))
    }
    work.matched = pages.count
    pages.sort { $0.rank > $1.rank }

    let typed = typedSuggestion(query)
    let typedHost: String? = {
      if case .url(let url)? = typed?.kind { return AddressInput.host(of: url) }
      return nil
    }()
    let completing = pages.first { page in
      AddressInput.autocompletes(
        candidateHost: page.site.host, domain: page.site.domain, typedHost: typedHost, lowercasedQuery: lower,
        trusted: page.isTab || page.frecency >= leadFrecency)
    }
    // A host the field completes inline leads as the site itself, as in Arc: its open tab ("Switch to Tab"), else its
    // root page. Its other pages, and other sites' pages but their best (or root) one, step aside: typing the start
    // of a host is looking for a site, so the list offers sites, one row each.
    var site: String?
    var autocomplete = completing.map { $0.row(favicon: favicon) }
    if let completing, typedHost == nil, completing.site.host.hasPrefix(lower), completing.site.host != lower {
      let siteHost = completing.site.host
      site = siteHost
      var lead = others.first { facts($0.url).host == siteHost }.map { tabSuggestion($0, name: name($0)) }
        ?? history.first { $0.site.isRoot && $0.site.host == siteHost }.map { historySuggestion($0, favicon: favicon) }
        ?? (completing.site.isRoot ? autocomplete : nil)
        ?? Suggestion(kind: .url(root(of: completing.url)), title: siteHost, detail: "", icon: autocomplete?.icon)
      lead.completion = siteHost
      autocomplete = lead
    }
    if !tokens.isEmpty {
      // Each site's front page in history (the first of several), looked up only once a page's host starts with what
      // was typed.
      var roots: [String: HistoryItem]?
      let first = tokens[0].text
      var seen = Set(site.map { [$0] } ?? [])
      pages = pages.compactMap { page in
        guard page.isHistory else { return page }
        let pageHost = page.site.host
        guard pageHost.hasPrefix(first) else { return page }
        guard seen.insert(pageHost).inserted else { return nil }
        if roots == nil {
          var found: [String: HistoryItem] = [:]
          for entry in history where entry.site.isRoot && found[entry.site.host] == nil { found[entry.site.host] = entry }
          roots = found
        }
        guard let root = roots?[pageHost], root.url != page.url else { return page }
        return Page(.history(root), url: root.url, site: root.site, match: page.match, strong: page.strong,
                    frecency: page.frecency)
      }
    }
    if pages.count > limit { pages.removeSubrange(limit...) }
    let pageRows = pages.map { $0.row(favicon: favicon) }
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
    // Settings by name after the commands ("Settings: Theme colour"). One leads only when it was named in full after
    // "settings" and nothing real is there to go to: no host the field completes, no command, no page that matches.
    var settingRows: [Suggestion] = []
    if typedHost == nil {
      for (index, match) in settings(query).enumerated() {
        let row = settingSuggestion(match.target)
        if index == 0, match.exact, leading == nil, autocomplete == nil, pages.isEmpty { leading = row } else { settingRows.append(row) }
      }
    }
    // With nothing else to lead, the best page you go to leads over a search for what you typed (Arc; Chromium's
    // "allowed to be default match"): only for a search (a typed address still goes there), from three characters,
    // matched at word starts, and never an old search results page (Enter would run that search, not yours).
    var rows: [Suggestion] = []
    if let first = autocomplete ?? leading {
      rows.append(first)
    } else if case .search? = typed?.kind, query.count >= leadMinimumLength,
              let page = pages.firstIndex(where: { $0.strong && $0.frecency >= leadFrecency && !AddressInput.isSearch($0.url) }) {
      rows.append(pageRows[page])
    }
    if let typed { rows.append(typed) }
    rows += actionRows
    rows += settingRows
    rows += pageRows.filter { row in !rows.contains { same($0, row) } }
    // Search suggestions fill what's left of the five rows the bar shows at once, after your own rows, so once those
    // and what you typed take three they get two at most. With nothing of yours (no site, tab, page, bookmark,
    // command or setting), they fill all ten rows, as Chrome's and Arc's lists do.
    let own = rows.filter { row in typed.map { $0.key != row.key } ?? true }.count
    let room = own == 0 ? limit - rows.count : max(0, visibleRows - rows.count)
    rows += searches
      .filter { $0.lowercased() != lower }
      .prefix(room)
      .compactMap(searchSuggestion)
    return Array(rows.prefix(limit))
  }

  /// A typed word as matched: its text and, when it is plain ASCII, its bytes (`grade`'s fast path).
  private struct Token {
    let text: String
    let ascii: [UInt8]?

    init<S: StringProtocol>(_ text: S) {
      self.text = String(text)
      let bytes = Array(self.text.utf8)
      ascii = bytes.allSatisfy { $0 < 0x80 && $0 != 13 } ? bytes : nil
    }
  }

  private static let titleScores = [0.0, 10, 25, 40]
  private static let urlScores = [0.0, 10, 25, 50]

  /// How well `tokens` match a page: nil when one of them is in neither the title nor the address. A word scores most
  /// at the start of the title or the host, then at a word start, least inside a word; the whole query starting the
  /// title adds a little (Chromium autocompletes titles that start with what you typed).
  private static func match(
    _ tokens: [Token], query: String, title: String, url: String
  ) -> (score: Double, strong: Bool)? {
    var total = 0.0
    var strong = true
    for token in tokens {
      let inTitle = grade(token, in: title)
      let inURL = grade(token, in: url)
      if inTitle == 0 && inURL == 0 { return nil }
      if max(inTitle, inURL) < 2 { strong = false }
      total += titleScores[inTitle] + urlScores[inURL]
    }
    var score = total / Double(max(1, tokens.count))
    if title.hasPrefix(query) { score += 20 }
    return (score, strong)
  }

  /// 3: `text` starts with `token`; 2: a word in it does; 1: it's inside a word; 0: it isn't there.
  private static func grade(_ token: Token, in text: String) -> Int {
    if text.hasPrefix(token.text) { return 3 }
    // Plain ASCII on both sides (nearly every title and address) is searched as bytes: the same answer as the string
    // search below at a fraction of its cost, which one letter over thousands of history entries pays on every key.
    if let needle = token.ascii, !needle.isEmpty,
       let fast = text.utf8.withContiguousStorageIfAvailable({ gradeASCII(needle, in: $0) }), let grade = fast {
      return grade
    }
    var found = 0
    var from = text.startIndex
    while let range = text.range(of: token.text, range: from..<text.endIndex) {
      if range.lowerBound == text.startIndex { return 3 }
      let before = text[text.index(before: range.lowerBound)]
      if !before.isLetter && !before.isNumber { return 2 }
      found = 1
      from = text.index(after: range.lowerBound)
    }
    return found
  }

  /// `grade` over bytes; nil when `text` isn't plain ASCII (or has a carriage return: "\r\n" is one character).
  private static func gradeASCII(_ needle: [UInt8], in text: UnsafeBufferPointer<UInt8>) -> Int? {
    let count = text.count, length = needle.count
    for byte in text where byte >= 0x80 || byte == 13 { return nil }
    guard length <= count, let base = text.baseAddress else { return 0 }
    return needle.withUnsafeBufferPointer { needle -> Int in
      guard let start = needle.baseAddress else { return 0 }
      var found = 0
      var from = 0
      while from + length <= count, let hit = memmem(base + from, count - from, start, length) {
        let at = UnsafePointer(hit.assumingMemoryBound(to: UInt8.self)) - base
        if at == 0 { return 3 }
        let before = text[at - 1]
        let alphanumeric = (before >= 0x30 && before <= 0x39) || (before >= 0x41 && before <= 0x5A) || (before >= 0x61 && before <= 0x7A)
        if !alphanumeric { return 2 }
        found = 1
        from = at + 1
      }
      return found
    }
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
      // Just what you typed, as Arc shows it: no engine name.
      return Suggestion(kind: .search(url), title: query, detail: "", icon: magnifier)
    }
    return Suggestion(kind: .url(url), title: AddressInput.display(for: url), detail: "Open", icon: globe)
  }

  private static func actionSuggestion(_ action: BarAction) -> Suggestion {
    Suggestion(
      kind: .action(action), title: action.title, detail: action.shortcut,
      icon: NSImage(systemSymbolName: action.symbol, accessibilityDescription: nil) ?? command)
  }

  private static func settingSuggestion(_ target: SettingsTarget) -> Suggestion {
    let title = "Settings: " + (target.kind == .pane ? target.pane.title : target.title)
    return Suggestion(
      kind: .setting(target), title: title, detail: target.kind == .pane ? "" : target.caption,
      icon: NSImage(systemSymbolName: target.pane.symbol, accessibilityDescription: nil) ?? command)
  }

  private static func searchSuggestion(_ text: String) -> Suggestion? {
    let url = AddressInput.searchURL(AddressInput.searchTemplate, query: text)
    return Suggestion(kind: .search(url), title: text, detail: "", icon: magnifier, suggested: true)
  }

  /// The bar's one row while it is scoped to a site search: what you typed, searched there. No pages, no suggestions:
  /// nothing you type is sent anywhere before Enter.
  static func scoped(_ scope: SearchScope, query raw: String) -> [Suggestion] {
    let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty, let url = scope.url(for: query) else { return [] }
    return [Suggestion(kind: .search(url), title: query, detail: "", icon: magnifier)]
  }

  /// Whether to ask the search engine for suggestions as you type this: a search (not an address), with suggestions on.
  static func wantsSearchSuggestions(for raw: String) -> Bool {
    let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty, SearchEngines.suggestURL != nil, query.count <= 200, let url = AddressInput.url(for: query) else { return false }
    return AddressInput.isSearch(url)
  }

  /// A page row: its title, then its short address (only the full address when it has no title).
  private static func pageSuggestion(kind: Suggestion.Kind, url: String, title: String, icon: NSImage?) -> Suggestion {
    Suggestion(
      kind: kind, title: title.isEmpty ? AddressInput.display(for: url) : title,
      detail: title.isEmpty ? "" : shortAddress(url), icon: icon)
  }

  private static func tabSuggestion(_ tab: RayCoreTab, name: String?) -> Suggestion {
    pageSuggestion(kind: .tab(tab), url: tab.url, title: name ?? tab.title, icon: tab.favicon ?? globe)
  }

  private static func historySuggestion(_ entry: HistoryItem, favicon: (String) -> NSImage?) -> Suggestion {
    pageSuggestion(kind: .history(entry.url), url: entry.url, title: entry.title, icon: favicon(entry.url) ?? clock)
  }

  private static func bookmarkSuggestion(_ bookmark: BookmarkItem, favicon: (String) -> NSImage?) -> Suggestion {
    pageSuggestion(kind: .bookmark(bookmark.url), url: bookmark.url, title: bookmark.title, icon: favicon(bookmark.url) ?? globe)
  }

  /// The front page of an address's site.
  private static func root(of url: String) -> String {
    guard var components = URLComponents(string: url) else { return url }
    components.path = "/"
    components.query = nil
    components.fragment = nil
    return components.string ?? url
  }

  private static func same(_ a: Suggestion, _ b: Suggestion) -> Bool {
    switch (a.kind, b.kind) {
    case let (.tab(x), .tab(y)): return x === y
    case let (.history(x), .history(y)), let (.bookmark(x), .bookmark(y)): return x == y
    default: return false
    }
  }
}
