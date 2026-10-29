import AppKit
import UniformTypeIdentifiers

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
    } else if text.lowercased().hasPrefix(viewSource + internalScheme + "://") {
      // The source of one of the engine's own pages, written as the address shows it (`display(for:)`).
      text = viewSource + "chrome://" + text.dropFirst(viewSource.count + internalScheme.count + 3)
    }
    if let colon = text.firstIndex(of: ":") {
      let scheme = text[..<colon].lowercased()
      if scheme == "javascript" { return nil }
      if passThroughSchemes.contains(scheme) && !looksLikeHostAndPort(text) {
        return isRemovedSettingsPage(text) ? settingsHome : text
      }
    }
    if !text.contains(" "), let host = hostPart(of: text), isHost(host) {
      return (isLocal(host) ? "http://" : "https://") + text
    }
    let query = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=?#"))) ?? text
    return searchTemplate.replacingOccurrences(of: "%s", with: query)
  }

  /// Chrome settings pages Ray's own Settings window stands in for, and the pane each opens: Appearance and behavior
  /// (`/appearance`, its `/fonts` page), and Profiles (`/people` and the pages under it), whose colour is in
  /// Appearance. The engine's page has neither any more (tools/trim-settings-pak.py), so a typed or in-page address
  /// to one of them goes to the window, never to a page that would only show something else.
  private static let nativeSettingsPaths: [String: String] = [
    "appearance": "appearance", "fonts": "appearance",
    "people": "appearance", "profiles": "appearance", "manageprofile": "appearance", "account": "appearance",
    "googleservices": "appearance", "signout": "appearance", "importdata": "appearance",
  ]

  /// Settings pages that are gone from the engine's page (tools/trim-settings-pak.py) with nothing of Ray's to stand in
  /// for them: Search engine (`/search`, `/searchEngines`), because Ray searches with a fixed Google. An address to one
  /// of them goes to the settings page itself, never to a page that would only show something else.
  private static let removedSettingsPaths: Set<String> = ["search", "searchengines"]

  /// What follows `chrome://settings/` in a `chrome://` or `ray://` settings address (lowercased, no slashes at the
  /// ends), or nil for any other address. The address is a URL the engine or `url(for:)` gave, never something a page
  /// said about itself.
  private static func settingsPath(of url: String) -> String? {
    guard let components = URLComponents(string: url.trimmingCharacters(in: .whitespacesAndNewlines)),
          let scheme = components.scheme?.lowercased(), scheme == "chrome" || scheme == internalScheme,
          components.host?.lowercased() == "settings", components.user == nil, components.password == nil
    else { return nil }
    return components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
  }

  /// The pane of Ray's own Settings window that a `chrome://settings/<page>` (or `ray://`) address stands for; Chrome's
  /// other settings pages still load as they are.
  static func nativeSettingsPane(for url: String) -> String? {
    settingsPath(of: url).flatMap { nativeSettingsPaths[$0] }
  }

  /// Where the settings page goes for a page it no longer has (see `removedSettingsPaths`).
  static let settingsHome = "chrome://settings/"

  /// Whether `url` is one of the settings pages the engine's page no longer has.
  static func isRemovedSettingsPage(_ url: String) -> Bool {
    settingsPath(of: url).map { removedSettingsPaths.contains($0) } ?? false
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
    // The ASCII (punycode) host, never the Unicode one: Ray has no IDN spoof checker, and a Cyrillic `аpple.com`
    // must not read as apple.com.
    if let host = components?.encodedHost, !host.isEmpty {
      return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
    let scheme = (components?.scheme ?? url.split(separator: ":").first.map(String.init) ?? "").lowercased()
    switch scheme {
    case "view-source":
      guard let inner = unwrapped(url)?.inner, URLComponents(string: inner)?.scheme != nil else { return viewSource }
      return viewSource + pillText(for: inner)
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
    if let (wrapper, inner) = unwrapped(url) { return wrapper + display(for: inner) }
    guard var components = URLComponents(string: url), components.host != nil else { return url }
    components.user = nil
    components.password = nil
    let text = components.string ?? url
    if components.scheme?.lowercased() == "chrome" { return internalScheme + text.dropFirst("chrome".count) }
    return text
  }

  // MARK: Address display

  static let viewSource = "view-source:"

  /// Schemes whose address is another URL: Chrome shows the scheme, then the inner URL formatted as any other, with
  /// its host as the emphasized part (`AutocompleteInput::ParseForEmphasizeComponents`, `url_formatter`'s
  /// view-source case).
  private static let wrapperSchemes = [viewSource, "blob:", "filesystem:"]

  /// A `view-source:`, `blob:` or `filesystem:` address split into its wrapper (lowercased) and the URL inside; nil
  /// for any other address. One level only, as in Chrome: an inner URL that is itself wrapped isn't taken apart.
  static func unwrapped(_ url: String) -> (wrapper: String, inner: String)? {
    let lower = url.lowercased()
    guard let wrapper = wrapperSchemes.first(where: { lower.hasPrefix($0) }) else { return nil }
    let inner = String(url.dropFirst(wrapper.count))
    let innerLower = inner.lowercased()
    guard !inner.isEmpty, !wrapperSchemes.contains(where: { innerLower.hasPrefix($0) }) else { return nil }
    return (wrapper, inner)
  }

  /// The URL whose host an address is about: the inner one of a wrapped address (`unwrapped`), else the address.
  /// The address is the engine's (the tab's URL), never anything a page said about itself.
  static func innerURL(of url: String) -> String { unwrapped(url)?.inner ?? url }

  /// The page address bar's text: a grey lead (the wrapper of a `view-source:` or `blob:` address), the host (no
  /// scheme or www., port kept; medium weight), then the rest: path, query and fragment, percent-encoded as the URL
  /// has them, grey. `user:pass@` never shows. A built-in page is all host, as ray://.
  struct AddressParts: Equatable {
    var lead = ""
    var host = ""
    var trail = ""
    var text: String { lead + host + trail }
  }

  static func addressParts(for url: String) -> AddressParts {
    guard !url.isEmpty else { return AddressParts() }
    if let (wrapper, inner) = unwrapped(url) {
      var parts = addressParts(for: inner)
      // An inner part with no scheme (`blob:null/…`) is no URL to take apart.
      guard URLComponents(string: inner)?.scheme != nil, !parts.host.isEmpty else {
        return AddressParts(host: pillText(for: url))
      }
      parts.lead = wrapper + parts.lead
      return parts
    }
    let shown = display(for: url)
    guard let components = URLComponents(string: shown), let host = components.encodedHost, !host.isEmpty else {
      return AddressParts(host: pillText(for: url))
    }
    if components.scheme == internalScheme { return AddressParts(host: shown) }
    let bareHost = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    let port = components.port.map { ":\($0)" } ?? ""
    var trail = components.percentEncodedPath == "/" ? "" : components.percentEncodedPath
    if let query = components.percentEncodedQuery { trail += "?" + query }
    if let fragment = components.percentEncodedFragment { trail += "#" + fragment }
    if !trail.isEmpty, !trail.hasPrefix("/") { trail = "/" + trail }
    return AddressParts(host: bareHost + port, trail: trail)
  }

  // MARK: Opens from other apps

  /// The document types Ray opens from Finder, as Info.plist declares them (scripts/build-app.sh), Arc's set: HTML
  /// and XHTML (what macOS needs to list Ray as a web browser) and PDF (the engine's PDF viewer; an alternate, so
  /// Preview stays the default).
  static let documentTypes = ["public.html", "public.xhtml", "com.adobe.pdf"]

  /// Chrome's longest URL (url::kMaxURLChars); anything longer from another app is refused.
  private static let longestLink = 2 * 1024 * 1024

  /// A link another app handed Ray (a click in Mail, `open -a Ray <url>`), as the address to load: http or https
  /// with a host, nothing else. Never `javascript:`, `data:`, `file:` or the engine's own pages: another app can
  /// send any URL it likes, and Chrome only takes web URLs from a launch too (`ValidateLaunchUrlWebSafe`).
  static func link(fromOtherApp url: URL) -> String? {
    let text = url.absoluteString
    guard text.utf8.count <= longestLink, let components = URLComponents(string: text),
          let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
          let host = components.host, !host.isEmpty else { return nil }
    return Self.url(for: text)
  }

  /// A file another app or Finder asked Ray to open (a document open, never a `file:` link), as its `file:` address:
  /// only an existing local regular file whose type is one of `documentTypes`. A symlink counts as the file it points
  /// to. Opening one is the user's choice in Finder, as typing a `file:` address is.
  static func document(fromOtherApp url: URL) -> String? {
    guard url.isFileURL, url.host.map({ $0.isEmpty || $0 == "localhost" }) ?? true, url.user == nil else { return nil }
    let file = url.standardizedFileURL.resolvingSymlinksInPath()
    guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .contentTypeKey]),
          values.isRegularFile == true, let type = values.contentType,
          documentTypes.contains(where: { UTType($0).map(type.conforms(to:)) ?? false }) else { return nil }
    return Self.url(for: URL(fileURLWithPath: file.path).absoluteString)
  }

  // MARK: Typed addresses

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
  /// `url` is the tab's address; a `view-source:` or `blob:` one is judged by the URL inside, the page the engine's
  /// level is for.
  static func of(level: String?, url: String) -> ConnectionLook {
    let components = URLComponents(string: AddressInput.innerURL(of: url))
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
