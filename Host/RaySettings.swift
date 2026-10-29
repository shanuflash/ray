import AppKit

/// The app-wide settings: one `Settings.json` in the data dir (next to `Sidebar.json`, so RAY_DATA_DIR moves both),
/// loaded at launch and saved 0.2 s after each change and on quit. What the settings are is `SettingsCatalog.swift`;
/// this is their values: `RaySettings.shared[.minimalURL]` reads, `set(.minimalURL, true)` writes, and
/// `observe(.minimalURL) { … }` follows changes. The file is kept as a dictionary, so keys this build doesn't know
/// (a newer build's settings, an older build's leftovers) survive every save. Private windows read these and never
/// write anything of their own to them.
final class RaySettings {
  static let shared = RaySettings(directory: (dataDirectory as NSString).deletingLastPathComponent)

  /// Chrome's page zoom levels (25% to 500%, as its Appearance page lists them).
  static let zoomLevels: [Double] = [0.25, 0.333, 0.5, 0.666, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3, 4, 5]
  static let maxZoomedHosts = 5000

  static func nearestZoom(_ value: Double) -> Double? {
    guard value.isFinite else { return nil }
    return zoomLevels.min { abs($0 - value) < abs($1 - value) }.flatMap { abs($0 - value) < 0.02 ? $0 : nil }
  }

  /// Ray's own state kept in Settings.json beside the settings: no row, no observers, never reset.
  private static let stateKeys: Set<String> = ["zoomedHosts", "zoomAdopted", "windowFrame", "onboarded"]

  /// Each setting's value by id, always valid (see `SettingKey.validate`).
  private var values: [String: Any] = [:]
  /// Everything else Settings.json held that isn't a setting or Ray's state: written back as it was read.
  private var unknown: [String: Any] = [:]
  /// Hosts the user zoomed with ⌘+ / ⌘−: they keep their own level when the default changes.
  private(set) var zoomedHosts: [String]
  private var zoomed: Set<String>
  /// Whether levels already in the engine's host zoom map (set before Ray tracked this) became the user's own.
  private(set) var zoomAdopted: Bool
  /// The Settings window's frame, as `NSStringFromRect`.
  private(set) var windowFrame: String?
  /// The first run's welcome is done. Only "Start browsing" sets it, so a new data dir and every profile from before
  /// the welcome existed (Ray 0.2.0 and earlier: no key in Settings.json, or no Settings.json at all) see it once.
  private(set) var onboarded: Bool

  private let url: URL?
  private var pending: DispatchWorkItem?
  private var themeObservation: SettingsObservation?

