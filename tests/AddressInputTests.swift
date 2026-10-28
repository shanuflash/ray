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
  ("ray://extensions", "chrome://extensions"),
  ("about:blank", "about:blank"),
  ("file:///tmp/a.html", "file:///tmp/a.html"),
  ("javascript:alert(1)", nil),
  ("JavaScript:alert(1)", nil),
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
]
for (input, expected) in pillCases where AddressInput.pillText(for: input) != expected {
  failures += 1
  print("FAIL pillText(\(input)) = \(AddressInput.pillText(for: input)), expected \(expected)")
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
]
for (level, url, expected) in lookCases where ConnectionLook.of(level: level, url: url) != expected {
  failures += 1
  print("FAIL look(\(level ?? "nil"), \(url)) = \(ConnectionLook.of(level: level, url: url)), want \(expected)")
}
// ray://settings/appearance and chrome://settings/appearance open the native Settings window; nothing else does.
let paneCases: [(String, String?)] = [
  ("chrome://settings/appearance", "appearance"),
  ("ray://settings/appearance", "appearance"),
  ("RAY://Settings/Appearance/", "appearance"),
  ("chrome://settings/appearance?x=1#y", "appearance"),
  ("chrome://settings", nil),
  ("chrome://settings/", nil),
  ("chrome://settings/privacy", nil),
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
let total = foregroundCases.count + 7 + paneCases.count + cases.count + displayCases.count + pillCases.count + autocompleteCases.count + lookCases.count
print(failures == 0 ? "all \(total) passed" : "\(failures) failed")
exit(failures == 0 ? 0 : 1)
