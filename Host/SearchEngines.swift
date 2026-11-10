import Foundation

// What the command bar searches with (Settings › Search): the default engine, its suggestions, and the user's site
// searches, which a keyword then Tab (or a space) scopes a search to.
//
// Ray keeps its own list rather than Chrome's TemplateURLService: the engine only lists its engines
// (`ac_search_engines_list`, read-only) and Ray's command bar searches by itself (`AddressInput.url(for:)`), so the
// default can change without an engine build. Ardia does the same (`BUILT_IN_ENGINES`), as do Crest and Cra. Pages that
// search through Chrome itself (a page's "Search Google for …" menu item) still use Chrome's default.

/// A search engine Settings › Search offers as the default. `%s` is the query; suggestions are OpenSearch's JSON,
/// `[query, [suggestion, …]]`.
struct SearchEngine: Equatable {
  let id: String
  let name: String
  /// Its host: Tab (or a space) after it in the command bar scopes a search to it, as Chrome's keywords for its
  /// prepopulated engines do.
  let keyword: String
  let url: String
  let suggestURL: String?
}

/// A search the command bar is scoped to: a site search, or a built-in engine by its host.
struct SearchScope: Equatable {
  let name: String
  let keyword: String
  let template: String
  /// The site's colour ("#RRGGBB") for the chip, the glow and the chosen row: Arc's table for the built-in ones
  /// (`autoActivatedEngineURLToPrimaryColor`); nil takes the site's icon colour, else the profile's.
  var brand: String? = nil

  /// `query` searched there; nil for a template Ray doesn't search with (never one it stored).
  func url(for query: String) -> String? { AddressInput.siteSearchURL(template, query: query) }
}

enum SearchEngines {
  /// The list, Ardia's engines without its regional and AI-chat extras (those are a site search away). Google first:
  /// the default, as in Arc, Chrome and Ardia.
  static let builtIn: [SearchEngine] = [
    SearchEngine(id: "google", name: "Google", keyword: "google.com", url: AddressInput.googleSearchTemplate,
                 suggestURL: "https://suggestqueries.google.com/complete/search?client=firefox&q=%s"),
    SearchEngine(id: "duckduckgo", name: "DuckDuckGo", keyword: "duckduckgo.com", url: "https://duckduckgo.com/?q=%s",
                 suggestURL: "https://duckduckgo.com/ac/?q=%s&type=list"),
    SearchEngine(id: "bing", name: "Bing", keyword: "bing.com", url: "https://www.bing.com/search?q=%s",
                 suggestURL: "https://api.bing.com/osjson.aspx?query=%s"),
    SearchEngine(id: "brave", name: "Brave Search", keyword: "search.brave.com", url: "https://search.brave.com/search?q=%s",
                 suggestURL: "https://search.brave.com/api/suggest?q=%s"),
    SearchEngine(id: "ecosia", name: "Ecosia", keyword: "ecosia.org", url: "https://www.ecosia.org/search?q=%s",
                 suggestURL: "https://ac.ecosia.org/autocomplete?q=%s&type=list"),
    SearchEngine(id: "kagi", name: "Kagi", keyword: "kagi.com", url: "https://kagi.com/search?q=%s", suggestURL: nil),
    SearchEngine(id: "startpage", name: "Startpage", keyword: "startpage.com", url: "https://www.startpage.com/do/search?q=%s",
                 suggestURL: "https://www.startpage.com/osuggestions?q=%s"),
    SearchEngine(id: "perplexity", name: "Perplexity", keyword: "perplexity.ai", url: "https://www.perplexity.ai/search?q=%s",
                 suggestURL: nil),
  ]

  static func engine(id: String) -> SearchEngine? { builtIn.first { $0.id == id } }

  /// The engines' colours, as the site searches' below.
  private static let engineBrands = [
    "google.com": "#4285F4", "duckduckgo.com": "#DE5833", "bing.com": "#008373", "search.brave.com": "#FB542B",
    "ecosia.org": "#36ACB8", "kagi.com": "#FFB319", "startpage.com": "#6573FF", "perplexity.ai": "#20808D",
  ]

