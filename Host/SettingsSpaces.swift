import AppKit

/// Settings › Spaces (owner's pick C of `docs/mocks/settings-spaces.html`, 2026-11-25): every Space as a small picture
/// of the window in its theme, the chosen one's editor under them (the sidebar's `SpaceEditorView`, every change at
/// once, Delete Space…), then Profiles: each profile with its Spaces, opening to its name, colour and Delete Profile…
/// (owner's pick 2A: its Spaces move to Default). It acts on the normal window (`SettingsDataProfile.window`).
final class SpacesPaneContent: SettingsPaneContent {
  let pictures = SpacePicturesView()
  let editor = SpaceSettingsEditor()
  let profiles = ProfilesListView()
  private var observer: NSObjectProtocol?

  init() {
    pictures.onSelect = { [weak self] id in self?.editor.show(id) }
    pictures.onNew = { [weak self] in
      guard let space = SettingsDataProfile.window?.addSpaceFromSettings() else { return }
      self?.pictures.selected = space.id
      self?.editor.show(space.id)
    }
    observer = NotificationCenter.default.addObserver(forName: BrowserWindowController.spacesDidChange, object: nil,
                                                      queue: .main) { [weak self] _ in self?.refresh() }
    refresh()
  }

  deinit { observer.map(NotificationCenter.default.removeObserver) }

  var hasContent: Bool { true }

  func sections() -> [SettingsSection] {
    [
      SettingsSection(
        id: "spaces.list", place: .top, view: pictures, card: false,
        search: [SettingsSearchEntry(title: "Spaces", detail: "Each Space's name, icon, colours and profile",
                                     keywords: ["space", "spaces", "theme", "colour", "color", "icon", "emoji", "new space",
                                                "delete space", "rename space"])]),
      SettingsSection(id: "spaces.editor", place: .top, view: editor),
      SettingsSection(
        id: "spaces.profiles", title: "Profiles", place: .bottom, view: profiles,
        search: [SettingsSearchEntry(title: "Profiles", detail: "Separate logins, history and passwords for Spaces",
                                     keywords: ["profile", "profiles", "accounts", "delete profile", "rename profile"])]),
    ]
  }

  func refresh() {
    guard let window = SettingsDataProfile.window else { return }
    let spaces = window.state.spaces
    if pictures.selected.flatMap(window.state.space(id:)) == nil { pictures.selected = window.state.current.id }
    pictures.show(spaces, profiles: window.state.profiles)
    if editor.spaceID != pictures.selected || editor.spaceID.flatMap(window.state.space(id:)) == nil {
      editor.show(pictures.selected)
    } else {
      editor.refreshProfiles()
    }
    profiles.show(window.state.profiles, spaces: spaces)
  }

  var debug: [String: Any] {
    ["selected": pictures.selected?.uuidString ?? NSNull(), "pictures": pictures.count, "editor": editor.debug,
     "profiles": profiles.debug, "dataProfile": SettingsDataProfile.debug]
  }
}

// MARK: Pictures

/// The Spaces as pictures, three a row, then "New Space"; a click chooses the one the editor shows.
final class SpacePicturesView: NSView, SettingsSizing {
  static let columns = 3
  static let cellHeight: CGFloat = 112
  private var cells: [SpacePictureCell] = []
  private let newCell = SpacePictureCell(space: nil, profile: nil)
  var selected: UUID?
  var onSelect: ((UUID) -> Void)?
  var onNew: (() -> Void)?
  var count: Int { cells.count }

  override init(frame: NSRect) {
    super.init(frame: frame)
    newCell.onClick = { [weak self] in self?.onNew?() }
    addSubview(newCell)
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }

  func show(_ spaces: [Space], profiles: [ProfileInfo]) {
    cells.forEach { $0.removeFromSuperview() }
    cells = spaces.map { space in
      let cell = SpacePictureCell(space: space, profile: profiles.count > 1 ? profiles.first { $0.directory == space.profile } : nil)
      cell.chosen = space.id == selected
      cell.onClick = { [weak self] in
        self?.selected = space.id
        self?.cells.forEach { $0.chosen = $0.spaceID == space.id }
        self?.onSelect?(space.id)
      }
      addSubview(cell)
      return cell
    }
    settingsSectionResized()
    needsLayout = true
  }

  func height(forWidth width: CGFloat) -> CGFloat {
    let rows = (cells.count + 1 + Self.columns - 1) / Self.columns
    return CGFloat(rows) * Self.cellHeight + CGFloat(max(0, rows - 1)) * 12
  }

