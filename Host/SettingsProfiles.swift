import AppKit

/// Which profile Settings' data panes (Passwords, Autofill, Extensions, Privacy) show and change (owner's pick 3B of
/// `docs/mocks/profiles.html`, Ardia's per-pane picker): the profile of the Space on screen in the normal window, until a
/// pane's pop-up picks another. Never a private window's.
enum SettingsDataProfile {
  /// Posted when the profile the panes show changed (a pick, or the Space on screen moving to another profile).
  static let didChange = Notification.Name("RaySettingsDataProfileDidChange")

  /// A profile picked in a pane's pop-up (`.some(nil)` is Default); nil follows the Space on screen.
  private(set) static var picked: String??
  private static var shown: String??
  private static var observer: NSObjectProtocol?

  static var window: BrowserWindowController? { AppController.shared.windows.first { !$0.isPrivate } }

  /// The directory the panes show (nil: Default).
  static var directory: String? {
    if let picked, let window, window.state.profileInfo(picked) != nil { return picked }
    return window?.state.current.profile
  }

  /// The engine profile the panes call: the chosen one once loaded, else the main one.
  static var current: RayCoreProfile? {
    guard let window else { return RayCoreEngine.shared?.defaultProfile }
    return window.loadedProfile(directory) ?? window.mainProfile
  }

  /// Every profile, for the pop-up.
  static var profiles: [ProfileInfo] { window?.state.profiles ?? [] }

  static func pick(_ directory: String?) {
    start()
    picked = .some(directory)
    guard let window else { return changed() }
    window.loadProfile(directory) { _ in changed() }
  }

  /// Follows the normal window: a Space switch to another profile moves the panes with it (unless one was picked).
  static func start() {
    guard observer == nil else { return }
    shown = .some(directory)
    observer = NotificationCenter.default.addObserver(forName: BrowserWindowController.spacesDidChange, object: nil,
                                                      queue: .main) { _ in
      if let picked, let window, window.state.profileInfo(picked) == nil { Self.picked = nil }
      if shown != .some(directory) {
        let wanted = directory
        if let window, wanted != nil, window.loadedProfile(wanted) == nil {
          window.loadProfile(wanted) { _ in changed() }
        } else {
          changed()
        }
      }
    }
  }

  private static func changed() {
    shown = .some(directory)
    NotificationCenter.default.post(name: didChange, object: nil)
  }

  /// A pane's reaction to a change: `reload` runs on the main thread after each.
  static func observe(_ reload: @escaping () -> Void) -> NSObjectProtocol {
    start()
    return NotificationCenter.default.addObserver(forName: didChange, object: nil, queue: .main) { _ in reload() }
  }

  /// The section each data pane puts at its top.
  static func section(_ pane: String) -> SettingsSection {
    start()
    return SettingsSection(id: "\(pane).profile", place: .top, view: ProfileChooserView(), card: false,
                           search: [SettingsSearchEntry(title: "Profile", detail: "Whose data this shows",
                                                        keywords: ["profile", "profiles", "account"])])
  }

  static var debug: [String: Any] {
    ["directory": directory ?? NSNull(), "picked": picked.map { $0 ?? "default" } ?? NSNull(),
     "path": current?.path ?? NSNull()]
  }
}

/// "Profile" with a pop-up of every profile at the right, at the top of a data pane; no height while there's one.
final class ProfileChooserView: NSView, SettingsSizing {
  private let label = settingsLabel("Profile", size: 13, weight: .semibold)
  let popUp = NSPopUpButton(frame: .zero, pullsDown: false)
  private var observers: [NSObjectProtocol] = []

  override init(frame: NSRect) {
    super.init(frame: frame)
    popUp.target = self
    popUp.action = #selector(chosen)
    popUp.controlSize = .regular
    addSubview(label)
    addSubview(popUp)
    for name in [BrowserWindowController.spacesDidChange, SettingsDataProfile.didChange] {
      observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        self?.refresh()
      })
    }
    refresh()
  }

  required init?(coder: NSCoder) { fatalError() }

  deinit { observers.forEach(NotificationCenter.default.removeObserver) }

  override var isFlipped: Bool { true }

  private var shows: Bool { SettingsDataProfile.profiles.count > 1 }

  func refresh() {
    let profiles = SettingsDataProfile.profiles
    popUp.removeAllItems()
    for info in profiles {
      popUp.addItem(withTitle: info.name)
      popUp.lastItem?.image = ProfileInfo.avatar(info, size: 14)
    }
    let current = SettingsDataProfile.directory
    popUp.selectItem(at: profiles.firstIndex { $0.directory == current } ?? 0)
    let wasHidden = isHidden
    isHidden = !shows
    if wasHidden != isHidden { settingsSectionResized() }
    needsLayout = true
  }

  @objc private func chosen() {
    let profiles = SettingsDataProfile.profiles
    let index = popUp.indexOfSelectedItem
    guard profiles.indices.contains(index) else { return }
    SettingsDataProfile.pick(profiles[index].directory)
  }

  func height(forWidth width: CGFloat) -> CGFloat { shows ? 30 : 0 }

  override func layout() {
    super.layout()
    let size = popUp.intrinsicContentSize
    popUp.frame = NSRect(x: bounds.width - size.width, y: ((bounds.height - size.height) / 2).rounded(),
                         width: size.width, height: size.height)
    let height = label.intrinsicContentSize.height
    label.frame = NSRect(x: 4, y: ((bounds.height - height) / 2).rounded(), width: 120, height: height)
  }

  /// For tests: picks the nth profile as a click would.
  func pick(_ index: Int) -> Bool {
    guard SettingsDataProfile.profiles.indices.contains(index) else { return false }
    popUp.selectItem(at: index)
    chosen()
    return true
  }
}
