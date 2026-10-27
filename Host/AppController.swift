import AppKit

final class AppController: NSObject, ArdiaCoreEngineDelegate {
  static let shared = AppController()

  private(set) var windows: [BrowserWindowController] = []
  private var quitting = false

  var current: BrowserWindowController? {
    windows.first { $0.window === NSApp.keyWindow } ?? windows.first { $0.window === NSApp.mainWindow } ?? windows.last
  }

  func engineDidStart() {
    guard let engine = ArdiaCoreEngine.shared else { return }
    NSLog("[lumen] engine started (Chromium %@)", engine.chromiumVersion)
    if let script = Bundle.main.url(forResource: "page_script", withExtension: "js"),
       let source = try? String(contentsOf: script, encoding: .utf8) {
      engine.pageScript = source
    }
    MainMenu.install(target: self)
    TestCommands.start()
    let controller = makeWindow(profile: engine.defaultProfile)
    controller.openTab(environment["LUMEN_START_URL"] ?? "https://example.com", foreground: true)
    controller.present(background: launchedInBackground)
  }

  func engineWillShutDown() {
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
    NSLog("[lumen] permission %@ dismissed (no prompt UI yet)", String(describing: request["type"] ?? "?"))
    ArdiaCoreEngine.resolvePermission(id, result: "dismiss", remember: false)
  }

  private func makeWindow(profile: ArdiaCoreProfile) -> BrowserWindowController {
    let controller = BrowserWindowController(profile: profile)
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
    ArdiaCoreEngine.shared?.quit()
  }

  @objc func newTab(_ sender: Any?) { current?.beginNewTab() }
  @objc func focusAddress(_ sender: Any?) { current?.focusAddress() }
  @objc func closeTab(_ sender: Any?) { current?.closeActiveTab() }
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
