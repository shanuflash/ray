import AppKit

final class AppController: NSObject, ArdiaCoreEngineDelegate, NSApplicationDelegate {
  static let shared = AppController()

  private(set) var windows: [BrowserWindowController] = []
  private var quitting = false

  /// The window used last: the key window, else the one most recently shown or focused (Ray in the background has
  /// no key window, and menu commands still belong to the window you were in).
  var current: BrowserWindowController? {
    windows.first { $0.window === NSApp.keyWindow } ?? lastFocused.flatMap { last in windows.first { $0 === last } }
      ?? windows.first { $0.window === NSApp.mainWindow } ?? windows.last
  }

  private weak var lastFocused: BrowserWindowController?

  func noteFocused(_ controller: BrowserWindowController) { lastFocused = controller }

  func engineDidStart() {
    guard let engine = ArdiaCoreEngine.shared else { return }
    NSLog("[ray] engine started (Chromium %@)", engine.chromiumVersion)
    if let major = engine.chromiumVersion.split(separator: ".").first {
      SearchSuggestions.userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
        + "(KHTML, like Gecko) Chrome/\(major).0.0.0 Safari/537.36"
    }
    if let script = Bundle.main.url(forResource: "page_script", withExtension: "js"),
       let source = try? String(contentsOf: script, encoding: .utf8) {
      engine.pageScript = source
    }
    NSApp.delegate = self
    MainMenu.install(target: self)
    NotificationCenter.default.addObserver(
      forName: RaySettings.didChange, object: nil, queue: .main) { _ in MainMenu.applyShortcutSettings() }
    installReservedKeyRouting()
    TestCommands.start()
    Updater.shared.start()
    openMainWindow(startURL: TestEnvironment["RAY_START_URL"])
  }

  /// The normal window, from Sidebar.json; Ray keeps one, since there's one sidebar session.
  @discardableResult
  private func openMainWindow(startURL: String? = nil) -> BrowserWindowController? {
    if let open = windows.first(where: { !$0.isPrivate }) {
      if !launchedInBackground { open.window.makeKeyAndOrderFront(nil) }
      return open
    }
    guard let engine = ArdiaCoreEngine.shared else { return nil }
    let controller = makeWindow(profile: engine.defaultProfile)
    controller.present(background: launchedInBackground)
    controller.restore(startURL: startURL)
    SearchEngine.refresh(profile: controller.mainProfile)
    controller.searches.warm()
    return controller
  }

  /// File › New Window (⌘N): the normal window, opened again if it was closed, else brought forward.
  @objc func newWindow(_ sender: Any?) { openMainWindow() }

