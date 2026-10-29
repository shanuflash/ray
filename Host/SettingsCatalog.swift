import AppKit

// Ray's settings, one typed entry each. An entry is everything about a setting: its id (also its key in
// Settings.json, never renamed without an alias), default, validation, scope, whether its feature exists, and how the
// Settings window shows it. `RaySettings` stores and observes them; the window's rows, the test command `setting`,
// the state log's `settings` dump and the `settings-catalog` check are all generated from this list.
//
// Adding a setting: one `static let` below plus its name in `all`, then the feature reads
// `RaySettings.shared[.yourSetting]` (and `observe(.yourSetting)` if it must follow changes).

// MARK: Catalog

extension AnySettingKey {
  /// Every setting, in the order the window lists them (rows group by `group`, in order of first appearance).
  static let all: [AnySettingKey] = [
    minimalURL, loadingProgress, theme, defaultZoom, newTabNextToActive, recentTabCycling, copyLinkShortcut,
    sidebarShortcut,
  ]

  /// Old ids that now load into a renamed setting: `"oldId": "newId"`. The old key stays in Settings.json as it was.
  static let aliases: [String: String] = [:]

  /// The page address bar shows only the host, the path on hover (off: the full address). View › Show Full Address
  /// is the same setting, inverted.
  static let minimalURL = SettingKey<Bool>(
    "minimalURL", default: false,
    ui: SettingUI(
      pane: .appearance, group: .address, title: "Minimal URL in the address bar",
      detail: "Show only the site in the address bar. The rest of the address appears when you hover it.",
      keywords: ["url", "address", "host", "full address", "path"], control: .toggle))

  /// A wash in the page address bar and a thin line on the page while it loads.
  static let loadingProgress = SettingKey<Bool>(
    "loadingProgress", default: true,
    ui: SettingUI(
      pane: .appearance, group: .address, title: "Show loading progress in the address bar",
      detail: "A wash fills the address bar, and a thin line runs along the page, while a page loads.",
      keywords: ["loading", "progress", "bar", "wash"], control: .toggle))

  /// The profile's colour as `#RRGGBB`; nil is the default lavender.
  static let theme = SettingKey<String?>(
    "theme", default: nil,
    validate: { hex in
      guard let hex else { return .some(nil) }
      return ProfileColor.parse(hex) != nil ? .some(hex.uppercased()) : nil
    },
    ui: SettingUI(
      pane: .appearance, group: .theme, title: "Theme",
      detail: "The colour of Ray's highlights: loading, selection, drop targets and switches.",
      keywords: ["colour", "color", "accent", "highlight"], control: .colour),
    log: { hex in
      let accent = ProfileColor.accent
      return [
        "setting": hex ?? "default",
        "accent": ProfileColor.hex(of: accent), "accentDark": ProfileColor.hex(of: accent, appearance: .darkAqua),
        "foreground": ProfileColor.foregroundName(on: accent),
        "foregroundDark": ProfileColor.foregroundName(on: accent, appearance: .darkAqua),
      ]
    })

  /// Zoom for sites the user hasn't zoomed themselves; 1 is 100%. One of Chrome's levels.
  static let defaultZoom = SettingKey<Double>(
    "defaultZoom", default: 1, validate: RaySettings.nearestZoom,
    ui: SettingUI(
      pane: .appearance, group: .page, title: "Page zoom",
      detail: "For sites you haven't zoomed yourself. Zooming a site with ⌘+ or ⌘− keeps its own level.",
      keywords: ["zoom", "size", "scale", "default zoom"],
      control: .choice(RaySettings.zoomLevels.map { SettingChoice(title: "\(Int(($0 * 100).rounded()))%", value: $0.settingText) })))

  static let newTabNextToActive = SettingKey<Bool>(
    "newTabNextToActive", default: false,
    ui: SettingUI(
      pane: .appearance, group: .tabs, title: "Open new tabs next to the active tab",
      detail: "A new tab goes right after the tab you're on, when it's in Today. Off: at the top of Today.",
      keywords: ["new tab", "position", "order"], control: .toggle))

  static let recentTabCycling = SettingKey<Bool>(
    "recentTabCycling", default: true,
    ui: SettingUI(
      pane: .appearance, group: .tabs, title: "Cycle through tabs in most recently used order with Ctrl+Tab",
      detail: "Hold Control and press Tab again to go further back. Off: in the order of the sidebar.",
      keywords: ["control tab", "ctrl tab", "switch tabs", "recent"], control: .toggle))

  static let copyLinkShortcut = SettingKey<Bool>(
    "copyLinkShortcut", default: true,
    ui: SettingUI(
      pane: .appearance, group: .shortcuts, title: "Enable quick page link copying with ⌘+Shift+C",
      detail: "Copies the page's address. Off: the key goes to the page.",
      keywords: ["copy link", "copy url", "shortcut", "keyboard"], control: .toggle))

