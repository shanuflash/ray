import Foundation

// Host/ProfileDefaults.swift: Chrome's third-party cookie value added to a profile's Preferences text, only where the
// user has none, and nothing else in the file changed.

var failures = 0
func expect(_ condition: Bool, _ message: String) {
  if !condition {
    failures += 1
    print("FAIL profile defaults: \(message)")
  }
}
func edit(_ text: String) -> String? { ProfileDefaults.withThirdPartyCookies(Data(text.utf8)).map { String(decoding: $0, as: UTF8.self) } }

// The value goes into the top-level profile object; doubles and everything else stay byte for byte.
let chrome = #"{"partition":{"per_host_zoom_levels":{"x":{"a.example":{"zoom_level":1.0}}}},"profile":{"name":"Your Chrome","x":{"profile":{}}},"z":[{"profile":1}]}"#
expect(edit(chrome) == #"{"partition":{"per_host_zoom_levels":{"x":{"a.example":{"zoom_level":1.0}}}},"profile":{"cookie_controls_mode":0,"name":"Your Chrome","x":{"profile":{}}},"z":[{"profile":1}]}"#,
       "added to profile: \(edit(chrome) ?? "nil")")
// A user's own choice (block, or allow) stays.
expect(edit(#"{"profile":{"cookie_controls_mode":1}}"#) == nil, "kept the user's block")
expect(edit(#"{"profile":{"cookie_controls_mode":0}}"#) == nil, "kept the user's allow")
// An empty profile object, and none at all.
expect(edit(#"{"profile":{}}"#) == #"{"profile":{"cookie_controls_mode":0}}"#, "empty profile: \(edit(#"{"profile":{}}"#) ?? "nil")")
expect(edit(#"{"a":1}"#) == #"{"profile":{"cookie_controls_mode":0},"a":1}"#, "no profile: \(edit(#"{"a":1}"#) ?? "nil")")
expect(edit("{}") == #"{"profile":{"cookie_controls_mode":0}}"#, "empty file object")
// A "profile" inside a string or a nested object isn't the top-level one.
let tricky = #"{"s":"\"profile\":{","n":{"profile":{"k":1}},"profile":{"k":2}}"#
expect(edit(tricky) == #"{"s":"\"profile\":{","n":{"profile":{"k":1}},"profile":{"cookie_controls_mode":0,"k":2}}"#,
       "tricky: \(edit(tricky) ?? "nil")")
// Not what Chrome writes: left alone.
expect(edit("not json") == nil, "not JSON")
expect(edit("[1]") == nil, "an array")
expect(edit(#"{"profile":3}"#) == nil, "profile isn't an object")

// On disk: a missing Preferences file is never made (Chrome would take the profile for an old one).
let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("ray-profile-defaults-\(getpid())")
try? FileManager.default.removeItem(atPath: dir)
try! FileManager.default.createDirectory(atPath: dir + "/Default", withIntermediateDirectories: true)
expect(!ProfileDefaults.apply(dataDirectory: dir).wrote, "wrote without a Preferences file")
expect(!FileManager.default.fileExists(atPath: dir + "/Default/Preferences"), "made a Preferences file")
FileManager.default.createFile(atPath: dir + "/Default/Preferences", contents: Data(#"{"profile":{"name":"P"}}"#.utf8),
                               attributes: [.posixPermissions: 0o600])
expect(ProfileDefaults.apply(dataDirectory: dir).wrote, "didn't write an existing profile")
let written = String(decoding: FileManager.default.contents(atPath: dir + "/Default/Preferences")!, as: UTF8.self)
expect(written == #"{"profile":{"cookie_controls_mode":0,"name":"P"}}"#, "on disk: \(written)")
let mode = (try? FileManager.default.attributesOfItem(atPath: dir + "/Default/Preferences"))?[.posixPermissions] as? Int
expect(mode == 0o600, "permissions \(String(mode ?? 0, radix: 8))")
expect(!ProfileDefaults.apply(dataDirectory: dir).wrote, "wrote twice")
try? FileManager.default.removeItem(atPath: dir)

if failures > 0 { exit(1) }
print("profile defaults: ok")
