import AppKit

struct Suggestion {
  enum Kind {
    case tab(ArdiaCoreTab)
    case url(String)
    case search(String)
    case history(String)
  }

  let kind: Kind
  let title: String
  let detail: String
  let icon: NSImage?

  var key: String {
    switch kind {
    case .tab(let tab): return "tab:\(tab.tabId)"
    case .url(let url), .search(let url), .history(let url): return "\(kindName):\(url)"
    }
  }

  var kindName: String {
    switch kind {
    case .tab: return "tab"
    case .url: return "url"
    case .search: return "search"
    case .history: return "history"
    }
  }
}

struct HistoryEntry {
  let url: String
  let title: String
  let visits: Int
  let lastVisit: Double
}

final class HistoryCache {
  private(set) var entries: [HistoryEntry] = []
  private var loading = false

  func refresh(profile: ArdiaCoreProfile, then done: @escaping () -> Void) {
    if loading { return }
    loading = true
    EngineCalls.call("ac_history_query", profile: profile, args: ["maxUrls": 3000, "maxVisits": 1]) { [weak self] reply in
      guard let self else { return }
      self.loading = false
      guard let rows = reply?["entries"] as? [[String: Any]] else { return }
      self.entries = rows.compactMap { row in
        guard let url = row["u"] as? String else { return nil }
        let visits = (row["v"] as? [Double]) ?? []
        return HistoryEntry(
          url: url, title: row["t"] as? String ?? "", visits: row["n"] as? Int ?? 0, lastVisit: visits.last ?? 0)
      }
      done()
    }
  }
}

final class FaviconCache {
  private var images: [String: NSImage] = [:]
  private var missing: Set<String> = []
  private var requested: Set<String> = []

  func image(for page: String) -> NSImage? { images[page] }

  func load(_ pages: [String], profile: ArdiaCoreProfile, then done: @escaping () -> Void) {
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
  static let endpoint = environment["LUMEN_SUGGEST_URL"]
    ?? "https://suggestqueries.google.com/complete/search?client=firefox&q=%s"

  private var cache: [String: [String]] = [:]
  private var latest: (query: String, results: [String]) = ("", [])
  private var pending: DispatchWorkItem?
  private var task: URLSessionDataTask?

  func current(for query: String) -> [String] {
    let key = query.lowercased()
    if let exact = cache[key] { return exact }
    guard !latest.query.isEmpty, key.hasPrefix(latest.query) else { return [] }
    return latest.results.filter { $0.lowercased().hasPrefix(key) }
  }

  func fetch(_ query: String, then done: @escaping () -> Void) {
    pending?.cancel()
    let key = query.lowercased()
    guard !key.isEmpty, cache[key] == nil else { return }
    let work = DispatchWorkItem { [weak self] in self?.request(key, then: done) }
    pending = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
  }

  private func request(_ key: String, then done: @escaping () -> Void) {
    task?.cancel()
    let encoded = key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=?#"))) ?? key
    guard let url = URL(string: Self.endpoint.replacingOccurrences(of: "%s", with: encoded)) else { return }
    task = URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
      guard let data,
            let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
            json.count > 1, let list = json[1] as? [String] else { return }
      DispatchQueue.main.async {
        guard let self else { return }
        self.cache[key] = list
        self.latest = (key, list)
        done()
      }
    }
    task?.resume()
  }
}

