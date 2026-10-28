import Foundation

/// The profile's default search engine, as the engine (Chromium's TemplateURLService, the list Settings edits) last
/// reported it. Everything it says is untrusted text: a template is used only after `validated`, and anything that
/// fails falls back to Google for searches and to no remote suggestions.
enum SearchEngine {
  static let fallbackTemplate = "https://www.google.com/search?q=%s"
  static let placeholder = "%s"

  struct Choice: Equatable {
    var name: String
    var search: String
    var suggestions: String?
  }

  /// Test builds can pin the search and suggestion URLs from the environment, so checks never reach a real engine.
  /// `useEngine(true)` (a test command) lifts only the search one, to test the engine's own default: the suggestions
  /// stay on the fixture, so a check never asks a real engine for anything. Normal builds have no override.
  private static let pinnedSearch = TestEnvironment["RAY_SEARCH_URL"]
  private(set) static var searchOverride = pinnedSearch
  private static let suggestionsOverride = TestEnvironment["RAY_SUGGEST_URL"]

  /// The last default the engine reported and Ray accepted; nil until the first reply or when it was unusable.
  private(set) static var current: Choice?

  static var searchTemplate: String { searchOverride ?? current?.search ?? fallbackTemplate }
  static var suggestionsTemplate: String? { suggestionsOverride ?? current?.suggestions }
  static var displayName: String { searchOverride != nil ? "Search" : current?.name ?? "Google" }

  static func useEngine(_ engine: Bool) {
    guard TestEnvironment.isTestBuild else { return }
    searchOverride = engine ? nil : pinnedSearch
  }

  /// The default engine out of an `ac_search_engines_list` reply. A nil reply (the call failed) keeps what Ray knew.
  /// Returns whether the choice changed.
  @discardableResult
  static func apply(_ reply: [String: Any]?) -> Bool {
    guard let engines = reply?["engines"] as? [[String: Any]] else { return false }
    let chosen = chosen(from: engines)
    guard chosen != current else { return false }
    current = chosen
    return true
  }

  static func chosen(from engines: [[String: Any]]) -> Choice? {
    guard let engine = engines.first(where: { $0["default"] as? Bool == true }),
          let search = validated(engine["url"] as? String) else { return nil }
    return Choice(
      name: cleanName(engine["name"] as? String), search: search,
      suggestions: validated(engine["suggestionsUrl"] as? String))
  }

  /// A template Ray will load or fetch: https (http only for a local host), a host, no credentials, and the
  /// search-terms placeholder exactly once. Placeholders Chromium leaves in its display form (`{google:RLZ}`,
  /// `{inputEncoding}`) are dropped with their query item; one anywhere else rejects the template. Returns the
  /// cleaned template, else nil.
  static func validated(_ raw: String?) -> String? {
    guard let raw, raw.count <= 2048,
          raw.unicodeScalars.allSatisfy({ !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.controlCharacters.contains($0) })
    else { return nil }
    var template = raw
    if let question = template.firstIndex(of: "?") {
      let items = template[template.index(after: question)...].split(separator: "&", omittingEmptySubsequences: true)
      let kept = items.filter { !$0.contains("{") && !$0.contains("}") }
      template = String(template[...question]) + kept.joined(separator: "&")
      if template.hasSuffix("?") && !raw.hasSuffix("?") { template.removeLast() }
    }
    guard !template.contains("{"), !template.contains("}"),
          template.components(separatedBy: placeholder).count == 2,
          let components = URLComponents(string: template.replacingOccurrences(of: placeholder, with: "x")),
          let scheme = components.scheme?.lowercased(), let host = components.host?.lowercased(), !host.isEmpty,
          components.user == nil, components.password == nil
    else { return nil }
    if scheme == "https" { return template }
    return scheme == "http" && isLoopback(host) ? template : nil
  }

  static func isLoopback(_ host: String) -> Bool {
    if host == "localhost" || host.hasSuffix(".localhost") || host == "[::1]" { return true }
    let parts = host.split(separator: ".")
    return parts.count == 4 && parts.first == "127" && parts.allSatisfy { UInt8($0) != nil }
  }

  /// `text` made safe for the place the placeholder sits: a query value, or a path segment.
  static func encode(_ text: String, into template: String) -> String {
    var allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=?#"))
    let before = template.components(separatedBy: placeholder).first ?? ""
    if !before.contains("?") { allowed.subtract(CharacterSet(charactersIn: "/")) }
    return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
  }

  static func searchURL(for text: String, template: String = SearchEngine.searchTemplate) -> String {
    template.replacingOccurrences(of: placeholder, with: encode(text, into: template))
  }

  /// Whether `url` is a results page of `template`: the text before and after the placeholder both match.
  static func isResults(_ url: String, of template: String) -> Bool {
    let parts = template.components(separatedBy: placeholder)
    guard parts.count == 2, url.hasPrefix(parts[0]), url.count > parts[0].count + parts[1].count else { return false }
    return parts[1].isEmpty || url.hasSuffix(parts[1])
  }

  /// What a suggestions endpoint answered. OpenSearch JSON (`[query, [suggestion, …]]`, which Google, Bing and
  /// DuckDuckGo with `type=list` give) and DuckDuckGo's `ac` list (`[{"phrase": …}]`); anything else is nothing.
  static func parseSuggestions(_ data: Data) -> [String]? {
    guard data.count <= 64 * 1024, let json = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return nil }
    var found: [String]?
    if json.count > 1, let list = json[1] as? [String] {
      found = list
    } else if !json.isEmpty, json.allSatisfy({ ($0 as? [String: Any])?["phrase"] is String }) {
      found = json.compactMap { ($0 as? [String: Any])?["phrase"] as? String }
    }
    return found?.filter { !$0.isEmpty && $0.count <= 200 }.prefix(20).map { $0 }
  }

  static func cleanName(_ name: String?) -> String {
    let scalars = (name ?? "").unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
    let text = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespaces)
    return text.isEmpty ? "the default engine" : String(text.prefix(40))
  }
}
