import AppKit

/// What Settings › Appearance offers, by name (also the names the test command `setting` takes).
enum RaySetting: String, CaseIterable {
  case minimalURL, loadingProgress, theme, defaultZoom, newTabNextToActive, recentTabCycling, copyLinkShortcut,
       sidebarShortcut
  /// Not offered in the window: the hosts the user zoomed themselves (see `BrowserWindowController` › Page zoom).
  case zoomedHosts
}

struct RaySettingsValues: Codable, Equatable {
  /// The page address bar shows only the host, the path on hover (off: the full address).
  var minimalURL = false
  /// A wash in the page address bar and a thin line on the page while it loads.
  var loadingProgress = true
  /// The profile's colour as `#RRGGBB`; nil is the default lavender.
  var theme: String?
  /// Zoom for sites the user hasn't zoomed themselves; 1 is 100%.
  var defaultZoom = 1.0
  var newTabNextToActive = false
  var recentTabCycling = true
  var copyLinkShortcut = true
  var sidebarShortcut = true
  /// Hosts the user zoomed with ⌘+ / ⌘−: they keep their own level when the default changes.
  var zoomedHosts: [String] = []
  /// Whether levels already in the engine's host zoom map (set before Ray tracked this) became the user's own.
  var zoomAdopted = false
  /// The Settings window's frame, as `NSStringFromRect`.
  var windowFrame: String?
  /// The first run's welcome is done. A file from before it existed reads as done (that Ray was already set up); a
  /// new data dir starts without it (see `init(directory:)`).
  var onboarded = true

  init() {}

  /// Older or damaged files still load: anything missing or out of range falls back to its default.
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let base = RaySettingsValues()
    minimalURL = (try? c.decodeIfPresent(Bool.self, forKey: .minimalURL)) ?? base.minimalURL
    loadingProgress = (try? c.decodeIfPresent(Bool.self, forKey: .loadingProgress)) ?? base.loadingProgress
    theme = (try? c.decodeIfPresent(String.self, forKey: .theme)).flatMap { ProfileColor.parse($0) != nil ? $0.uppercased() : nil }
    defaultZoom = (try? c.decodeIfPresent(Double.self, forKey: .defaultZoom)).flatMap(RaySettings.nearestZoom) ?? base.defaultZoom
    newTabNextToActive = (try? c.decodeIfPresent(Bool.self, forKey: .newTabNextToActive)) ?? base.newTabNextToActive
    recentTabCycling = (try? c.decodeIfPresent(Bool.self, forKey: .recentTabCycling)) ?? base.recentTabCycling
    copyLinkShortcut = (try? c.decodeIfPresent(Bool.self, forKey: .copyLinkShortcut)) ?? base.copyLinkShortcut
    sidebarShortcut = (try? c.decodeIfPresent(Bool.self, forKey: .sidebarShortcut)) ?? base.sidebarShortcut
    zoomedHosts = ((try? c.decodeIfPresent([String].self, forKey: .zoomedHosts)) ?? [])
      .filter { !$0.isEmpty && $0.count <= 255 }.prefix(RaySettings.maxZoomedHosts).map { $0 }
    zoomAdopted = (try? c.decodeIfPresent(Bool.self, forKey: .zoomAdopted)) ?? base.zoomAdopted
    windowFrame = try? c.decodeIfPresent(String.self, forKey: .windowFrame)
    onboarded = (try? c.decodeIfPresent(Bool.self, forKey: .onboarded)) ?? base.onboarded
  }

  /// The settings that differ between two values.
  func changes(from old: RaySettingsValues) -> [RaySetting] {
    var out: [RaySetting] = []
    if minimalURL != old.minimalURL { out.append(.minimalURL) }
    if loadingProgress != old.loadingProgress { out.append(.loadingProgress) }
    if theme != old.theme { out.append(.theme) }
    if defaultZoom != old.defaultZoom { out.append(.defaultZoom) }
    if newTabNextToActive != old.newTabNextToActive { out.append(.newTabNextToActive) }
    if recentTabCycling != old.recentTabCycling { out.append(.recentTabCycling) }
    if copyLinkShortcut != old.copyLinkShortcut { out.append(.copyLinkShortcut) }
    if sidebarShortcut != old.sidebarShortcut { out.append(.sidebarShortcut) }
    if zoomedHosts != old.zoomedHosts { out.append(.zoomedHosts) }
    return out
  }
}

