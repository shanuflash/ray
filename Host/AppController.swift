import AppKit

final class AppController: NSObject, RayCoreEngineDelegate, NSApplicationDelegate {
  static let shared = AppController()

  private(set) var windows: [BrowserWindowController] = []
  private(set) var quitting = false
  /// The launch's first normal window has opened: Settings › General › When Ray quits applies to that one only.
  private var sessionStarted = false

  /// The window used last: the key window, else the one most recently shown or focused (Ray in the background has
  /// no key window, and menu commands still belong to the window you were in).
  var current: BrowserWindowController? {
    windows.first { $0.window === NSApp.keyWindow } ?? lastFocused.flatMap { last in windows.first { $0 === last } }
      ?? windows.first { $0.window === NSApp.mainWindow } ?? windows.last
  }

  private weak var lastFocused: BrowserWindowController?

  func noteFocused(_ controller: BrowserWindowController) { lastFocused = controller }

  func engineDidStart() {
    guard let engine = RayCoreEngine.shared else { return }
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
    SearchEngines.install()
    MainMenu.install(target: self)
    installReservedKeyRouting()
    TestCommands.start()
    Updater.shared.start()
    // The first window once AppKit's launch is over, so a link or file that launched Ray (its launch's open event
    // comes in after the engine starts) opens in place of the start page, with the session behind it.
    LinksFromApps.whenLaunched { [self] links in
      let main = openMainWindow(startURL: TestEnvironment["RAY_START_URL"], forLinks: !links.isEmpty)
      if let main, !links.isEmpty { openLinks(links, in: main) }
      // A new data dir's first window welcomes you (once; never in a test instance unless a check asks).
      if OnboardingView.showsAtLaunch { main?.showOnboarding(.firstRun) }
    }
  }

  /// The normal window, from Sidebar.json; Ray keeps one, since there's one sidebar session. `forLinks`: links from
  /// other apps are about to open in it, so a window opened for them skips its start page (a new tab, or
  /// RAY_START_URL), as Chrome closes its New Tab page for them.
  @discardableResult
  func openMainWindow(startURL: String? = nil, forLinks: Bool = false) -> BrowserWindowController? {
    if let open = windows.first(where: { !$0.isPrivate }) {
      if !launchedInBackground { open.window.makeKeyAndOrderFront(nil) }
      return open
    }
    guard let engine = RayCoreEngine.shared else { return nil }
    let controller = makeWindow(profile: engine.defaultProfile)
    // When Ray quits › Start fresh: the launch begins without last time's Today tabs (closing and reopening the
    // window later isn't a quit, so ⌘N keeps them).
    let fresh = !sessionStarted && RaySettings.shared[.onQuit] == "fresh"
    sessionStarted = true
    if fresh { controller.startFresh() }
    controller.present(background: launchedInBackground)
    if !forLinks { controller.restore(startURL: startURL, fresh: fresh) }
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
    CloseWarnings.quitCancelled()
    windows.forEach { $0.resumeAfterCancelledQuit() }
  }

  func engineWillShutDown() {
    if !quitting { windows.forEach { $0.prepareForQuit() } }
    quitting = true
    RaySettings.shared.flush()
  }