  override func layout() {
    super.layout()
    let gap: CGFloat = 12
    let width = (bounds.width - gap * CGFloat(Self.columns - 1)) / CGFloat(Self.columns)
    for (index, cell) in (cells + [newCell]).enumerated() {
      let column = index % Self.columns, row = index / Self.columns
      cell.frame = NSRect(x: CGFloat(column) * (width + gap), y: CGFloat(row) * (Self.cellHeight + gap), width: width,
                          height: Self.cellHeight).integral
    }
  }

  func press(_ index: Int) -> Bool {
    let all = cells + [newCell]
    guard all.indices.contains(index) else { return false }
    all[index].onClick?()
    return true
  }
}

/// One Space as a small window in its theme (its Window colour around a sidebar and a page), its icon and name
/// under it, and its profile when there's more than one; "New Space" when it has none.
final class SpacePictureCell: NSView {
  let spaceID: UUID?
  private let space: Space?
  private let profile: ProfileInfo?
  var onClick: (() -> Void)?
  var chosen = false { didSet { needsDisplay = true } }

  init(space: Space?, profile: ProfileInfo?) {
    self.space = space
    spaceID = space?.id
    self.profile = profile
    super.init(frame: .zero)
    setAccessibilityRole(.button)
    setAccessibilityLabel(space?.name ?? "New Space")
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }
  override var mouseDownCanMoveWindow: Bool { false }
  override func mouseDown(with event: NSEvent) {}
  override func mouseUp(with event: NSEvent) {
    if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
  }
  override func accessibilityPerformPress() -> Bool {
    onClick?()
    return true
  }

  override func draw(_ dirtyRect: NSRect) {
    let card = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 10, yRadius: 10)
    SettingsColors.card.setFill()
    card.fill()
    let picture = NSRect(x: 7, y: 7, width: bounds.width - 14, height: bounds.height - 40)
    guard let space else {
      let dashed = NSBezierPath(roundedRect: picture, xRadius: 6, yRadius: 6)
      dashed.lineWidth = 1
      dashed.setLineDash([4, 3], count: 2, phase: 0)
      NSColor.tertiaryLabelColor.setStroke()
      dashed.stroke()
      let plus = NSAttributedString(string: "+", attributes: [.font: NSFont.systemFont(ofSize: 22, weight: .light),
                                                              .foregroundColor: NSColor.secondaryLabelColor])
      let size = plus.size()
      plus.draw(at: NSPoint(x: picture.midX - size.width / 2, y: picture.midY - size.height / 2))
      label("New Space", nil, at: picture.maxY)
      edge(card)
      return
    }
    SpaceLook.windowColor(space.color).setFill()
    NSBezierPath(roundedRect: picture, xRadius: 6, yRadius: 6).fill()
    let side = NSRect(x: picture.minX + 5, y: picture.minY + 6, width: picture.width * 0.3, height: picture.height - 12)
    NSColor.labelColor.withAlphaComponent(0.13).setFill()
    for (index, fraction) in [0.75, 0.9, 0.6, 0.8].enumerated() {
      NSBezierPath(roundedRect: NSRect(x: side.minX, y: side.minY + CGFloat(index) * 9, width: side.width * fraction, height: 5),
                   xRadius: 2.5, yRadius: 2.5).fill()
    }
    let page = NSRect(x: side.maxX + 5, y: picture.minY + 4, width: picture.maxX - side.maxX - 9, height: picture.height - 8)
    NSColor.textBackgroundColor.setFill()
    NSBezierPath(roundedRect: page, xRadius: 4, yRadius: 4).fill()
    label("\(SpaceIcon.prefix(for: space))\(space.name)", profile?.name, at: picture.maxY)
    edge(card)
  }

  private func label(_ title: String, _ caption: String?, at top: CGFloat) {
    let text = NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium),
                                                              .foregroundColor: NSColor.labelColor])
    text.draw(with: NSRect(x: 10, y: top + 8, width: bounds.width - 20 - (caption == nil ? 0 : 60), height: 18),
              options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    if let caption {
      let small = NSAttributedString(string: caption, attributes: [.font: NSFont.systemFont(ofSize: 11),
                                                                   .foregroundColor: NSColor.secondaryLabelColor])
      let size = small.size()
      small.draw(at: NSPoint(x: bounds.width - 10 - min(size.width, 56), y: top + 9))
    }
  }

  private func edge(_ card: NSBezierPath) {
    if chosen {
      let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.25, dy: 1.25), xRadius: 10, yRadius: 10)
      ring.lineWidth = 2.5
      ProfileColor.visible(on: SettingsColors.content).setStroke()
      ring.stroke()
    } else {
      card.lineWidth = 0.5
      SettingsColors.cardEdge.setStroke()
      card.stroke()
    }
  }
}

