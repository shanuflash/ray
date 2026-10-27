import AppKit

final class SidebarEntry: Codable {
  enum Kind: String, Codable {
    case favorite
    case pinned
    case today
  }

  let id: UUID
  var kind: Kind
  var pinnedURL: String?
  var url: String
  var title: String
  var lastActive: Date
  var tab: ArdiaCoreTab?

  private enum CodingKeys: String, CodingKey {
    case id, kind, pinnedURL, url, title, lastActive
  }

  init(kind: Kind, url: String, title: String = "") {
    id = UUID()
    self.kind = kind
    self.url = url
    self.title = title
    pinnedURL = kind == .today ? nil : url
    lastActive = Date()
  }

  var isLive: Bool { tab.map { !$0.closed } ?? false }

  var currentURL: String {
    if let tab, !tab.closed, !tab.url.isEmpty { return tab.url }
    return url
  }

  var displayTitle: String {
    if let tab, !tab.closed, !tab.title.isEmpty { return tab.title }
    return title.isEmpty ? AddressInput.display(for: currentURL) : title
  }

  var host: String {
    let host = URLComponents(string: currentURL)?.host ?? ""
    return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
  }

  var isAwayFromPinned: Bool {
    guard let pinnedURL else { return false }
    return Self.normalized(currentURL) != Self.normalized(pinnedURL)
  }

  func remember() {
    guard let tab, !tab.closed else { return }
    if !tab.url.isEmpty { url = tab.url }
    if !tab.title.isEmpty { title = tab.title }
  }

  private static func normalized(_ url: String) -> String {
    var components = URLComponents(string: url)
    components?.fragment = nil
    var text = components?.string ?? url
    if text.hasSuffix("/") { text.removeLast() }
    return text
  }
}

final class SidebarState: Codable {
  static let todayLifetime: TimeInterval = 12 * 60 * 60

  var favorites: [SidebarEntry] = []
  var pinned: [SidebarEntry] = []
  var today: [SidebarEntry] = []
  var activeEntryID: UUID?
  var sidebarHidden = false
  /// Whether the window was full screen, to reopen that way. Optional so older files still load.
  var fullScreen: Bool?

  var allEntries: [SidebarEntry] { favorites + pinned + today }

  func entry(for tab: ArdiaCoreTab) -> SidebarEntry? {
    allEntries.first { $0.tab === tab }
  }

  func entry(id: UUID) -> SidebarEntry? {
    allEntries.first { $0.id == id }
  }

  func remove(_ entry: SidebarEntry) {
    favorites.removeAll { $0 === entry }
    pinned.removeAll { $0 === entry }
    today.removeAll { $0 === entry }
    if activeEntryID == entry.id { activeEntryID = nil }
  }

  func archiveStaleToday(now: Date = Date()) {
    today.removeAll { !$0.isLive && $0.id != activeEntryID && now.timeIntervalSince($0.lastActive) > Self.todayLifetime }
  }
}

final class SidebarStore {
  private let url: URL
  private var pending: DispatchWorkItem?
  private let queue = DispatchQueue(label: "ray.sidebar.store", qos: .utility)

  init(directory: String) {
    url = URL(fileURLWithPath: directory).appendingPathComponent("Sidebar.json")
  }

  func load() -> SidebarState? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONDecoder().decode(SidebarState.self, from: data)
  }

  func save(_ state: SidebarState) {
    pending?.cancel()
    let work = DispatchWorkItem { [weak self] in self?.write(state, now: false) }
    pending = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
  }

  func saveNow(_ state: SidebarState) {
    pending?.cancel()
    pending = nil
    write(state, now: true)
  }

  private func write(_ state: SidebarState, now: Bool) {
    state.allEntries.forEach { $0.remember() }
    guard let data = try? JSONEncoder().encode(state) else { return }
    let url = self.url
    if now {
      queue.sync { try? data.write(to: url, options: .atomic) }
    } else {
      queue.async { try? data.write(to: url, options: .atomic) }
    }
  }
}