  func engineWindowForNewBrowser(of profile: RayCoreProfile, type: String) -> RayCoreWindow? {
    guard type == "normal" || type == "popup" else { return nil }
    if let window = windows.first(where: { $0.profile === profile }) { return window.coreWindow }
    // A link from another app while no window is open brings the normal window back for it.
    if !profile.offTheRecord, profile === RayCoreEngine.shared?.defaultProfile { return openMainWindow()?.coreWindow }
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

  func engine(_ engine: RayCoreEngine, permissionRequest request: [String: Any], tab: RayCoreTab) {
    guard let id = request["id"] as? String else { return }
    guard let controller = windows.first(where: { $0.owns(tab) }) else {
      RayCoreEngine.resolvePermission(id, result: "dismiss", remember: false)
      return
    }
    controller.permissions.add(request, tab: tab)
  }

  func engine(_ engine: RayCoreEngine, permissionRequestDismissed requestId: String) {
    windows.forEach { $0.permissions.dismissed(requestId) }
  }

  func engine(_ engine: RayCoreEngine, extensionInstallPrompt prompt: [String: Any], tab: RayCoreTab?) {
    let controller = tab.flatMap { tab in windows.first { $0.owns(tab) } } ?? current
    guard let controller else {
      if let id = prompt["requestId"] as? String { RayCoreEngine.resolveExtensionInstallPrompt(id, accepted: false) }
      return
    }
    controller.extensions.showInstallPrompt(prompt, in: controller.window)
  }

  func engine(_ engine: RayCoreEngine, extensionActionPopup popup: [String: Any], tab: RayCoreTab) -> Bool {
    guard let id = popup["extensionId"] as? String, let controller = windows.first(where: { $0.owns(tab) }) else {
      return false
    }
    controller.extensions.showPopup(for: id, tab: tab, anchor: controller.extensionsAnchor)
    return true
  }

  /// File › New Private Window (⇧⌘N): a window on the profile's off-the-record side. Nothing it does is saved, and
  /// its cookies and history go when the last private window closes.
  @objc func newPrivateWindow(_ sender: Any?) {
    guard let engine = RayCoreEngine.shared else { return }
    let main = current.map { $0.mainProfile } ?? engine.defaultProfile
    engine.offTheRecordProfile(for: main) { [weak self] profile, _ in
      guard let self, let profile else { return }
      let controller = self.makeWindow(profile: profile, main: main)
      controller.present(background: launchedInBackground)
      controller.restore(startURL: nil)
    }
  }

  private func makeWindow(profile: RayCoreProfile, main: RayCoreProfile? = nil) -> BrowserWindowController {
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
    // Settings › General › Warn before quitting with ⌘Q: the warning comes back here once you choose Quit.
    guard CloseWarnings.allowsQuit(then: { [weak self] in self?.quit(sender) }) else { return }
    quitting = true
    windows.forEach { $0.prepareForQuit() }
    RaySettings.shared.flush()
    RayCoreEngine.shared?.quit()
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
    let engine = RayCoreEngine.shared?.chromiumVersion ?? ""
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
  /// The sidebar-only Arc import (no menu item since Import from Browser…; its check still drives it).
  @objc func importFromArc(_ sender: Any?) { current?.importFromArc() }
  /// File › Import from Browser…: the onboarding's import steps, over the normal window (never a private one).
  @objc func importFromBrowser(_ sender: Any?) {
    let window = current.flatMap { $0.isPrivate ? nil : $0 } ?? openMainWindow()
    if let window, !launchedInBackground { window.window.makeKeyAndOrderFront(nil) }
    window?.showOnboarding(.importOnly)
  }
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
  @objc func reload(_ sender: Any?) { current?.activeTab?.userReload() }
  @objc func reloadIgnoringCache(_ sender: Any?) { current?.activeTab?.userReloadIgnoringCache() }
  @objc func goBack(_ sender: Any?) { current?.activeTab?.userGoBack() }
  @objc func goForward(_ sender: Any?) { current?.activeTab?.userGoForward() }
  @objc func toggleDevTools(_ sender: Any?) { current?.toggleDevTools() }
  @objc func printPage(_ sender: Any?) { current?.runChromeCommand(.print) }
  @objc func printWithSystemDialog(_ sender: Any?) { current?.runChromeCommand(.systemPrint) }
  @objc func savePage(_ sender: Any?) { current?.runChromeCommand(.savePage) }
  @objc func viewSource(_ sender: Any?) { current?.viewSource() }
  @objc func zoomIn(_ sender: Any?) { _ = current?.zoomCommand("in") }
  @objc func zoomOut(_ sender: Any?) { _ = current?.zoomCommand("out") }
  @objc func actualSize(_ sender: Any?) { _ = current?.zoomCommand("reset") }
  @objc func showHistory(_ sender: Any?) { openPage("ray://history") }
  @objc func clearBrowsingData(_ sender: Any?) { openPage("ray://settings/clearBrowserData") }
  @objc func taskManager(_ sender: Any?) { current?.runChromeCommand(.taskManager) }

  /// One of Chrome's own pages, in the window you were in: switched to when it's already open, else a new tab.
  func openPage(_ address: String) {
    guard let controller = current ?? openMainWindow(), let url = AddressInput.url(for: address) else { return }
    controller.showPage(url)
    if !launchedInBackground { controller.window.makeKeyAndOrderFront(nil) }
  }
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

  // MARK: Welcome again

  /// Ray › Show Welcome Again (⌥ over Settings…): the first run from its welcome, for anyone who never saw it (an
  /// existing Settings.json counts as onboarded). Over the frontmost normal window, never a private one; its import
  /// writes into this profile, as File › Import from Browser… does.
  @objc func showWelcomeAgain(_ sender: Any?) {
    let front = NSApp.orderedWindows.lazy.compactMap { shown in self.windows.first { $0.window === shown && !$0.isPrivate } }.first
    let window = front ?? openMainWindow()
    if let window, !launchedInBackground { window.window.makeKeyAndOrderFront(nil) }
    window?.showOnboarding(.firstRun)
  }
}

extension AppController: NSMenuItemValidation {
  // MARK: Menu validation

  /// The menu's, and the command bar's too: the bar offers a command only while this enables it (BarActions).
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
    case #selector(reload(_:)), #selector(reloadIgnoringCache(_:)), #selector(toggleDevTools(_:)), #selector(printPage(_:)),
         #selector(printWithSystemDialog(_:)), #selector(savePage(_:)), #selector(zoomIn(_:)), #selector(zoomOut(_:)),
         #selector(actualSize(_:)):
      return current?.activeTab != nil
    case #selector(viewSource(_:)):
      return current?.viewSourceURL != nil
    case #selector(taskManager(_:)):
      return current != nil
    case #selector(togglePin(_:)):
      item.title = current?.activeEntry.map { $0.kind != .today } == true ? "Unpin Tab" : "Pin Tab"
      return current?.activeEntry != nil
    case #selector(backToPinned(_:)):
      return current?.activeEntry?.isAwayFromPinned == true
    case #selector(clearToday(_:)):
      return current?.state.today.isEmpty == false
    case #selector(copyURL(_:)):
      return current?.activeEntry.map { !$0.currentURL.isEmpty } ?? false
    case #selector(find(_:)), #selector(toggleSiteControls(_:)):
      return current?.activeTab != nil
    default: return true
    }
  }
}
