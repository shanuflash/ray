import Foundation

/// Arc's sidebar, read from its StorableSidebar.json (read-only, and only when the user asks to import): the
/// default profile's favorites and each space's pinned tabs and folders. The format follows Ardia's importer
/// (`packages/import/ios/Core/ArcSidebar.swift`): flat lists of [id, object] pairs linked by `childrenIds`.
struct ArcImport {
  indirect enum Node {
    case tab(url: String, title: String)
    case folder(title: String, children: [Node])
  }

  struct Space {
    let name: String
    let pinned: [Node]
  }

  var spaces: [Space] = []
  var favorites: [Node] = []

  static var file: URL {
    if let path = TestEnvironment["RAY_ARC_SIDEBAR"] { return URL(fileURLWithPath: path) }
    return FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/Arc/StorableSidebar.json")
  }

  /// Arc's sidebar file is tens of MB at most; refuse anything far larger.
  static let maxBytes = 64 * 1024 * 1024

  static func load() -> ArcImport? {
    guard let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int,
          size <= maxBytes, let data = try? Data(contentsOf: file) else { return nil }
    return parse(data)
  }

  static func parse(_ data: Data) -> ArcImport? {
    guard let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let containers = (top["sidebar"] as? [String: Any])?["containers"] as? [Any] else { return nil }
    let boxes = containers.map { $0 as? [String: Any] ?? [:] }
    // The main sidebar is the box after the {"global": …} marker (Ardia's rule), else the first that has spaces.
    let index = boxes.indices.first { $0 > 0 && boxes[$0 - 1]["global"] != nil && boxes[$0]["spaces"] != nil }
      ?? boxes.indices.first { boxes[$0]["spaces"] != nil }
    guard let index else { return nil }
    let box = boxes[index]

    var items: [String: [String: Any]] = [:]
    for item in objects(box["items"]) {
      if let id = item["id"] as? String { items[id] = item }
    }
    var result = ArcImport()
    var untitled = 0
    for space in objects(box["spaces"]) {
      guard let pinned = containerIDs(space)["pinned"] else { continue }
      var seen = Set<String>()
      let tree = self.tree(of: pinned, items: items, seen: &seen)
      let name: String
      if let title = space["title"] as? String, !title.isEmpty {
        name = title
      } else {
        untitled += 1
        name = "Space \(untitled)"
      }
      if !tree.isEmpty { result.spaces.append(Space(name: name, pinned: tree)) }
    }
    for (descriptor, container) in pairs(box["topAppsContainerIDs"]) {
      guard (descriptor as? [String: Any])?["default"] != nil, let container = container as? String else { continue }
      var seen = Set<String>()
      result.favorites += flatten(tree(of: container, items: items, seen: &seen))
    }
    return result
  }

  // MARK: Parsing helpers

  private static func objects(_ any: Any?) -> [[String: Any]] {
    (any as? [Any] ?? []).compactMap { $0 as? [String: Any] }
  }

  private static func pairs(_ any: Any?) -> [(Any, Any)] {
    let list = any as? [Any] ?? []
    return stride(from: 0, to: max(list.count - 1, 0), by: 2).map { (list[$0], list[$0 + 1]) }
  }

  private static func containerIDs(_ space: [String: Any]) -> [String: String] {
    var ids: [String: String] = [:]
    for (label, value) in pairs(space["newContainerIDs"]) {
      if let id = value as? String, let key = (label as? [String: Any])?.keys.first { ids[key] = ids[key] ?? id }
    }
    for (label, value) in pairs(space["containerIDs"]) {
      if let key = label as? String, let id = value as? String { ids[key] = ids[key] ?? id }
    }
    return ids
  }

  private static func tree(of containerID: String, items: [String: [String: Any]], seen: inout Set<String>,
                           depth: Int = 0) -> [Node] {
    guard depth < 32, let container = items[containerID], seen.insert(containerID).inserted else { return [] }
    var nodes: [Node] = []
    for id in container["childrenIds"] as? [String] ?? [] {
      guard let item = items[id] else { continue }
      let data = item["data"] as? [String: Any] ?? [:]
      let custom = (item["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
      if let tab = data["tab"] as? [String: Any], let url = tab["savedURL"] as? String {
        guard seen.insert(id).inserted, safe(url) else { continue }
        nodes.append(.tab(url: url, title: plain(custom ?? tab["savedTitle"] as? String ?? "")))
      } else if data["list"] != nil {
        nodes.append(.folder(title: plain(custom ?? "Folder"), children: tree(of: id, items: items, seen: &seen, depth: depth + 1)))
      } else if data["splitView"] != nil {
        nodes += tree(of: id, items: items, seen: &seen, depth: depth + 1)
      }
    }
    return nodes
  }

  private static func flatten(_ nodes: [Node]) -> [Node] {
    nodes.flatMap { node -> [Node] in
      if case .folder(_, let children) = node { return flatten(children) }
      return [node]
    }
  }

  /// Only web pages come across: never javascript:, data:, file: or anything else from the file.
  private static func safe(_ url: String) -> Bool {
    guard url.count <= 8192, let scheme = URLComponents(string: url)?.scheme?.lowercased() else { return false }
    return scheme == "https" || scheme == "http"
  }

  private static func plain(_ text: String) -> String {
    let single = text.components(separatedBy: .newlines).joined(separator: " ")
    return String(single.prefix(200))
  }

  // MARK: Summary

  var counts: (favorites: Int, tabs: Int, folders: Int) {
    func count(_ nodes: [Node]) -> (Int, Int) {
      nodes.reduce((0, 0)) { total, node in
        switch node {
        case .tab: return (total.0 + 1, total.1)
        case .folder(_, let children):
          let inner = count(children)
          return (total.0 + inner.0, total.1 + inner.1 + 1)
        }
      }
    }
    let pinned = count(spaces.flatMap(\.pinned))
    return (favorites.count, pinned.0, pinned.1 + (spaces.count > 1 ? spaces.count : 0))
  }
}
