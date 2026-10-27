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
]
for (input, expected) in displayCases where AddressInput.display(for: input) != expected {
  failures += 1
  print("FAIL display(\(input)) = \(AddressInput.display(for: input)), expected \(expected)")
}
let pillCases: [(String, String)] = [
  ("https://www.example.com/path?q=1#x", "example.com"),
  ("http://localhost:3000/", "localhost"),
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
let total = cases.count + displayCases.count + pillCases.count + autocompleteCases.count
print(failures == 0 ? "all \(total) passed" : "\(failures) failed")
exit(failures == 0 ? 0 : 1)
