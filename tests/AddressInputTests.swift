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
// A search template the engine reports is used only when it is https (http for a local host) with a host and the
// placeholder exactly once; Chromium's leftover `{…}` parameters are dropped with their query item.
let templateCases: [(String?, String?)] = [
  ("https://duckduckgo.com/?q=%s", "https://duckduckgo.com/?q=%s"),
  ("https://www.google.com/search?q=%s", "https://www.google.com/search?q=%s"),
  ("https://www.google.com/search?q=%s&{google:RLZ}{google:sourceId}ie={inputEncoding}", "https://www.google.com/search?q=%s"),
  ("https://www.bing.com/osjson.aspx?query=%s&language={language}", "https://www.bing.com/osjson.aspx?query=%s"),
  ("https://example.com/search/%s", "https://example.com/search/%s"),
  ("http://127.0.0.1:8080/engine?q=%s", "http://127.0.0.1:8080/engine?q=%s"),
  ("http://localhost:3000/s?q=%s", "http://localhost:3000/s?q=%s"),
  ("http://app.localhost/s?q=%s", "http://app.localhost/s?q=%s"),
  ("http://[::1]:9/s?q=%s", "http://[::1]:9/s?q=%s"),
  ("javascript:alert(%s)", nil),
  ("JavaScript://example.com/%0Aalert(%s)", nil),
  ("data:text/html,%s", nil),
  ("file:///tmp/%s", nil),
  ("chrome://settings/?q=%s", nil),
  ("ftp://example.com/?q=%s", nil),
  ("http://example.com/?q=%s", nil),
  ("http://127.0.0.1.evil.com/?q=%s", nil),
  ("https://example.com/?q=", nil),
  ("https://example.com/?q=%s&r=%s", nil),
  ("https:///?q=%s", nil),
  ("https://?q=%s", nil),
  ("https://user:pass@example.com/?q=%s", nil),
  ("https://{google:baseURL}search?q=%s", nil),
  ("https://example.com/{x}/?q=%s", nil),
  ("https://exa mple.com/?q=%s", nil),
  ("https://example.com/?q=%s\\nHost: evil", nil),
  ("//example.com/?q=%s", nil),
  ("example.com/?q=%s", nil),
  ("", nil),
  (nil, nil),
]
for (input, expected) in templateCases where SearchEngine.validated(input) != expected {
  failures += 1
  print("FAIL validated(\(input.debugDescription)) = \(SearchEngine.validated(input).debugDescription), want \(expected.debugDescription)")
}
// The default engine's reply: its default wins, a bad default falls back (nil), the name is cleaned.
let engineReply: [[String: Any]] = [
  ["name": "Other", "url": "https://other.example/?q=%s", "suggestionsUrl": "", "default": false],
  ["name": "Duck\u{7}Go", "url": "https://duckduckgo.com/?q=%s", "suggestionsUrl": "https://duckduckgo.com/ac/?q=%s&type=list", "default": true],
]
if SearchEngine.chosen(from: engineReply) != SearchEngine.Choice(
  name: "DuckGo", search: "https://duckduckgo.com/?q=%s", suggestions: "https://duckduckgo.com/ac/?q=%s&type=list") {
  failures += 1
  print("FAIL chosen(from:) = \(String(describing: SearchEngine.chosen(from: engineReply)))")
}
let noSuggestions: [[String: Any]] = [["name": "Mine", "url": "https://mine.example/?q=%s", "suggestionsUrl": "", "default": true]]
if SearchEngine.chosen(from: noSuggestions)?.suggestions != nil || SearchEngine.chosen(from: noSuggestions)?.search != "https://mine.example/?q=%s" {
  failures += 1
  print("FAIL an engine without suggestions kept one: \(String(describing: SearchEngine.chosen(from: noSuggestions)))")
}
let badDefault: [[String: Any]] = [
  ["name": "Evil", "url": "javascript:alert(%s)", "suggestionsUrl": "", "default": true],
  ["name": "Fine", "url": "https://fine.example/?q=%s", "default": false],
]
if SearchEngine.chosen(from: badDefault) != nil { failures += 1; print("FAIL a javascript: default engine was accepted") }
if SearchEngine.chosen(from: []) != nil { failures += 1; print("FAIL no engines gave a choice") }
let badSuggestions: [[String: Any]] = [["name": "Odd", "url": "https://odd.example/?q=%s", "suggestionsUrl": "javascript:%s", "default": true]]
if SearchEngine.chosen(from: badSuggestions)?.suggestions != nil { failures += 1; print("FAIL a javascript: suggestions URL was accepted") }
// Typed text goes into the template encoded for the place it lands: a query value, or a path segment.
let encodeCases: [(String, String, String)] = [
  ("https://x.example/?q=%s", "a&b c", "https://x.example/?q=a%26b%20c"),
  ("https://x.example/?q=%s", "1+1=2#x?y", "https://x.example/?q=1%2B1%3D2%23x%3Fy"),
  ("https://x.example/?q=%s", "a/b", "https://x.example/?q=a/b"),
  ("https://x.example/search/%s", "a/b c", "https://x.example/search/a%2Fb%20c"),
  ("https://x.example/?q=%s&hl=en", "hi", "https://x.example/?q=hi&hl=en"),
  ("https://x.example/?q=%s", "100%s", "https://x.example/?q=100%25s"),
]
for (template, text, expected) in encodeCases where SearchEngine.searchURL(for: text, template: template) != expected {
  failures += 1
  print("FAIL searchURL(\(text), \(template)) = \(SearchEngine.searchURL(for: text, template: template)), want \(expected)")
}
// Results pages are recognised by the template's own text before and after the query.
let resultsCases: [(String, String, Bool)] = [
  ("https://x.example/?q=%s", "https://x.example/?q=hello", true),
  ("https://x.example/?q=%s", "https://x.example/?q=", false),
  ("https://x.example/?q=%s", "https://x.example/about", false),
  ("https://x.example/?q=%s&hl=en", "https://x.example/?q=hi&hl=en", true),
  ("https://x.example/?q=%s&hl=en", "https://x.example/?q=hi", false),
  ("https://x.example/search/%s", "https://x.example/search/a%20b", true),
  ("https://x.example/search/%s", "https://y.example/search/a", false),
]
for (template, url, expected) in resultsCases where SearchEngine.isResults(url, of: template) != expected {
  failures += 1
  print("FAIL isResults(\(url), \(template)) want \(expected)")
}
// Suggestion answers: OpenSearch JSON and DuckDuckGo's `ac` list are read; anything else is nothing.
let suggestionCases: [(String, [String]?)] = [
  (#"["hel",["hello","help"],[],{}]"#, ["hello", "help"]),
  (#"["hel",[]]"#, []),
  (#"[{"phrase":"hello"},{"phrase":"help"}]"#, ["hello", "help"]),
  (#"{"q":"x"}"#, nil),
  (#"["hel"]"#, nil),
  (#"["hel",[1,2]]"#, nil),
  (#"[{"phrase":"a"},{"other":"b"}]"#, nil),
  ("<html>no</html>", nil),
  ("", nil),
]
for (json, expected) in suggestionCases where SearchEngine.parseSuggestions(Data(json.utf8)) != expected {
  failures += 1
  print("FAIL parseSuggestions(\(json)) = \(String(describing: SearchEngine.parseSuggestions(Data(json.utf8)))), want \(String(describing: expected))")
}
if SearchEngine.parseSuggestions(Data(count: 70 * 1024)) != nil { failures += 1; print("FAIL an oversized answer was read") }
// The test overrides (RAY_SEARCH_URL / RAY_SUGGEST_URL) win until `useEngine(true)`; without them the engine's
// choice, else Google and no remote suggestions.
if SearchEngine.suggestionsTemplate != nil && TestEnvironment["RAY_SUGGEST_URL"] == nil { failures += 1; print("FAIL suggestions without a default engine") }
if TestEnvironment["RAY_SEARCH_URL"] == nil && AddressInput.searchTemplate != SearchEngine.fallbackTemplate {
  failures += 1
  print("FAIL the template without a default engine is \(AddressInput.searchTemplate)")
}
SearchEngine.apply(["engines": engineReply])
if TestEnvironment["RAY_SEARCH_URL"] == nil, AddressInput.url(for: "a b") != "https://duckduckgo.com/?q=a%20b" {
  failures += 1
  print("FAIL a typed search went to \(AddressInput.url(for: "a b") ?? "nil")")
}
if TestEnvironment["RAY_SEARCH_URL"] == nil, !AddressInput.isSearch("https://duckduckgo.com/?q=a%20b") || AddressInput.isSearch("https://www.google.com/search?q=a") {
  failures += 1
  print("FAIL isSearch ignores the default engine")
}
SearchEngine.apply(["engines": badDefault])
if TestEnvironment["RAY_SEARCH_URL"] == nil, AddressInput.searchTemplate != SearchEngine.fallbackTemplate {
  failures += 1
  print("FAIL a bad default engine didn't fall back to Google: \(AddressInput.searchTemplate)")
}
SearchEngine.apply(nil)
let total = templateCases.count + 6 + encodeCases.count + resultsCases.count + suggestionCases.count + 6
  + foregroundCases.count + 7 + paneCases.count + cases.count + displayCases.count + pillCases.count + autocompleteCases.count + lookCases.count
print(failures == 0 ? "all \(total) passed" : "\(failures) failed")
exit(failures == 0 ? 0 : 1)
