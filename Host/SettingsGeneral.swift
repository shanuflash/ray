import AppKit
import ServiceManagement
import Sparkle

// Settings › General: the default-browser strip, opening at login, quitting and closing, downloads, updates and
// import. The quitting rows are catalog settings (Settings.json); the rest live where macOS, the engine or Sparkle
// keep them, so they are this pane's own sections and always show the real value:
// - default browser: LaunchServices (`NSWorkspace.setDefaultApplication`, macOS's own confirmation);
// - open at login: `SMAppService.mainApp`;
// - downloads: the engine's prefs (`ac_downloads_settings` / `ac_downloads_set_settings`), as Chrome's page has them;
// - updates: Sparkle's `SPUUpdater`, only while it runs (the real app with a real key).
// Test builds never change the real default browser or login items: `GeneralSystem` answers from fakes there.

// MARK: Settings

extension SettingGroup {
  static let quitting = SettingGroup(id: "quitting", title: "Quitting and closing")
}

extension AnySettingKey {
  /// ⌘Q asks first (`CloseWarnings.allowsQuit`). Off, as in Arc, Dia and Ardia.
  static let warnBeforeQuitting = SettingKey<Bool>(
    "warnBeforeQuitting", default: false,
    ui: SettingUI(
      pane: .general, group: .quitting, title: "Warn before quitting with ⌘Q",
      detail: "Asks before Ray quits, so a stray ⌘Q closes nothing. Pressing ⌘Q again quits.",
      keywords: ["quit", "confirm", "cmd q", "command q", "accidentally"], control: .toggle))

  /// Closing a window that would lose two or more tabs asks first (`CloseWarnings.allowsClose`). On, as in Ardia.
  static let warnBeforeClosingWindow = SettingKey<Bool>(
    "warnBeforeClosingWindow", default: true,
    ui: SettingUI(
      pane: .general, group: .quitting, title: "Warn before closing a window with several tabs",
      detail: "Asks before a private window with two or more tabs closes, since its tabs go with it. "
        + "Your normal window keeps its tabs: ⌘N brings them back.",
      keywords: ["close window", "confirm", "private window", "tabs", "accidentally"], control: .toggle))

  /// What the next launch shows: Today's tabs as they were, or a fresh start (`BrowserWindowController.startFresh`).
  static let onQuit = SettingKey<String>(
    "onQuit", default: "keep",
    ui: SettingUI(
      pane: .general, group: .quitting, title: "When Ray quits",
      detail: "Start fresh closes Today's tabs for the next launch; ⇧⌘T and History › Recently Closed bring them back. "
        + "Pinned tabs and favorites always stay.",
      keywords: ["restore", "session", "reopen", "start fresh", "keep tabs", "preserve", "launch", "startup"],
      control: .choice([
        SettingChoice(title: "Keep tabs and windows", value: "keep"), SettingChoice(title: "Start fresh", value: "fresh"),
      ])))
}

// MARK: Pane

final class GeneralPaneContent: SettingsPaneContent {
  /// The pane's content as the window last built it, for the test command and the state log.
  private(set) static weak var current: GeneralPaneContent?

  private let system = GeneralSystem.shared
  private weak var strip: SettingsCallToAction?
  private var loginRow: SettingsRowView?
  private let loginSwitch = RaySwitch()
  private var folderRow: SettingsRowView?
  private let folderButton = NSButton(title: "Change…", target: nil, action: nil)
  private let askSwitch = RaySwitch()
  private let updateRows = SettingsSlot()
  /// Whether the update rows were built for an updater (switches and Check Now) or for none (the version alone).
  private var updateRowsForUpdater: Bool?
  private let checkSwitch = RaySwitch()
  private let installSwitch = RaySwitch()
  private var versionRow: SettingsRowView?
  private let checkNow = NSButton(title: "Check Now", target: nil, action: nil)
  private let importButton = NSButton(title: "Import…", target: nil, action: nil)
  private var observer: NSObjectProtocol?

  init() {
    Self.current = self
    observer = NotificationCenter.default.addObserver(forName: GeneralSystem.didChange, object: nil, queue: .main) { [weak self] _ in
      self?.refresh()
    }
  }

  deinit {
    if let observer { NotificationCenter.default.removeObserver(observer) }
  }

  var hasContent: Bool { true }