  /// Arc's built-in site searches (its app's own list, less Google's image, news and flight searches, which share
  /// google.com's host), each with its brand colour. A user's site search with the same keyword comes first.
  static let siteSearches: [SearchScope] = [
    SearchScope(name: "YouTube", keyword: "youtube.com", template: "https://www.youtube.com/results?search_query=%s", brand: "#FF0000"),
    SearchScope(name: "Wikipedia", keyword: "wikipedia.org", template: "https://en.wikipedia.org/w/index.php?search=%s", brand: "#000000"),
    SearchScope(name: "GitHub", keyword: "github.com", template: "https://github.com/search?q=%s", brand: "#181717"),
    SearchScope(name: "Google Maps", keyword: "maps.google.com", template: "https://www.google.com/maps/search/%s", brand: "#34A853"),
    SearchScope(name: "Google Drive", keyword: "drive.google.com", template: "https://drive.google.com/drive/search?q=%s", brand: "#1FA463"),
    SearchScope(name: "Google Docs", keyword: "docs.google.com", template: "https://docs.google.com/document/u/0/?q=%s", brand: "#4285F4"),
    SearchScope(name: "Google Calendar", keyword: "calendar.google.com",
                template: "https://calendar.google.com/calendar/u/0/r/search?q=%s", brand: "#4285F4"),
    SearchScope(name: "Amazon", keyword: "amazon.com", template: "https://www.amazon.com/s?k=%s", brand: "#FF9900"),
    SearchScope(name: "Reddit", keyword: "reddit.com", template: "https://www.reddit.com/search/?q=%s", brand: "#FF4500"),
    SearchScope(name: "X", keyword: "x.com", template: "https://x.com/search?q=%s", brand: "#000000"),
    SearchScope(name: "LinkedIn", keyword: "linkedin.com",
                template: "https://www.linkedin.com/search/results/all/?keywords=%s", brand: "#0A66C2"),
    SearchScope(name: "Pinterest", keyword: "pinterest.com", template: "https://www.pinterest.com/search/pins/?q=%s", brand: "#E60023"),
    SearchScope(name: "Spotify", keyword: "open.spotify.com", template: "https://open.spotify.com/search/%s", brand: "#1DB954"),
    SearchScope(name: "SoundCloud", keyword: "soundcloud.com", template: "https://soundcloud.com/search?q=%s", brand: "#FF5500"),
    SearchScope(name: "Apple Music", keyword: "music.apple.com", template: "https://music.apple.com/us/search?term=%s", brand: "#FA243C"),
    SearchScope(name: "Stack Overflow", keyword: "stackoverflow.com", template: "https://stackoverflow.com/search?q=%s", brand: "#F48024"),
    SearchScope(name: "Figma", keyword: "figma.com", template: "https://www.figma.com/files/search?q=%s", brand: "#A259FF"),
    SearchScope(name: "Dropbox", keyword: "dropbox.com", template: "https://www.dropbox.com/search/personal?query=%s", brand: "#0061FF"),
    SearchScope(name: "Asana", keyword: "app.asana.com", template: "https://app.asana.com/0/search?q=%s", brand: "#F06A6A"),
    SearchScope(name: "Goodreads", keyword: "goodreads.com", template: "https://www.goodreads.com/search?query=%s", brand: "#553B08"),
    SearchScope(name: "Netflix", keyword: "netflix.com", template: "https://www.netflix.com/search?q=%s", brand: "#E50914"),
    SearchScope(name: "Threads", keyword: "threads.net", template: "https://www.threads.net/search/?q=%s", brand: "#000000"),
    SearchScope(name: "TikTok", keyword: "tiktok.com", template: "https://www.tiktok.com/search?q=%s", brand: "#FE2C55"),
  ]