  /// Clicking the Dock icon with no window open brings the normal window back (Ray keeps running without one).
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    if !windows.contains(where: { $0.window.isVisible }) { openMainWindow() }
    return true
  }

  /// Chrome's reserved shortcuts (⌘W, ⌘T, ⌘N, …) go to Ray's menu before Chrome's window can take them. With a page
  /// focused the engine already asks Ray first (preHandleKeyEvent), but with no page (an empty window) Chrome's
  /// window class ran its own command, and ⌘W on an empty window did nothing. App-local, keys to Ray's own windows
  /// only; nothing global.
  private func installReservedKeyRouting() {
    NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard let self, Shortcuts.isReserved(event), let window = event.window,
            self.windows.contains(where: { $0.window === window }),
            NSApp.mainMenu?.performKeyEquivalent(with: event) == true else { return event }
      return nil
    }
    // Releasing Control settles a Ctrl+Tab through the recently used tabs on the tab it reached.
    NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
      if !event.modifierFlags.contains(.control) { self?.windows.forEach { $0.endTabCycle() } }
      return event
    }
  }

  func engineQuitCancelled() {
    quitting = false
    windows.forEach { $0.resumeAfterCancelledQuit() }
  }

  func engineWillShutDown() {
    if !quitting { windows.forEach { $0.prepareForQuit() } }
    quitting = true
    RaySettings.shared.flush()
  }

  func engineWindowForNewBrowser(of profile: ArdiaCoreProfile, type: String) -> ArdiaCoreWindow? {
    guard type == "normal" || type == "popup" else { return nil }
    if let window = windows.first(where: { $0.profile === profile }) { return window.coreWindow }
    // A link from another app while no window is open brings the normal window back for it.
    if !profile.offTheRecord, profile === ArdiaCoreEngine.shared?.defaultProfile { return openMainWindow()?.coreWindow }
    // A private page opened from elsewhere (say "Open Link in Incognito Window") gets a private window of its own,
    // never a normal one.
    if profile.offTheRecord, let main = windows.first(where: { !$0.isPrivate })?.profile {
      let controller = makeWindow(profile: profile, main: main)
      controller.present(background: launchedInBackground)
      return controller.coreWindow
    }
    return current?.coreWindow
  }

  func engineIsReservedKeyEvent(_ event: NSEvent) -> Bool {
    Shortcuts.isReserved(event)
  }

  func engine(_ engine: ArdiaCoreEngine, permissionRequest request: [String: Any], tab: ArdiaCoreTab) {
    guard let id = request["id"] as? String else { return }
    guard let controller = windows.first(where: { $0.owns(tab) }) else {
      ArdiaCoreEngine.resolvePermission(id, result: "dismiss", remember: false)
      return
    }
    controller.permissions.add(request, tab: tab)
  }

  func engine(_ engine: ArdiaCoreEngine, permissionRequestDismissed requestId: String) {
    windows.forEach { $0.permissions.dismissed(requestId) }
  }

  func engine(_ engine: ArdiaCoreEngine, extensionInstallPrompt prompt: [String: Any], tab: ArdiaCoreTab?) {
    let controller = tab.flatMap { tab in windows.first { $0.owns(tab) } } ?? current
    guard let controller else {
      if let id = prompt["requestId"] as? String { ArdiaCoreEngine.resolveExtensionInstallPrompt(id, accepted: false) }
      return
    }
    controller.extensions.showInstallPrompt(prompt, in: controller.window)
  }

  func engine(_ engine: ArdiaCoreEngine, extensionActionPopup popup: [String: Any], tab: ArdiaCoreTab) -> Bool {
    guard let id = popup["extensionId"] as? String, let controller = windows.first(where: { $0.owns(tab) }) else {
      return false
    }
    controller.extensions.showPopup(for: id, tab: tab, anchor: controller.extensionsAnchor)
    return true
  }

  /// File › New Private Window (⇧⌘N): a window on the profile's off-the-record side. Nothing it does is saved, and
  /// its cookies and history go when the last private window closes.
  @objc func newPrivateWindow(_ sender: Any?) {
    guard let engine = ArdiaCoreEngine.shared else { return }
    let main = current.map { $0.mainProfile } ?? engine.defaultProfile
    engine.offTheRecordProfile(for: main) { [weak self] profile, _ in
      guard let self, let profile else { return }
      let controller = self.makeWindow(profile: profile, main: main)
      controller.present(background: launchedInBackground)
      controller.restore(startURL: nil)
    }
  }

  private func makeWindow(profile: ArdiaCoreProfile, main: ArdiaCoreProfile? = nil) -> BrowserWindowController {
    let directory = profile.offTheRecord ? nil : (dataDirectory as NSString).deletingLastPathComponent
    let controller = BrowserWindowController(
      profile: profile, mainProfile: main ?? profile, store: SidebarStore(directory: directory))
    // Closing the last window leaves Ray running, as Mac apps do; the Dock icon or ⌘N bring the window back.
    controller.onClose = { [weak self, weak controller] in
      guard let self, let controller else { return }
      self.windows.removeAll { $0 === controller }
    }
    windows.append(controller)
    return controller
  }

  @objc func quit(_ sender: Any?) {
    guard !quitting else { return }
    quitting = true
    windows.forEach { $0.prepareForQuit() }
    RaySettings.shared.flush()
    ArdiaCoreEngine.shared?.quit()
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    quitting = true
    windows.forEach { $0.prepareForQuit() }
    RaySettings.shared.flush()
    return .terminateNow
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

  @objc func newTab(_ sender: Any?) { current?.beginNewTab() }

  /// Ray › Check for Updates…
  @objc func checkForUpdates(_ sender: Any?) { Updater.shared.checkForUpdates(sender) }

  /// The About panel, laid out like Arc's: version, the Chromium engine version, and what Ray is built on.
  @objc func showAbout(_ sender: Any?) {
    let center = NSMutableParagraphStyle()
    center.alignment = .center
    center.paragraphSpacing = 6
    let body: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.labelColor, .paragraphStyle: center,
    ]
    let credits = NSMutableAttributedString()
    func add(_ text: String, link: String? = nil) {
      var attributes = body
      if let link, let url = URL(string: link) { attributes[.link] = url }
      credits.append(NSAttributedString(string: text, attributes: attributes))
    }
    let engine = ArdiaCoreEngine.shared?.chromiumVersion ?? ""
    if !engine.isEmpty { add("Chromium Engine Version \(engine)\n") }
    add("Ray is made possible by the ")
    add("Chromium", link: "https://www.chromium.org/")
    add(" open source project, ")
    add("Helium", link: "https://github.com/imputnet/helium")
    add(" and ")
    add("Ardia", link: "https://github.com/mantrakp04/ardia")
    add("'s engine, as well as other ")
    add("open source software", link: "chrome://credits")
    add(".\n")
    add("Ray is free software under the GNU GPL v3. ")
    add("Source code", link: "https://github.com/shanuflash/ray")
    add(".")
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    NSApp.activate()
    NSApp.orderFrontStandardAboutPanel(options: [
      .applicationVersion: "Version \(version)",
      .version: "",
      .credits: credits,
    ])
  }
  @objc func focusAddress(_ sender: Any?) { current?.focusAddress() }
  @objc func copyURL(_ sender: Any?) { current?.copyURL() }
  @objc func newFolder(_ sender: Any?) { current?.newFolder() }
  @objc func importFromArc(_ sender: Any?) { current?.importFromArc() }
  @objc func showDownloads(_ sender: Any?) { current?.toggleDownloads() }
  @objc func toggleToolbar(_ sender: Any?) { current?.toggleToolbar() }
  @objc func toggleFullAddress(_ sender: Any?) { current?.toggleFullAddress() }
  @objc func toggleSiteControls(_ sender: Any?) { current?.toggleSiteControls() }
  @objc func find(_ sender: Any?) { current?.showFind() }
  @objc func findNext(_ sender: Any?) { current?.findAgain(forward: true) }
  @objc func findPrevious(_ sender: Any?) { current?.findAgain(forward: false) }
  @objc func closeTab(_ sender: Any?) {
    // ⌘W in the Settings window closes it, not a tab of the browser behind it.
    if SettingsWindowController.shared.isKey { SettingsWindowController.shared.close() } else { current?.closeActive() }
  }
  @objc func showSettings(_ sender: Any?) { SettingsWindowController.shared.show() }

  /// Settings › All Settings…: Chrome's own settings page, in a tab of the window you were in.
  func openChromeSettings() {
    guard let controller = current ?? openMainWindow(), let url = AddressInput.url(for: "ray://settings") else { return }
    controller.openToday(url, after: controller.activeEntry, foreground: true)
    if !launchedInBackground { controller.window.makeKeyAndOrderFront(nil) }
  }
  @objc func toggleSidebar(_ sender: Any?) { current?.toggleSidebar() }
  @objc func togglePin(_ sender: Any?) { current?.togglePin() }
  @objc func backToPinned(_ sender: Any?) { current?.backToPinned() }
  @objc func clearToday(_ sender: Any?) { current?.clearToday() }
  @objc func reload(_ sender: Any?) { current?.activeTab?.reload() }
  @objc func reloadIgnoringCache(_ sender: Any?) { current?.activeTab?.reloadIgnoringCache() }
  @objc func goBack(_ sender: Any?) { current?.activeTab?.goBack() }
  @objc func goForward(_ sender: Any?) { current?.activeTab?.goForward() }
  @objc func toggleDevTools(_ sender: Any?) { current?.toggleDevTools() }
  @objc func nextTab(_ sender: Any?) { current?.cycleTab(by: 1) }
  @objc func previousTab(_ sender: Any?) { current?.cycleTab(by: -1) }
  // ⌃Tab and ⌃⇧Tab both land on one of these (AppKit may match the ⌃Tab item for either), so the direction comes
  // from whether ⇧ was down in the key itself.
  @objc func nextTabWithControl(_ sender: Any?) { current?.cycleTabWithControl(by: shiftIsDown ? -1 : 1) }
  @objc func previousTabWithControl(_ sender: Any?) { current?.cycleTabWithControl(by: -1) }

  private var shiftIsDown: Bool {
    guard let event = NSApp.currentEvent, event.type == .keyDown else { return false }
    return event.modifierFlags.contains(.shift)
  }
  @objc func selectTab(_ sender: NSMenuItem) { current?.selectTab(number: sender.tag) }
}

extension AppController: NSMenuItemValidation {
  func validateMenuItem(_ item: NSMenuItem) -> Bool {
    switch item.action {
    case #selector(goBack(_:)): return current?.activeTab?.canGoBack ?? false
    case #selector(goForward(_:)): return current?.activeTab?.canGoForward ?? false
    case #selector(checkForUpdates(_:)): return Updater.shared.canCheck
    case #selector(toggleToolbar(_:)):
      item.state = current?.toolbarShown == true ? .on : .off
      return current != nil
    case #selector(toggleFullAddress(_:)):
      item.state = current?.fullAddressShown == true ? .on : .off
      return current?.toolbarShown == true
    case #selector(closeTab(_:)):
      // With no tab open, ⌘W closes the window, as in Chrome and Arc.
      item.title = current?.activeEntry == nil || SettingsWindowController.shared.isKey ? "Close Window" : "Close Tab"
      return current != nil || SettingsWindowController.shared.isKey
    case #selector(reload(_:)), #selector(reloadIgnoringCache(_:)), #selector(toggleDevTools(_:)):
      return current?.activeTab != nil
    default: return true
    }
  }
}
