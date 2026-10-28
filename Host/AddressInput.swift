import AppKit

enum AddressInput {
  static let searchTemplate = TestEnvironment["RAY_SEARCH_URL"]
    ?? "https://www.google.com/search?q=%s"

  private static let passThroughSchemes: Set<String> = ["http", "https", "file", "chrome", "about", "data", "view-source"]

  /// Ray's name for the engine's own pages, as Arc has arc://: ray://settings is chrome://settings.
  static let internalScheme = "ray"

  static func url(for input: String) -> String? {
    var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return nil }
    if text.lowercased().hasPrefix(internalScheme + "://") {
      text = "chrome://" + text.dropFirst(internalScheme.count + 3)
    }
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
    if components?.scheme?.lowercased() == "chrome", let host = components?.host, !host.isEmpty {
      return internalScheme + "://" + host
    }
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
    let text = components.string ?? url
    if components.scheme?.lowercased() == "chrome" { return internalScheme + text.dropFirst("chrome".count) }
    return text
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

/// How the address shows a page's connection. Chrome counts loopback hosts as trustworthy and never warns on them;
/// Ray also stays quiet on `*.localhost` and `*.test`, names that only ever point at the user's own dev servers.
/// Plain http elsewhere gets a grey open lock, like Chrome's grey "Not secure"; red is kept for a certificate error
/// on a real site, the one case worth stopping for.
enum ConnectionLook: Equatable {
  case quiet, local, open, partly, broken

  /// `level` is the engine's security level for the tab (`secure`, `mixed`, `insecure`, `certificateError`, …).
  static func of(level: String?, url: String) -> ConnectionLook {
    let components = URLComponents(string: url)
    let level = level ?? (components?.scheme == "http" ? "insecure" : "none")
    switch level {
    case "insecure", "certificateError":
      if isDevHost(components?.host ?? "") { return .local }
      return level == "insecure" ? .open : .broken
    case "mixed": return .partly
    default: return .quiet
    }
  }

  static func isDevHost(_ host: String) -> Bool {
    let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".test") || host == "::1" { return true }
    let parts = host.split(separator: ".", omittingEmptySubsequences: false)
    return parts.count == 4 && parts.allSatisfy { UInt8($0) != nil } && parts[0] == "127"
  }

  /// The icon beside the address, if any.
  var symbol: String? {
    switch self {
    case .quiet, .local: return nil
    case .open: return "lock.open.fill"
    case .partly: return "lock.trianglebadge.exclamationmark.fill"
    case .broken: return "lock.slash.fill"
    }
  }

  var tint: NSColor {
    switch self {
    case .broken: return .systemRed
    case .partly: return .systemOrange
    default: return .tertiaryLabelColor
    }
  }

  var label: String {
    switch self {
    case .open: return "Not secure"
    case .partly: return "Partly secure"
    case .broken: return "Certificate not valid"
    default: return ""
    }
  }
}