  /// "Make Ray your default browser", hidden while it is.
  func callToAction() -> NSView? {
    let strip = SettingsCallToAction(
      symbol: "globe", text: "Make Ray your default browser, so links from other apps open here.",
      button: "Make Default") { [weak self] in self?.makeDefault() }
    strip.isHidden = system.isDefaultBrowser
    self.strip = strip
    return strip
  }

  func sections() -> [SettingsSection] {
    Self.current = self
    system.refresh()
    return [loginSection(), downloadsSection(), updatesSection(), importSection()]
  }

  private func loginSection() -> SettingsSection {
    loginSwitch.setAccessibilityLabel("Open Ray at login")
    loginSwitch.onChange = { [weak self] on in self?.system.setOpenAtLogin(on) }
    let row = SettingsRowView(title: "Open Ray at login", detail: "", control: loginSwitch)
    loginRow = row
    return SettingsSection(
      id: "general.openAtLogin", title: "Opening Ray", place: .top, view: SettingsRowList(rows: [row]),
      search: [SettingsSearchEntry(
        title: "Open Ray at login", detail: "Ray opens when you log in to your Mac",
        keywords: ["startup", "launch", "login items", "boot", "start"])])
  }

  private func downloadsSection() -> SettingsSection {
    folderButton.bezelStyle = .rounded
    folderButton.target = self
    folderButton.action = #selector(chooseFolder)
    askSwitch.setAccessibilityLabel("Ask where to save each file")
    askSwitch.onChange = { [weak self] on in self?.system.downloads.set(askWhereToSave: on) }
    let folder = SettingsRowView(title: "Downloads folder", detail: "", control: folderButton)
    folderRow = folder
    let ask = SettingsRowView(
      title: "Ask where to save each file", detail: "Off: files go straight to the downloads folder.", control: askSwitch)
    return SettingsSection(
      id: "general.downloads", title: "Downloads", place: .after(SettingGroup.quitting.id),
      view: SettingsRowList(rows: [folder, ask]),
      search: [
        SettingsSearchEntry(title: "Downloads folder", detail: "Where downloaded files are saved",
                            keywords: ["download location", "save to", "path", "folder"]),
        SettingsSearchEntry(title: "Ask where to save each file", detail: "Choose a place for every download",
                            keywords: ["download location", "save as", "prompt", "choose folder"]),
      ])
  }

  private func updatesSection() -> SettingsSection {
    checkSwitch.setAccessibilityLabel("Check for updates automatically")
    checkSwitch.onChange = { [weak self] on in self?.system.setAutomaticChecks(on) }
    installSwitch.setAccessibilityLabel("Install updates automatically")
    installSwitch.onChange = { [weak self] on in self?.system.setAutomaticInstall(on) }
    checkNow.bezelStyle = .rounded
    checkNow.target = self
    checkNow.action = #selector(checkForUpdates)
    buildUpdateRows()
    var search = [SettingsSearchEntry(title: "Check for updates now", detail: "Ray's version, and whether a newer one is out",
                                      keywords: ["update", "version", "sparkle", "upgrade"])]
    if system.updates != nil {
      search += [
        SettingsSearchEntry(title: "Check for updates automatically", keywords: ["update", "sparkle", "automatic"]),
        SettingsSearchEntry(title: "Install updates automatically", detail: "Updates install when Ray quits",
                            keywords: ["update", "install", "automatic", "background"]),
      ]
    }
    return SettingsSection(
      id: "general.updates", title: "Updates", place: .after(SettingGroup.quitting.id), view: updateRows, search: search)
  }

  /// With an updater: the two switches, then the version with Check Now. Without one (Ray.app until the release key
  /// exists): the version alone, saying updates aren't set up.
  private func buildUpdateRows() {
    let hasUpdater = system.updates != nil
    guard updateRowsForUpdater != hasUpdater else { return }
    updateRowsForUpdater = hasUpdater
    checkNow.isHidden = !hasUpdater
    let version = SettingsRowView(title: "Ray \(GeneralSystem.version)", detail: "", control: hasUpdater ? checkNow : nil)
    versionRow = version
    var rows: [NSView] = []
    if hasUpdater {
      rows = [
        SettingsRowView(title: "Check for updates automatically", detail: "Once a day.", control: checkSwitch),
        SettingsRowView(
          title: "Install updates automatically",
          detail: "Downloads them in the background and installs them when Ray quits.", control: installSwitch),
      ]
    }
    rows.append(version)
    updateRows.content = SettingsRowList(rows: rows)
  }

