import Foundation

enum AddressInput {
  static let searchTemplate = TestEnvironment["RAY_SEARCH_URL"]
    ?? "https://www.google.com/search?q=%s"

  private static let passThroughSchemes: Set<String> = ["http", "https", "file", "chrome", "about", "data", "view-source"]

  static func url(for input: String) -> String? {
    let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return nil }
    if let colon = text.firstIndex(of: ":") {
      let scheme = text[..<colon].lowercased()
      if scheme == "javascript" { return nil }
      if passThroughSchemes.contains(scheme) && !looksLikeHostAndPort(text) { return text }
    }
    if !text.contains(" "), let host = hostPart(of: text), isHost(host) {
      return (isLocal(host) ? "http://" : "https://") + text
    }
    let query = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=?#"))) ?? text
    return searchTemplate.replacingOccurrences(of: "%s", with: query)
  }

  static func isSearch(_ url: String) -> Bool {
    url.hasPrefix(searchTemplate.replacingOccurrences(of: "%s", with: ""))
  }

  static func host(of url: String) -> String {
    let host = URLComponents(string: url)?.host?.lowercased() ?? ""
    return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
  }

  static func registrableDomain(_ host: String) -> String {
    let labels = host.split(separator: ".")
    guard labels.count > 2, let last = labels.last else { return host }
    let second = labels[labels.count - 2]
    let take = last.count == 2 && second.count <= 3 ? 3 : 2
    return labels.suffix(take).joined(separator: ".")
  }

  static func autocompletes(candidateHost: String, typedHost: String?, query: String) -> Bool {
    guard !candidateHost.isEmpty else { return false }
    if let typedHost { return candidateHost == typedHost }
    return registrableDomain(candidateHost).hasPrefix(query.lowercased())
  }

  static func pillText(for url: String) -> String {
    guard !url.isEmpty else { return "" }
    let components = URLComponents(string: url)
    if let host = components?.host, !host.isEmpty {
      return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
    let scheme = (components?.scheme ?? url.split(separator: ":").first.map(String.init) ?? "").lowercased()
    switch scheme {
    case "about":
      return "about:" + (components?.path ?? "")
    case "file":
      return "file: " + ((components?.path ?? "") as NSString).lastPathComponent
    case "blob":
      let inner = URLComponents(string: String(url.dropFirst(5)))?.host ?? ""
      return inner.isEmpty ? "blob:" : "blob: " + inner
    default:
      return scheme.isEmpty ? "" : scheme + ":"
    }
  }

  static func display(for url: String) -> String {
    guard var components = URLComponents(string: url), components.host != nil else { return url }
    components.user = nil
    components.password = nil
    return components.string ?? url
  }

  private static func hostPart(of text: String) -> String? {
    let end = text.firstIndex(where: { "/?#".contains($0) }) ?? text.endIndex
    let authority = text[..<end]
    let host = authority.split(separator: "@").last.map(String.init) ?? String(authority)
    if host.hasPrefix("[") { return host }
    return host.split(separator: ":").first.map(String.init)
  }

  private static func looksLikeHostAndPort(_ text: String) -> Bool {
    guard let colon = text.firstIndex(of: ":") else { return false }
    let rest = text[text.index(after: colon)...]
    let port = rest.prefix(while: { $0.isNumber })
    return !port.isEmpty && (port.endIndex == rest.endIndex || "/?#".contains(rest[port.endIndex]))
  }

  private static func isHost(_ host: String) -> Bool {
    if isLocal(host) { return true }
    let labels = host.split(separator: ".", omittingEmptySubsequences: false)
    guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty }) else { return false }
    guard let tld = labels.last, tld.count >= 2 else { return false }
    return tld.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
  }

  private static func isLocal(_ host: String) -> Bool {
    if host == "localhost" || host.hasSuffix(".localhost") || host.hasPrefix("[") { return true }
    let parts = host.split(separator: ".")
    return parts.count == 4 && parts.allSatisfy { UInt8($0) != nil }
  }
}