  init(directory: String?) {
    url = directory.map { URL(fileURLWithPath: $0).appendingPathComponent("Settings.json") }
    // Older or damaged files still load: a setting that's missing or not a valid value takes its default.
    var file = url.flatMap { try? Data(contentsOf: $0) }
      .flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any] ?? [:]
    for (old, new) in AnySettingKey.aliases where file[new] == nil {
      if let value = file[old] { file[new] = value }
    }
    let hosts = ((file["zoomedHosts"] as? [Any]) ?? []).compactMap { $0 as? String }
      .filter { !$0.isEmpty && $0.count <= 255 }.prefix(Self.maxZoomedHosts).map { $0 }
    zoomedHosts = hosts
    zoomed = Set(hosts)
    zoomAdopted = file["zoomAdopted"].flatMap { Bool(settingJSON: $0) } ?? false
    windowFrame = file["windowFrame"] as? String
    onboarded = file["onboarded"].flatMap { Bool(settingJSON: $0) } ?? false
    values = Dictionary(uniqueKeysWithValues: AnySettingKey.all.map { ($0.id, $0.load(file[$0.id])) })
    let known = Set(AnySettingKey.all.map(\.id)).union(Self.stateKeys)
    unknown = file.filter { !known.contains($0.key) }
    // The profile's colour follows Settings › Theme.
    ProfileColor.apply(hex: self[.theme])
    themeObservation = observe(.theme) { ProfileColor.apply(hex: $0) }
  }

  // MARK: Reading and changing

  subscript<Value>(key: SettingKey<Value>) -> Value { values[key.id] as? Value ?? key.defaultValue }

  /// A setting's value as text (what `apply` takes).
  func text(of key: AnySettingKey) -> String { key.text(of: values[key.id] as Any) }

  /// Changes a setting, saves, and tells its observers. False when `validate` refuses the value (nothing changes).
  @discardableResult
  func set<Value>(_ key: SettingKey<Value>, _ value: Value) -> Bool {
    guard let valid = key.validate(value) else { return false }
    guard valid != self[key] else { return true }
    values[key.id] = valid
    save()
    changed(key.id)
    return true
  }

  /// Sets a setting from text: `on` / `off`, a level such as `1.25`, `#RRGGBB`, or `default` for any setting. Returns
  /// whether the text made sense. The window's controls and the test command `setting` both end up here.
  @discardableResult
  func apply(_ key: AnySettingKey, _ text: String) -> Bool { key.apply(text, to: self) }

  /// The same by id (or an alias); false for an id that isn't a setting.
  @discardableResult
  func apply(id: String, _ text: String) -> Bool {
    guard let key = AnySettingKey.named(id) else { return false }
    return apply(key, text)
  }

  // MARK: Observing

  /// In the order they began, so a window that registered first hears first.
  private var observations: [(id: ObjectIdentifier, keys: Set<String>, fire: () -> Void)] = []
  private var changedKeys: Set<String> = []
  private var deliveryScheduled = false

  /// Calls `handler` with the setting's new value after it changes: on the main thread, once per run-loop turn
  /// however many times it changed. Lasts as long as the returned observation is kept.
  func observe<Value>(_ key: SettingKey<Value>, _ handler: @escaping (Value) -> Void) -> SettingsObservation {
    observe([key]) { [unowned self] in handler(self[key]) }
  }

  /// Calls `handler` once per run-loop turn in which any of `keys` changed (`AnySettingKey.all`: any setting).
  func observe(_ keys: [AnySettingKey], _ handler: @escaping () -> Void) -> SettingsObservation {
    let observation = SettingsObservation(settings: self)
    observations.append((ObjectIdentifier(observation), Set(keys.map(\.id)), handler))
    return observation
  }

  fileprivate func remove(_ observation: SettingsObservation) {
    let id = ObjectIdentifier(observation)
    observations.removeAll { $0.id == id }
  }

  private func changed(_ id: String) {
    changedKeys.insert(id)
    guard !deliveryScheduled else { return }
    deliveryScheduled = true
    DispatchQueue.main.async { [weak self] in self?.deliver() }
  }

  private func deliver() {
    deliveryScheduled = false
    let keys = changedKeys
    changedKeys = []
    // A handler may add or end observations: work from a copy, skipping any ended meanwhile.
    for observation in observations where !observation.keys.isDisjoint(with: keys) {
      guard observations.contains(where: { $0.id == observation.id }) else { continue }
      observation.fire()
    }
  }

  // MARK: Zoomed hosts

  func isZoomed(_ host: String) -> Bool { zoomed.contains(host) }

  func markZoomed(_ host: String) {
    guard !zoomed.contains(host), zoomed.count < Self.maxZoomedHosts else { return }
    zoomedHosts.append(host)
    zoomed.insert(host)
    save()
  }

  func unmarkZoomed(_ host: String) {
    guard zoomed.contains(host) else { return }
    zoomedHosts.removeAll { $0 == host }
    zoomed.remove(host)
    save()
  }

  private var zoomWaiters: [() -> Void] = []

  /// Levels the engine already holds for hosts when Ray first tracks zoom are the user's own (they were set with
  /// ⌘+ / ⌘−, or in Chrome's pages): mark those hosts once, so the default never overwrites them. `then` runs once
  /// that is done, now if it already was.
  func adoptExistingZoom(profile: RayCoreProfile, then: @escaping () -> Void) {
    if zoomAdopted { return then() }
    zoomWaiters.append(then)
    guard zoomWaiters.count == 1 else { return }
    EngineCalls.call("ac_zoom_list", profile: profile) { [weak self] reply in
      guard let self else { return }
      let hosts = ((reply?["levels"] as? [String: Any]) ?? [:]).keys.map { $0.lowercased() }
        .filter { !$0.isEmpty && $0.count <= 255 }
      for host in hosts { self.markZoomed(host) }
      self.zoomAdopted = true
      self.save()
      let waiters = self.zoomWaiters
      self.zoomWaiters = []
      waiters.forEach { $0() }
    }
  }

  // MARK: Onboarding

  /// The first run finished ("Start browsing"): it never shows again for this data dir.
  func markOnboarded() {
    onboarded = true
    flush()
  }

  // MARK: Saving

  /// The Settings window's frame, remembered without telling anyone.
  func rememberWindowFrame(_ frame: NSRect) {
    let text = NSStringFromRect(frame)
    guard windowFrame != text else { return }
    windowFrame = text
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
    guard let url else { return }
    var file = unknown
    for key in AnySettingKey.all { file[key.id] = values[key.id].flatMap { key.json(of: $0) } }
    file["zoomedHosts"] = zoomedHosts
    file["zoomAdopted"] = zoomAdopted
    file["onboarded"] = onboarded
    file["windowFrame"] = windowFrame
    guard JSONSerialization.isValidJSONObject(file),
          let data = try? JSONSerialization.data(withJSONObject: file, options: [.sortedKeys]) else { return }
    try? data.write(to: url, options: .atomic)
  }

  // MARK: State log

  /// Every setting as the state log shows it (by id), and Ray's state kept beside them.
  var debug: [String: Any] {
    var out: [String: Any] = [:]
    for key in AnySettingKey.all { out[key.id] = key.log(of: values[key.id] as Any) }
    out["zoomedHosts"] = zoomedHosts.sorted()
    out["zoomAdopted"] = zoomAdopted
    out["onboarded"] = onboarded
    return out
  }
}

/// Keeps an `observe` call alive; it stops when this is released.
final class SettingsObservation {
  private weak var settings: RaySettings?

  fileprivate init(settings: RaySettings) { self.settings = settings }

  deinit { settings?.remove(self) }
}