  private func importSection() -> SettingsSection {
    importButton.bezelStyle = .rounded
    importButton.target = self
    importButton.action = #selector(importFromBrowser)
    let row = SettingsRowView(
      title: "Import from another browser",
      detail: "Tabs, bookmarks, history, passwords and more, from Arc, Chrome, Safari, Firefox and others.",
      control: importButton)
    return SettingsSection(
      id: "general.import", title: "Import", place: .after(SettingGroup.quitting.id), view: SettingsRowList(rows: [row]),
      search: [SettingsSearchEntry(
        title: "Import from another browser", detail: "Bring tabs, bookmarks and passwords over",
        keywords: ["import", "migrate", "switch", "transfer", "arc", "chrome", "safari"])])
  }

  // MARK: Showing what's true

  /// Every row as macOS, the engine and Sparkle have it now; rows whose text changed relay the pane.
  func refresh() {
    var changed = false
    if let strip, strip.isHidden != system.isDefaultBrowser {
      strip.isHidden = system.isDefaultBrowser
      changed = true
    }
    let login = system.loginStatus
    loginSwitch.isOn = login == .enabled || login == .requiresApproval
    changed = set(loginRow, login == .requiresApproval
      ? "Allow Ray in System Settings › General › Login Items to finish." : "Ray opens when you log in to your Mac.") || changed
    let downloads = system.downloads
    if let folder = downloads.folder {
      let managed = downloads.managed ? ", set by your organization" : ""
      changed = set(folderRow, GeneralSystem.homeRelative(folder) + managed) || changed
    }
    askSwitch.isOn = downloads.askWhereToSave
    folderButton.isEnabled = downloads.loaded && !downloads.managed
    askSwitch.isEnabled = downloads.loaded && !downloads.managed
    askSwitch.alphaValue = askSwitch.isEnabled ? 1 : 0.45
    if updateRowsForUpdater != nil, updateRowsForUpdater != (system.updates != nil) {
      buildUpdateRows()
      changed = true
    }
    if let updates = system.updates {
      checkSwitch.isOn = updates.automaticallyChecks
      // Installing on its own needs the checks (Sparkle's and Ardia's rule): off and greyed while they're off.
      installSwitch.isOn = updates.automaticallyChecks && updates.automaticallyDownloads
      installSwitch.isEnabled = updates.automaticallyChecks
      installSwitch.alphaValue = installSwitch.isEnabled ? 1 : 0.45
      checkNow.isEnabled = updates.canCheck
      let checked = updates.lastCheck.map {
        "Last checked " + DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .short) + "."
      } ?? "Not checked yet."
      changed = set(versionRow, checked) || changed
    } else {
      changed = set(versionRow, "Updates aren't set up for this build.") || changed
    }
    if changed { (strip ?? folderRow)?.settingsPaneChanged() }
  }

  private func set(_ row: SettingsRowView?, _ detail: String) -> Bool {
    guard let row, row.detail != detail else { return false }
    row.detail = detail
    return true
  }

  // MARK: Actions

  private func makeDefault() { system.makeDefaultBrowser() }

  @objc private func chooseFolder() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false
    panel.prompt = "Use Folder"
    panel.message = "Choose where Ray saves downloaded files."
    if let folder = system.downloads.folder { panel.directoryURL = URL(fileURLWithPath: folder, isDirectory: true) }
    let done: (NSApplication.ModalResponse) -> Void = { [weak self] response in
      guard response == .OK, let url = panel.url else { return }
      self?.system.downloads.set(folder: url.path)
    }
    if let window = folderButton.window { panel.beginSheetModal(for: window, completionHandler: done) } else { done(panel.runModal()) }
  }

  @objc private func checkForUpdates() { system.checkForUpdates() }

  @objc private func importFromBrowser() { AppController.shared.importFromBrowser(nil) }

  // MARK: Tests

  /// `general <words>`: presses this pane's own controls as a click would (`cta`, `login`, `ask`, `autocheck`,
  /// `autoinstall`, `checknow`, `import`), or `folder <path>` as the folder panel's choice.
  func press(_ words: [String]) -> String {
    switch words.first {
    case "cta":
      guard let strip, !strip.isHidden else { return "no strip" }
      strip.press()
    case "login": loginSwitch.press()
    case "ask":
      guard askSwitch.isEnabled else { return "disabled" }
      askSwitch.press()
    case "autocheck":
      guard system.updates != nil else { return "no updater" }
      checkSwitch.press()
    case "autoinstall":
      guard system.updates != nil, installSwitch.isEnabled else { return "disabled" }
      installSwitch.press()
    case "checknow":
      guard system.updates != nil, checkNow.isEnabled else { return "disabled" }
      checkNow.performClick(nil)
    case "import": importButton.performClick(nil)
    case "folder":
      guard words.count == 2, words[1].hasPrefix("/"), folderButton.isEnabled else { return "usage: general folder <absolute path>" }
      system.downloads.set(folder: words[1])
    default: return "no such control"
    }
    return "ok"
  }

  var debug: [String: Any] {
    [
      "stripShown": strip.map { !$0.isHidden && $0.superview != nil } ?? false,
      "login": loginSwitch.isOn, "loginDetail": loginRow?.detail ?? "",
      "folder": folderRow?.detail ?? "", "folderEnabled": folderButton.isEnabled, "ask": askSwitch.isOn,
      "updateRows": (updateRows.content as? SettingsRowList)?.rows.compactMap { ($0 as? SettingsRowView)?.title } ?? [],
      "autoCheck": checkSwitch.isOn, "autoInstall": installSwitch.isOn, "autoInstallEnabled": installSwitch.isEnabled,
      "checkNowShown": !checkNow.isHidden, "checkNowEnabled": checkNow.isEnabled, "versionDetail": versionRow?.detail ?? "",
    ]
  }
}

