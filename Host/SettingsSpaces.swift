import AppKit

/// Settings › Spaces and Profiles (owner's pick B of `docs/mocks/settings-spaces.html`, 2026-11-25; Arc's Settings ›
/// Profiles): each profile is a group (its avatar and name, New Space… and a ⋯ with Rename…, Colour, Delete Profile…),
/// its Spaces are the rows of its card, and a Space's row opens to its editor (name, icon, Window, Accent, Profile,
/// which moves it to another profile, Delete Space…). New Profile… at the bottom makes a profile with a Space. Deleting
/// a profile moves its Spaces to Default (pick 2A). It acts on the normal window (`SettingsDataProfile.window`).
final class SpacesPaneContent: SettingsPaneContent {
  let groups = ProfileGroupsView()
  var editor: SpaceSettingsEditor { groups.editor }
  private var observer: NSObjectProtocol?

  init() {
    observer = NotificationCenter.default.addObserver(forName: BrowserWindowController.spacesDidChange, object: nil,
                                                      queue: .main) { [weak self] _ in self?.refresh() }
    refresh()
  }

  deinit { observer.map(NotificationCenter.default.removeObserver) }

  var hasContent: Bool { true }

  func sections() -> [SettingsSection] {
    [
      SettingsSection(
        id: "spaces.list", place: .top, view: groups, card: false,
        search: [SettingsSearchEntry(title: "Spaces", detail: "Each Space's name, icon, colours and profile",
                                     keywords: ["space", "spaces", "theme", "colour", "color", "icon", "emoji", "new space",
                                                "delete space", "rename space"]),
                 SettingsSearchEntry(title: "Profiles", detail: "Separate logins, history and passwords for Spaces",
                                     keywords: ["profile", "profiles", "accounts", "new profile", "delete profile",
                                                "rename profile"])]),
    ]
  }

  func refresh() {
    guard let window = SettingsDataProfile.window else { return }
    groups.show(window.state.profiles, spaces: window.state.spaces, current: window.state.current.id)
  }

  var debug: [String: Any] {
    ["selected": groups.selected?.uuidString ?? NSNull(), "spaces": groups.spaceCount, "editor": editor.debug,
     "profiles": groups.debug, "dataProfile": SettingsDataProfile.debug,
     "copy": ["asking": ProfileCopy.pending != nil, "running": ProfileCopy.running, "last": ProfileCopy.last as Any? ?? NSNull()]]
  }
}

// MARK: Groups

/// The profiles as groups on cards, their Spaces as rows; the chosen Space's editor after its row.
final class ProfileGroupsView: NSView, SettingsSizing, NSTextFieldDelegate {
  let editor = SpaceSettingsEditor()
  private let stack = SettingsStack()
  private(set) var selected: UUID?
  private var infos: [ProfileInfo] = []
  private var spaces: [Space] = []
  private var rows: [UUID: SettingsItemRow] = [:]
  private var moreButtons: [String: NSButton] = [:]
  /// The profile whose name is being edited (its card leads with a field).
  private var renaming: String?
  private var renameField: EditorField?
  /// The profiles and Spaces last shown (directories, ids, profiles).
  private var shape: [String] = []

  override var isFlipped: Bool { true }

  override init(frame: NSRect) {
    super.init(frame: frame)
    stack.cards = true
    addSubview(stack)
  }

  required init?(coder: NSCoder) { fatalError() }

  private static func key(_ directory: String?) -> String { directory ?? "default" }
  private var window_: BrowserWindowController? { SettingsDataProfile.window }

  var spaceCount: Int { spaces.count }

  func show(_ profiles: [ProfileInfo], spaces: [Space], current: UUID?) {
    // Typing a name keeps the rows (nothing rebuilds under the field) unless a Space or profile came or went.
    let shape = profiles.map { $0.directory ?? "" } + spaces.map { "\($0.id)\($0.profile ?? "")" }
    if renameField?.field.currentEditor() != nil || editor.isTyping, shape == self.shape { return }
    self.shape = shape
    infos = profiles
    if infos.first?.directory != nil || infos.isEmpty {
      infos.insert(ProfileInfo(directory: nil, name: ProfileInfo.defaultName, color: nil, source: nil), at: 0)
    }
    self.spaces = spaces
    if let selected, !spaces.contains(where: { $0.id == selected }) { self.selected = nil }
    rebuild()
  }

