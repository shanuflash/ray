import AppKit

// Ray's settings, one typed entry each. An entry is everything about a setting: its id (also its key in
// Settings.json, never renamed without an alias), default, validation, scope, whether its feature exists, and how the
// Settings window shows it. `RaySettings` stores and observes them; the window's rows, its search, the command bar's
// "Settings: …" rows, the test command `setting`, the state log's `settings` dump and the `settings-catalog` check are
// all generated from this list.
//
// Adding a setting: one `static let` below plus its name in `all`, then the feature reads
// `RaySettings.shared[.yourSetting]` (and `observe(.yourSetting)` if it must follow changes).

// MARK: Catalog

extension AnySettingKey {
  /// Every setting, in the order the window lists them (rows group by `group`, in order of first appearance).
  static let all: [AnySettingKey] = [
    theme, appearanceMode, minimalURL, loadingProgress, defaultZoom, scrollBars, newTabNextToActive, recentTabCycling,
    copyLinkShortcut, sidebarShortcut,
    warnBeforeQuitting, warnBeforeClosingWindow, onQuit,  // General (SettingsGeneral.swift)
    offerToSavePasswords, jumpCloudRelay, autofillAddresses, autofillCards,  // Passwords (and JumpCloudRelay.swift), Autofill
    searchEngine, searchSuggestions, siteSearches,  // Search (SettingsSearchPane.swift)
    pageAddressBar,
    appIcon,
    showSidebarButton,
    showClearButton,
    hideAddressBarWhileScrolling,
    fadeUnloadedTabs,
    tabReorderHaptics,
    sidebarMediaControls,
    autoPictureInPicture,
    undoReopensClosedTab,
    shortcuts,  // Shortcuts (MenuShortcuts.swift, SettingsShortcutEditor.swift)
  ]

  /// Old ids that now load into a renamed setting: `"oldId": "newId"`. The old key stays in Settings.json as it was.
  static let aliases: [String: String] = [:]

  // Appearance

  /// The profile's colour as `#RRGGBB`; nil is the default lavender.
  static let theme = SettingKey<String?>(
    "theme", default: nil,
    validate: { hex in
      guard let hex else { return .some(nil) }
      return ProfileColor.parse(hex) != nil ? .some(hex.uppercased()) : nil
    },
    ui: SettingUI(
      pane: .appearance, group: .theme, title: "Theme colour",
      detail: "Ray's highlights: loading, selection, drop targets and switches.",
      keywords: ["colour", "color", "accent", "highlight", "theme"], control: .colour),
    log: { hex in
      let accent = ProfileColor.accent
      return [
        "setting": hex ?? "default",
        "accent": ProfileColor.hex(of: accent), "accentDark": ProfileColor.hex(of: accent, appearance: .darkAqua),
        "foreground": ProfileColor.foregroundName(on: accent),
        "foregroundDark": ProfileColor.foregroundName(on: accent, appearance: .darkAqua),
      ]
    })

  /// Light, dark, or as macOS is, for Ray's own windows (`AppLook`); pages are told the same, as Chrome tells them.
  static let appearanceMode = SettingKey<String>(
    "appearanceMode", default: "auto",
    ui: SettingUI(
      pane: .appearance, group: .theme, title: "Light or dark",
      detail: "Ray's sidebar, toolbar, panels and Settings. Pages that have a dark look use it too. Automatic follows macOS.",
      keywords: ["dark mode", "light mode", "appearance", "night"],
      control: .picture(
        [SettingChoice(title: "Automatic", value: "auto"), SettingChoice(title: "Light", value: "light"),
         SettingChoice(title: "Dark", value: "dark")],
        picture: { MiniRayWindow.appearanceChoice($0) })))

  /// The page address bar shows only the host, the path on hover (off: the full address). View › Show Full Address
  /// is the same setting, inverted.
  static let minimalURL = SettingKey<Bool>(
    "minimalURL", default: false,
    ui: SettingUI(
      pane: .appearance, group: .address, title: "Show only the site in the address bar",
      detail: "The rest of the address appears when you hover it. Also in View › Show Full Address.",
      keywords: ["minimal url", "url", "address", "host", "full address", "path"], control: .toggle))

