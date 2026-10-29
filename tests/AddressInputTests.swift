import Foundation

let search = { (q: String) in AddressInput.searchTemplate.replacingOccurrences(of: "%s", with: q) }

let cases: [(String, String?)] = [
  ("example.com", "https://example.com"),
  ("example.com/path?q=1", "https://example.com/path?q=1"),
  ("https://example.com", "https://example.com"),
  ("http://example.com:8080/x", "http://example.com:8080/x"),
  ("localhost:3000", "http://localhost:3000"),
  ("localhost", "http://localhost"),
  ("192.168.1.10:8080", "http://192.168.1.10:8080"),
  ("app.localhost", "http://app.localhost"),
  ("chrome://settings", "chrome://settings"),
  ("ray://settings", "chrome://settings"),
  ("RAY://settings/help", "chrome://settings/help"),
  // Settings' Search pages are addresses like any other (the window takes them: `nativeSettingsPane`).
  ("ray://settings/search", "chrome://settings/search"),
  ("chrome://settings/searchEngines?x=1", "chrome://settings/searchEngines?x=1"),
  ("chrome://settings/?search=theme", "chrome://settings/?search=theme"),
  ("chrome://settings/privacy", "chrome://settings/privacy"),
  ("ray://settings/privacy", "chrome://settings/content"),
  ("RAY://Settings/Privacy/", "chrome://settings/content"),
  ("chrome://settings/searchEngines/x", "chrome://settings/searchEngines/x"),
  ("chrome://extensions/search", "chrome://extensions/search"),
  ("ray://extensions", "chrome://extensions"),
  ("about:blank", "about:blank"),
  ("file:///tmp/a.html", "file:///tmp/a.html"),
  ("javascript:alert(1)", nil),
  ("JavaScript:alert(1)", nil),
  ("data:text/html,<p>x</p>", "data:text/html,<p>x</p>"),
  ("view-source:https://example.com/x#f", "view-source:https://example.com/x#f"),
  ("view-source:ray://settings/help", "view-source:chrome://settings/help"),
  ("  ", nil),
  ("hello world", search("hello%20world")),
  ("swift", search("swift")),
  ("a&b", search("a%26b")),
  ("what is 1+1", search("what%20is%201%2B1")),
  ("version 1.2", search("version%201.2")),
]