/// The app-wide settings: one `Settings.json` in the data dir (next to `Sidebar.json`, so RAY_DATA_DIR moves both),
/// loaded at launch and saved shortly after each change. Every window observes `didChange`. Private windows read
/// these and never add anything of their own to them.
final class RaySettings {
  static let shared = RaySettings(directory: (dataDirectory as NSString).deletingLastPathComponent)

  /// Posted on the main thread after a change; `userInfo["keys"]` is the `[RaySetting]` that changed.
  static let didChange = Notification.Name("RaySettingsDidChange")

  /// Chrome's page zoom levels (25% to 500%, as its Appearance page lists them).
  static let zoomLevels: [Double] = [0.25, 0.333, 0.5, 0.666, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3, 4, 5]
  static let maxZoomedHosts = 5000

  static func nearestZoom(_ value: Double) -> Double? {
    guard value.isFinite else { return nil }
    return zoomLevels.min { abs($0 - value) < abs($1 - value) }.flatMap { abs($0 - value) < 0.02 ? $0 : nil }
  }

  private(set) var values: RaySettingsValues
  private var zoomed: Set<String>
  private let url: URL?
  private var pending: DispatchWorkItem?

  init(directory: String?) {
    url = directory.map { URL(fileURLWithPath: $0).appendingPathComponent("Settings.json") }
    let loaded = url.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode(RaySettingsValues.self, from: $0) }
    values = loaded ?? RaySettingsValues()
    // A data dir with neither file is new: its first window shows the welcome. One with a Sidebar.json (Ray 0.1, or
    // a Settings.json lost) was already in use, so an update never greets an existing user.
    if loaded == nil, let url,
       !FileManager.default.fileExists(atPath: url.deletingLastPathComponent().appendingPathComponent("Sidebar.json").path) {
      values.onboarded = false
    }
    zoomed = Set(values.zoomedHosts)
    ProfileColor.apply(hex: values.theme)
  }

  // MARK: Changing

  /// Applies a change, saves, and tells the windows. The one way anything changes a setting: the window's controls
  /// and the test command both end up here.
  func update(_ change: (inout RaySettingsValues) -> Void) {
    let old = values
    var new = values
    change(&new)
    guard new != old else { return }
    values = new
    zoomed = Set(new.zoomedHosts)
    save()
    let keys = new.changes(from: old)
    if keys.contains(.theme) { ProfileColor.apply(hex: new.theme) }
    guard !keys.isEmpty else { return }
    NotificationCenter.default.post(name: Self.didChange, object: self, userInfo: ["keys": keys])
  }

  /// Sets one setting from text: `on` / `off`, `default` or `#RRGGBB` for the theme, a level such as `1.25` for zoom.
  /// Returns whether the text made sense. The window's controls call this too.
  @discardableResult
  func apply(_ key: RaySetting, _ text: String) -> Bool {
    let flag: Bool? = ["on", "true", "1", "yes"].contains(text.lowercased()) ? true
      : ["off", "false", "0", "no"].contains(text.lowercased()) ? false : nil
    switch key {
    case .minimalURL: guard let flag else { return false }; update { $0.minimalURL = flag }
    case .loadingProgress: guard let flag else { return false }; update { $0.loadingProgress = flag }
    case .newTabNextToActive: guard let flag else { return false }; update { $0.newTabNextToActive = flag }
    case .recentTabCycling: guard let flag else { return false }; update { $0.recentTabCycling = flag }
    case .copyLinkShortcut: guard let flag else { return false }; update { $0.copyLinkShortcut = flag }
    case .sidebarShortcut: guard let flag else { return false }; update { $0.sidebarShortcut = flag }
    case .theme:
      if text.lowercased() == "default" {
        update { $0.theme = nil }
      } else {
        guard ProfileColor.parse(text) != nil else { return false }
        update { $0.theme = text.uppercased() }
      }
    case .defaultZoom:
      guard let level = Double(text).flatMap(Self.nearestZoom) else { return false }
      update { $0.defaultZoom = level }
    case .zoomedHosts: return false
    }
    return true
  }

  // MARK: Zoomed hosts

  func isZoomed(_ host: String) -> Bool { zoomed.contains(host) }

  func markZoomed(_ host: String) {
    guard !zoomed.contains(host), zoomed.count < Self.maxZoomedHosts else { return }
    update { $0.zoomedHosts.append(host) }
  }

  func unmarkZoomed(_ host: String) {
    guard zoomed.contains(host) else { return }
    update { $0.zoomedHosts.removeAll { $0 == host } }
  }

  private var zoomWaiters: [() -> Void] = []

  /// Levels the engine already holds for hosts when Ray first tracks zoom are the user's own (they were set with
  /// ⌘+ / ⌘−, or in Chrome's pages): mark those hosts once, so the default never overwrites them. `then` runs once
  /// that is done, now if it already was.
  func adoptExistingZoom(profile: RayCoreProfile, then: @escaping () -> Void) {
    if values.zoomAdopted { return then() }
    zoomWaiters.append(then)
    guard zoomWaiters.count == 1 else { return }
    EngineCalls.call("ac_zoom_list", profile: profile) { [weak self] reply in
      guard let self else { return }
      let hosts = ((reply?["levels"] as? [String: Any]) ?? [:]).keys.map { $0.lowercased() }
        .filter { !$0.isEmpty && $0.count <= 255 }
      self.update {
        for host in hosts where !$0.zoomedHosts.contains(host) && $0.zoomedHosts.count < Self.maxZoomedHosts {
          $0.zoomedHosts.append(host)
        }
        $0.zoomAdopted = true
      }
      let waiters = self.zoomWaiters
      self.zoomWaiters = []
      waiters.forEach { $0() }
    }
  }

  // MARK: Onboarding

  /// The first run finished ("Start browsing"): it never shows again for this data dir.
  func markOnboarded() {
    update { $0.onboarded = true }
    flush()
  }

  // MARK: Saving

  /// The Settings window's frame, remembered without telling anyone.
  func rememberWindowFrame(_ frame: NSRect) {
    let text = NSStringFromRect(frame)
    guard values.windowFrame != text else { return }
    values.windowFrame = text
    save()
  }

  private func save() {
    guard url != nil else { return }
    pending?.cancel()
    let work = DispatchWorkItem { [weak self] in self?.flush() }
    pending = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
  }

  /// Writes now (on quit, so the last change isn't lost).
  func flush() {
    pending?.cancel()
    pending = nil
    guard let url, let data = try? JSONEncoder().encode(values) else { return }
    try? data.write(to: url, options: .atomic)
  }

  // MARK: State log

  var debug: [String: Any] {
    let accent = ProfileColor.accent
    return [
      "minimalURL": values.minimalURL, "loadingProgress": values.loadingProgress,
      "theme": [
        "setting": values.theme ?? "default",
        "accent": ProfileColor.hex(of: accent), "accentDark": ProfileColor.hex(of: accent, appearance: .darkAqua),
        "foreground": ProfileColor.foregroundName(on: accent),
        "foregroundDark": ProfileColor.foregroundName(on: accent, appearance: .darkAqua),
      ],
      "defaultZoom": values.defaultZoom, "newTabNextToActive": values.newTabNextToActive,
      "recentTabCycling": values.recentTabCycling, "copyLinkShortcut": values.copyLinkShortcut,
      "sidebarShortcut": values.sidebarShortcut, "zoomedHosts": values.zoomedHosts.sorted(),
      "zoomAdopted": values.zoomAdopted, "onboarded": values.onboarded,
    ]
  }
}
