import AppKit

// The keys of Ray's menu commands: what each one answers to, the user's own shortcuts over the defaults (Settings ›
// Shortcuts, `SettingsShortcutEditor.swift`), and which keys Chrome's page never sees first (`Shortcuts.isReserved`).
//
// One place decides each item's key equivalent (`apply`): the user's shortcut for the command if they set one ("none"
// takes its key away), else its default, which the ⇧⌘C and ⌘S switches of Settings › Shortcuts decide for Copy URL,
// Toggle Sidebar and Save Page As, and which yields to a shortcut the user gave another command. The command bar
// reads each item's key live (`BarActions.shortcut`), so it follows.
//
// What can change: Ray's own commands (AppController's and History's), except Quit and Settings, whose ⌘Q and ⌘, are
// every Mac app's. macOS's items (Hide, Minimize, Cut, Copy, Paste, Undo, Full Screen…) aren't listed and keep their
// keys, and no command may take one of them, nor a key macOS keeps for itself (⌘⇥, ⌘Space, screenshots).
//
// Reserved keys follow their commands, as Chrome reserves commands rather than keys
// (`BrowserCommandController::IsReservedCommandOrKey`): New Tab moved to ⌃⌘J makes ⌃⌘J reach Ray before the page,
// and ⌘T then goes to the page.

// MARK: Key combinations

/// A key with its modifiers, as a menu item answers to it, a key press reads, and the setting stores it
/// ("ctrl+opt+shift+cmd+k": the modifiers in the order macOS draws them, then the key).
struct KeyCombo: Hashable {
  /// One character, lowercased ("k", "[", ","), or a key's name ("f5", "left", "return", "plus" for +).
  let key: String
  /// Control, Option, Shift and Command only.
  let modifiers: NSEvent.ModifierFlags

  static let relevant: NSEvent.ModifierFlags = [.control, .option, .shift, .command]

  init(_ key: String, _ modifiers: NSEvent.ModifierFlags) {
    self.key = key
    self.modifiers = modifiers.intersection(Self.relevant)
  }

  static func == (a: KeyCombo, b: KeyCombo) -> Bool { a.key == b.key && a.modifiers == b.modifiers }
  func hash(into hasher: inout Hasher) {
    hasher.combine(key)
    hasher.combine(modifiers.rawValue)
  }

  private struct Named {
    let name: String
    let equivalent: String
    let display: String
    let keyCodes: [UInt16]
  }

  private static func scalar(_ value: Int) -> String { String(Character(UnicodeScalar(UInt32(value))!)) }

