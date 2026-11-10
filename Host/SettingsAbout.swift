import AppKit

/// Settings › About Ray: the version (with Check Now beside it while there is an updater, General's same button and
/// call) and the engine, in the window's own row style. The example of a pane with content of its own: this file plus
/// one line in `SettingsPanes.make(_:)`.
final class AboutPaneContent: SettingsPaneContent {
  var hasContent: Bool { true }
  private let checkNow = SettingsButton("Check Now")
  private let versionControl: SettingsTrailingControls
  private var observer: NSObjectProtocol?

  init() {
    let info = Bundle.main.infoDictionary ?? [:]
    let version = info["CFBundleShortVersionString"] as? String ?? "?"
    let build = info["CFBundleVersion"] as? String ?? "?"
    versionControl = SettingsTrailingControls([SettingsValueLabel("\(version) (\(build))"), checkNow])
    checkNow.setAccessibilityLabel("Check for Updates")
    checkNow.onClick = { GeneralSystem.shared.checkForUpdates() }
    refresh()
    observer = NotificationCenter.default.addObserver(forName: GeneralSystem.didChange, object: nil, queue: .main) { [weak self] _ in
      self?.refresh()
    }
  }

  deinit {
    if let observer { NotificationCenter.default.removeObserver(observer) }
  }

  /// Check Now only while there is an updater (Ray.app without its release key has none).
  private func refresh() {
    let shown = GeneralSystem.shared.updates != nil
    guard checkNow.isHidden == shown else { return }
    checkNow.isHidden = !shown
    versionControl.settingsSectionResized()
  }

  func sections() -> [SettingsSection] {
    let engine = RayCoreEngine.shared?.chromiumVersion ?? ""
    var rows = [SettingsRowView(title: "Version", detail: "", control: versionControl)]
    if !engine.isEmpty {
      rows.append(SettingsRowView(
        title: "Engine", detail: "Chromium without Google.", control: SettingsValueLabel(engine)))
    }
    return [
      SettingsSection(
        id: "about.version", title: "Ray", place: .top, view: SettingsRowList(rows: rows),
        search: [
          SettingsSearchEntry(title: "Version", detail: "Ray's version and build", keywords: ["about", "build", "release"]),
          SettingsSearchEntry(title: "Check for updates", detail: "Whether a newer Ray is out",
                              keywords: ["update", "upgrade", "sparkle", "new version"]),
          SettingsSearchEntry(title: "Engine", detail: "The Chromium version under Ray", keywords: ["chromium", "chrome"]),
        ])
    ]
  }

  // MARK: Tests

  /// Whether Check Now shows.
  var checkNowShown: Bool { !checkNow.isHidden }

  /// `settings press aboutCheckNow`: Check Now pressed as a click would.
  func pressCheckNow() -> Bool {
    guard !checkNow.isHidden else { return false }
    checkNow.onClick?()
    return true
  }
}

/// Several controls side by side on a row's right (a value and a button), 12 pt apart; hidden ones take no room.
final class SettingsTrailingControls: NSView {
  private let views: [NSView]
  private static let gap: CGFloat = 12

  init(_ views: [NSView]) {
    self.views = views
    super.init(frame: .zero)
    views.forEach { addSubview($0) }
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }

  private var shown: [NSView] { views.filter { !$0.isHidden } }

  override var fittingSize: NSSize {
    let sizes = shown.map(\.fittingSize)
    return NSSize(width: sizes.reduce(0) { $0 + $1.width } + Self.gap * CGFloat(max(0, sizes.count - 1)),
                  height: sizes.map(\.height).max() ?? 0)
  }

  override func layout() {
    super.layout()
    var x: CGFloat = 0
    for view in shown {
      let size = view.fittingSize
      view.frame = NSRect(x: x, y: ((bounds.height - size.height) / 2).rounded(), width: size.width, height: size.height)
      x += size.width + Self.gap
    }
  }
}