  static let sidebarShortcut = SettingKey<Bool>(
    "sidebarShortcut", default: true,
    ui: SettingUI(
      pane: .appearance, group: .shortcuts, title: "Use ⌘+S to toggle vertical tabs in Vertical layout",
      detail: "In Ray, ⌘S shows and hides the sidebar. Off: the key goes to the page (Save Page As).",
      keywords: ["sidebar", "save page", "shortcut", "keyboard"], control: .toggle))

  /// The setting with this id (or an old id from `aliases`).
  static func named(_ id: String) -> AnySettingKey? {
    let current = aliases[id] ?? id
    return all.first { $0.id == current }
  }
}

// MARK: Pieces of an entry

/// Where a setting's value lives. Every setting is app-wide today (Settings.json); per-profile and per-Space values
/// come with Spaces.
enum SettingScope: String {
  case app
}

/// The Settings window's panes (only Appearance today).
enum SettingPane: String {
  case appearance
}

/// A group of rows in a pane; `title` is its header (none for an untitled group).
struct SettingGroup: Equatable {
  let id: String
  let title: String?

  static let address = SettingGroup(id: "address", title: nil)
  static let theme = SettingGroup(id: "theme", title: nil)
  static let page = SettingGroup(id: "page", title: "Page")
  static let tabs = SettingGroup(id: "tabs", title: "Tabs")
  static let shortcuts = SettingGroup(id: "shortcuts", title: "Shortcuts")
}

/// One option of a choice: what the menu shows, and the value's text (what `setting <id> <value>` takes).
struct SettingChoice {
  let title: String
  let value: String
}

/// How the window edits a setting.
enum SettingControl {
  /// A `RaySwitch` (Bool settings).
  case toggle
  /// A pop-up of fixed options; the setting accepts only these.
  case choice([SettingChoice])
  /// The colour swatches and a custom colour (`#RRGGBB` or the default).
  case colour
  /// A view of the setting's own, named here, built by the window.
  case custom(String)

  var kind: String {
    switch self {
    case .toggle: return "toggle"
    case .choice: return "choice"
    case .colour: return "colour"
    case .custom(let name): return "custom:\(name)"
    }
  }
}

/// How a setting appears in the Settings window and its search.
struct SettingUI {
  let pane: SettingPane
  let group: SettingGroup
  let title: String
  let detail: String
  /// Other words settings search matches besides the title and detail.
  let keywords: [String]
  let control: SettingControl
  /// Rarely changed: sits under its group's "More…" line.
  let rare: Bool

  init(pane: SettingPane, group: SettingGroup, title: String, detail: String, keywords: [String] = [],
       control: SettingControl, rare: Bool = false) {
    self.pane = pane
    self.group = group
    self.title = title
    self.detail = detail
    self.keywords = keywords
    self.control = control
    self.rare = rare
  }
}

// MARK: Keys

/// A setting without its value type: what lists, the window and the test command work with. Each one is a
/// `SettingKey<Value>`.
class AnySettingKey {
  /// Stable: also the key in Settings.json and the name the test command takes.
  let id: String
  let scope: SettingScope
  /// Whether the feature behind it exists. A row for one that doesn't shows only in test builds.
  let built: Bool
  let ui: SettingUI

  fileprivate init(id: String, scope: SettingScope, built: Bool, ui: SettingUI) {
    self.id = id
    self.scope = scope
    self.built = built
    self.ui = ui
  }

  /// Whether the window shows its row.
  var shown: Bool { built || TestEnvironment.isTestBuild }

  // Type-erased operations, each implemented by `SettingKey`.

  /// The value from Settings.json (`nil`: the key is missing), or the default when it isn't a valid one.
  func load(_ json: Any?) -> Any { fatalError() }
  /// What goes into Settings.json; nil leaves the key out.
  func json(of value: Any) -> Any? { fatalError() }
  /// The value's text, which `apply` reads back.
  func text(of value: Any) -> String { fatalError() }
  /// What the state log shows.
  func log(of value: Any) -> Any { fatalError() }
  var defaultText: String { fatalError() }
  /// Sets the setting from text (`default` is the default); false when the text isn't a valid value.
  func apply(_ text: String, to settings: RaySettings) -> Bool { fatalError() }
}

/// One setting. Its value is always valid: whatever it is set to or loaded from passes `validate`, which may change
/// it (a zoom level snaps to Chrome's nearest) or refuse it (nil).
final class SettingKey<Value: SettingValue>: AnySettingKey {
  let defaultValue: Value
  let validate: (Value) -> Value?
  private let logger: ((Value) -> Any)?

  init(_ id: String, default value: Value, validate: @escaping (Value) -> Value? = { $0 }, scope: SettingScope = .app,
       built: Bool = true, ui: SettingUI, log: ((Value) -> Any)? = nil) {
    defaultValue = value
    // A choice accepts only its options.
    if case .choice(let options) = ui.control {
      let allowed = Set(options.map(\.value))
      self.validate = { validate($0).flatMap { allowed.contains($0.settingText) ? $0 : nil } }
    } else {
      self.validate = validate
    }
    logger = log
    super.init(id: id, scope: scope, built: built, ui: ui)
  }