  // F1–F20's key codes, in order.
  private static let functionKeyCodes: [UInt16] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]

  private static let named: [Named] = {
    var out = [
      Named(name: "return", equivalent: "\r", display: "↩", keyCodes: [36, 76]),
      Named(name: "tab", equivalent: "\t", display: "⇥", keyCodes: [48]),
      Named(name: "space", equivalent: " ", display: "Space", keyCodes: [49]),
      Named(name: "delete", equivalent: String(UnicodeScalar(UInt8(NSBackspaceCharacter))), display: "⌫", keyCodes: [51]),
      Named(name: "forwarddelete", equivalent: scalar(NSDeleteFunctionKey), display: "⌦", keyCodes: [117]),
      Named(name: "escape", equivalent: "\u{1b}", display: "⎋", keyCodes: [53]),
      Named(name: "left", equivalent: scalar(NSLeftArrowFunctionKey), display: "←", keyCodes: [123]),
      Named(name: "right", equivalent: scalar(NSRightArrowFunctionKey), display: "→", keyCodes: [124]),
      Named(name: "down", equivalent: scalar(NSDownArrowFunctionKey), display: "↓", keyCodes: [125]),
      Named(name: "up", equivalent: scalar(NSUpArrowFunctionKey), display: "↑", keyCodes: [126]),
      Named(name: "home", equivalent: scalar(NSHomeFunctionKey), display: "↖", keyCodes: [115]),
      Named(name: "end", equivalent: scalar(NSEndFunctionKey), display: "↘", keyCodes: [119]),
      Named(name: "pageup", equivalent: scalar(NSPageUpFunctionKey), display: "⇞", keyCodes: [116]),
      Named(name: "pagedown", equivalent: scalar(NSPageDownFunctionKey), display: "⇟", keyCodes: [121]),
      Named(name: "plus", equivalent: "+", display: "+", keyCodes: []),
    ]
    for number in 1...20 {
      out.append(Named(name: "f\(number)", equivalent: scalar(NSF1FunctionKey + number - 1), display: "F\(number)",
                       keyCodes: [functionKeyCodes[number - 1]]))
    }
    return out
  }()

  private static let byName = Dictionary(uniqueKeysWithValues: named.map { ($0.name, $0) })
  private static let byEquivalent: [String: Named] = {
    var out = Dictionary(uniqueKeysWithValues: named.map { ($0.equivalent, $0) })
    out[String(UnicodeScalar(UInt8(NSDeleteCharacter)))] = byName["delete"]
    return out
  }()
  private static let byKeyCode: [UInt16: Named] = {
    var out: [UInt16: Named] = [:]
    for entry in named { for code in entry.keyCodes { out[code] = entry } }
    return out
  }()

  /// A key the setting can name: one printable character, or a named key.
  private static func isKey(_ key: String) -> Bool {
    if byName[key] != nil { return true }
    guard key.count == 1, let character = key.first, key == key.lowercased() else { return false }
    return !character.isWhitespace && !character.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
      && !(0xF700...0xF8FF).contains(character.unicodeScalars.first!.value)
  }

  /// F1–F20: a shortcut on its own, without a modifier (Ardia's rule).
  var isFunctionKey: Bool { key.count >= 2 && key.hasPrefix("f") && Int(key.dropFirst()).map { (1...20).contains($0) } == true }

  /// What a menu can be given: ⌘ or ⌃ with the key, or a function key. ⌥ alone (or ⇧) would take a character away
  /// from typing (⌥E is é), as a menu key equivalent fires before text input.
  var isAssignable: Bool { !modifiers.intersection([.command, .control]).isEmpty || isFunctionKey }

  // MARK: Reading and writing

  /// A menu item's key equivalent; nil for none. An uppercase letter is a shifted one, whether or not the mask says so.
  init?(item: NSMenuItem) {
    let equivalent = item.keyEquivalent
    guard !equivalent.isEmpty else { return nil }
    var modifiers = item.keyEquivalentModifierMask
    if let named = Self.byEquivalent[equivalent] {
      self.init(named.name, modifiers)
      return
    }
    if equivalent.count == 1, let first = equivalent.first, first.isLetter, first.isUppercase { modifiers.insert(.shift) }
    self.init(equivalent.lowercased(), modifiers)
  }

  /// What the menu item takes: a shifted letter uppercase ("C" for ⇧⌘C, CLAUDE.md's gotcha).
  var itemEquivalent: (key: String, modifiers: NSEvent.ModifierFlags) {
    if let named = Self.byName[key] { return (named.equivalent, modifiers) }
    let letter = key.count == 1 && key.first?.isLetter == true
    return (letter && modifiers.contains(.shift) ? key.uppercased() : key, modifiers)
  }

  /// A key press: its key without Shift or Option applied ("]" for ⇧⌘], "e" for ⌥⌘E), and its modifiers.
  init?(event: NSEvent) {
    guard event.type == .keyDown else { return nil }
    let modifiers = event.modifierFlags.intersection(Self.relevant)
    if let named = Self.byKeyCode[event.keyCode] {
      self.init(named.name, modifiers)
      return
    }
    let base = event.characters(byApplyingModifiers: []).flatMap { $0.isEmpty ? nil : $0 } ?? event.charactersIgnoringModifiers ?? ""
    if let named = Self.byEquivalent[base] {
      self.init(named.name, modifiers)
      return
    }
    let key = base == "+" ? "plus" : base.lowercased()
    guard Self.isKey(key) else { return nil }
    self.init(key, modifiers)
  }

  /// The ways a key press may match a menu item: its base key, and the character it typed with Shift (a layout whose
  /// base key differs), so `Shortcuts.isReserved` finds the item AppKit's own matching would.
  static func candidates(for event: NSEvent) -> [KeyCombo] {
    var out: [KeyCombo] = []
    if let combo = KeyCombo(event: event) { out.append(combo) }
    let modifiers = event.modifierFlags.intersection(relevant)
    if let typed = event.charactersIgnoringModifiers, !typed.isEmpty {
      let key = typed == "+" ? "plus" : typed.lowercased()
      if let named = byEquivalent[typed] {
        out.append(KeyCombo(named.name, modifiers))
      } else if isKey(key) {
        out.append(KeyCombo(key, modifiers))
        // A shifted symbol ("}" for ⇧⌘]) as the unshifted key the item names (a US layout's pairs).
        if let unshifted = usShifted[typed] { out.append(KeyCombo(unshifted, modifiers)) }
      }
    }
    return out
  }

  private static let usShifted: [String: String] = [
    "{": "[", "}": "]", "<": ",", ">": ".", "?": "/", ":": ";", "\"": "'", "|": "\\", "_": "-", "~": "`",
    "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9", ")": "0",
  ]

  /// The setting's text: "ctrl+opt+shift+cmd+k" (modifiers in this order, the key last).
  var text: String {
    var parts: [String] = []
    if modifiers.contains(.control) { parts.append("ctrl") }
    if modifiers.contains(.option) { parts.append("opt") }
    if modifiers.contains(.shift) { parts.append("shift") }
    if modifiers.contains(.command) { parts.append("cmd") }
    return (parts + [key]).joined(separator: "+")
  }

  /// From the setting's text; nil for anything that isn't one key with known modifiers.
  init?(text: String) {
    let parts = text.trimmingCharacters(in: .whitespaces).lowercased().split(separator: "+", omittingEmptySubsequences: false).map(String.init)
    guard let key = parts.last, Self.isKey(key) else { return nil }
    var modifiers: NSEvent.ModifierFlags = []
    for part in parts.dropLast() {
      let flag: NSEvent.ModifierFlags
      switch part {
      case "ctrl", "control": flag = .control
      case "opt", "option", "alt": flag = .option
      case "shift": flag = .shift
      case "cmd", "command": flag = .command
      default: return nil
      }
      guard !modifiers.contains(flag) else { return nil }
      modifiers.insert(flag)
    }
    self.init(key, modifiers)
  }

  /// As a menu draws it: ⌃⌥⇧⌘ then the key ("⇧⌘C", "⌃⌘F5").
  var display: String {
    var text = ""
    if modifiers.contains(.control) { text += "⌃" }
    if modifiers.contains(.option) { text += "⌥" }
    if modifiers.contains(.shift) { text += "⇧" }
    if modifiers.contains(.command) { text += "⌘" }
    return text + (Self.byName[key]?.display ?? key.uppercased())
  }
}

