import AppKit

/// A window's extensions: the list from the engine, the menu behind the address bar's puzzle button (Arc keeps
/// extensions there), action popups in a popover under that button, and Chrome's install prompt as a sheet.
final class ExtensionsController: NSObject, NSPopoverDelegate, ArdiaCoreTabDelegate {
  struct Item {
    let id: String
    let name: String
    let enabled: Bool
  }

  private(set) var items: [Item] = []
  private let profile: ArdiaCoreProfile
  private let coreWindow: ArdiaCoreWindow
  var onChange: (() -> Void)?
  var openPage: ((String) -> Void)?

  private var popover: NSPopover?
  private var popupTab: ArdiaCoreTab?
  private(set) var popupURL: String?
  private var prompt: (id: String, name: String, alert: NSAlert, add: NSButton)?

  init(profile: ArdiaCoreProfile, coreWindow: ArdiaCoreWindow) {
    self.profile = profile
    self.coreWindow = coreWindow
    super.init()
  }

  func refresh() {
    EngineCalls.call("ac_extensions_list", profile: profile) { [weak self] reply in
      guard let self, let list = reply?["extensions"] as? [[String: Any]] else { return }
      self.items = list.compactMap { info in
        guard let id = info["id"] as? String, let name = info["name"] as? String else { return nil }
        return Item(id: id, name: name, enabled: info["enabled"] as? Bool ?? false)
      }
      self.onChange?()
    }
  }

  /// Installs an unpacked extension from a folder (Chrome's "Load unpacked"); used by tests.
  func installUnpacked(_ path: String, completion: @escaping (String?) -> Void) {
    EngineCalls.call("ac_extensions_install", profile: profile, args: ["path": path]) { [weak self] reply in
      self?.refresh()
      completion(reply?["id"] as? String)
    }
  }

  // MARK: Menu

