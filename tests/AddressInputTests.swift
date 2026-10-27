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
print(failures == 0 ? "all \(cases.count + displayCases.count) passed" : "\(failures) failed")
exit(failures == 0 ? 0 : 1)