enum Suggestions {
  static let limit = 8
  private static let globe = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
  private static let clock = NSImage(systemSymbolName: "clock", accessibilityDescription: nil)
  private static let magnifier = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)

  static let maxSearchSuggestions = 4

  static func build(
    query raw: String, tabs: [ArdiaCoreTab], active: ArdiaCoreTab?, history: [HistoryEntry], searches: [String],
    favicon: (String) -> NSImage? = { _ in nil }
  ) -> [Suggestion] {
    let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if query.isEmpty {
      return tabs.filter { $0 !== active }.prefix(limit).map(tabSuggestion)
    }
    let tokens = query.lowercased().split(separator: " ").map(String.init)
    let matchingTabs = tabs.filter { matches(tokens, $0.title, $0.url) }.prefix(4).map(tabSuggestion)
    let openURLs = Set(tabs.map(\.url))
    let now = Date().timeIntervalSince1970 * 1000
    let matchingHistory = history
      .filter { !openURLs.contains($0.url) && matches(tokens, $0.title, $0.url) }
      .map { entry in (entry, score(entry, query: query.lowercased(), now: now)) }
      .sorted { $0.1 > $1.1 }
      .prefix(6)
      .map { entry, _ in
        Suggestion(
          kind: .history(entry.url), title: entry.title.isEmpty ? entry.url : entry.title,
          detail: AddressInput.display(for: entry.url), icon: favicon(entry.url) ?? clock)
      }

    var rows: [Suggestion] = []
    let typed = typedSuggestion(query)
    let autocomplete = (matchingTabs + matchingHistory).first { hostStarts($0, with: query.lowercased()) }
    if let autocomplete { rows.append(autocomplete) }
    if let typed { rows.append(typed) }
    let searchRows = searches
      .filter { $0.lowercased() != query.lowercased() }
      .prefix(maxSearchSuggestions)
      .compactMap(searchSuggestion)
    let others = (matchingTabs + matchingHistory).filter { row in !rows.contains { same($0, row) } }
    let room = max(0, limit - rows.count - min(others.count, 3))
    rows += searchRows.prefix(room)
    rows += others
    return Array(rows.prefix(limit))
  }

  private static func typedSuggestion(_ query: String) -> Suggestion? {
    guard let url = AddressInput.url(for: query) else { return nil }
    if AddressInput.isSearch(url) {
      return Suggestion(kind: .search(url), title: query, detail: "Search Google", icon: magnifier)
    }
    return Suggestion(kind: .url(url), title: AddressInput.display(for: url), detail: "Open", icon: globe)
  }

  private static func searchSuggestion(_ text: String) -> Suggestion? {
    let query = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=?#"))) ?? text
    let url = AddressInput.searchTemplate.replacingOccurrences(of: "%s", with: query)
    return Suggestion(kind: .search(url), title: text, detail: "", icon: magnifier)
  }

  static func wantsSearchSuggestions(for raw: String) -> Bool {
    let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty, query.count <= 200, let url = AddressInput.url(for: query) else { return false }
    return AddressInput.isSearch(url)
  }

  private static func tabSuggestion(_ tab: ArdiaCoreTab) -> Suggestion {
    Suggestion(
      kind: .tab(tab), title: tab.title.isEmpty ? AddressInput.display(for: tab.url) : tab.title,
      detail: AddressInput.display(for: tab.url), icon: tab.favicon ?? globe)
  }

  private static func matches(_ tokens: [String], _ title: String, _ url: String) -> Bool {
    let haystack = (title + " " + url).lowercased()
    return tokens.allSatisfy { haystack.contains($0) }
  }

  private static func score(_ entry: HistoryEntry, query: String, now: Double) -> Double {
    let days = max(0, (now - entry.lastVisit) / 86_400_000)
    var score = log(Double(entry.visits) + 1) * 2 - days / 14
    if host(of: entry.url).hasPrefix(query) { score += 6 }
    if entry.title.lowercased().hasPrefix(query) { score += 2 }
    return score
  }

  private static func hostStarts(_ suggestion: Suggestion, with query: String) -> Bool {
    switch suggestion.kind {
    case .tab(let tab): return host(of: tab.url).hasPrefix(query)
    case .history(let url): return host(of: url).hasPrefix(query)
    default: return false
    }
  }

  private static func host(of url: String) -> String {
    let host = URLComponents(string: url)?.host?.lowercased() ?? ""
    return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
  }

  private static func same(_ a: Suggestion, _ b: Suggestion) -> Bool {
    switch (a.kind, b.kind) {
    case let (.tab(x), .tab(y)): return x === y
    case let (.history(x), .history(y)): return x == y
    default: return false
    }
  }
}