// MARK: Setting

/// The user's shortcuts: a menu command's id (`MenuCommand.id`, its action's name: "copyURL", "selectTab3") to a key,
/// or nil for none (the command keeps no key). A command missing from the map has its default. Settings.json keeps an
/// object of `"id": "ctrl+cmd+k"` or `"none"`; as text (the test command, the catalog check) it is that object's JSON on
/// one line, keys sorted.
struct ShortcutOverrides: SettingValue {
  var entries: [String: KeyCombo?]

  init(_ entries: [String: KeyCombo?] = [:]) { self.entries = entries }

  static let most = 300

  /// Why `combo` can't be any command's shortcut, in words; nil when it can. `except` is the command asking (its own
  /// items don't count).
  static func refusal(_ combo: KeyCombo, for id: String? = nil) -> String? {
    if !combo.isAssignable { return "Use ⌘ or ⌃ with the key, or a function key (F1–F20)." }
    if let reason = MenuShortcuts.macOSKeys[combo] { return "\(combo.display) belongs to macOS: \(reason)." }
    if let fixed = MenuShortcuts.fixedHolder(of: combo, except: id) {
      return "\(combo.display) is \(fixed), which can't change."
    }
    return nil
  }

  /// The setting's validation: every key assignable and free of macOS's, no key twice, at most `most` entries, and
  /// (once the menu is up) every id a command that can change.
  static func validate(_ value: ShortcutOverrides) -> ShortcutOverrides? {
    guard value.entries.count <= most else { return nil }
    var seen = Set<KeyCombo>()
    for (id, combo) in value.entries {
      guard isID(id) else { return nil }
      if MenuShortcuts.isInstalled, MenuShortcuts.command(id)?.rebindable != true { return nil }
      guard let combo else { continue }
      guard seen.insert(combo).inserted, refusal(combo, for: id) == nil else { return nil }
    }
    return value
  }

