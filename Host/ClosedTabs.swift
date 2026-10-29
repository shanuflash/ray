import AppKit

/// A tab the user closed, kept so ⇧⌘T and History › Recently Closed can bring it back where it was: the same place
/// in Today, or the pinned row (in its folder) or favorite it was the page of.
struct ClosedTab {
  let id = UUID()
  /// The sidebar entry it was. A pinned or favorite entry stays in the sidebar (closing only unloads it), so
  /// reopening brings that same row back to life; a Today entry is gone and comes back as a new one.
  let entryID: UUID
  let kind: SidebarEntry.Kind
  /// Its place in its section (today, pinned or favorites) when it closed.
  let index: Int
  let parentID: UUID?
  let pinnedURL: String?
  let url: String
  let title: String
  /// The tab's own name (Rename…), shown in place of its title and given back when a Today tab comes back.
  var customTitle: String?
  let favicon: NSImage?
  /// The key the engine's tab restore service holds the tab's back/forward list under (`ac_tab_restore_take`). Nil
  /// in a private window: the engine keeps nothing off the record, so those come back on their last page only.
  let restoreKey: String?

  var host: String {
    let host = URLComponents(string: url)?.host ?? ""
    return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
  }

  var menuTitle: String {
    let text = customTitle ?? (title.isEmpty ? AddressInput.display(for: url) : title)
    return text.count > 60 ? String(text.prefix(59)) + "…" : text
  }
}

/// The tabs closed in a window, newest last. The normal window's list is app-wide (`main`), so it outlives the window
/// (⌘N brings it back with its sidebar, and ⇧⌘T keeps walking back). Each private window has its own, in memory only,
/// and it goes with the window. Nothing here is ever written to disk.
final class ClosedTabs {
  static let main = ClosedTabs()
  /// As many as Chrome's tab restore service keeps (kMaxEntries), so older ones can still find their history.
  static let limit = 25

  private(set) var items: [ClosedTab] = []
  private var watchingHistory = false

  var isEmpty: Bool { items.isEmpty }

  func add(_ tab: ClosedTab) {
    items.append(tab)
    if items.count > Self.limit { items.removeFirst(items.count - Self.limit) }
  }

  /// The newest, or the one with this id; it leaves the list.
  func take(_ id: UUID? = nil) -> ClosedTab? {
    guard let at = id.map({ id in items.lastIndex { $0.id == id } }) ?? items.indices.last else { return nil }
    return items.remove(at: at)
  }

  /// A pinned or favorite row opened again by hand: its closed page is no longer one to bring back.
  func forget(entry id: UUID) { items.removeAll { $0.entryID == id } }

  /// Deleting history (Clear Browsing Data, or pages in History) takes the closed tabs with it, as it empties Chrome's
  /// own tab restore service: all of them for a time range, else the deleted pages. Normal profile only.
  func watchHistory(profile: RayCoreProfile) {
    guard !watchingHistory, !profile.offTheRecord else { return }
    watchingHistory = true
    EngineCalls.call("ac_history_watch", profile: profile) { _ in }
    EngineEvents.on("history.changed") { [weak self] payload in
      guard let self else { return }
      for change in payload["changes"] as? [[String: Any]] ?? [] where change["kind"] as? String == "deleted" {
        if change["all"] as? Bool != false {
          self.items.removeAll()
        } else {
          let urls = Set(change["urls"] as? [String] ?? [])
          self.items.removeAll { urls.contains($0.url) }
        }
      }
    }
  }
}

/// History › Reopen Closed Tab (⇧⌘T) and History › Recently Closed, for the window you're in.
final class ClosedTabsMenu: NSObject, NSMenuDelegate, NSMenuItemValidation {
  static let shared = ClosedTabsMenu()
  /// As many as Chrome's History menu lists.
  static let shown = 10

  private var current: BrowserWindowController? { AppController.shared.current }

  /// The Recently Closed item, its submenu filled each time it opens.
  func recentlyClosedItem() -> NSMenuItem {
    let menu = NSMenu(title: "Recently Closed")
    menu.delegate = self
    let item = NSMenuItem(title: "Recently Closed", action: nil, keyEquivalent: "")
    item.submenu = menu
    return item
  }