  /// A wash in the page address bar and a thin line on the page while it loads.
  static let loadingProgress = SettingKey<Bool>(
    "loadingProgress", default: true,
    ui: SettingUI(
      pane: .appearance, group: .address, title: "Show loading progress",
      detail: "A wash fills the address bar, and a thin line runs along the page, while a page loads.",
      keywords: ["loading", "progress", "bar", "wash"], control: .toggle))

  /// Zoom for sites the user hasn't zoomed themselves; 1 is 100%. One of Chrome's levels.
  static let defaultZoom = SettingKey<Double>(
    "defaultZoom", default: 1, validate: RaySettings.nearestZoom,
    ui: SettingUI(
      pane: .appearance, group: .page, title: "Page zoom",
      detail: "For sites you haven't zoomed yourself. Zooming a site with ⌘+ or ⌘− keeps its own level.",
      keywords: ["zoom", "size", "scale", "default zoom"],
      control: .choice(RaySettings.zoomLevels.map { SettingChoice(title: "\(Int(($0 * 100).rounded()))%", value: $0.settingText) })))

  /// When pages (and Ray's own lists) show their scroll bars (`AppLook`).
  static let scrollBars = SettingKey<String>(
    "scrollBars", default: "system",
    ui: SettingUI(
      pane: .appearance, group: .page, title: "Show scroll bars",
      detail: "In pages and Ray's own lists. Automatic follows System Settings › Appearance.",
      keywords: ["scroll bars", "scrollbar", "scrolling"],
      control: .segmented([
        SettingChoice(title: "Automatic", value: "system"), SettingChoice(title: "When scrolling", value: "scrolling"),
        SettingChoice(title: "Always", value: "always"),
      ]),
      rare: true))

  /// The address bar above the page; off, the sidebar has the address. View › Show Address Bar on Page is the same
  /// setting, for every window.
  static let pageAddressBar = SettingKey<Bool>(
    "pageAddressBar", default: true,
    ui: SettingUI(
      pane: .appearance, group: .address, title: "Show the address bar above the page",
      detail: "Off, the address sits at the top of the sidebar, as in Arc. Also in View › Show Address Bar on Page.",
      keywords: ["toolbar", "url bar", "address bar", "arc", "dia", "top bar"], control: .toggle))

  /// Ray's icon in the Dock. Not built yet (the other icons need designing): its row shows only in test builds.
  static let appIcon = SettingKey<String>(
    "appIcon", default: "default", built: false,
    ui: SettingUI(
      pane: .appearance, group: .theme, title: "App icon",
      detail: "Shown in the Dock and the app switcher.",
      keywords: ["dock icon", "logo", "icon"],
      control: .choice([SettingChoice(title: "Default", value: "default")]), rare: true))

  // Tabs and sidebar

  /// Where ⌘T puts a new tab: the top of Today (off, Arc's), or right below the tab you're on.
  static let newTabNextToActive = SettingKey<Bool>(
    "newTabNextToActive", default: false,
    ui: SettingUI(
      pane: .tabs, group: .newTabs, title: "New tabs open",
      detail: "Where ⌘T and New Tab put it. From a pinned tab, at the top.",
      keywords: ["new tab", "position", "order", "where", "next to", "below", "top"],
      control: .segmented([SettingChoice(title: "At the top", value: "off"), SettingChoice(title: "Below current", value: "on")])))

  static let recentTabCycling = SettingKey<Bool>(
    "recentTabCycling", default: true,
    ui: SettingUI(
      pane: .tabs, group: .switching, title: "Switch tabs in recently used order with ⌃Tab",
      detail: "Hold Control and press Tab again to go further back. Off: in the order of the sidebar.",
      keywords: ["control tab", "ctrl tab", "switch tabs", "recent", "cycle"], control: .toggle))

  /// The sidebar button in the sidebar's top row and the page's address bar.
  static let showSidebarButton = SettingKey<Bool>(
    "showSidebarButton", default: true,
    ui: SettingUI(
      pane: .tabs, group: .sidebar, title: "Show the sidebar button",
      detail: "⌘S and View › Toggle Sidebar still hide and show the sidebar.",
      keywords: ["sidebar", "toggle", "button", "hide sidebar"], control: .toggle))