/// Holds one view and takes its size: a section whose rows are rebuilt when what they show changes.
final class SettingsSlot: NSView, SettingsSizing {
  var content: NSView? {
    didSet {
      oldValue?.removeFromSuperview()
      if let content { addSubview(content) }
      needsLayout = true
    }
  }

  override var isFlipped: Bool { true }

  func height(forWidth width: CGFloat) -> CGFloat { content.map { sizedHeight($0, width: width) } ?? 0 }

  override func layout() {
    super.layout()
    content?.frame = bounds
  }
}

extension NSView {
  /// A pane's own row changed size (its text, a strip hidden): the pane lays out again and the window refits it.
  func settingsPaneChanged() {
    var view = superview
    while let current = view {
      if let pane = current as? SettingsPaneView {
        pane.needsLayout = true
        pane.onResize?()
        return
      }
      view = current.superview
    }
  }
}

// MARK: System

/// Where General's non-catalog settings really live. Real in Ray.app; in test builds the default browser and the
/// login item are fakes held in memory (a check must never change the Mac's default browser or login items), and
/// the updater is a fake when Sparkle isn't running (it never runs in test builds).
final class GeneralSystem {
  static let shared = GeneralSystem()
  /// Posted on the main thread when anything here may have changed.
  static let didChange = Notification.Name("RayGeneralSystemDidChange")

  private let fake = TestEnvironment.isTestBuild
  let downloads = DownloadSettings()