  /// ⇧⌘T: the last tab closed in this window, back where it was. With no window open it brings the normal window back,
  /// which still has its tabs (Chrome reopens the window you closed).
  @objc func reopenClosedTab(_ sender: Any?) {
    guard let controller = current else {
      AppController.shared.newWindow(nil)
      return
    }
    controller.reopenClosedTab()
  }

  @objc func reopenRecentlyClosed(_ sender: NSMenuItem) {
    guard let id = sender.representedObject as? UUID else { return }
    if current == nil { AppController.shared.newWindow(nil) }
    current?.reopenClosedTab(id)
  }

  private var list: ClosedTabs { current?.closedTabs ?? ClosedTabs.main }

  func validateMenuItem(_ item: NSMenuItem) -> Bool {
    switch item.action {
    case #selector(reopenClosedTab(_:)): return current == nil || !list.isEmpty
    default: return true
    }
  }

  func menuNeedsUpdate(_ menu: NSMenu) { fill(menu, from: list) }

  private func fill(_ menu: NSMenu, from list: ClosedTabs) {
    menu.removeAllItems()
    let recent = list.items.reversed().prefix(Self.shown)
    if recent.isEmpty {
      let none = NSMenuItem(title: "No Recently Closed Tabs", action: nil, keyEquivalent: "")
      none.isEnabled = false
      menu.addItem(none)
      return
    }
    for tab in recent {
      let item = NSMenuItem(title: tab.menuTitle, action: #selector(reopenRecentlyClosed(_:)), keyEquivalent: "")
      item.target = self
      item.representedObject = tab.id
      // The host only, never the full address (it can carry what the page put in its path or query).
      item.toolTip = tab.host.isEmpty ? nil : tab.host
      item.image = tab.favicon.map(Self.menuIcon)
      menu.addItem(item)
    }
  }

  private static func menuIcon(_ image: NSImage) -> NSImage {
    let size = NSSize(width: 16, height: 16)
    return NSImage(size: size, flipped: false) { rect in
      image.draw(in: rect)
      return true
    }
  }

  /// For tests: clicks the n-th item of History › Recently Closed (0 is the newest), filled as opening it fills it.
  func pressRecentlyClosed(_ index: Int) -> Bool {
    guard let history = NSApp.mainMenu?.item(withTitle: "History")?.submenu,
          let menu = history.item(withTitle: "Recently Closed")?.submenu else { return false }
    menuNeedsUpdate(menu)
    guard menu.items.indices.contains(index), menu.items[index].action != nil else { return false }
    menu.performActionForItem(at: index)
    return true
  }

  /// For the state log: what the Recently Closed submenu would list for this window, and whether ⇧⌘T is on.
  func debug(for controller: BrowserWindowController) -> [String: Any] {
    let menu = NSMenu()
    fill(menu, from: controller.closedTabs)
    let probe = NSMenuItem(title: "", action: #selector(reopenClosedTab(_:)), keyEquivalent: "")
    return [
      "reopenEnabled": controller === current ? validateMenuItem(probe) : !controller.closedTabs.isEmpty,
      "items": menu.items.filter { $0.action != nil }.map { item -> [String: Any] in
        ["title": item.title, "tooltip": item.toolTip ?? "", "icon": item.image != nil]
      },
      "kinds": controller.closedTabs.items.reversed().map { "\($0.kind.rawValue):\($0.index)" },
    ]
  }
}

// MARK: Undo close tab

/// Settings › Reopen closed tabs with ⌘Z (off; Arc's ⌘Z, and Ardia's "⌘Z reopens closed tabs"): while it's on, Edit ›
/// Undo's target is this. Outside text it reopens the last closed tab as ⇧⌘T does (again: the one closed before);
/// with a text field of Ray's or an editable element of the page focused it is Undo, sent on down the responder chain
/// as if the item had no target. Keys reach the page first (CLAUDE.md, Key routing), so a page that takes ⌘Z for its
/// own undo (an editor calling preventDefault) never gets here; Chrome's renderer leaves ⌘Z to the menu on the Mac.
final class UndoCloseTab: NSObject, NSMenuItemValidation {
  static let shared = UndoCloseTab()
  static let undo = Selector(("undo:"))
  private var observation: SettingsObservation?

  func install() {
    apply()
    observation = RaySettings.shared.observe(.undoReopensClosedTab) { [weak self] _ in self?.apply() }
  }

  /// Edit › Undo points here while the setting is on, and at the responder chain (no target, AppKit's own) while off.
  private func apply() {
    guard let item = MainMenu.item(for: Self.undo) else { return }
    item.target = RaySettings.shared[.undoReopensClosedTab] ? self : nil
    item.title = "Undo"
  }

  /// The window ⌘Z is for: the key window, or with Ray in the background (no key window) the browser window used last.
  private var window: NSWindow? { NSApp.keyWindow ?? AppController.shared.current?.window }

  /// Whether ⌘Z reopens a tab now: the setting is on, the window is a browser window and what has its focus edits no
  /// text.
  var reopens: Bool {
    guard RaySettings.shared[.undoReopensClosedTab], let window,
          AppController.shared.windows.contains(where: { $0.window === window }) else { return false }
    return !Self.editsText(window.firstResponder)
  }

  /// What takes undo: in the window's responder chain (the page, else the window's own undo manager), as AppKit finds
  /// it for an item with no target.
  private var undoTarget: NSResponder? {
    var responder = window?.firstResponder
    while let current = responder {
      if current.responds(to: Self.undo) { return current }
      responder = current.nextResponder
    }
    return nil
  }

  /// A text field or view of Ray's (its field editor), or the page with an editable element focused: Chrome's page
  /// view reports the focused element's text input type (`textInputType`, 0 for none; text, password, search,
  /// contenteditable and the rest are not 0), the same thing Ardia reads.
  static func editsText(_ responder: NSResponder?) -> Bool {
    guard let responder else { return false }
    if responder is NSText { return true }
    let selector = NSSelectorFromString("textInputType")
    guard let page = NSClassFromString("RenderWidgetHostViewCocoa"), responder.isKind(of: page),
          responder.responds(to: selector) else { return false }
    typealias Getter = @convention(c) (AnyObject, Selector) -> Int32
    return unsafeBitCast(responder.method(for: selector), to: Getter.self)(responder, selector) != 0
  }

  @objc(undo:) func undoOrReopen(_ sender: Any?) {
    if reopens {
      ClosedTabsMenu.shared.reopenClosedTab(sender)
    } else if let target = undoTarget {
      NSApp.sendAction(Self.undo, to: target, from: sender)
    }
  }

  func validateMenuItem(_ item: NSMenuItem) -> Bool {
    let reopens = self.reopens
    item.title = reopens ? "Undo Close Tab" : "Undo"
    if reopens {
      let probe = NSMenuItem(title: "", action: #selector(ClosedTabsMenu.reopenClosedTab(_:)), keyEquivalent: "")
      return ClosedTabsMenu.shared.validateMenuItem(probe)
    }
    // Undo as AppKit would have it: enabled when whatever takes undo: in the responder chain says so.
    guard let target = undoTarget else { return false }
    typealias Validate = @convention(c) (AnyObject, Selector, NSMenuItem) -> ObjCBool
    for name in ["validateMenuItem:", "validateUserInterfaceItem:"] {
      let validate = NSSelectorFromString(name)
      if target.responds(to: validate) {
        return unsafeBitCast(target.method(for: validate), to: Validate.self)(target, validate, item).boolValue
      }
    }
    return true
  }

  /// For the state log: whether Edit › Undo is Ray's now, what ⌘Z would do (and the item's title for it), and what
  /// has the key window's focus.
  var debug: [String: Any] {
    let item = MainMenu.item(for: Self.undo)
    let responder = window?.firstResponder
    var title = item?.title ?? ""
    if let item, item.target === self {
      _ = validateMenuItem(item)
      title = item.title
    }
    return [
      "target": item?.target === self, "reopens": reopens, "title": title,
      "focus": responder.map { String(describing: type(of: $0)) } ?? "", "editsText": Self.editsText(responder),
    ]
  }
}