  func menu(for tab: ArdiaCoreTab?, anchor: NSView) -> NSMenu {
    let menu = NSMenu()
    let enabled = items.filter(\.enabled)
    let states = tab?.actionStates(forExtensions: enabled.map(\.id)) ?? [:]
    for item in enabled {
      let state = states[item.id] as? [String: Any]
      var title = item.name
      if let badge = state?["badgeText"] as? String, !badge.isEmpty { title += "  \(badge)" }
      let entry = NSMenuItem(title: title, action: #selector(run(_:)), keyEquivalent: "")
      entry.target = self
      entry.representedObject = RunChoice(id: item.id, tab: tab, anchor: anchor)
      entry.image = (state?["icon"] as? String).flatMap(Self.image(fromDataURL:))
        ?? NSImage(systemSymbolName: "puzzlepiece.extension", accessibilityDescription: nil)
      entry.image?.size = NSSize(width: 16, height: 16)
      entry.isEnabled = tab != nil && (state?["enabled"] as? Bool ?? true)
      menu.addItem(entry)
    }
    if !enabled.isEmpty { menu.addItem(.separator()) }
    let manage = NSMenuItem(title: "Manage Extensions…", action: #selector(openManage), keyEquivalent: "")
    manage.target = self
    menu.addItem(manage)
    let store = NSMenuItem(title: "Get Extensions…", action: #selector(openStore), keyEquivalent: "")
    store.target = self
    menu.addItem(store)
    return menu
  }

  @objc private func openManage() { openPage?("chrome://extensions") }
  @objc private func openStore() { openPage?("https://chromewebstore.google.com/category/extensions") }

  @objc private func run(_ item: NSMenuItem) {
    guard let choice = item.representedObject as? RunChoice, let tab = choice.tab, !tab.closed,
          let anchor = choice.anchor else { return }
    run(choice.id, on: tab, anchor: anchor)
  }

  /// Runs an extension's toolbar action on a tab; an action with a popup opens it under the anchor.
  func run(_ id: String, on tab: ArdiaCoreTab, anchor: NSView) {
    if tab.executeExtensionAction(id) == "popup" { showPopup(for: id, tab: tab, anchor: anchor) }
  }

  // MARK: Popup

  /// Opens the extension's own popup page (only a chrome-extension:// page of that extension) in a popover.
  func showPopup(for id: String, tab: ArdiaCoreTab, anchor: NSView) {
    let state = tab.actionStates(forExtensions: [id])[id] as? [String: Any]
    guard let url = state?["popup"] as? String, url.hasPrefix("chrome-extension://\(id)/"),
          anchor.window != nil else { return }
    closePopup()
    guard let page = coreWindow.openExtensionView(url, profile: profile, kind: "popup") else { return }
    page.delegate = self
    popupTab = page
    popupURL = url
    let controller = NSViewController()
    let container = NSView(frame: NSRect(origin: .zero, size: Self.clamp(page.preferredSize)))
    page.view.frame = container.bounds
    page.view.autoresizingMask = [.width, .height]
    container.addSubview(page.view)
    controller.view = container
    let popover = NSPopover()
    popover.contentViewController = controller
    popover.contentSize = container.frame.size
    popover.behavior = .transient
    popover.animates = false
    popover.delegate = self
    self.popover = popover
    popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
    page.noteShown(byHost: true)
    page.focus()
    onChange?()
  }

  func closePopup() {
    popover?.close()
  }

  func popoverDidClose(_ notification: Notification) {
    let page = popupTab
    popupTab = nil
    popupURL = nil
    popover = nil
    if let page, !page.closed { page.close() }
    onChange?()
  }

  func tab(_ tab: ArdiaCoreTab, preferredSizeDidChange size: NSSize) {
    guard tab === popupTab else { return }
    popover?.contentSize = Self.clamp(size)
  }

  func tabWillClose(_ tab: ArdiaCoreTab) {
    if tab === popupTab { popover?.close() }
  }

  /// Chrome's popup limits: at least 25 pt, at most 800 × 600.
  private static func clamp(_ size: NSSize) -> NSSize {
    NSSize(width: min(max(size.width, 25), 800), height: min(max(size.height, 25), 600))
  }

  // MARK: Install prompt

  /// Chrome's "Add extension?" as a sheet. Following the security checklist: Return and Escape cancel, the Add
  /// button ignores clicks for its first half second, and the prompt names the extension, version and ID.
  func showInstallPrompt(_ request: [String: Any], in window: NSWindow?) {
    guard let id = request["requestId"] as? String else { return }
    guard let window, prompt == nil else {
      ArdiaCoreEngine.resolveExtensionInstallPrompt(id, accepted: false)
      return
    }
    let name = Self.plain(request["name"] as? String ?? "this extension", limit: 60)
    let alert = NSAlert()
    alert.messageText = "Add “\(name)”?"
    let permissions = (request["permissions"] as? [String] ?? []).map { "• " + Self.plain($0, limit: 160) }
    var details = permissions.isEmpty
      ? "It doesn't ask for any special permissions."
      : "It will be able to:\n" + permissions.prefix(12).joined(separator: "\n")
    let version = Self.plain(request["version"] as? String ?? "", limit: 40)
    let extensionID = Self.plain(request["id"] as? String ?? "", limit: 40)
    details += "\n\nVersion \(version) · ID \(extensionID)"
    alert.informativeText = details
    if let icon = (request["icon"] as? String).flatMap(Self.image(fromDataURL:)) { alert.icon = icon }
    alert.addButton(withTitle: "Cancel")
    let add = alert.addButton(withTitle: "Add Extension")
    add.keyEquivalent = ""
    add.isEnabled = false
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { add.isEnabled = true }
    prompt = (id, name, alert, add)
    onChange?()
    alert.beginSheetModal(for: window) { [weak self] response in
      guard let self else { return }
      self.prompt = nil
      ArdiaCoreEngine.resolveExtensionInstallPrompt(id, accepted: response == .alertSecondButtonReturn)
      self.refresh()
      self.onChange?()
    }
  }

  /// For tests: the open prompt, and answering it the way a click would.
  var promptState: [String: Any]? {
    prompt.map { ["id": $0.id, "name": $0.name, "addEnabled": $0.add.isEnabled] }
  }

  func answerPrompt(accept: Bool) -> Bool {
    guard let prompt else { return false }
    let button = accept ? prompt.add : prompt.alert.buttons[0]
    guard button.isEnabled else { return false }
    button.performClick(nil)
    return true
  }

  // MARK: Helpers

  private static func plain(_ text: String, limit: Int) -> String {
    let single = text.components(separatedBy: .newlines).joined(separator: " ")
    return single.count > limit ? String(single.prefix(limit)) + "…" : single
  }

  static func image(fromDataURL url: String) -> NSImage? {
    guard url.hasPrefix("data:image/png;base64,"),
          let data = Data(base64Encoded: String(url.dropFirst("data:image/png;base64,".count))) else { return nil }
    return NSImage(data: data)
  }
}

private final class RunChoice {
  let id: String
  weak var tab: ArdiaCoreTab?
  weak var anchor: NSView?

  init(id: String, tab: ArdiaCoreTab?, anchor: NSView) {
    self.id = id
    self.tab = tab
    self.anchor = anchor
  }
}