  static var version: String {
    let info = Bundle.main.infoDictionary ?? [:]
    return "\(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?"))"
  }

  /// `~/…` for a folder in the home folder.
  static func homeRelative(_ path: String) -> String {
    let home = NSHomeDirectory()
    return path == home || path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
  }

  private init() {
    // The default browser and login items can change in System Settings while Ray runs; Sparkle's switches can
    // change in its own prompts. Look again whenever Ray comes forward or the Settings window does.
    NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
      self?.refresh()
    }
    NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] note in
      if (note.object as? NSWindow)?.title == "Settings" { self?.refresh() }
    }
  }

  /// Reads everything again and tells the pane.
  func refresh() {
    downloads.load()
    changed()
  }

  fileprivate func changed() {
    NotificationCenter.default.post(name: Self.didChange, object: nil)
  }

  // MARK: Default browser

  /// Fakes (test builds only): whether macOS says Ray is the default, whether the user accepts macOS's question, and
  /// the schemes Ray asked for.
  var fakeIsDefault = false
  var fakeAccepts = true
  private(set) var fakeRequests: [String] = []
  private(set) var askingDefault = false

  /// Ray opens both http and https links.
  var isDefaultBrowser: Bool {
    if fake { return fakeIsDefault }
    let ours = Bundle.main.bundleIdentifier
    return ["http://example.com", "https://example.com"].allSatisfy { address in
      URL(string: address).flatMap { NSWorkspace.shared.urlForApplication(toOpen: $0) }
        .flatMap { Bundle(url: $0)?.bundleIdentifier } == ours
    }
  }

  /// Asks macOS to make Ray the default browser. macOS shows its own confirmation ("Use Ray or keep …?"); declining
  /// leaves the old browser. One answer covers http and https; https is asked for alone only if it was left behind.
  func makeDefaultBrowser() {
    guard !askingDefault, !isDefaultBrowser else { return }
    askingDefault = true
    func finish() {
      askingDefault = false
      changed()
    }
    if fake {
      fakeRequests += ["http", "https"]
      DispatchQueue.main.async { [self] in
        if fakeAccepts { fakeIsDefault = true }
        finish()
      }
      return
    }
    let app = Bundle.main.bundleURL
    NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: "http") { _ in
      DispatchQueue.main.async {
        guard let https = URL(string: "https://example.com"),
              NSWorkspace.shared.urlForApplication(toOpen: https)?.standardizedFileURL != app.standardizedFileURL else {
          return finish()
        }
        NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: "https") { _ in
          DispatchQueue.main.async { finish() }
        }
      }
    }
  }

  // MARK: Open at login

  /// The fake login item (test builds only): its status, and whether registering it needs the user's approval.
  var fakeLoginStatus: SMAppService.Status = .notRegistered
  var fakeNeedsApproval = false
  private(set) var loginCalls: [String] = []

  var loginStatus: SMAppService.Status { fake ? fakeLoginStatus : SMAppService.mainApp.status }

  /// Registers or removes Ray as a login item. macOS may hold a new one for approval in System Settings › General ›
  /// Login Items; the switch stays on and the row says so.
  func setOpenAtLogin(_ on: Bool) {
    loginCalls.append(on ? "register" : "unregister")
    if fake {
      fakeLoginStatus = on ? (fakeNeedsApproval ? .requiresApproval : .enabled) : .notRegistered
    } else {
      do {
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
      } catch {
        NSLog("[ray] login item not changed: %@", error.localizedDescription)
      }
    }
    changed()
  }

  // MARK: Updates

  /// A fake updater for test builds (Sparkle never runs there), so the rows and their wiring are checked; `nil` with
  /// `general updater none` to see what a build without updates shows.
  private var fakeUpdates: FakeUpdates? = TestEnvironment.isTestBuild ? FakeUpdates() : nil

  var updates: UpdateControls? {
    if let updater = Updater.shared.updater { return SparkleUpdates(updater: updater) }
    return fakeUpdates
  }

  func setAutomaticChecks(_ on: Bool) {
    guard let updates else { return }
    updates.automaticallyChecks = on
    changed()
  }

  func setAutomaticInstall(_ on: Bool) {
    guard let updates, updates.automaticallyChecks else { return changed() }
    updates.automaticallyDownloads = on
    changed()
  }

  func checkForUpdates() {
    updates?.checkNow()
    changed()
  }

  // MARK: Tests

  func command(_ words: [String]) -> String {
    switch (words.first, words.count > 1 ? words[1] : nil) {
    case ("default", "yes"?): fakeIsDefault = true
    case ("default", "no"?): fakeIsDefault = false
    case ("accept", "yes"?): fakeAccepts = true
    case ("accept", "no"?): fakeAccepts = false
    case ("loginstatus", let status?):
      switch status {
      case "enabled": fakeLoginStatus = .enabled
      case "approval": fakeLoginStatus = .requiresApproval
      case "off": fakeLoginStatus = .notRegistered
      default: return "usage: general loginstatus enabled|approval|off"
      }
    case ("approval", "yes"?): fakeNeedsApproval = true
    case ("approval", "no"?): fakeNeedsApproval = false
    case ("updater", "none"?): fakeUpdates = nil
    case ("updater", "fake"?): fakeUpdates = FakeUpdates()
    case ("refresh", nil): break
    default: return "usage"
    }
    refresh()
    return "ok"
  }

  var debug: [String: Any] {
    [
      "isDefault": isDefaultBrowser, "defaultRequests": fakeRequests, "asking": askingDefault,
      "loginStatus": { () -> String in
        switch loginStatus {
        case .enabled: return "enabled"
        case .requiresApproval: return "approval"
        case .notRegistered: return "off"
        default: return "notFound"
        }
      }(),
      "loginCalls": loginCalls,
      "downloads": downloads.debug,
      "updates": updates.map { u -> [String: Any] in
        ["kind": u is FakeUpdates ? "fake" : "sparkle", "autoCheck": u.automaticallyChecks,
         "autoInstall": u.automaticallyDownloads, "checks": (u as? FakeUpdates)?.checks ?? 0]
      } ?? NSNull(),
      "pane": GeneralPaneContent.current?.debug ?? NSNull(),
      "warning": CloseWarnings.debug,
    ]
  }
}

