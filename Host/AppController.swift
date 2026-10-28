import AppKit

final class AppController: NSObject, ArdiaCoreEngineDelegate, NSApplicationDelegate {
  static let shared = AppController()

  private(set) var windows: [BrowserWindowController] = []
  private var quitting = false

  var current: BrowserWindowController? {
    windows.first { $0.window === NSApp.keyWindow } ?? windows.first { $0.window === NSApp.mainWindow } ?? windows.last
  }

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
    TestCommands.start()
    let controller = makeWindow(profile: engine.defaultProfile)
    controller.present(background: launchedInBackground)
    controller.restore(startURL: TestEnvironment["RAY_START_URL"])
    controller.searches.warm()
  }

  func engineQuitCancelled() {
    quitting = false
    windows.forEach { $0.resumeAfterCancelledQuit() }
  }

  func engineWillShutDown() {
    if !quitting { windows.forEach { $0.prepareForQuit() } }
    quitting = true
  }

  func engineWindowForNewBrowser(of profile: ArdiaCoreProfile, type: String) -> ArdiaCoreWindow? {
    guard type == "normal" || type == "popup" else { return nil }
    return (windows.first { $0.profile === profile } ?? current)?.coreWindow
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

  private func makeWindow(profile: ArdiaCoreProfile) -> BrowserWindowController {
    let controller = BrowserWindowController(
      profile: profile, store: SidebarStore(directory: (dataDirectory as NSString).deletingLastPathComponent))
    controller.onClose = { [weak self, weak controller] in
      guard let self, let controller else { return }
      self.windows.removeAll { $0 === controller }
      if self.windows.isEmpty { self.quit(nil) }
    }
    windows.append(controller)
    return controller
  }

  @objc func quit(_ sender: Any?) {
    guard !quitting else { return }
    quitting = true
    windows.forEach { $0.prepareForQuit() }
    ArdiaCoreEngine.shared?.quit()
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    quitting = true
    windows.forEach { $0.prepareForQuit() }
    return .terminateNow
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

  @objc func newTab(_ sender: Any?) { current?.beginNewTab() }

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
  @objc func showDownloads(_ sender: Any?) { current?.showDownloads() }
  @objc func find(_ sender: Any?) { current?.showFind() }
  @objc func findNext(_ sender: Any?) { current?.findAgain(forward: true) }
  @objc func findPrevious(_ sender: Any?) { current?.findAgain(forward: false) }
  @objc func closeTab(_ sender: Any?) { current?.closeActive() }
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
  @objc func selectTab(_ sender: NSMenuItem) { current?.selectTab(number: sender.tag) }
}

extension AppController: NSMenuItemValidation {
  func validateMenuItem(_ item: NSMenuItem) -> Bool {
    switch item.action {
    case #selector(goBack(_:)): return current?.activeTab?.canGoBack ?? false
    case #selector(goForward(_:)): return current?.activeTab?.canGoForward ?? false
    case #selector(closeTab(_:)), #selector(reload(_:)), #selector(reloadIgnoringCache(_:)), #selector(toggleDevTools(_:)):
      return current?.activeTab != nil
    default: return true
    }
  }
}