  /// The user's site searches, then the built-in ones whose keyword they haven't taken.
  private static var allSiteSearches: [SearchScope] {
    let own = RaySettings.shared[.siteSearches].items.map { SearchScope(name: $0.name, keyword: $0.keyword, template: $0.url) }
    return own + siteSearches.filter { site in !own.contains { $0.keyword == site.keyword } }
  }

  /// The default engine (Settings › Search engine).
  static var chosen: SearchEngine { engine(id: RaySettings.shared[.searchEngine]) ?? builtIn[0] }

  /// Where the command bar's search suggestions come from as you type: the chosen engine's, when Settings › Search
  /// suggestions is on and it has them; nil sends nothing anywhere. Test builds send every engine's to the fixture
  /// (RAY_SUGGEST_URL, `%e` the engine's id), never to a real engine.
  static var suggestURL: String? {
    let engine = chosen
    guard RaySettings.shared[.searchSuggestions], let url = engine.suggestURL else { return nil }
    return TestEnvironment["RAY_SUGGEST_URL"].map { $0.replacingOccurrences(of: "%e", with: engine.id) } ?? url
  }

  /// Points the command bar's searches (`AddressInput.searchTemplate`) at the chosen engine. Once, at launch.
  static func install() { AddressInput.searchTemplateSource = { chosen.url } }

  /// The search `word` scopes the command bar to: a site search by its keyword, else a built-in engine by its host
  /// (Chrome's and Ardia's keywords). Nil for anything else.
  static func scope(forKeyword word: String) -> SearchScope? {
    let keyword = word.trimmingCharacters(in: .whitespaces).lowercased()
    guard !keyword.isEmpty else { return nil }
    let bare = keyword.hasPrefix("www.") ? String(keyword.dropFirst(4)) : keyword
    if let site = allSiteSearches.first(where: { $0.keyword == keyword || $0.keyword == bare }) { return site }
    if let engine = builtIn.first(where: { $0.keyword == bare }) {
      return SearchScope(name: engine.name, keyword: engine.keyword, template: engine.url, brand: engineBrands[engine.keyword])
    }
    return nil
  }

  /// The site search the command bar offers for what you typed (Arc's "Search YouTube  Tab"): an exact keyword, else
  /// the site search whose keyword, name or a word of its name starts with it ("y", "you", "maps"). Several match: the
  /// one whose site you use most (`use`, by keyword), then the list's order. Engines only by their exact host.
  static func offer(for typed: String, use: (String) -> Double) -> SearchScope? {
    let text = typed.trimmingCharacters(in: .whitespaces).lowercased()
    guard !text.isEmpty, text.count <= 64, !text.contains(" ") else { return nil }
    if let exact = scope(forKeyword: text) { return exact }
    let bare = text.hasPrefix("www.") ? String(text.dropFirst(4)) : text
    var best: (scope: SearchScope, use: Double)?
    for site in allSiteSearches where starts(site, with: bare) {
      let used = use(site.keyword)
      if best == nil || used > best!.use { best = (site, used) }
    }
    return best?.scope
  }

  private static func starts(_ site: SearchScope, with text: String) -> Bool {
    let name = site.name.lowercased()
    return site.keyword.hasPrefix(text) || name.replacingOccurrences(of: " ", with: "").hasPrefix(text)
      || name.split(separator: " ").contains { $0.hasPrefix(text) }
  }
}

// MARK: Site searches

/// A site search of the user's: a name, the keyword that scopes the command bar to it, and its address with `%s`.
struct SiteSearch: Equatable {
  let name: String
  let keyword: String
  let url: String

  static let longestName = 64
  /// Crest's limit.
  static let longestKeyword = 32
  static let most = 100

  struct Problem: Error, Equatable {
    let message: String
  }

