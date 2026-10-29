import AppKit

/// A window's extensions: the list from the engine, the menu behind the address bar's puzzle button (Arc keeps
/// extensions there), action popups in a borderless window under that button, and Chrome's install prompt as a sheet.
final class ExtensionsController: NSObject, RayCoreTabDelegate {
  struct Item {
    let id: String
    let name: String
    let enabled: Bool
    /// The extension's own icon (from its manifest), for when its toolbar action hasn't set one.
    let icon: String?
  }

  private(set) var items: [Item] = []
  private let profile: RayCoreProfile
  private let coreWindow: RayCoreWindow
  var onChange: (() -> Void)?
  var openPage: ((String) -> Void)?

  private var popupWindow: ExtensionPopupWindow?
  private var popupTab: RayCoreTab?
  private weak var popupAnchor: NSView?
  private var popupMonitors: [Any] = []
  private var popupObservers: [NSObjectProtocol] = []
  private(set) var popupURL: String?
  private var prompt: (id: String, name: String, alert: NSAlert, add: NSButton)?

  init(profile: RayCoreProfile, coreWindow: RayCoreWindow) {
    self.profile = profile
    self.coreWindow = coreWindow
    super.init()
  }

  func refresh() {
    EngineCalls.call("ac_extensions_list", profile: profile) { [weak self] reply in
      guard let self, let list = reply?["extensions"] as? [[String: Any]] else { return }
      self.items = list.compactMap { info in
        guard let id = info["id"] as? String, let name = info["name"] as? String else { return nil }
        return Item(id: id, name: name, enabled: info["enabled"] as? Bool ?? false, icon: info["icon"] as? String)
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

  func menu(for tab: RayCoreTab?, anchor: NSView) -> NSMenu {
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
      entry.image = icon(for: item, state: state)
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

  /// The action's icon for this tab, else the extension's own, as Chrome's toolbar falls back (an action's icon
  /// loads late, and some extensions only ever set one from their background page).
  func icon(for item: Item, state: [String: Any]?) -> NSImage? {
    (state?["icon"] as? String).flatMap(Self.image(fromDataURL:)) ?? item.icon.flatMap(Self.image(fromDataURL:))
  }

  @objc private func openManage() { openPage?("chrome://extensions") }
  @objc private func openStore() { openPage?("https://chromewebstore.google.com/category/extensions") }

  @objc private func run(_ item: NSMenuItem) {
    guard let choice = item.representedObject as? RunChoice, let tab = choice.tab, !tab.closed,
          let anchor = choice.anchor else { return }
    run(choice.id, on: tab, anchor: anchor)
  }

  /// Runs an extension's toolbar action on a tab; an action with a popup opens it under the anchor.
  func run(_ id: String, on tab: RayCoreTab, anchor: NSView) {
    if tab.executeExtensionAction(id) == "popup" { showPopup(for: id, tab: tab, anchor: anchor) }
  }

  // MARK: Popup

  /// Opens the extension's own popup page (only a chrome-extension:// page of that extension) in a borderless child
  /// window under the anchor, as Chrome, Crest and Cra do. Not an NSPopover: on macOS 27 a popover composites its
  /// material with what it hosts, and an opaque view behind Chrome's render view occludes the renderer's remote
  /// layer, so the popup showed plain white however much its page drew.
  func showPopup(for id: String, tab: RayCoreTab, anchor: NSView) {
    let state = tab.actionStates(forExtensions: [id])[id] as? [String: Any]
    guard let url = state?["popup"] as? String, url.hasPrefix("chrome-extension://\(id)/"),
          let parent = anchor.window else { return }
    closePopup()
    guard let page = coreWindow.openExtensionView(url, profile: profile, kind: "popup") else { return }
    page.delegate = self
    // Chrome's base under an extension popup is white (a dark-scheme page paints its own dark canvas over it). It is
    // the page's own base, drawn by the renderer: nothing of Ray's sits behind the page.
    page.contentsBackgroundColor = .white
    popupTab = page
    popupURL = url
    popupAnchor = anchor
    let size = Self.clamp(page.preferredSize)
    let container = NSView(frame: NSRect(origin: .zero, size: size))
    container.wantsLayer = true
    container.layer?.backgroundColor = NSColor.clear.cgColor
    container.layer?.cornerRadius = 10
    container.layer?.cornerCurve = .continuous
    container.layer?.masksToBounds = true
    // A hairline over the page's edge (a layer's border draws above its sublayers), so a white popup still reads
    // against a white page.
    container.layer?.borderWidth = 0.5
    container.layer?.borderColor = NSColor.black.withAlphaComponent(0.15).cgColor
    page.view.frame = container.bounds
    page.view.autoresizingMask = [.width, .height]
    container.addSubview(page.view)
    let window = ExtensionPopupWindow(contentRect: container.frame, styleMask: .borderless, backing: .buffered,
                                      defer: false)
    window.isReleasedWhenClosed = false
    window.isOpaque = false
    window.backgroundColor = .clear
    window.hasShadow = true
    window.isMovable = false
    window.animationBehavior = .none
    window.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
    window.contentView = container
    window.onCancel = { [weak self] in self?.closePopup() }
    popupWindow = window
    place(window, size: size)
    // A child of the browser window: it moves and orders with it, and stays over it (at its level, or a raised
    // browser window would cover it).
    window.level = parent.level
    parent.addChildWindow(window, ordered: .above)
    if NSApp.isActive { window.makeKey() }
    page.noteShown(byHost: true)
    page.focus()
    watchForDismissal(parent: parent)
    onChange?()
  }

  func closePopup() {
    guard let window = popupWindow else { return }
    let page = popupTab
    popupWindow = nil
    popupTab = nil
    popupURL = nil
    popupAnchor = nil
    for monitor in popupMonitors { NSEvent.removeMonitor(monitor) }
    popupMonitors = []
    for observer in popupObservers { NotificationCenter.default.removeObserver(observer) }
    popupObservers = []
    window.parent?.removeChildWindow(window)
    window.orderOut(nil)
    window.contentView = NSView()
    window.close()
    if let page, !page.closed { page.close() }
    onChange?()
  }

  /// A click in any other of Ray's windows (the browser window too), Escape, Ray going to the background or the
  /// browser window closing ends the popup, as Chrome's ends when it loses focus. App-local monitors only.
  private func watchForDismissal(parent: NSWindow) {
    let click = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) {
      [weak self] event in
      if let self, let window = self.popupWindow, event.window !== window { self.closePopup() }
      return event
    }
    // The page gets keys first, and Ray's render view doesn't hand an unused Escape back: the popup takes Escape
    // while it is key.
    let escape = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard let self, let window = self.popupWindow, event.window === window, event.keyCode == 53,
            event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else { return event }
      self.closePopup()
      return nil
    }
    popupMonitors = [click, escape].compactMap { $0 }
    let center = NotificationCenter.default
    popupObservers = [
      center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) {
        [weak self] _ in self?.closePopup()
      },
      center.addObserver(forName: NSWindow.willCloseNotification, object: parent, queue: .main) {
        [weak self] _ in self?.closePopup()
      },
    ]
  }

  /// Under the anchor and centred on it, inside the screen's visible area; above the anchor when there's no room
  /// below. The top edge stays put as the page resizes itself.
  private func place(_ window: NSWindow, size: NSSize) {
    guard let anchor = popupAnchor, let parent = anchor.window else { return }
    let rect = parent.convertToScreen(anchor.convert(anchor.bounds, to: nil))
    let visible = (parent.screen ?? NSScreen.main)?.visibleFrame.insetBy(dx: 8, dy: 8) ?? .infinite
    var frame = NSRect(x: (rect.midX - size.width / 2).rounded(), y: rect.minY - 4 - size.height,
                       width: size.width, height: size.height)
    if frame.minY < visible.minY, rect.maxY + 4 + size.height <= visible.maxY { frame.origin.y = rect.maxY + 4 }
    frame.origin.x = max(min(frame.minX, visible.maxX - size.width), visible.minX)
    frame.origin.y = max(frame.minY, visible.minY)
    window.setFrame(frame, display: true)
  }

  func tab(_ tab: RayCoreTab, preferredSizeDidChange size: NSSize) {
    guard tab === popupTab, let window = popupWindow else { return }
    place(window, size: Self.clamp(size))
  }

  func tabWillClose(_ tab: RayCoreTab) {
    if tab === popupTab { closePopup() }
  }

  /// For the state log: the popup's window as it is (frame from the main screen's top left, as `screencapture -R`
  /// takes it), and whether Chrome's content layer for its page has arrived under the render view.
  var popupViewState: [String: Any]? {
    guard let window = popupWindow, let page = popupTab else { return nil }
    let top = NSScreen.screens.first?.frame.maxY ?? 0
    let frame = window.frame
    let render = PageFrameWatch.renderView(in: page.view)
    let contentLayers = render?.layer?.sublayers?.reduce(0) { $0 + ($1.sublayers?.count ?? 0) } ?? 0
    return [
      "frame": String(format: "%.0f,%.0f,%.0f,%.0f", frame.minX, top - frame.maxY, frame.width, frame.height),
      "visible": window.isVisible, "onScreen": window.occlusionState.contains(.visible), "child": window.parent != nil,
      "opaque": window.isOpaque, "pageHidden": page.view.isHiddenOrHasHiddenAncestor, "renderView": render != nil,
      "contentLayers": contentLayers, "behind": window.contentView?.subviews.count ?? 0,
    ]
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
      RayCoreEngine.resolveExtensionInstallPrompt(id, accepted: false)
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
      RayCoreEngine.resolveExtensionInstallPrompt(id, accepted: response == .alertSecondButtonReturn)
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

  /// An image from a base64 `data:image/…` URL (the engine's icons; manifests may use any image type).
  static func image(fromDataURL url: String) -> NSImage? {
    guard url.hasPrefix("data:image/"), let comma = url.firstIndex(of: ","),
          url[..<comma].hasSuffix(";base64"),
          let data = Data(base64Encoded: String(url[url.index(after: comma)...])) else { return nil }
    return NSImage(data: data)
  }
}

/// An extension popup's window: borderless, never main, key so the popup's own fields take typing.
private final class ExtensionPopupWindow: NSWindow {
  var onCancel: (() -> Void)?
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
  override func cancelOperation(_ sender: Any?) { onCancel?() }
}

private final class RunChoice {
  let id: String
  weak var tab: RayCoreTab?
  weak var anchor: NSView?

  init(id: String, tab: RayCoreTab?, anchor: NSView) {
    self.id = id
    self.tab = tab
    self.anchor = anchor
  }
}