// MARK: Editor

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
    windowSwatches.onCustom = { [weak self] in self?.pickColor(\.color) }
    windowRow = windowSwatches
    let windowColour = SettingsRowView(title: "Window", detail: "", control: windowSwatches)

    let accentSwatches = SwatchRow(entries: [(nil, "Profile colour")] + SpaceTheme.accents.map { ($0 as String?, $0) })
    accentSwatches.compact = true
    accentSwatches.selection = space.accent
    accentSwatches.onChoose = { [weak self] hex in self?.change { $0.accent = hex } }
    accentSwatches.onCustom = { [weak self] in self?.pickColor(\.accent) }
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

// MARK: Profiles

/// Each profile: its avatar, name and Spaces; opened, its name, colour and Delete Profile… (not Default's).
final class ProfilesListView: NSView, SettingsSizing {
  private var rows: [SettingsItemRow] = []
  private var opened: Set<String> = []
  private(set) var infos: [ProfileInfo] = []
  private var nameFields: [String: EditorField] = [:]
  private var deleteButtons: [String: SettingsButton] = [:]
  private var swatchRows: [String: SwatchRow] = [:]
  private var colourFor: String??

  override var isFlipped: Bool { true }

  private static func key(_ directory: String?) -> String { directory ?? "default" }

  func show(_ profiles: [ProfileInfo], spaces: [Space]) {
    // Typing in a name keeps its row: nothing rebuilds under the field.
    if nameFields.values.contains(where: { $0.field.currentEditor() != nil }), profiles.map(\.directory) == infos.map(\.directory) {
      return
    }
    infos = profiles
    rows.forEach { $0.removeFromSuperview() }
    nameFields = [:]
    deleteButtons = [:]
    swatchRows = [:]
    rows = profiles.map { info in
      let key = Self.key(info.directory)
      let names = spaces.filter { $0.profile == info.directory }.map(\.name)
      let row = SettingsItemRow(key: key, icon: ProfileInfo.avatar(info, size: 22), title: info.name,
                                detail: names.isEmpty ? "No Spaces" : names.joined(separator: ", "),
                                body: body(for: info), open: opened.contains(key))
      row.onToggle = { [weak self, weak row] open in
        if open { self?.opened.insert(key) } else { self?.opened.remove(key) }
        row?.settingsSectionResized()
      }
      addSubview(row)
      return row
    }
    settingsSectionResized()
    needsLayout = true
  }

  private func body(for info: ProfileInfo) -> NSView {
    let key = Self.key(info.directory)
    let name = EditorField(placeholder: "Profile name")
    name.field.stringValue = info.name
    name.field.target = self
    name.field.action = #selector(nameCommitted(_:))
    name.field.identifier = NSUserInterfaceItemIdentifier(key)
    nameFields[key] = name
    // Appearance's own swatch row: lavender (nil), the presets and any colour, the chosen one marked.
    let swatches = SwatchRow()
    swatches.compact = true
    swatches.selection = info.color
    swatches.onChoose = { hex in SettingsDataProfile.window?.setProfileColor(info.directory, hex) }
    swatches.onCustom = { [weak self] in self?.pickColour(for: info) }
    swatchRows[key] = swatches
    let delete = SettingsButton("Delete Profile…", destructive: true) { [weak self] in self?.askDelete(info) }
    delete.isHidden = info.directory == nil
    deleteButtons[key] = delete
    return ProfileBody(name: name, swatches: swatches, delete: delete)
  }