var failures = 0
for (input, expected) in cases {
  let got = AddressInput.url(for: input)
  if got != expected {
    failures += 1
    print("FAIL url(\(input.debugDescription)) = \(got.debugDescription), expected \(expected.debugDescription)")
  }
}
let displayCases: [(String, String)] = [
  ("https://user:pass@example.com/x", "https://example.com/x"),
  ("http://example.com:8080/", "http://example.com:8080/"),
  ("chrome://settings/help", "ray://settings/help"),
  ("https://example.com/x#frag", "https://example.com/x#frag"),
  ("view-source:https://user:pass@example.com/x#f", "view-source:https://example.com/x#f"),
  ("view-source:chrome://settings/help", "view-source:ray://settings/help"),
  ("data:text/html,<p>x</p>", "data:text/html,<p>x</p>"),
]
for (input, expected) in displayCases where AddressInput.display(for: input) != expected {
  failures += 1
  print("FAIL display(\(input)) = \(AddressInput.display(for: input)), expected \(expected)")
}
let pillCases: [(String, String)] = [
  ("https://www.example.com/path?q=1#x", "example.com"),
  ("http://localhost:3000/", "localhost"),
  ("chrome://settings/help", "ray://settings"),
  ("about:blank#////accounts.google.com", "about:blank"),
  ("about:blank?x=//accounts.google.com", "about:blank"),
  ("data:text/html,<h1>accounts.google.com</h1>", "data:"),
  ("blob:https://evil.example/1234-5678", "blob: evil.example"),
  ("file:///Users/me/Downloads/accounts.google.com.html", "file: accounts.google.com.html"),
  ("", ""),
  ("view-source:https://www.github.com/a/b#c", "view-source:github.com"),
  ("view-source:", "view-source:"),
  ("view-source:about:blank", "view-source:about:blank"),
  // IDN hosts stay punycode: no spoof checker, so a Cyrillic "а" never passes for a Latin one.
  ("https://www.xn--pple-43d.com/", "xn--pple-43d.com"),
]
for (input, expected) in pillCases where AddressInput.pillText(for: input) != expected {
  failures += 1
  print("FAIL pillText(\(input)) = \(AddressInput.pillText(for: input)), expected \(expected)")
}
// The page address bar: grey lead, host, grey trail. Full address shows the fragment as Chrome does; minimal shows
// lead and host and the trail only on hover (the view decides that, from the same parts).
typealias Parts = AddressInput.AddressParts
let partsCases: [(String, Parts)] = [
  ("https://github.com/mantrakp04/ardia/releases#release-v0.2.43-nightly.1",
   Parts(host: "github.com", trail: "/mantrakp04/ardia/releases#release-v0.2.43-nightly.1")),
  ("https://example.com/x?q=1&r=%20#sec%C3%A9", Parts(host: "example.com", trail: "/x?q=1&r=%20#sec%C3%A9")),
  ("https://example.com/#top", Parts(host: "example.com", trail: "/#top")),
  ("https://example.com/?q=1", Parts(host: "example.com", trail: "/?q=1")),
  ("https://www.example.com/", Parts(host: "example.com")),
  ("http://localhost:3000/a#b", Parts(host: "localhost:3000", trail: "/a#b")),
  ("https://user:pass@example.com/x", Parts(host: "example.com", trail: "/x")),
  ("view-source:https://github.com/mantrakp04/ardia/releases#release-v0.2.43-nightly.1",
   Parts(lead: "view-source:", host: "github.com", trail: "/mantrakp04/ardia/releases#release-v0.2.43-nightly.1")),
  ("view-source:https://www.example.com/", Parts(lead: "view-source:", host: "example.com")),
  ("VIEW-SOURCE:https://example.com/", Parts(lead: "view-source:", host: "example.com")),
  // `user:pass@` stays hidden inside view-source, and a lookalike host in the userinfo never leads.
  ("view-source:https://accounts.google.com:pw@evil.example/x", Parts(lead: "view-source:", host: "evil.example", trail: "/x")),
  ("view-source:http://127.0.0.1:8080/b?c", Parts(lead: "view-source:", host: "127.0.0.1:8080", trail: "/b?c")),
  ("view-source:chrome://settings/help", Parts(lead: "view-source:", host: "ray://settings/help")),
  ("view-source:about:blank", Parts(lead: "view-source:", host: "about:blank")),
  ("view-source:view-source:https://example.com/", Parts(host: "view-source:")),
  ("blob:https://evil.example/1234-5678", Parts(lead: "blob:", host: "evil.example", trail: "/1234-5678")),
  ("blob:null/1234-5678", Parts(host: "blob:")),
  ("filesystem:https://example.com/temporary/a.txt", Parts(lead: "filesystem:", host: "example.com", trail: "/temporary/a.txt")),
  ("chrome://settings/help", Parts(host: "ray://settings/help")),
  ("data:text/html,<h1>accounts.google.com</h1>", Parts(host: "data:")),
  ("about:blank#////accounts.google.com", Parts(host: "about:blank")),
  // IDN stays punycode, and a long host is all host (the view elides it from the start, never moving any to the trail).
  ("https://www.xn--pple-43d.com/login", Parts(host: "xn--pple-43d.com", trail: "/login")),
  ("https://bücher.example/x", Parts(host: "xn--bcher-kva.example", trail: "/x")),
  ("https://" + String(repeating: "a", count: 60) + ".accounts.google.com." + String(repeating: "b", count: 60) + ".evil.example/p",
   Parts(host: String(repeating: "a", count: 60) + ".accounts.google.com." + String(repeating: "b", count: 60) + ".evil.example", trail: "/p")),
  ("", Parts()),
]
for (input, expected) in partsCases where AddressInput.addressParts(for: input) != expected {
  failures += 1
  print("FAIL addressParts(\(input)) = \(AddressInput.addressParts(for: input)), expected \(expected)")
}
let autocompleteCases: [(String, String?, String, Bool)] = [
  ("github.com", nil, "git", true),
  ("google.com.evil.tld", nil, "google", false),
  ("google.com.evil.tld", "google.com", "google.com", false),
  ("google.com", "google.com", "google.com", true),
  ("mail.google.com", nil, "mail", false),
  ("bbc.co.uk", nil, "bbc", true),
  ("evil.co.uk", nil, "co", false),
  ("", nil, "x", false),
]
for (candidate, typed, query, expected) in autocompleteCases
where AddressInput.autocompletes(candidateHost: candidate, typedHost: typed, query: query) != expected {
  failures += 1
  print("FAIL autocompletes(\(candidate), typed: \(typed ?? "nil"), \(query)) != \(expected)")
}
// Dev hosts never warn; plain http elsewhere is a quiet open lock; red only for a real site's bad certificate.
let lookCases: [(String?, String, ConnectionLook)] = [
  ("insecure", "http://localhost:3000/", .local),
  ("insecure", "http://127.0.0.1:8080/x", .local),
  ("insecure", "http://[::1]:8080/", .local),
  ("insecure", "http://app.localhost/", .local),
  ("insecure", "http://dev.example.test/", .local),
  ("certificateError", "https://dev.example.test/", .local),
  ("insecure", "http://example.com/", .open),
  (nil, "http://example.com/", .open),
  ("insecure", "http://127.0.0.1.evil.com/", .open),
  ("insecure", "http://test.example.com/", .open),
  ("insecure", "http://192.168.1.10/", .open),
  ("certificateError", "https://example.com/", .broken),
  ("mixed", "https://example.com/", .partly),
  ("secure", "https://example.com/", .quiet),
  ("none", "chrome://settings", .quiet),
  // A view-source: or blob: address is judged by the URL inside it.
  ("insecure", "view-source:http://localhost:3000/", .local),
  ("insecure", "view-source:http://example.com/", .open),
  (nil, "view-source:http://example.com/", .open),
  ("certificateError", "view-source:https://example.com/", .broken),
  ("secure", "view-source:https://example.com/", .quiet),
  ("insecure", "blob:http://127.0.0.1:8080/1234", .local),
]
for (level, url, expected) in lookCases where ConnectionLook.of(level: level, url: url) != expected {
  failures += 1
  print("FAIL look(\(level ?? "nil"), \(url)) = \(ConnectionLook.of(level: level, url: url)), want \(expected)")
}
// ray://settings/appearance, chrome://settings/appearance and the Profiles pages open the native Settings window; nothing else does.
let paneCases: [(String, String?)] = [
  ("chrome://settings/appearance", "appearance"),
  ("ray://settings/appearance", "appearance"),
  ("RAY://Settings/Appearance/", "appearance"),
  ("chrome://settings/appearance?x=1#y", "appearance"),
  ("chrome://settings/fonts", "appearance"),
  ("chrome://settings/people", "appearance"),
  ("ray://settings/people", "appearance"),
  ("ray://settings/Profiles/", "appearance"),
  ("chrome://settings/manageProfile", "appearance"),
  ("chrome://settings/people/x", nil),
  ("chrome://settings/peopleish", nil),
  ("chrome://extensions/people", nil),
  ("chrome://settings", nil),
  ("chrome://settings/", nil),
  ("chrome://settings/privacy", nil),
  // Ray's own panes by name; the ones Chrome still draws (privacy, passwords, autofill, extensions) stay Chrome's.
  ("ray://settings/general", "general"), ("ray://settings/tabs", "tabs"), ("RAY://Settings/Shortcuts/", "shortcuts"),
  ("ray://settings/about", "about"), ("ray://settings/passwords", "passwords"), ("ray://settings/autofill", "autofill"),
  ("ray://settings/tabs/x", nil),
  // Privacy: Chrome's Site settings pages and ray://settings/privacy; Chrome's Privacy and security page stays Chrome's.
  ("chrome://settings/content", "privacy"), ("chrome://settings/content/all", "privacy"),
  ("chrome://settings/content/siteDetails?site=https%3A%2F%2Fexample.com", "privacy"), ("chrome://settings/content/zoomLevels", "privacy"),
  ("ray://settings/privacy", "privacy"), ("RAY://Settings/Privacy/", "privacy"), ("chrome://settings/content/camera", nil),
  ("chrome://settings/clearBrowserData", nil), ("chrome://settings/security", nil),
  // Extensions: ray://settings/extensions; chrome://extensions is Chrome's page.
  ("ray://settings/extensions", "extensions"), ("chrome://extensions", nil),
  // Passwords and Autofill: Chrome's settings pages and its password manager page, any path of it.
  ("chrome://settings/passwords", "passwords"), ("chrome://settings/addresses", "autofill"), ("chrome://settings/payments", "autofill"),
  ("chrome://settings/autofill", "autofill"), ("chrome://password-manager", "passwords"), ("chrome://password-manager/passwords", "passwords"),
  ("chrome://password-manager/settings?x=1", "passwords"), ("ray://password-manager/checkup", "passwords"),
  ("https://password-manager/passwords", nil), ("chrome://user@password-manager/", nil), ("chrome://passwords-manager/", nil),
  // Search engine, gone from Chrome's page, is Ray's Search pane: typed, from a link or from the page itself.
  ("chrome://settings/search", "search"), ("ray://settings/search", "search"), ("RAY://Settings/SearchEngines/", "search"),
  ("chrome://settings/searchEngines#x", "search"), (" chrome://settings/search ", "search"),
  ("chrome://settings/?search=a", nil), ("chrome://settings/searchEngines/x", nil), ("chrome://settings/searching", nil),
  ("chrome://extensions/search", nil), ("https://settings/search", nil), ("https://example.com/settings/search", nil),
  ("chrome://user@settings/search", nil),
  ("chrome://settings/appearance/fonts", nil),
  ("chrome://extensions/appearance", nil),
  ("https://settings/appearance", nil),
  ("https://example.com/settings/appearance", nil),
  ("chrome://user@settings/appearance", nil),
  ("javascript:alert(1)", nil),
  ("", nil),
]
for (input, expected) in paneCases where AddressInput.nativeSettingsPane(for: input) != expected {
  failures += 1
  print("FAIL nativeSettingsPane(\(input)) = \(AddressInput.nativeSettingsPane(for: input) ?? "nil"), want \(expected ?? "nil")")
}
// A site search's address (Settings › Search): http or https with a host, %s outside the host, nothing else.
let templateCases: [(String, String?)] = [
  ("https://en.wikipedia.org/w/index.php?search=%s", "https://en.wikipedia.org/w/index.php?search=%s"),
  ("  https://github.com/search?q=%s&type=code  ", "https://github.com/search?q=%s&type=code"),
  ("HTTP://localhost:8080/find?q=%s", "HTTP://localhost:8080/find?q=%s"),
  ("https://open.spotify.com/search/%s", "https://open.spotify.com/search/%s"),
  ("https://mail.google.com/mail/u/0/#search/%s", "https://mail.google.com/mail/u/0/#search/%s"),
  ("http://127.0.0.1:9/s?q=%s&again=%s", "http://127.0.0.1:9/s?q=%s&again=%s"),
  ("https://example.com/search?q=", nil),
  ("https://example.com/search?q=%S", nil),
  ("javascript:alert(1)//%s", nil),
  ("JavaScript:void(%s)", nil),
  ("data:text/html,%s", nil),
  ("file:///tmp/%s", nil),
  ("chrome://settings/?search=%s", nil),
  ("ray://settings/?search=%s", nil),
  ("ftp://example.com/%s", nil),
  ("example.com/?q=%s", nil),
  ("https://%s.example.com/", nil),
  ("https://%s/", nil),
  ("https://example.com:%s/", nil),
  ("https://user:pass@example.com/?q=%s", nil),
  ("https://user@example.com/?q=%s", nil),
  ("https://example.com/a b?q=%s", nil),
  ("https://example.com/?q=%s\n", "https://example.com/?q=%s"),
  ("https://example.com/?q=%s\u{0}", nil),
  ("https:///?q=%s", nil),
  ("https://example.com/?q=%s&x=" + String(repeating: "a", count: 2048), nil),
  ("", nil),
]
for (input, expected) in templateCases where AddressInput.siteSearchTemplate(input) != expected {
  failures += 1
  print("FAIL siteSearchTemplate(\(input.debugDescription)) = \(AddressInput.siteSearchTemplate(input).debugDescription), want \(expected.debugDescription)")
}
// A query in a template: encoded once, so it can't add parameters or a fragment, or spell a placeholder.
let searchURLCases: [(String, String, String?)] = [
  ("https://en.wikipedia.org/w/index.php?search=%s", "swift lang", "https://en.wikipedia.org/w/index.php?search=swift%20lang"),
  ("https://x.example/?q=%s", "a&b=c#d?e+f", "https://x.example/?q=a%26b%3Dc%23d%3Fe%2Bf"),
  ("https://x.example/?q=%s", "%s", "https://x.example/?q=%25s"),
  ("https://x.example/?q=%s&r=%s", "é", "https://x.example/?q=%C3%A9&r=%C3%A9"),
  ("javascript:alert(%s)", "1", nil),
  ("https://x.example/", "q", nil),
]
for (template, query, expected) in searchURLCases where AddressInput.siteSearchURL(template, query: query) != expected {
  failures += 1
  print("FAIL siteSearchURL(\(template), \(query)) = \(AddressInput.siteSearchURL(template, query: query).debugDescription), want \(expected.debugDescription)")
}
// The default engine is the app's choice: what you type searches it, and only its results pages count as searches.
let googleTemplate = AddressInput.searchTemplate
AddressInput.searchTemplateSource = { "https://duckduckgo.com/?q=%s" }
let engineChecks: [(String, Bool)] = [
  ("follows", AddressInput.url(for: "hello world") == "https://duckduckgo.com/?q=hello%20world"),
  ("isSearch", AddressInput.isSearch("https://duckduckgo.com/?q=a")),
  ("other engine", !AddressInput.isSearch(googleTemplate.replacingOccurrences(of: "%s", with: "a"))),
  ("addresses", AddressInput.url(for: "example.com") == "https://example.com"),
]
AddressInput.searchTemplateSource = { googleTemplate }
for (name, ok) in engineChecks where !ok {
  failures += 1
  print("FAIL the chosen engine: \(name)")
}
// Text on an accent fill is white or black, whichever has the higher WCAG contrast ratio against it.
let foregroundCases: [(String, Bool)] = [
  ("#FFFFFF", false), ("#000000", true), ("#FFD60A", false), ("#F2B01E", false), ("#1A1A8C", true),
  ("#8257E5", true), ("#A486F0", false), ("#2F6BEA", true), ("#777777", false), ("#767676", false), ("#757575", true),
]
for (hex, white) in foregroundCases {
  guard let c = ProfileColor.parse(hex) else { failures += 1; print("FAIL parse(\(hex))"); continue }
  if ProfileColor.prefersWhite(c.r, c.g, c.b) != white {
    failures += 1
    print("FAIL prefersWhite(\(hex)) = \(!white), want \(white)")
  }
  // The choice is the better of the two ratios, never the worse.
  let l = ProfileColor.luminance(c.r, c.g, c.b)
  let chosen = ProfileColor.contrast(white ? 1 : 0, l), other = ProfileColor.contrast(white ? 0 : 1, l)
  if chosen < other { failures += 1; print("FAIL \(hex) picked the lower contrast (\(chosen) < \(other))") }
}
if abs(ProfileColor.contrast(1, 0) - 21) > 0.001 { failures += 1; print("FAIL white on black isn't 21:1") }
for (text, valid) in [("#8257E5", true), ("#fff", false), ("8257E5", false), ("#GGGGGG", false), ("", false), ("#8257E5FF", false)]
where (ProfileColor.parse(text) != nil) != valid {
  failures += 1
  print("FAIL parse(\(text)) validity")
}
// Links from other apps: http(s) with a host, nothing else.
let linkCases: [(String, String?)] = [
  ("https://example.com/x?q=1#f", "https://example.com/x?q=1#f"),
  ("HTTP://Example.com", "HTTP://Example.com"),
  ("http://localhost:3000/", "http://localhost:3000/"),
  ("javascript:alert(1)", nil),
  ("JavaScript:alert(1)", nil),
  ("data:text/html,x", nil),
  ("chrome://settings", nil),
  ("ray://settings", nil),
  ("view-source:https://example.com", nil),
  ("about:blank", nil),
  ("file:///etc/hosts", nil),
  ("https:example.com", nil),
  ("ftp://example.com", nil),
  ("mailto:a@example.com", nil),
]
for (input, expected) in linkCases {
  let got = URL(string: input).flatMap { AddressInput.link(fromOtherApp: $0) }
  if got != expected {
    failures += 1
    print("FAIL link(fromOtherApp: \(input)) = \(got.debugDescription), expected \(expected.debugDescription)")
  }
}
// Documents: existing local regular files of the declared types only.
let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ray-docs-\(getpid())")
try? FileManager.default.createDirectory(at: folder.appendingPathComponent("dir.html"), withIntermediateDirectories: true)
for name in ["a page.html", "b.xhtml", "c.pdf", "d.txt", "e.sh", "f.svg"] {
  FileManager.default.createFile(atPath: folder.appendingPathComponent(name).path, contents: Data("x".utf8))
}
try? FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("link.html"),
                                            withDestinationURL: folder.appendingPathComponent("a page.html"))
try? FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("sneaky.html"),
                                            withDestinationURL: folder.appendingPathComponent("e.sh"))
let real = folder.resolvingSymlinksInPath()
let documentCases: [(String, String?)] = [
  ("a page.html", real.appendingPathComponent("a page.html").absoluteString),
  ("b.xhtml", real.appendingPathComponent("b.xhtml").absoluteString),
  ("c.pdf", real.appendingPathComponent("c.pdf").absoluteString),
  ("link.html", real.appendingPathComponent("a page.html").absoluteString),
  ("sneaky.html", nil),
  ("d.txt", nil),
  ("e.sh", nil),
  ("f.svg", nil),
  ("dir.html", nil),
  ("missing.html", nil),
]
for (name, expected) in documentCases {
  let got = AddressInput.document(fromOtherApp: folder.appendingPathComponent(name))
  if got != expected {
    failures += 1
    print("FAIL document(fromOtherApp: \(name)) = \(got.debugDescription), expected \(expected.debugDescription)")
  }
}
for text in ["https://example.com/a.html", "file://host.example/a.html"] where URL(string: text).flatMap({ AddressInput.document(fromOtherApp: $0) }) != nil {
  failures += 1
  print("FAIL document(fromOtherApp: \(text)) was taken")
}
try? FileManager.default.removeItem(at: folder)
let total = linkCases.count + documentCases.count + 2 + templateCases.count + searchURLCases.count + engineChecks.count + foregroundCases.count + 7 + paneCases.count + cases.count + displayCases.count + pillCases.count + partsCases.count + autocompleteCases.count + lookCases.count
print(failures == 0 ? "all \(total) passed" : "\(failures) failed")
exit(failures == 0 ? 0 : 1)