/// What the update rows change.
protocol UpdateControls {
  var automaticallyChecks: Bool { get nonmutating set }
  var automaticallyDownloads: Bool { get nonmutating set }
  var canCheck: Bool { get }
  var lastCheck: Date? { get }
  func checkNow()
}

/// Sparkle's own switches (kept in its user defaults; Info.plist's SUEnableAutomaticChecks and SUAutomaticallyUpdate
/// are the defaults) and its Check for Updates, with its standard dialogs.
private struct SparkleUpdates: UpdateControls {
  let updater: SPUUpdater

  var automaticallyChecks: Bool {
    get { updater.automaticallyChecksForUpdates }
    nonmutating set { updater.automaticallyChecksForUpdates = newValue }
  }
  var automaticallyDownloads: Bool {
    get { updater.automaticallyDownloadsUpdates }
    nonmutating set { updater.automaticallyDownloadsUpdates = newValue }
  }
  var canCheck: Bool { updater.canCheckForUpdates }
  var lastCheck: Date? { updater.lastUpdateCheckDate }
  func checkNow() { Updater.shared.checkForUpdates(nil) }
}

/// Test builds: Sparkle's defaults (both on, as Info.plist sets them), in memory; Check Now only counts.
private final class FakeUpdates: UpdateControls {
  private var checksOn = true
  private var downloadsOn = true
  private(set) var checks = 0
  private var checked: Date?

  var automaticallyChecks: Bool {
    get { checksOn }
    set { checksOn = newValue }
  }
  var automaticallyDownloads: Bool {
    get { downloadsOn }
    set { downloadsOn = newValue }
  }
  var canCheck: Bool { true }
  var lastCheck: Date? { checked }
  func checkNow() {
    checks += 1
    checked = Date()
  }
}

// MARK: Downloads

/// The default profile's download folder and "ask where to save", as the engine keeps them (Chrome's prefs; private
/// windows follow the profile they came from). Read on demand; changes go back through `ac_downloads_set_settings`,
/// which refuses relative paths and anything while a policy manages downloads.
final class DownloadSettings {
  private(set) var folder: String?
  private(set) var askWhereToSave = false
  private(set) var managed = false
  private(set) var loaded = false
  private(set) var lastError: String?

  private var profile: RayCoreProfile? { RayCoreEngine.shared?.defaultProfile }

  func load() {
    guard let profile else { return }
    EngineCalls.call("ac_downloads_settings", profile: profile) { [weak self] reply in self?.take(reply) }
  }

  func set(folder: String) { send(["folder": folder]) }

  func set(askWhereToSave: Bool) { send(["askWhereToSave": askWhereToSave]) }

  private func send(_ args: [String: Any]) {
    guard let profile else { return }
    EngineCalls.call("ac_downloads_set_settings", profile: profile, args: args) { [weak self] reply in self?.take(reply) }
  }

  private func take(_ reply: [String: Any]?) {
    if let folder = reply?["folder"] as? String {
      self.folder = folder
      askWhereToSave = reply?["askWhereToSave"] as? Bool ?? false
      managed = reply?["managed"] as? Bool ?? false
      loaded = true
      lastError = nil
    } else {
      lastError = reply?["error"] as? String ?? "no reply"
    }
    GeneralSystem.shared.changed()
  }

  var debug: [String: Any] {
    ["folder": folder ?? NSNull(), "ask": askWhereToSave, "managed": managed, "loaded": loaded, "error": lastError ?? NSNull()]
  }
}