  /// Arc's ↓ Clear between pinned tabs and Today. Not built yet: its row shows only in test builds.
  static let showClearButton = SettingKey<Bool>(
    "showClearButton", default: true, built: false,
    ui: SettingUI(
      pane: .tabs, group: .sidebar, title: "Show the Clear button",
      detail: "Between your pinned tabs and Today. File › Clear Today's Tabs still clears them.",
      keywords: ["clear", "close all tabs", "today", "arc", "divider"], control: .toggle))

  /// The address bar above the page tucks away while you scroll down. Not built yet: its row shows only in test builds.
  static let hideAddressBarWhileScrolling = SettingKey<Bool>(
    "hideAddressBarWhileScrolling", default: false, built: false,
    ui: SettingUI(
      pane: .tabs, group: .sidebar, title: "Hide the address bar while scrolling",
      detail: "Scrolling down tucks it into a thin strip with the site's name; scrolling up or a click brings it back.",
      keywords: ["auto hide", "toolbar", "compact", "scroll"], control: .toggle))

  /// A tab whose page isn't loaded shows its icon faded.
  static let fadeUnloadedTabs = SettingKey<Bool>(
    "fadeUnloadedTabs", default: false,
    ui: SettingUI(
      pane: .tabs, group: .sidebar, title: "Fade icons of unloaded tabs",
      detail: "A tab whose page isn't loaded, like a pinned tab you haven't opened or one restored after a relaunch. Clicking it loads the page.",
      keywords: ["unloaded", "asleep", "sleeping", "dim", "grey", "gray", "inactive", "pinned"], control: .toggle))

  /// A trackpad tick each time a dragged tab finds a new place.
  static let tabReorderHaptics = SettingKey<Bool>(
    "tabReorderHaptics", default: true,
    ui: SettingUI(
      pane: .tabs, group: .sidebar, title: "Haptic feedback when reordering tabs",
      detail: "The trackpad ticks each time a tab you're dragging moves to a new place.",
      keywords: ["haptic", "trackpad", "vibration", "drag", "reorder", "force touch"], control: .toggle))

  /// A player at the bottom of the sidebar for a tab playing out of sight. Not built yet: its row shows only in test builds.
  static let sidebarMediaControls = SettingKey<Bool>(
    "sidebarMediaControls", default: true, built: false,
    ui: SettingUI(
      pane: .tabs, group: .media, title: "Show media controls in the sidebar",
      detail: "When a tab you're not looking at plays sound, a player appears at the bottom of the sidebar.",
      keywords: ["music", "player", "audio", "now playing", "media"], control: .toggle))

  /// A video pops out when you leave its tab. Not built yet: its row shows only in test builds.
  static let autoPictureInPicture = SettingKey<Bool>(
    "autoPictureInPicture", default: true, built: false,
    ui: SettingUI(
      pane: .tabs, group: .media, title: "Automatic Picture in Picture",
      detail: "A video or call you're watching pops out when you switch tabs, and returns when you come back.",
      keywords: ["pip", "video", "floating", "mini player", "picture in picture"], control: .toggle))

  // Shortcuts

  static let copyLinkShortcut = SettingKey<Bool>(
    "copyLinkShortcut", default: true,
    ui: SettingUI(
      pane: .shortcuts, group: .keys, title: "Copy the page's link with ⇧⌘C",
      detail: "As Edit › Copy URL does. Off: the key goes to the page.",
      keywords: ["copy link", "copy url", "shortcut", "keyboard"], control: .toggle))

  static let sidebarShortcut = SettingKey<Bool>(
    "sidebarShortcut", default: true,
    ui: SettingUI(
      pane: .shortcuts, group: .keys, title: "Show and hide the sidebar with ⌘S",
      detail: "Off: the key goes to the page (Save Page As).",
      keywords: ["sidebar", "save page", "shortcut", "keyboard", "toggle"], control: .toggle))

  /// Edit › Undo reopens the last closed tab outside text (`UndoCloseTab`), as in Arc.
  static let undoReopensClosedTab = SettingKey<Bool>(
    "undoReopensClosedTab", default: false,
    ui: SettingUI(
      pane: .shortcuts, group: .keys, title: "Reopen closed tabs with ⌘Z",
      detail: "Outside text fields, as in Arc; press it again for the tab closed before. In a text field ⌘Z still undoes typing.",
      keywords: ["undo", "reopen", "closed tab", "restore tab", "cmd z", "arc"], control: .toggle))