  private func rebuild() {
    var items: [SettingsStack.Item] = []
    rows = [:]
    moreButtons = [:]
    for (index, info) in infos.enumerated() {
      let key = Self.key(info.directory)
      let header = SettingsDataHeader(title: info.name)
      let newSpace = SettingsButton("New Space…") { [weak self] in self?.newSpace(in: info.directory) }
      let more = NSButton(image: NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "More")!,
                          target: self, action: #selector(morePressed(_:)))
      more.isBordered = false
      more.contentTintColor = .secondaryLabelColor
      more.tag = index
      more.setAccessibilityLabel("\(info.name) profile")
      moreButtons[key] = more
      header.setTrailing([newSpace, more])
      items.append(.init(view: header, gap: index == 0 ? 0 : 18))
      if renaming == key {
        let field = renameField ?? EditorField(placeholder: "Profile name")
        if renameField == nil { field.field.stringValue = info.name }
        field.field.delegate = self
        renameField = field
        let save = SettingsButton("Save", primary: true) { [weak self] in self?.commitRename() }
        let cancel = SettingsButton("Cancel") { [weak self] in self?.endRename() }
        items.append(.init(view: SettingsRenameRow(field: field, buttons: [cancel, save])))
      }
      let own = spaces.filter { $0.profile == info.directory }
      if own.isEmpty {
        items.append(.init(view: SettingsNote("No Spaces", inset: SettingsNote.rowInset)))
      }
      for (n, space) in own.enumerated() {
        let tabs = (space.pinned + space.today).filter { !$0.isFolder }.count
        let row = SettingsItemRow(key: space.id.uuidString, icon: Self.icon(space), title: space.name,
                                  detail: tabs == 1 ? "1 tab" : "\(tabs) tabs", disclosure: true)
        row.expanded = space.id == selected
        row.onClick = { [weak self] in self?.select(space.id) }
        rows[space.id] = row
        items.append(.init(view: row, line: n > 0 || renaming == key))
        if space.id == selected {
          editor.show(space.id)
          items.append(.init(view: editor, line: true))
        }
      }
    }
    let newProfile = SettingsDataHeader(title: "")
    newProfile.setTrailing([SettingsButton("New Profile…") { [weak self] in self?.newProfile() }])
    items.append(.init(view: newProfile, gap: 10))
    stack.set(items)
    settingsSectionResized()
    needsLayout = true
  }

  /// The Space's icon as a 22 pt image (its emoji or symbol on a wash of its colour).
  private static func icon(_ space: Space) -> NSImage {
    NSImage(size: NSSize(width: 22, height: 22), flipped: false) { rect in
      let tint = space.color.flatMap(ProfileColor.parse).map { NSColor(srgbRed: $0.r, green: $0.g, blue: $0.b, alpha: 0.25) }
        ?? NSColor.labelColor.withAlphaComponent(0.08)
      tint.setFill()
      NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
      drawIcon(space.icon ?? String(space.name.prefix(1)), in: rect, size: 13)
      return true
    }
  }

  func select(_ id: UUID?) {
    selected = selected == id ? nil : id
    rebuild()
  }

  private func newSpace(in directory: String?) {
    guard let window = window_, let space = window.addSpaceFromSettings(profile: directory) else { return }
    selected = space.id
    if let current = SettingsDataProfile.window { show(current.state.profiles, spaces: current.state.spaces, current: nil) }
  }

  private func newProfile() {
    guard let window = window_, let directory = window.addProfileFromSettings() else { return }
    renaming = Self.key(directory)
    renameField = nil
    show(window.state.profiles, spaces: window.state.spaces, current: nil)
    if let field = renameField {
      field.window?.makeFirstResponder(field.field)
      field.field.currentEditor()?.selectAll(nil)
    }
  }

  // MARK: The profile's ⋯

  @objc private func morePressed(_ sender: NSButton) {
    guard let menu = moreMenu(sender.tag) else { return }
    menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
  }

