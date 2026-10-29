import AppKit

/// One of Ray's menu commands offered as a command bar row (Arc's command bar is also a control centre: "task" offers
/// Task Manager, "copy" Copy URL). It runs the menu item itself, so it does exactly what the menu would.
struct BarAction {
  let item: NSMenuItem
  let title: String
  let symbol: String
  /// The item's key equivalent as it is now ("⇧⌘C"; "" when Settings freed it or it has none).
  let shortcut: String
  /// Whether an exact match may take the first row (Enter). Clear Today's Tabs never does: it has no undo.
  let leads: Bool
  fileprivate let names: [[String]]

  var id: String { item.action.map(NSStringFromSelector) ?? title }
}

/// The command bar's action rows, read from the main menu rather than a list of their own, so a new menu command
/// shows up here without a second change. Only the direct items of each top-level menu that Ray's AppController runs
/// count (not a submenu's, like a list of recently closed tabs), minus the few that make no sense from the bar, and
/// only while the menu would enable them (Print with no page isn't offered).
///
/// Matching: at least two characters, every typed word the start of a word of the title or a synonym, in order
/// (Ardia, Crest and Cra all wait for two characters; word starts, never any substring). At most 2 rows for a query
/// under four characters, else 3 (Ardia: 2 / 4, Crest: 3). An address never matches, and an action never takes the
/// first row from a host the field autocompletes (see `Suggestions.build`).
enum BarActions {
  private struct Extra {
    var symbol: String
    var synonyms: [String] = []
    /// The bar's title when the menu's would read oddly on its own (Ardia's `barTitle`).
    var title: String? = nil
    var leads = true
  }