  private static func isID(_ id: String) -> Bool {
    !id.isEmpty && id.count <= 64 && id.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII }
  }

  private static func entry(_ text: String) -> KeyCombo?? {
    if text.lowercased() == "none" { return .some(nil) }
    return KeyCombo(text: text).map { .some($0) }
  }

  /// From Settings.json: entries that don't read as a key are dropped, the rest kept (ids this build doesn't know too:
  /// a newer build's commands).
  init?(settingJSON json: Any) {
    guard let object = json as? [String: Any] else { return nil }
    var entries: [String: KeyCombo?] = [:]
    var seen = Set<KeyCombo>()
    for (id, value) in object.sorted(by: { $0.key < $1.key }) where Self.isID(id) && entries.count < Self.most {
      guard let text = value as? String, let combo = Self.entry(text) else { continue }
      if let combo { guard combo.isAssignable, MenuShortcuts.macOSKeys[combo] == nil, seen.insert(combo).inserted else { continue } }
      entries[id] = combo
    }
    self.entries = entries
  }

  var json: [String: String] { entries.mapValues { $0?.text ?? "none" } }

  var settingJSON: Any? { entries.isEmpty ? nil : json }

  /// From text: strict, every entry valid.
  init?(settingText text: String) {
    guard let data = text.data(using: .utf8), let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
    var entries: [String: KeyCombo?] = [:]
    for (id, value) in object {
      guard let text = value as? String, let combo = Self.entry(text) else { return nil }
      entries[id] = combo
    }
    self.entries = entries
  }

  var settingText: String {
    guard let data = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys, .withoutEscapingSlashes]),
          let text = String(data: data, encoding: .utf8) else { return "{}" }
    return text
  }
}

extension AnySettingKey {
  /// The user's own shortcuts for Ray's menu commands (`MenuShortcuts`).
  static let shortcuts = SettingKey<ShortcutOverrides>(
    "shortcuts", default: ShortcutOverrides(), validate: ShortcutOverrides.validate,
    ui: SettingUI(
      pane: .shortcuts, group: .menuShortcuts, title: "Change a command's shortcut",
      detail: "Click a shortcut, then press the keys you want: ⌘ or ⌃ with a key, or a function key. Escape cancels; "
        + "Delete removes it.",
      keywords: ["keyboard shortcuts", "keys", "hotkeys", "key bindings", "rebind", "remap", "customize", "shortcut editor"],
      control: .custom("shortcuts")),
    log: { $0.json },
    customTests: (
      samples: [#"{"copyURL":"ctrl+cmd+k","find":"none"}"#, "{}"],
      rejects: [
        "nonsense",
        #"{"copyURL":"k"}"#,
        #"{"copyURL":"opt+k"}"#,
        #"{"copyURL":"cmd+q"}"#,
        #"{"copyURL":"cmd+c"}"#,
        #"{"copyURL":"cmd+tab"}"#,
        #"{"copyURL":"ctrl+cmd+k","find":"ctrl+cmd+k"}"#,
        #"{"quit":"ctrl+cmd+k"}"#,
        #"{"noSuchCommand":"ctrl+cmd+k"}"#,
        #"{"copyURL":"cmd+nosuchkey"}"#,
      ]))
}

extension SettingGroup {
  static let menuShortcuts = SettingGroup(id: "menuShortcuts", title: "Menu commands")
}

// MARK: Commands

/// One of Ray's menu commands as Settings › Shortcuts lists it: its item, any hidden items that answer for it (⌘= for
/// Zoom In), and the key it was built with.
final class MenuCommand {
  /// The action's name without its colon, plus the item's tag when it has one ("selectTab3"). Stable: the setting's key.
  let id: String
  /// As the menu was built ("Close Tab", "Pin Tab"; validation renames some items as it goes).
  let title: String
  /// The top-level menu it is in ("File").
  let menu: String
  let item: NSMenuItem
  fileprivate(set) var aliases: [(item: NSMenuItem, key: KeyCombo?)] = []
  let builtKey: KeyCombo?
  /// Ray's own and not one every Mac app keeps (Quit, Settings).
  let rebindable: Bool
  /// Why it can't change, for its row.
  let lockedReason: String?

  fileprivate init(id: String, title: String, menu: String, item: NSMenuItem, lockedReason: String?) {
    self.id = id
    self.title = title
    self.menu = menu
    self.item = item
    builtKey = KeyCombo(item: item)
    self.lockedReason = lockedReason
    rebindable = lockedReason == nil
  }