  func moreMenu(_ index: Int) -> NSMenu? {
    guard infos.indices.contains(index) else { return nil }
    let info = infos[index]
    let menu = NSMenu()
    func item(_ title: String, _ run: @escaping () -> Void) -> NSMenuItem {
      let item = NSMenuItem(title: title, action: #selector(MenuAction.run(_:)), keyEquivalent: "")
      let action = MenuAction(run)
      item.target = action
      item.representedObject = action
      return item
    }
    menu.addItem(item("Rename…") { [weak self] in self?.beginRename(info.directory) })
    let colour = NSMenuItem(title: "Colour", action: nil, keyEquivalent: "")
    let colours = NSMenu()
    for (name, hex) in [("Lavender", nil as String?)] + ProfileColor.presets.map({ ($0.name, $0.hex as String?) }) {
      let entry = item(name) { SettingsDataProfile.window?.setProfileColor(info.directory, hex) }
      entry.state = info.color == hex ? .on : .off
      entry.image = ProfileInfo.avatar(ProfileInfo(directory: info.directory, name: " ", color: hex, source: nil), size: 12)
      colours.addItem(entry)
    }
    colours.addItem(.separator())
    colours.addItem(item("Custom…") { [weak self] in
      guard let self, let button = self.moreButtons[Self.key(info.directory)] else { return }
      ColorPadPopup.show(from: button, hex: info.color) { hex in SettingsDataProfile.window?.setProfileColor(info.directory, hex) }
    })
    colour.submenu = colours
    menu.addItem(colour)
    if infos.count > 1 {
      menu.addItem(.separator())
      menu.addItem(item("Copy to Another Profile…") { ProfileCopy.ask(from: info.directory) })
    }
    if info.directory != nil {
      menu.addItem(.separator())
      menu.addItem(item("Delete Profile…") { [weak self] in self?.askDelete(info) })
    }
    return menu
  }

  private func beginRename(_ directory: String?) {
    renaming = Self.key(directory)
    renameField = nil
    rebuild()
    if let field = renameField {
      field.window?.makeFirstResponder(field.field)
      field.field.currentEditor()?.selectAll(nil)
    }
  }

  private func commitRename() {
    guard let key = renaming, let info = infos.first(where: { Self.key($0.directory) == key }),
          let text = renameField?.field.stringValue else { return endRename() }
    renaming = nil
    renameField = nil
    SettingsDataProfile.window?.renameProfile(info.directory, to: text)
    rebuild()
  }

  private func endRename() {
    renaming = nil
    renameField = nil
    rebuild()
  }

  func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
    if selector == #selector(NSResponder.insertNewline(_:)) { commitRename(); return true }
    if selector == #selector(NSResponder.cancelOperation(_:)) { endRename(); return true }
    return false
  }

  private func askDelete(_ info: ProfileInfo) {
    guard let directory = info.directory, let window = window_ else { return }
    let spaces = window.state.spaces(on: directory).map(\.name)
    let moving = spaces.isEmpty ? "" : " \(spaces.joined(separator: ", ")) \(spaces.count == 1 ? "moves" : "move") to Default."
    SettingsConfirm.ask("deleteProfile", title: "Delete the “\(info.name)” profile?",
                        message: "Its passwords, cookies, history and extensions are deleted.\(moving)",
                        confirm: "Delete") { yes in
      if yes { window.deleteProfile(directory) }
    }
  }

  func height(forWidth width: CGFloat) -> CGFloat { stack.height(forWidth: width) }

  override func layout() {
    super.layout()
    stack.frame = bounds
  }

  // MARK: Tests

  /// The nth Space as the rows list them (profile by profile).
  func spaceID(_ index: Int) -> UUID? {
    let ordered = infos.flatMap { info in spaces.filter { $0.profile == info.directory } }
    return ordered.indices.contains(index) ? ordered[index].id : nil
  }

  func pressNewSpace(_ profile: Int) -> Bool {
    guard infos.indices.contains(profile) else { return false }
    newSpace(in: infos[profile].directory)
    return true
  }

  func pressNewProfile() { newProfile() }

  func profile(_ index: Int) -> ProfileInfo? { infos.indices.contains(index) ? infos[index] : nil }

  func rename(_ index: Int, _ text: String) -> Bool {
    guard infos.indices.contains(index) else { return false }
    beginRename(infos[index].directory)
    renameField?.field.stringValue = text
    commitRename()
    return true
  }

  func chooseColour(_ index: Int, _ swatch: Int) -> Bool {
    guard infos.indices.contains(index), swatch >= 0, swatch <= ProfileColor.presets.count else { return false }
    SettingsDataProfile.window?.setProfileColor(infos[index].directory, swatch == 0 ? nil : ProfileColor.presets[swatch - 1].hex)
    return true
  }

  func pressDelete(_ index: Int) -> Bool {
    guard infos.indices.contains(index), infos[index].directory != nil else { return false }
    askDelete(infos[index])
    return true
  }

