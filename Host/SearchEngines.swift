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
    if let site = RaySettings.shared[.siteSearches].items.first(where: { $0.keyword == keyword }) {
      return SearchScope(name: site.name, keyword: site.keyword, template: site.url)
    }
    let bare = keyword.hasPrefix("www.") ? String(keyword.dropFirst(4)) : keyword
    if let engine = builtIn.first(where: { $0.keyword == bare }) {
      return SearchScope(name: engine.name, keyword: engine.keyword, template: engine.url)
    }
    return nil
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