  /// Custom Colour…: macOS's colour panel, followed live.
  private func pickColour(for info: ProfileInfo) {
    colourFor = .some(info.directory)
    let panel = NSColorPanel.shared
    panel.showsAlpha = false
    panel.setTarget(self)
    panel.setAction(#selector(colourPicked(_:)))
    if !TestEnvironment.isTestBuild { panel.orderFront(nil) }
  }

  @objc private func colourPicked(_ panel: NSColorPanel) {
    guard let directory = colourFor else { return }
    SettingsDataProfile.window?.setProfileColor(directory, ProfileColor.hex(of: panel.color))
  }

  func chooseColour(_ index: Int, _ swatch: Int) -> Bool {
    guard infos.indices.contains(index), let row = swatchRows[Self.key(infos[index].directory)] else { return false }
    return row.press(index: swatch)
  }

  @objc private func nameCommitted(_ field: NSTextField) {
    guard let key = field.identifier?.rawValue, let info = infos.first(where: { Self.key($0.directory) == key }) else { return }
    SettingsDataProfile.window?.renameProfile(info.directory, to: field.stringValue)
  }

  private func askDelete(_ info: ProfileInfo) {
    guard let directory = info.directory, let window = SettingsDataProfile.window else { return }
    let spaces = window.state.spaces(on: directory).map(\.name)
    let moving = spaces.isEmpty ? "" : " \(spaces.joined(separator: ", ")) \(spaces.count == 1 ? "moves" : "move") to Default."
    SettingsConfirm.ask("deleteProfile", title: "Delete the “\(info.name)” profile?",
                        message: "Its passwords, cookies, history and extensions are deleted.\(moving)",
                        confirm: "Delete") { yes in
      if yes { window.deleteProfile(directory) }
    }
  }

  func height(forWidth width: CGFloat) -> CGFloat { rows.reduce(0) { $0 + $1.height(forWidth: width) } }

  override func layout() {
    super.layout()
    var y: CGFloat = 0
    for row in rows {
      let height = row.height(forWidth: bounds.width)
      row.frame = NSRect(x: 0, y: y, width: bounds.width, height: height)
      y += height
    }
  }

  // For tests.
  func toggle(_ index: Int) -> Bool {
    guard rows.indices.contains(index) else { return false }
    rows[index].toggle()
    return true
  }

  func rename(_ index: Int, _ text: String) -> Bool {
    guard infos.indices.contains(index), let field = nameFields[Self.key(infos[index].directory)]?.field else { return false }
    field.stringValue = text
    nameCommitted(field)
    return true
  }

  func pressDelete(_ index: Int) -> Bool {
    guard infos.indices.contains(index), let button = deleteButtons[Self.key(infos[index].directory)], !button.isHidden
    else { return false }
    button.onClick?()
    return true
  }

  var debug: [[String: Any]] {
    zip(infos, rows).map { info, row in
      ["name": info.name, "spaces": row.detail, "open": row.isOpen, "deletable": info.directory != nil]
    }
  }
}

/// A profile's row opened: its name, colour swatches and Delete Profile….
private final class ProfileBody: NSView, SettingsSizing {
  private let name: EditorField
  private let swatches: SwatchRow
  private let delete: SettingsButton
  private let colourLabel = settingsLabel("Colour", size: 12, color: .secondaryLabelColor)

  init(name: EditorField, swatches: SwatchRow, delete: SettingsButton) {
    self.name = name
    self.swatches = swatches
    self.delete = delete
    super.init(frame: .zero)
    [name, colourLabel, swatches, delete].forEach(addSubview)
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }

  func height(forWidth width: CGFloat) -> CGFloat { delete.isHidden ? 82 : 120 }

  override func layout() {
    super.layout()
    name.frame = NSRect(x: 0, y: 4, width: min(bounds.width, 280), height: 28)
    let labelHeight = colourLabel.intrinsicContentSize.height
    colourLabel.frame = NSRect(x: 0, y: 44 + (22 - labelHeight) / 2, width: 50, height: labelHeight)
    let size = swatches.fittingSize
    swatches.frame = NSRect(x: 56, y: 44 + (22 - size.height) / 2, width: size.width, height: size.height).integral
    delete.frame = NSRect(x: 0, y: 82, width: max(delete.fittingSize.width, 130), height: 28)
  }
}

// MARK: Tests

extension SpacesPaneContent {
  /// `spacespane state|pick <n>|new|name <text>|icon <n>|window <n>|accent <n>|profile <n>|delete|confirm accept|cancel|
  /// profileopen <n>|profilerename <n> <text>|profiledelete <n>|dataprofile <n>`: the pane as clicks would drive it
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
      guard let number, content.pictures.press(number) else { return "no such space" }
    case "new":
      guard content.pictures.press(content.pictures.count) else { return "no new" }
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
    case "profileopen":
      guard let number, content.profiles.toggle(number) else { return "no profile" }
    case "profilerename":
      guard let number, content.profiles.rename(number, rest) else { return "no profile" }
    case "profilecolour":
      guard let number, words.count > 2, let swatch = Int(words[2]), content.profiles.chooseColour(number, swatch)
      else { return "no swatch" }
    case "profiledelete":
      guard let number, content.profiles.pressDelete(number) else { return "can't delete" }
    case "dataprofile":
      let infos = SettingsDataProfile.profiles
      guard let number, infos.indices.contains(number) else { return "no profile" }
      SettingsDataProfile.pick(infos[number].directory)
    default:
      return "usage: spacespane state|pick|new|name|icon|window|accent|profile|delete|confirm|profileopen|profilerename|profiledelete|dataprofile"
    }
    return "ok"
  }
}