  // Passwords

  /// JumpCloud Go through Google Chrome (Host/JumpCloudRelay.swift): JumpCloud's helper gives its token only to
  /// browsers it knows, so Ray's own Chrome does the Touch ID step and Ray takes the jumpcloud.com cookies.
  static let jumpCloudRelay = SettingKey<Bool>(
    "jumpCloudRelay", default: false,
    ui: SettingUI(
      pane: .passwords, group: .signIn, title: "Sign in with JumpCloud Go through Chrome",
      detail: "On JumpCloud's sign-in page, a small Google Chrome window opens for Touch ID, then you're signed in here.",
      keywords: ["jumpcloud", "jumpcloud go", "sso", "single sign-on", "touch id", "passwordless", "work", "chrome"],
      control: .toggle))

  /// The setting with this id (or an old id from `aliases`).
  static func named(_ id: String) -> AnySettingKey? {
    let current = aliases[id] ?? id
    return all.first { $0.id == current }
  }
}

// MARK: Panes

/// The Settings window's panes, in sidebar order. Each has a title, a line saying what it is for and an SF Symbol;
/// its rows come from the catalog (`ui.pane`), its own UI (if any) from `SettingsPanes.content(for:)`.
enum SettingPane: String, CaseIterable {
  case general, tabs, appearance, search, privacy, passwords, autofill, extensions, shortcuts, about

  /// Where a pane sits in the window's sidebar: the top group, "Your data" or "More".
  enum Section: String, CaseIterable {
    case main, data, more

    var title: String? {
      switch self {
      case .main: return nil
      case .data: return "Your data"
      case .more: return "More"
      }
    }
  }

  struct Info {
    let title: String
    let subtitle: String
    let symbol: String
    let section: Section
  }

  // One line per pane, a blank line between them, so changes to different panes merge cleanly.
  var info: Info {
    switch self {
    case .general: return Info(title: "General", subtitle: "Opening and quitting Ray, downloads and updates.", symbol: "gearshape", section: .main)

    case .tabs: return Info(title: "Tabs and sidebar", subtitle: "Where new tabs go and how you move between them.", symbol: "sidebar.left", section: .main)

    case .appearance: return Info(title: "Appearance", subtitle: "Your colour, the address bar and how pages look.", symbol: "paintpalette", section: .main)

    case .search: return Info(title: "Search", subtitle: "The search engine and what the command bar suggests.", symbol: "magnifyingglass", section: .main)

    case .privacy: return Info(title: "Privacy", subtitle: "What sites may do, and clearing what they keep.", symbol: "hand.raised", section: .data)

    case .passwords: return Info(title: "Passwords", subtitle: "Saved passwords and passkeys, and when Ray offers to save them.", symbol: "key", section: .data)

    case .autofill: return Info(title: "Autofill", subtitle: "Addresses and cards Ray fills in for you.", symbol: "creditcard", section: .data)

    case .extensions: return Info(title: "Extensions", subtitle: "What you've installed, and what each may reach.", symbol: "puzzlepiece.extension", section: .data)

    case .shortcuts: return Info(title: "Shortcuts", subtitle: "Every command's key, and which keys go to the page.", symbol: "command", section: .more)

    case .about: return Info(title: "About Ray", subtitle: "Ray's version and the engine under it.", symbol: "info.circle", section: .more)
    }
  }

  var title: String { info.title }
  var subtitle: String { info.subtitle }
  var symbol: String { info.symbol }
  var section: Section { info.section }

  /// The catalog's settings in this pane whose rows show (see `AnySettingKey.shown`), in catalog order.
  var shownSettings: [AnySettingKey] { AnySettingKey.all.filter { $0.ui.pane == self && $0.shown } }

  /// Whether the window lists this pane: always in test builds; in Ray.app only with a row to show or content of its
  /// own, so nobody opens an empty page.
  var isShown: Bool {
    AnySettingKey.showsUnbuilt || !shownSettings.isEmpty || (SettingsPanes.content(for: self)?.hasContent ?? false)
  }

  /// The panes the window lists, in sidebar order.
  static var shown: [SettingPane] { allCases.filter(\.isShown) }
}

