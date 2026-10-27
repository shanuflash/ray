import Foundation

enum AddressInput {
  static let searchTemplate = "https://www.google.com/search?q=%s"

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