  /// The value from text: `default`, or what `Value` reads, validated.
  func parse(_ text: String) -> Value? {
    if text.lowercased() == "default" { return defaultValue }
    return Value(settingText: text).flatMap(validate)
  }

  private func typed(_ value: Any) -> Value { value as? Value ?? defaultValue }

  override func load(_ json: Any?) -> Any {
    guard let json, !(json is NSNull), let value = Value(settingJSON: json).flatMap(validate) else { return defaultValue }
    return value
  }

  override func json(of value: Any) -> Any? { typed(value).settingJSON }
  override func text(of value: Any) -> String { typed(value).settingText }
  override func log(of value: Any) -> Any { logger?(typed(value)) ?? typed(value).settingJSON ?? NSNull() }
  override var defaultText: String { defaultValue.settingText }

  override func apply(_ text: String, to settings: RaySettings) -> Bool {
    guard let value = parse(text) else { return false }
    return settings.set(self, value)
  }
}

// MARK: Value types

/// What a setting can hold: how it reads from and writes to Settings.json (as `JSONSerialization` has it) and how
/// it reads from text (the test command, the window's controls).
protocol SettingValue: Equatable {
  /// Nil when the JSON isn't this type (the setting then falls back to its default).
  init?(settingJSON json: Any)
  /// Nil leaves the key out of Settings.json.
  var settingJSON: Any? { get }
  init?(settingText text: String)
  /// Read back by `init?(settingText:)`.
  var settingText: String { get }
}

private func isJSONBool(_ value: Any) -> Bool {
  guard let number = value as? NSNumber else { return false }
  return CFGetTypeID(number) == CFBooleanGetTypeID()
}

extension Bool: SettingValue {
  init?(settingJSON json: Any) {
    guard isJSONBool(json), let flag = json as? Bool else { return nil }
    self = flag
  }
  var settingJSON: Any? { self }
  init?(settingText text: String) {
    switch text.lowercased() {
    case "on", "true", "1", "yes": self = true
    case "off", "false", "0", "no": self = false
    default: return nil
    }
  }
  var settingText: String { self ? "on" : "off" }
}

extension Double: SettingValue {
  init?(settingJSON json: Any) {
    guard !isJSONBool(json), let number = json as? NSNumber, number.doubleValue.isFinite else { return nil }
    self = number.doubleValue
  }
  var settingJSON: Any? { self }
  init?(settingText text: String) {
    guard let value = Double(text), value.isFinite else { return nil }
    self = value
  }
  var settingText: String { String(self) }
}

extension Int: SettingValue {
  init?(settingJSON json: Any) {
    guard !isJSONBool(json), let number = json as? NSNumber, let value = Int(exactly: number.doubleValue) else { return nil }
    self = value
  }
  var settingJSON: Any? { self }
  init?(settingText text: String) {
    guard let value = Int(text) else { return nil }
    self = value
  }
  var settingText: String { String(self) }
}

extension String: SettingValue {
  init?(settingJSON json: Any) {
    guard let text = json as? String else { return nil }
    self = text
  }
  var settingJSON: Any? { self }
  init?(settingText text: String) { self = text }
  var settingText: String { self }
}

/// An optional text: nil (the default, as text `default`) leaves the key out of Settings.json.
extension Optional: SettingValue where Wrapped == String {
  init?(settingJSON json: Any) {
    guard let text = json as? String else { return nil }
    self = .some(text)
  }
  var settingJSON: Any? { self }
  init?(settingText text: String) { self = .some(text) }
  var settingText: String { self ?? "default" }
}

// MARK: Tests

extension AnySettingKey {
  /// Values the `settings-catalog` check sets and reads back, as text.
  var samples: [String] {
    switch ui.control {
    case .toggle: return ["on", "off"]
    case .choice(let options): return [options.first, options.last].compactMap { $0?.value }
    case .colour: return [ProfileColor.presets[0].hex, ProfileColor.presets[1].hex, "default"]
    case .custom: return []
    }
  }

  /// Text the check expects `setting <id> <text>` to refuse.
  var rejects: [String] {
    switch ui.control {
    case .toggle: return ["maybe", "2"]
    case .choice: return ["nonsense", "999"]
    case .colour: return ["red", "#12345G", "#1234567"]
    case .custom: return ["nonsense"]
    }
  }

  /// For `settings catalog`: every setting, what it is and its value now, as text.
  static func catalogDebug(_ settings: RaySettings) -> [[String: Any]] {
    all.map { key in
      [
        "id": key.id, "scope": key.scope.rawValue, "built": key.built, "pane": key.ui.pane.rawValue,
        "group": key.ui.group.id, "title": key.ui.title, "control": key.ui.control.kind, "rare": key.ui.rare,
        "default": key.defaultText, "value": settings.text(of: key), "samples": key.samples, "rejects": key.rejects,
      ]
    }
  }
}
