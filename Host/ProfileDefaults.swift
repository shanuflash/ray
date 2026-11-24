import Foundation

/// Chrome's defaults where the engine's differ and Ray's app can't set them through the engine. Helium's
/// `inox-patchset/modify-default-prefs.patch` blocks third-party cookies (`profile.cookie_controls_mode` 1); Chrome and
/// Arc allow them (0, blocked only in private windows), and sites that embed another site's page need them (Teams'
/// app tabs: "This app may have issues in the web version of Teams"). The engine's own default goes back to Chrome's
/// at the next engine build (docs/MISSING.md #75); until then, and for profiles made before it, Ray writes Chrome's
/// value into the profile's Preferences before the engine starts,
/// only where the user never chose (the key absent). The RayCore profile only sets booleans, and this one is a
/// number. A missing Preferences file is left alone: writing one would make Chrome take a new profile for an old one
/// (`ProfileImpl::IsNewProfile`), so a new data dir gets it at its second launch.
enum ProfileDefaults {
  static let cookieKey = "cookie_controls_mode"
  static let allowThirdParty = 0

  struct Report {
    let note: String
    let wrote: Bool
  }

  static func apply(dataDirectory: String) -> Report {
    let path = (dataDirectory as NSString).appendingPathComponent("Default/Preferences")
    guard FileManager.default.fileExists(atPath: path) else { return Report(note: "no profile yet", wrote: false) }
    if SafeStorage.dataDirectoryInUse(dataDirectory) { return Report(note: "in use", wrote: false) }
    guard let data = FileManager.default.contents(atPath: path) else { return Report(note: "unreadable", wrote: false) }
    guard let edited = withThirdPartyCookies(data) else { return Report(note: "kept", wrote: false) }
    let attributes = try? FileManager.default.attributesOfItem(atPath: path)
    do {
      try edited.write(to: URL(fileURLWithPath: path), options: .atomic)
      if let mode = attributes?[.posixPermissions] {
        try? FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: path)
      }
      return Report(note: "third-party cookies allowed", wrote: true)
    } catch {
      return Report(note: "couldn't write", wrote: false)
    }
  }

  /// The Preferences text with `"cookie_controls_mode":0` added to its top-level `profile` object, or nil when the
  /// user already has a value, or the file isn't the JSON object Chrome writes. Only those bytes change: a round trip
  /// through JSONSerialization would rewrite every number (a double 1.0 back as the integer 1, which Chrome reads as
  /// the wrong type).
  static func withThirdPartyCookies(_ data: Data) -> Data? {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    let profile = root["profile"]
    if let profile, !(profile is [String: Any]) { return nil }
    if (profile as? [String: Any])?[cookieKey] != nil { return nil }
    let bytes = [UInt8](data)
    var insertion: (at: Int, text: String)
    if profile != nil {
      guard let open = topLevelObjectStart(of: "profile", in: bytes) else { return nil }
      let empty = nextNonSpace(in: bytes, after: open).map { bytes[$0] == UInt8(ascii: "}") } ?? false
      insertion = (open + 1, "\"\(cookieKey)\":\(allowThirdParty)" + (empty ? "" : ","))
    } else {
      guard let open = bytes.firstIndex(of: UInt8(ascii: "{")) else { return nil }
      let empty = nextNonSpace(in: bytes, after: open).map { bytes[$0] == UInt8(ascii: "}") } ?? false
      insertion = (open + 1, "\"profile\":{\"\(cookieKey)\":\(allowThirdParty)}" + (empty ? "" : ","))
    }
    var out = bytes
    out.insert(contentsOf: Array(insertion.text.utf8), at: insertion.at)
    let result = Data(out)
    // The edit must leave the same JSON with only the one value added.
    guard let check = try? JSONSerialization.jsonObject(with: result) as? [String: Any],
          (check["profile"] as? [String: Any])?[cookieKey] as? Int == allowThirdParty,
          Set(check.keys) == Set(root.keys).union(["profile"])
    else { return nil }
    return result
  }

  /// The index of the `{` that opens the value of `key` in the top-level object.
  static func topLevelObjectStart(of key: String, in bytes: [UInt8]) -> Int? {
    let quote = UInt8(ascii: "\""), backslash = UInt8(ascii: "\\")
    var depth = 0, i = 0
    while i < bytes.count {
      let byte = bytes[i]
      if byte == quote {
        // A string: read it whole; at depth 1 it may be the key.
        var end = i + 1
        while end < bytes.count, bytes[end] != quote { end += bytes[end] == backslash ? 2 : 1 }
        guard end < bytes.count else { return nil }
        if depth == 1, String(decoding: bytes[(i + 1)..<end], as: UTF8.self) == key,
           let colon = nextNonSpace(in: bytes, after: end), bytes[colon] == UInt8(ascii: ":"),
           let value = nextNonSpace(in: bytes, after: colon) {
          return bytes[value] == UInt8(ascii: "{") ? value : nil
        }
        i = end + 1
        continue
      }
      if byte == UInt8(ascii: "{") || byte == UInt8(ascii: "[") { depth += 1 }
      if byte == UInt8(ascii: "}") || byte == UInt8(ascii: "]") { depth -= 1 }
      i += 1
    }
    return nil
  }

  static func nextNonSpace(in bytes: [UInt8], after index: Int) -> Int? {
    var i = index + 1
    while i < bytes.count, [UInt8(ascii: " "), 0x0a, 0x0d, 0x09].contains(bytes[i]) { i += 1 }
    return i < bytes.count ? i : nil
  }
}