  var debug: [[String: Any]] {
    infos.map { info in
      let names = spaces.filter { $0.profile == info.directory }.map(\.name)
      return ["name": info.name, "spaces": names.joined(separator: ", "), "color": info.color ?? NSNull(),
              "renaming": renaming == Self.key(info.directory), "deletable": info.directory != nil,
              "menu": moreMenu(infos.firstIndex { $0.directory == info.directory } ?? 0)?.items
                .map { $0.isSeparatorItem ? "-" : $0.title } ?? []]
    }
  }
}

/// A profile's name being edited, at the top of its card: the field, Cancel and Save.
private final class SettingsRenameRow: NSView, SettingsSizing {
  private let field: EditorField
  private let buttons: [SettingsButton]

  init(field: EditorField, buttons: [SettingsButton]) {
    self.field = field
    self.buttons = buttons
    super.init(frame: .zero)
    addSubview(field)
    buttons.forEach { addSubview($0) }
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }

  func height(forWidth width: CGFloat) -> CGFloat { 48 }

  override func layout() {
    super.layout()
    var right = bounds.width
    for button in buttons.reversed() {
      let size = button.fittingSize
      button.frame = NSRect(x: right - size.width, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
      right -= size.width + 8
    }
    field.frame = NSRect(x: 0, y: 10, width: min(280, right - 8), height: 28)
  }
}

/// An NSMenuItem's closure.
final class MenuAction: NSObject {
  private let run: () -> Void
  init(_ run: @escaping () -> Void) { self.run = run }
  @objc func run(_ sender: Any?) { run() }
}

/// The chosen Space in Settings' own rows (as every other pane): Name, Icon, Window, Accent and Profile, then Delete
/// Space…. Every change applies at once (`applyFromSettings`).
final class SpaceSettingsEditor: NSView, SettingsSizing, NSTextFieldDelegate {
  private(set) var spaceID: UUID?
  private var list: SettingsRowList?
  private let nameField = EditorField(placeholder: "Space name")
  private var iconPopUp: SettingsPopUp?
  private var windowRow: SwatchRow?
  private var accentRow: SwatchRow?
  private var profilePopUp: SettingsPopUp?
  private var deleteButton: SettingsButton?
  private var pickingColor: WritableKeyPath<SpaceDraft, String?>?

  override var isFlipped: Bool { true }

  private var window_: BrowserWindowController? { SettingsDataProfile.window }
  private var space: Space? { spaceID.flatMap { window_?.state.space(id: $0) } }

  private var draft: SpaceDraft? {
    guard let space else { return nil }
    return SpaceDraft(name: space.name, icon: space.icon, color: space.color, accent: space.accent, profile: space.profile)
  }

  func show(_ id: UUID?) {
    list?.removeFromSuperview()
    list = nil
    spaceID = id
    guard let window = window_, let space else {
      settingsSectionResized()
      return
    }
    nameField.field.stringValue = space.name
    nameField.field.delegate = self
    nameField.field.setAccessibilityLabel("Space name")
    let name = SettingsRowView(title: "Name", detail: "", control: FixedSize(nameField, NSSize(width: 220, height: 28)))

    let icons = SettingsPopUp([("None", "")] + SpaceTheme.icons.map { (Self.iconTitle($0), $0) }, selected: space.icon ?? "")
    for item in icons.itemArray {
      guard let value = item.representedObject as? String, value.hasPrefix("sf:") else { continue }
      item.image = NSImage(systemSymbolName: String(value.dropFirst(3)), accessibilityDescription: nil)
    }
    icons.onChoose = { [weak self] value in self?.change { $0.icon = value.isEmpty ? nil : value } }
    iconPopUp = icons
    let icon = SettingsRowView(title: "Icon", detail: "", control: icons)

    let windowSwatches = SwatchRow(entries: [(nil, "Ray's")] + SpaceTheme.windows.map { ($0 as String?, $0) },
                                   none: SidebarColors.background)
    windowSwatches.compact = true
    windowSwatches.selection = space.color
    windowSwatches.onChoose = { [weak self] hex in self?.change { $0.color = hex } }
    windowSwatches.onCustomHex = { [weak self] hex in self?.change { $0.color = hex } }
    windowRow = windowSwatches
    let windowColour = SettingsRowView(title: "Window", detail: "", control: windowSwatches)

    let accentSwatches = SwatchRow(entries: [(nil, "Profile colour")] + SpaceTheme.accents.map { ($0 as String?, $0) })
    accentSwatches.compact = true
    accentSwatches.selection = space.accent
    accentSwatches.onChoose = { [weak self] hex in self?.change { $0.accent = hex } }
    accentSwatches.onCustomHex = { [weak self] hex in self?.change { $0.accent = hex } }
    accentRow = accentSwatches
    let accent = SettingsRowView(title: "Accent", detail: "", control: accentSwatches)

    let profiles = SettingsPopUp(window.profileChoices().map { ($0.title, $0.directory ?? "") } + [("-", "-"), ("New Profile", SpaceEditorView.newProfile)],
                                 selected: space.profile ?? "")
    profiles.onChoose = { [weak self] value in self?.change { $0.profile = value.isEmpty ? nil : value } }
    profilePopUp = profiles
    let profile = SettingsRowView(title: "Profile", detail: "", control: profiles)

    let delete = SettingsButton("Delete Space…", destructive: true) { [weak self] in self?.askDelete() }
    delete.isEnabled = window.state.spaces.count > 1
    deleteButton = delete
    let remove = SettingsRowView(title: "", detail: "", control: delete)

    let made = SettingsRowList(rows: [name, icon, windowColour, accent, profile, remove])
    addSubview(made)
    list = made
    settingsSectionResized()
    needsLayout = true
  }