// MARK: Pieces of an entry

/// Where a setting's value lives. Every setting is app-wide today (Settings.json); per-profile and per-Space values
/// come with Spaces.
enum SettingScope: String {
  case app
}

/// A group of rows in a pane; `title` is its header (none for an untitled group).
struct SettingGroup: Equatable {
  let id: String
  let title: String?

  static let theme = SettingGroup(id: "theme", title: "Theme")
  static let address = SettingGroup(id: "address", title: "Address bar")
  static let page = SettingGroup(id: "page", title: "Pages")
  static let newTabs = SettingGroup(id: "newTabs", title: "New tabs")
  static let switching = SettingGroup(id: "switching", title: "Switching tabs")
  static let sidebar = SettingGroup(id: "sidebar", title: "Sidebar and address bar")
  static let media = SettingGroup(id: "media", title: "Media")
  static let keys = SettingGroup(id: "keys", title: "Ray's keys")
  static let signIn = SettingGroup(id: "signIn", title: "Signing in")
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
  /// Two or three options side by side (`RaySegmentedControl`); the setting accepts only these.
  case segmented([SettingChoice])
  /// Options as pictures under the row, each drawn by `picture(value)` (a `MiniRayWindow`, say); the selected one has
  /// a ring in the profile's colour and a check before its caption. The setting accepts only these.
  case picture([SettingChoice], picture: (String) -> NSView)
  /// The colour swatches and a custom colour (`#RRGGBB` or the default).
  case colour
  /// A view of the setting's own, named here, built by its pane's `SettingsPaneContent.control(named:for:)`.
  case custom(String)

  var kind: String {
    switch self {
    case .toggle: return "toggle"
    case .choice: return "choice"
    case .segmented: return "segmented"
    case .picture: return "picture"
    case .colour: return "colour"
    case .custom(let name): return "custom:\(name)"
    }
  }

  /// The fixed options of a choice, segmented or picture control.
  var options: [SettingChoice]? {
    switch self {
    case .choice(let options), .segmented(let options), .picture(let options, _): return options
    default: return nil
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
  /// Rarely changed: sits under its group's "More" line.
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
  /// A `.custom` control's values for the `settings-catalog` check, as text: ones it sets and reads back, ones it
  /// must refuse (other controls' come from the control).
  let customTests: (samples: [String], rejects: [String])?

  fileprivate init(id: String, scope: SettingScope, built: Bool, ui: SettingUI, customTests: (samples: [String], rejects: [String])?) {
    self.id = id
    self.scope = scope
    self.built = built
    self.ui = ui
    self.customTests = customTests
  }

  /// Test builds show unbuilt rows and every pane; `settings asapp on` (tests only) shows what Ray.app shows.
  static var showsUnbuilt: Bool { TestEnvironment.isTestBuild && !looksLikeRayApp }
  static var looksLikeRayApp = false

  /// Whether the window (and its search, and the command bar) shows its row.
  var shown: Bool { built || Self.showsUnbuilt }

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
       built: Bool = true, ui: SettingUI, log: ((Value) -> Any)? = nil,
       customTests: (samples: [String], rejects: [String])? = nil) {
    defaultValue = value
    // A choice (pop-up, segmented or pictures) accepts only its options.
    if let options = ui.control.options {
      let allowed = Set(options.map(\.value))
      self.validate = { validate($0).flatMap { allowed.contains($0.settingText) ? $0 : nil } }
    } else {
      self.validate = validate
    }
    logger = log
    super.init(id: id, scope: scope, built: built, ui: ui, customTests: customTests)
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
    case .choice(let options), .segmented(let options), .picture(let options, _):
      return [options.first, options.last].compactMap { $0?.value }
    case .colour: return [ProfileColor.presets[0].hex, ProfileColor.presets[1].hex, "default"]
    case .custom: return customTests?.samples ?? []
    }
  }

  /// Text the check expects `setting <id> <text>` to refuse.
  var rejects: [String] {
    switch ui.control {
    case .toggle: return ["maybe", "2"]
    case .choice, .segmented, .picture: return ["nonsense", "999"]
    case .colour: return ["red", "#12345G", "#1234567"]
    case .custom: return customTests?.rejects ?? ["nonsense"]
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