  /// Its key now, as the menu has it.
  var current: KeyCombo? { KeyCombo(item: item) }
}

enum MenuShortcuts {
  /// Ray's commands in menu order (filled once the menu is built).
  private(set) static var commands: [MenuCommand] = []
  /// Items whose keys never change: macOS's own, and the ⌥ and ⌃Tab alternates.
  private static var fixed: [(item: NSMenuItem, menu: String)] = []
  static var isInstalled: Bool { !commands.isEmpty }
  private static var observation: SettingsObservation?
  /// Posted after each `apply`.
  static let didApply = Notification.Name("RayMenuShortcutsDidApply")

  /// Every Mac app's: they stay as they are, and nothing else may take their keys.
  private static let locked: [String: String] = [
    "quit": "⌘Q quits Ray, as in every Mac app",
    "showSettings": "⌘, opens Settings, as in every Mac app",
  ]

  /// Keys macOS takes before Ray sees them, or keeps for the system: never a command's.
  static let macOSKeys: [KeyCombo: String] = {
    var out: [KeyCombo: String] = [:]
    func add(_ text: String, _ reason: String) { out[KeyCombo(text: text)!] = reason }
    add("cmd+tab", "it switches apps")
    add("shift+cmd+tab", "it switches apps")
    add("cmd+`", "it switches windows")
    add("shift+cmd+`", "it switches windows")
    add("cmd+space", "it opens Spotlight")
    add("ctrl+space", "it switches input sources")
    add("ctrl+cmd+space", "it shows Emoji & Symbols")
    add("opt+cmd+escape", "it opens Force Quit")
    add("shift+cmd+3", "it takes a screenshot")
    add("shift+cmd+4", "it takes a screenshot")
    add("shift+cmd+5", "it takes a screenshot")
    add("ctrl+cmd+q", "it locks the screen")
    add("opt+cmd+d", "it shows and hides the Dock")
    add("cmd+h", "it hides Ray")
    add("opt+cmd+h", "it hides other apps")
    add("cmd+m", "it minimizes the window")
    add("cmd+q", "it quits Ray")
    return out
  }()

  /// Chrome's reserved commands (`IsReservedCommandOrKey`): their keys reach Ray before the page.
  private static let reservedIDs: Set<String> = [
    "newTab", "closeTab", "newWindow", "newPrivateWindow", "quit", "showSettings", "reopenClosedTab", "nextTab",
    "previousTab", "nextTabWithControl", "previousTabWithControl",
  ]
  /// ⇧⌘W is Chrome's Close Window, which Ray has no item for: still never the page's first.
  private static let reservedWithoutItem: Set<KeyCombo> = [KeyCombo("w", [.command, .shift])]
  private static var reserved: Set<KeyCombo> = reservedWithoutItem

  private static func isRayTarget(_ target: AnyObject?) -> Bool {
    target === AppController.shared || target === ClosedTabsMenu.shared
  }

  private static func id(of item: NSMenuItem) -> String? {
    guard let action = item.action else { return nil }
    var name = NSStringFromSelector(action)
    if name.hasSuffix(":") { name.removeLast() }
    return item.tag == 0 ? name : "\(name)\(item.tag)"
  }

  /// Reads Ray's commands from the main menu, once it is built: the direct items of each top-level menu (not a
  /// submenu's, like Recently Closed's tabs), each with the key it was built with.
  static func install() {
    guard let main = NSApp.mainMenu else { return }
    commands = []
    fixed = []
    var byID: [String: MenuCommand] = [:]
    for top in main.items {
      guard let menu = top.submenu, menu !== NSApp.servicesMenu else { continue }
      for item in menu.items where !item.isSeparatorItem && item.submenu == nil && item.action != nil {
        let hidden = item.isHidden || item.isAlternate
        guard isRayTarget(item.target), let id = id(of: item) else {
          fixed.append((item, top.title))
          continue
        }
        if hidden {
          // A hidden item answering for a listed one (⌘= for Zoom In) follows it; other alternates stay as built.
          if item.isHidden, let primary = byID[id] { primary.aliases.append((item, KeyCombo(item: item))) } else { fixed.append((item, top.title)) }
          continue
        }
        guard byID[id] == nil else { continue }
        let command = MenuCommand(id: id, title: item.title, menu: top.title, item: item, lockedReason: locked[id])
        byID[id] = command
        commands.append(command)
      }
    }
    apply()
    observation = RaySettings.shared.observe([.shortcuts, .copyLinkShortcut, .sidebarShortcut]) { apply() }
  }