  private static func iconTitle(_ icon: String) -> String {
    icon.hasPrefix("sf:") ? String(icon.dropFirst(3)).replacingOccurrences(of: ".fill", with: "").capitalized : icon
  }

  private func change(_ edit: (inout SpaceDraft) -> Void) {
    guard let window = window_, let space, var draft else { return }
    edit(&draft)
    window.applyFromSettings(draft, to: space)
  }

  func controlTextDidChange(_ obj: Notification) {
    let text = nameField.field.stringValue
    guard Space.name(from: text) != nil else { return }
    change { $0.name = text }
  }

  private func pickColor(_ path: WritableKeyPath<SpaceDraft, String?>) {
    pickingColor = path
    let panel = NSColorPanel.shared
    panel.showsAlpha = false
    panel.setTarget(self)
    panel.setAction(#selector(colorPicked(_:)))
    if !TestEnvironment.isTestBuild { panel.orderFront(nil) }
  }

  @objc private func colorPicked(_ panel: NSColorPanel) {
    guard let path = pickingColor else { return }
    let hex = ProfileColor.hex(of: panel.color)
    change { $0[keyPath: path] = hex }
  }

  private func askDelete() {
    guard let window = window_, let space, window.state.spaces.count > 1 else { return }
    let tabs = (space.pinned + space.today).filter { !$0.isFolder }.count
    SettingsConfirm.ask("deleteSpace", title: "Delete “\(space.name)”?",
                        message: tabs == 0 ? "" : "Its \(tabs == 1 ? "tab closes" : "\(tabs) tabs close"). ⇧⌘T brings them back.",
                        confirm: "Delete") { yes in
      if yes { window.deleteSpace(space) }
    }
  }

  /// Something changed elsewhere (a profile made or renamed, a colour from the sidebar): the rows show it, unless the
  /// name is being typed.
  func refreshProfiles() {
    guard nameField.field.currentEditor() == nil else { return }
    show(spaceID)
  }

  var isTyping: Bool { nameField.field.currentEditor() != nil }

  func height(forWidth width: CGFloat) -> CGFloat { list.map { sizedHeight($0, width: width) } ?? 0 }

  override func layout() {
    super.layout()
    list?.frame = bounds
  }

  // For tests: as clicks and typing would.
  func setName(_ text: String) {
    nameField.field.stringValue = text
    controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
  }

  func chooseIcon(_ index: Int) -> Bool {
    guard SpaceTheme.icons.indices.contains(index) else { return false }
    change { $0.icon = SpaceTheme.icons[index] }
    return true
  }

  func chooseWindow(_ index: Int) { change { $0.color = index == 0 ? nil : SpaceTheme.windows[min(index - 1, SpaceTheme.windows.count - 1)] } }
  func chooseAccent(_ index: Int) { change { $0.accent = index == 0 ? nil : SpaceTheme.accents[min(index - 1, SpaceTheme.accents.count - 1)] } }

  /// The nth of the Profile pop-up's choices (the last is New Profile).
  func chooseProfile(_ index: Int) -> Bool {
    guard let window = window_ else { return false }
    let choices = window.profileChoices().map(\.directory) + [SpaceEditorView.newProfile]
    guard choices.indices.contains(index) else { return false }
    change { $0.profile = choices[index] }
    return true
  }

  var canDelete: Bool { deleteButton?.isEnabled == true }
  func pressDelete() { askDelete() }

  var debug: [String: Any] {
    guard let space else { return [:] }
    return ["name": space.name, "icon": space.icon ?? NSNull(), "color": space.color ?? NSNull(),
            "accent": space.accent ?? NSNull(), "profile": space.profile ?? NSNull(),
            "profiles": (window_?.profileChoices().map(\.title) ?? []) + ["New Profile"], "rows": list?.rows.count ?? 0]
  }
}

// MARK: Tests

extension SpacesPaneContent {
  /// `spacespane state|pick <n>|new [profile]|newprofile|name <text>|icon <n>|window <n>|accent <n>|profile <n>|delete|
  /// confirm accept|cancel|profilerename <n> <text>|profilecolour <n> <swatch>|profiledelete <n>|dataprofile <n>`: the pane as clicks would drive it
  /// (`<n>` from 1; `dataprofile` picks the data panes' profile, as their pop-up would). Opens the pane if it isn't.
  static func test(_ argument: String) -> String {
    guard let content = SettingsPanes.content(for: .spaces) as? SpacesPaneContent else { return "no pane" }
    let words = argument.split(separator: " ").map(String.init)
    let number = words.count > 1 ? Int(words[1]).map { $0 - 1 } : nil
    let rest = words.dropFirst(2).joined(separator: " ")
    content.refresh()
    switch words.first {
    case "state":
      guard let data = try? JSONSerialization.data(withJSONObject: content.debug),
            let text = String(data: data, encoding: .utf8) else { return "{}" }
      return text
    case "pick":
      guard let number, let id = content.groups.spaceID(number) else { return "no such space" }
      if content.groups.selected != id { content.groups.select(id) }
    case "new":
      // `new [profile]`: New Space… in a profile's group (1 = Default).
      guard content.groups.pressNewSpace(number ?? 0) else { return "no profile" }
    case "newprofile": content.groups.pressNewProfile()
    case "name": content.editor.setName(words.dropFirst().joined(separator: " "))
    case "icon":
      guard let number, content.editor.chooseIcon(number) else { return "no icon" }
    case "window": content.editor.chooseWindow((number ?? -1) + 1)
    case "accent": content.editor.chooseAccent((number ?? -1) + 1)
    case "profile":
      guard let number, content.editor.chooseProfile(number) else { return "no profile" }
    case "delete":
      guard content.editor.canDelete else { return "can't delete" }
      content.editor.pressDelete()
    case "confirm": return SettingsConfirm.answer(accept: words.count > 1 && words[1] == "accept")
    case "profilerename":
      guard let number, content.groups.rename(number, rest) else { return "no profile" }
    case "profilecolour":
      guard let number, words.count > 2, let swatch = Int(words[2]), content.groups.chooseColour(number, swatch)
      else { return "no swatch" }
    case "profiledelete":
      guard let number, content.groups.pressDelete(number) else { return "can't delete" }
    case "copy":
      // `copy <n>`: Copy to Another Profile… from the nth profile; `copyform <target n> <kinds,…>`; `copygo`.
      guard let number, let info = content.groups.profile(number) else { return "no profile" }
      ProfileCopy.ask(from: info.directory)
      guard ProfileCopy.pending != nil else { return "not asked" }
    case "copyform":
      guard let number, let form = ProfileCopy.pending else { return "no form" }
      let kinds = Set(words.dropFirst(2).joined(separator: ",").split(separator: ",").compactMap { ProfileCopy.Kind(rawValue: String($0)) })
      form.set(kinds, target: number)
    case "copygo":
      guard let question = ProfileCopy.pendingQuestion, question.buttons.count > 1, question.buttons[1].isEnabled else { return "not ready" }
      question.buttons[1].onClick?()
    case "dataprofile":
      let infos = SettingsDataProfile.profiles
      guard let number, infos.indices.contains(number) else { return "no profile" }
      SettingsDataProfile.pick(infos[number].directory)
    default:
      return "usage: spacespane state|pick|new [profile]|newprofile|name|icon|window|accent|profile|delete|confirm|profilerename|profilecolour|profiledelete|copy|copyform|copygo|dataprofile"
    }
    return "ok"
  }
}
