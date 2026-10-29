import AppKit

// A Settings pane is its catalog rows (generated: grouped by `group`, rare rows under a "More" line at the end of
// their group) plus, optionally, UI of its own from a `SettingsPaneContent`. Adding a pane's own UI is one new file
// (`Host/SettingsPrivacy.swift`: a class conforming to `SettingsPaneContent`) and one line in `content(for:)` below;
// the window's layout code doesn't change. A pane with no visible rows and no content of its own is hidden in Ray.app.

/// What a pane adds to its generated rows. Every member has a default, so a provider implements only what it needs.
/// The window asks once, when it builds the pane; views it returns stay for the window's life and follow changes
/// themselves (observe the settings or engine state they show).
protocol SettingsPaneContent: AnyObject {
  /// Whether the pane has something of its own to show (so Ray.app lists it even with no catalog rows). Asked often:
  /// answer without building views.
  var hasContent: Bool { get }
  /// The one call to action at the top of the pane (`SettingsCallToAction`), or nil.
  func callToAction() -> NSView?
  /// Sections of the pane's own, placed among the generated groups (see `SettingsSection.Place`).
  func sections() -> [SettingsSection]
  /// One control at the right end of a group's header (a per-profile picker, say), or nil.
  func headerAccessory(for group: SettingGroup) -> NSView?
  /// The control for a `.custom(name)` setting of this pane.
  func control(named name: String, for key: AnySettingKey) -> NSView?
  /// A small live picture beside a setting's row (a `MiniRayWindow` showing what the setting does), or nil.
  func picture(for key: AnySettingKey) -> NSView?
}

extension SettingsPaneContent {
  /// Pictures and header controls alone don't count; a provider with sections or a call to action says true.
  var hasContent: Bool { false }
  func callToAction() -> NSView? { nil }
  func sections() -> [SettingsSection] { [] }
  func headerAccessory(for group: SettingGroup) -> NSView? { nil }
  func control(named name: String, for key: AnySettingKey) -> NSView? { nil }
  func picture(for key: AnySettingKey) -> NSView? { nil }
}

/// A block of a pane's own UI: an optional header like a group's, then its view (full column width). Its search
/// entries make it findable from the window's search and the command bar; choosing one scrolls to the section and
/// flashes it.
struct SettingsSection {
  enum Place {
    /// Above the generated groups (under the call to action).
    case top
    /// Right after the generated group with this id.
    case after(String)
    /// Below everything else.
    case bottom
  }

  /// Unique in the window: also the anchor search results and `settings open <pane>` flashes use.
  let id: String
  let title: String?
  let place: Place
  let view: NSView
  let search: [SettingsSearchEntry]

  init(id: String, title: String? = nil, place: Place = .bottom, view: NSView, search: [SettingsSearchEntry] = []) {
    self.id = id
    self.title = title
    self.place = place
    self.view = view
    self.search = search
  }
}

/// Something a pane's own section offers to search: a title, a line under it and other words that find it.
struct SettingsSearchEntry {
  let title: String
  let detail: String
  let keywords: [String]

  init(title: String, detail: String = "", keywords: [String] = []) {
    self.title = title
    self.detail = detail
    self.keywords = keywords
  }
}

/// A view whose height follows its width (wrapping text): sections and controls that adopt it are laid out by it,
/// others by their `fittingSize`.
protocol SettingsSizing: AnyObject {
  func height(forWidth width: CGFloat) -> CGFloat
}

enum SettingsPanes {
  private static var made: [SettingPane: SettingsPaneContent] = [:]
  private static var madeSections: [SettingPane: [SettingsSection]] = [:]

  /// The pane's own content, made once.
  static func content(for pane: SettingPane) -> SettingsPaneContent? {
    if let content = made[pane] { return content }
    guard let content = make(pane) else { return nil }
    made[pane] = content
    return content
  }

  /// The pane's own sections, asked of its content once (the window shows these views; search reads their entries).
  static func sections(for pane: SettingPane) -> [SettingsSection] {
    if let sections = madeSections[pane] { return sections }
    let sections = content(for: pane)?.sections() ?? []
    madeSections[pane] = sections
    return sections
  }

  // The registry: one line per pane, a blank line between them, so panes added in parallel merge cleanly.
  private static func make(_ pane: SettingPane) -> SettingsPaneContent? {
    switch pane {
    case .general: return GeneralPaneContent()

    case .tabs: return TabsPaneContent()

    case .appearance: return AppearancePaneContent()

    case .search: return nil

    case .privacy: return PrivacyPaneContent()

    case .passwords: return PasswordsPaneContent.shared

    case .autofill: return AutofillPaneContent.shared

    case .extensions: return ExtensionsPaneContent()

    case .shortcuts: return nil

    case .about: return AboutPaneContent()
    }
  }
}