  // Titles, symbols and synonyms after Ardia's command catalog (commandCatalog.ts, barActions.ts).
  private static let extras: [Selector: Extra] = [
    #selector(AppController.newTab(_:)): Extra(symbol: "plus", synonyms: ["open tab"]),
    #selector(AppController.newWindow(_:)): Extra(symbol: "macwindow"),
    #selector(AppController.newPrivateWindow(_:)): Extra(
      symbol: "eyeglasses", synonyms: ["private window", "incognito window", "incognito"]),
    #selector(AppController.closeTab(_:)): Extra(symbol: "xmark"),
    #selector(AppController.togglePin(_:)): Extra(symbol: "pin", synonyms: ["pin", "unpin", "pin tab", "unpin tab"]),
    #selector(AppController.newFolder(_:)): Extra(symbol: "folder.badge.plus", synonyms: ["folder", "create folder"]),
    #selector(AppController.backToPinned(_:)): Extra(
      symbol: "arrow.uturn.backward.circle", synonyms: ["reset pinned tab", "pinned url"]),
    #selector(AppController.clearToday(_:)): Extra(
      symbol: "xmark.square",
      synonyms: ["clear unpinned tabs", "close unpinned tabs", "close all tabs", "clear today", "archive tabs"],
      leads: false),
    #selector(AppController.importFromBrowser(_:)): Extra(
      symbol: "square.and.arrow.down",
      synonyms: ["import browser data", "import from arc", "import bookmarks", "import passwords", "import history"]),
    #selector(AppController.savePage(_:)): Extra(symbol: "arrow.down.doc", synonyms: ["save page", "download page"]),
    #selector(AppController.printPage(_:)): Extra(symbol: "printer"),
    #selector(AppController.copyURL(_:)): Extra(symbol: "link", synonyms: ["copy link", "copy address"]),
    #selector(AppController.find(_:)): Extra(
      symbol: "text.magnifyingglass", synonyms: ["find", "search page", "search in page"], title: "Find in Page"),
    #selector(AppController.toggleSidebar(_:)): Extra(
      symbol: "sidebar.left", synonyms: ["hide sidebar", "show sidebar", "focus mode"]),
    #selector(AppController.toggleToolbar(_:)): Extra(
      symbol: "menubar.rectangle",
      synonyms: ["show address bar", "hide address bar", "toolbar", "url bar", "address bar"]),
    #selector(AppController.toggleFullAddress(_:)): Extra(
      symbol: "text.alignleft", synonyms: ["show full url", "hide full url", "full url", "full address"]),
    #selector(AppController.toggleSiteControls(_:)): Extra(
      symbol: "slider.horizontal.3", synonyms: ["site settings", "site permissions", "permissions"]),
    #selector(AppController.reload(_:)): Extra(symbol: "arrow.clockwise", synonyms: ["reload", "refresh"]),
    #selector(AppController.reloadIgnoringCache(_:)): Extra(
      symbol: "arrow.clockwise", synonyms: ["hard reload", "hard refresh", "force refresh"]),
    #selector(AppController.actualSize(_:)): Extra(symbol: "1.magnifyingglass", synonyms: ["reset zoom", "zoom reset"]),
    #selector(AppController.zoomIn(_:)): Extra(symbol: "plus.magnifyingglass"),
    #selector(AppController.zoomOut(_:)): Extra(symbol: "minus.magnifyingglass"),
    #selector(AppController.showDownloads(_:)): Extra(symbol: "arrow.down.circle", synonyms: ["show downloads"]),
    #selector(AppController.toggleDevTools(_:)): Extra(
      symbol: "hammer", synonyms: ["devtools", "inspect", "inspector", "console"]),
    #selector(AppController.viewSource(_:)): Extra(
      symbol: "chevron.left.forwardslash.chevron.right", synonyms: ["page source", "source", "html"]),
    #selector(AppController.showHistory(_:)): Extra(symbol: "clock", synonyms: ["history", "show history"]),
    #selector(AppController.taskManager(_:)): Extra(symbol: "cpu", synonyms: ["processes", "memory"]),
    #selector(AppController.clearBrowsingData(_:)): Extra(
      symbol: "trash",
      synonyms: ["clear history", "clear cache", "clear cookies", "delete history", "delete cookies", "delete data"]),
    #selector(AppController.showSettings(_:)): Extra(
      symbol: "gearshape", synonyms: ["settings", "preferences", "prefs", "options"]),
    #selector(AppController.checkForUpdates(_:)): Extra(
      symbol: "arrow.triangle.2.circlepath", synonyms: ["update ray", "updates"]),
    // Commands the menu may gain later: their symbol and synonyms wait here; the menu item itself is what offers them.
    Selector(("reopenClosedTab:")): Extra(
      symbol: "arrow.uturn.backward", synonyms: ["undo close tab", "restore tab", "reopen tab"]),
  ]

  /// Menu commands the bar leaves out: the bar is already open (Open Location), they act on a bar or panel that isn't
  /// (Find Next), they walk tabs or history (keys do that better), or they'd end the session from a stray Enter (Quit).
  private static let excluded: Set<Selector> = [
    #selector(AppController.showAbout(_:)), #selector(AppController.quit(_:)), #selector(AppController.focusAddress(_:)),
    #selector(AppController.findNext(_:)), #selector(AppController.findPrevious(_:)),
    #selector(AppController.goBack(_:)), #selector(AppController.goForward(_:)),
    #selector(AppController.nextTab(_:)), #selector(AppController.previousTab(_:)),
    #selector(AppController.nextTabWithControl(_:)), #selector(AppController.previousTabWithControl(_:)),
    #selector(AppController.selectTab(_:)), #selector(AppController.printWithSystemDialog(_:)),
  ]

  /// The commands the bar can run now, validated as the menu would validate them.
  static func available() -> [BarAction] {
    guard let menu = NSApp.mainMenu else { return [] }
    var seen = Set<Selector>()
    var out: [BarAction] = []
    for top in menu.items {
      for item in top.submenu?.items ?? [] {
        guard let selector = item.action, isRayTarget(item.target), !item.isSeparatorItem, !item.isHidden,
              item.submenu == nil, item.representedObject == nil, item.tag == 0,
              !excluded.contains(selector), seen.insert(selector).inserted,
              validate(item) else { continue }
        let extra = extras[selector]
        let title = barTitle(item, extra)
        out.append(BarAction(
          item: item, title: title, symbol: extra?.symbol ?? "command", shortcut: shortcut(of: item),
          leads: extra?.leads ?? true,
          names: ([title] + (extra?.synonyms ?? [])).map(words)))
      }
    }
    return out
  }

  /// The menu's title as a command: no trailing ellipsis (Ardia's `commandBarTitle`), and a checked "Show …" toggle
  /// reads "Hide …", since that is what it will do.
  private static func barTitle(_ item: NSMenuItem, _ extra: Extra?) -> String {
    var title = extra?.title ?? item.title
    while title.hasSuffix("…") || title.hasSuffix(".") { title.removeLast() }
    if item.state == .on, title.hasPrefix("Show ") { title = "Hide " + title.dropFirst(5) }
    return title
  }

  /// The actions a query asks for, best first, with whether it named one exactly (its title or a synonym).
  static func matches(_ query: String, in actions: [BarAction]) -> [(action: BarAction, exact: Bool)] {
    let typed = words(query)
    let joined = typed.joined(separator: " ")
    guard joined.count >= 2 else { return [] }
    var hits: [(action: BarAction, exact: Bool, score: Int)] = []
    for action in actions {
      var best: Int?
      var exact = false
      for (index, name) in action.names.enumerated() {
        guard var score = score(typed, name) else { continue }
        if name.joined(separator: " ") == joined { exact = true; score += 1000 }
        if index > 0 { score -= 5 }  // the title before a synonym
        best = max(best ?? score, score)
      }
      if let best { hits.append((action, exact, best)) }
    }
    let limit = joined.count < 4 ? 2 : 3
    return hits.sorted { $0.score > $1.score }.prefix(limit).map { ($0.action, $0.exact) }
  }

  /// Every typed word starts a word of the name, in order; earlier and longer matches score higher (after Ardia's
  /// `scoreName`, without its substring and subsequence fallbacks).
  private static func score(_ typed: [String], _ name: [String]) -> Int? {
    guard !typed.isEmpty else { return nil }
    var from = 0
    var score = name.joined(separator: " ").hasPrefix(typed.joined(separator: " ")) ? 200 : 0
    for token in typed {
      guard let at = name[from...].firstIndex(where: { $0.hasPrefix(token) }) else { return nil }
      score += 60 + token.count * 4 - at * 2
      from = at + 1
    }
    return score - name.count
  }

  /// Lowercased words: apostrophes dropped ("today's" is one word), anything else not a letter or digit splits.
  private static func words(_ text: String) -> [String] {
    text.lowercased().replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "’", with: "")
      .split { !$0.isLetter && !$0.isNumber }.map(String.init)
  }

  /// Runs the action as its menu item would: the same selector to the same target, only if the menu would still
  /// enable it. Only the command bar's Enter or click calls this.
  @discardableResult
  static func run(_ action: BarAction) -> Bool {
    guard let selector = action.item.action, validate(action.item) else { return false }
    return NSApp.sendAction(selector, to: action.item.target, from: action.item)
  }

  /// Ray's own menu targets: AppController, and History's recently closed tabs (ClosedTabsMenu).
  private static func isRayTarget(_ target: AnyObject?) -> Bool {
    target === AppController.shared || target === ClosedTabsMenu.shared
  }

  /// Enabled as the menu would show it, asked of the item's own target.
  private static func validate(_ item: NSMenuItem) -> Bool {
    (item.target as? NSMenuItemValidation)?.validateMenuItem(item) ?? false
  }

  /// A menu item's key equivalent as the menu draws it: ⌃⌥⇧⌘ then the key.
  static func shortcut(of item: NSMenuItem) -> String {
    let key = item.keyEquivalent
    guard !key.isEmpty else { return "" }
    var modifiers = item.keyEquivalentModifierMask
    // An uppercase letter is a shifted key whether or not the mask says so.
    if key.count == 1, let first = key.first, first.isLetter, first.isUppercase { modifiers.insert(.shift) }
    var text = ""
    if modifiers.contains(.control) { text += "⌃" }
    if modifiers.contains(.option) { text += "⌥" }
    if modifiers.contains(.shift) { text += "⇧" }
    if modifiers.contains(.command) { text += "⌘" }
    let named: [String: String] = [
      String(UnicodeScalar(UInt8(NSBackspaceCharacter))): "⌫", String(UnicodeScalar(UInt8(NSDeleteCharacter))): "⌫",
      "\t": "⇥", "\r": "↩", " ": "Space", "\u{1b}": "⎋",
    ]
    return text + (named[key] ?? key.uppercased())
  }
}