  /// A site search from what the user typed, tidied (trimmed, the keyword lowercased) and checked, or what's wrong
  /// with it, in words for the editor. `others` are the rest of the user's site searches: a keyword names one thing.
  static func make(name: String, keyword: String, url: String, among others: [SiteSearch]) -> Result<SiteSearch, Problem> {
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let keyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let url = url.trimmingCharacters(in: .whitespacesAndNewlines)
    func fail(_ message: String) -> Result<SiteSearch, Problem> { .failure(Problem(message: message)) }
    if name.isEmpty { return fail("Enter a name.") }
    if name.count > longestName || name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
      return fail("Use a shorter name, on one line.")
    }
    if keyword.isEmpty { return fail("Enter a keyword.") }
    if keyword.count > longestKeyword
      || keyword.unicodeScalars.contains(where: {
        CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) || "/:".unicodeScalars.contains($0)
      }) {
      return fail("A keyword is one short word: no spaces, slashes or colons.")
    }
    if let engine = SearchEngines.builtIn.first(where: { $0.keyword == keyword || "www." + $0.keyword == keyword }) {
      return fail("“\(keyword)” already searches \(engine.name).")
    }
    if let other = others.first(where: { $0.keyword == keyword }) {
      return fail("“\(keyword)” is already the keyword for \(other.name).")
    }
    if !url.contains("%s") { return fail("Put %s in the address where the search terms go.") }
    guard let template = AddressInput.siteSearchTemplate(url) else {
      return fail("Enter an address that starts with https:// (or http://), with %s where the search terms go.")
    }
    return .success(SiteSearch(name: name, keyword: keyword, url: template))
  }

  var json: [String: String] { ["name": name, "keyword": keyword, "url": url] }

  static func from(json: Any) -> (name: String, keyword: String, url: String)? {
    guard let entry = json as? [String: Any], let name = entry["name"] as? String, let keyword = entry["keyword"] as? String,
          let url = entry["url"] as? String else { return nil }
    return (name, keyword, url)
  }
}

/// The user's site searches, as a setting's value (`siteSearches`): every entry valid, keywords unique. Settings.json
/// keeps them as a list of `{name, keyword, url}`; as text (the test command, the catalog check) they are that list's
/// JSON on one line.
struct SiteSearchList: SettingValue {
  var items: [SiteSearch]

  init(_ items: [SiteSearch]) { self.items = items }

  /// Entries checked in order; nil when any isn't valid (`lenient`: those are dropped instead).
  static func checked(_ entries: [(name: String, keyword: String, url: String)], lenient: Bool = false) -> SiteSearchList? {
    var accepted: [SiteSearch] = []
    for entry in entries {
      switch SiteSearch.make(name: entry.name, keyword: entry.keyword, url: entry.url, among: accepted) {
      case .success(let site) where accepted.count < SiteSearch.most: accepted.append(site)
      default: if !lenient { return nil }
      }
    }
    return SiteSearchList(accepted)
  }

  /// The setting's validation: the list as it would be stored, or nil.
  static func validate(_ list: SiteSearchList) -> SiteSearchList? {
    checked(list.items.map { ($0.name, $0.keyword, $0.url) })
  }

  /// From Settings.json: what isn't a valid entry (an older or damaged file) is dropped, the rest kept.
  init?(settingJSON json: Any) {
    guard let list = json as? [Any] else { return nil }
    self = Self.checked(list.compactMap(SiteSearch.from(json:)), lenient: true) ?? SiteSearchList([])
  }

  var settingJSON: Any? { items.isEmpty ? nil : items.map(\.json) }

  /// From text: strict, every entry valid.
  init?(settingText text: String) {
    guard let data = text.data(using: .utf8), let list = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return nil }
    let entries = list.compactMap(SiteSearch.from(json:))
    guard entries.count == list.count, let checked = Self.checked(entries) else { return nil }
    self = checked
  }

  var settingText: String {
    guard let data = try? JSONSerialization.data(withJSONObject: items.map(\.json), options: [.sortedKeys, .withoutEscapingSlashes]),
          let text = String(data: data, encoding: .utf8) else { return "[]" }
    return text
  }
}