  static func command(_ id: String) -> MenuCommand? { commands.first { $0.id == id } }

  /// A command's key when the user hasn't chosen one: as built, except the three Settings › Shortcuts switches.
  static func defaultKey(of command: MenuCommand) -> KeyCombo? {
    let settings = RaySettings.shared
    switch command.id {
    case "copyURL": return settings[.copyLinkShortcut] ? KeyCombo("c", [.command, .shift]) : nil
    case "toggleSidebar": return settings[.sidebarShortcut] ? KeyCombo("s", .command) : nil
    case "savePage": return settings[.sidebarShortcut] ? nil : KeyCombo("s", .command)
    default: return command.builtKey
    }
  }

  /// The user's shortcuts the menu can use: commands that can change, keys nothing fixed holds.
  static var overrides: [String: KeyCombo?] {
    RaySettings.shared[.shortcuts].entries.filter { id, combo in
      command(id)?.rebindable == true && combo.map { fixedHolder(of: $0, except: id) == nil } ?? true
    }
  }

  /// Whether the user chose `command`'s key (or took it away).
  static func isCustomized(_ command: MenuCommand) -> Bool { overrides.keys.contains(command.id) }

  /// The one place each command's key is decided, then set on its items. At launch and after every change.
  static func apply() {
    let chosen = overrides
    let taken = Set(chosen.values.compactMap { $0 })
    for command in commands {
      let key: KeyCombo?
      if let own = chosen[command.id] {
        key = own
      } else {
        let fallback = defaultKey(of: command)
        // A default yields to a shortcut the user gave another command.
        key = fallback.flatMap { taken.contains($0) ? nil : $0 }
      }
      set(command.item, key)
      for alias in command.aliases {
        let aliasKey = chosen[command.id] == nil ? alias.key.flatMap { taken.contains($0) ? nil : $0 } : nil
        set(alias.item, aliasKey)
      }
    }
    var keys = reservedWithoutItem
    for command in commands where reservedIDs.contains(command.id) {
      if let key = command.current { keys.insert(key) }
    }
    for (item, _) in fixed where id(of: item).map(reservedIDs.contains) == true {
      if let key = KeyCombo(item: item) { keys.insert(key) }
    }
    reserved = keys
    NotificationCenter.default.post(name: didApply, object: nil)
  }

  private static func set(_ item: NSMenuItem, _ key: KeyCombo?) {
    let equivalent: (key: String, modifiers: NSEvent.ModifierFlags) = key?.itemEquivalent ?? ("", [])
    if item.keyEquivalent != equivalent.key { item.keyEquivalent = equivalent.key }
    if item.keyEquivalentModifierMask != equivalent.modifiers { item.keyEquivalentModifierMask = equivalent.modifiers }
  }

  // MARK: Who holds a key

  /// What holds `combo` and can't let go of it, in words ("Copy in the Edit menu"): a macOS item, an alternate, or a
  /// locked command. Nil when nothing fixed does.
  static func fixedHolder(of combo: KeyCombo, except id: String?) -> String? {
    for (item, menu) in fixed where KeyCombo(item: item) == combo {
      if let itemID = self.id(of: item), itemID == id { continue }
      return "\(item.title) in the \(menu) menu"
    }
    for command in commands where !command.rebindable && command.id != id && command.current == combo {
      return "\(command.title) in the \(command.menu) menu"
    }
    return nil
  }

  /// The command of Ray's that answers to `combo` now (or would, through a hidden alias), other than `id`.
  static func holder(of combo: KeyCombo, except id: String) -> MenuCommand? {
    commands.first { command in
      command.id != id && command.rebindable
        && (command.current == combo || command.aliases.contains { KeyCombo(item: $0.item) == combo })
    }
  }

  // MARK: Reserved keys

  /// Whether a key press belongs to one of Chrome's reserved commands as the menu has them now.
  static func isReserved(_ event: NSEvent) -> Bool {
    KeyCombo.candidates(for: event).contains { reserved.contains($0) }
  }

  // MARK: Tests

  /// For the state log: each listed command's key as the menu draws it ("" for none), and the reserved keys.
  static var debug: [String: Any] {
    [
      "keys": Dictionary(uniqueKeysWithValues: commands.map { ($0.id, $0.current?.display ?? "") }),
      "reserved": reserved.map(\.display).sorted(),
    ]
  }
}
