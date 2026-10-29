import AppKit

// Settings › Passwords: the JumpCloud Go relay's setup row, under "Sign in with JumpCloud Go through Chrome"
// (Host/JumpCloudRelay.swift). PasswordsPaneContent places it with `section`.

extension JumpCloudSetupRow {
  /// The row as a Passwords section, after the "Signing in" group.
  static func section() -> SettingsSection {
    SettingsSection(
      id: "jumpCloudRelay.setup", place: .after(SettingGroup.signIn.id), view: JumpCloudSetupRow(),
      search: [
        SettingsSearchEntry(
          title: "Set up JumpCloud Go in Chrome", detail: "Install JumpCloud Go in Ray's own Chrome profile, once",
          keywords: ["jumpcloud", "jumpcloud go", "extension", "chrome", "set up"]),
      ])
  }
}

/// "JumpCloud Go in Chrome": what's there (Chrome, its signature, the extension) and a Set Up… button that opens
/// Ray's Chrome on the extension's Web Store page. Follows the relay's changes (Chrome closing after setup).
final class JumpCloudSetupRow: NSView, SettingsSizing {
  private let row: SettingsRowView
  private let button = AccentButton(title: "Set Up…")
  private var observer: NSObjectProtocol?

  init() {
    row = SettingsRowView(title: "JumpCloud Go in Chrome", detail: "", control: button)
    super.init(frame: .zero)
    addSubview(row)
    button.onClick = { [weak self] in
      guard JumpCloudRelay.shared.status.canSetUp else { return }
      JumpCloudRelay.shared.setUp()
      self?.refresh()
    }
    observer = NotificationCenter.default.addObserver(
      forName: JumpCloudRelay.didChange, object: nil, queue: .main
    ) { [weak self] _ in self?.refresh() }
    refresh()
  }

  required init?(coder: NSCoder) { fatalError() }

  deinit {
    if let observer { NotificationCenter.default.removeObserver(observer) }
  }

  override var isFlipped: Bool { true }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window != nil { refresh() }
  }

  private func refresh() {
    let status = JumpCloudRelay.shared.status
    if row.detail != status.text {
      row.detail = status.text
      row.settingsPaneChanged()
    }
    button.alphaValue = status.canSetUp ? 1 : 0.4
  }

  func height(forWidth width: CGFloat) -> CGFloat { row.height(forWidth: width) }

  override func layout() {
    super.layout()
    row.frame = bounds
  }
}
