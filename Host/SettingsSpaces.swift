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
        id: "spaces.list", title: "Spaces", place: .top, view: pictures, card: false,
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
    if editor.spaceID == nil || editor.spaceID.flatMap(window.state.space(id:)) == nil {
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

/// The chosen Space's editor, on its card.
final class SpaceSettingsEditor: NSView, SettingsSizing {
  private(set) var spaceID: UUID?
  private(set) var editor: SpaceEditorView?

  override var isFlipped: Bool { true }

  func show(_ id: UUID?) {
    editor?.removeFromSuperview()
    editor = nil
    spaceID = id
    guard let window = SettingsDataProfile.window, let id, let space = window.state.space(id: id) else {
      settingsSectionResized()
      return
    }
    let draft = SpaceDraft(name: space.name, icon: space.icon, color: space.color, accent: space.accent, profile: space.profile)
    let made = SpaceEditorView(draft: draft, isNew: false, profiles: window.profileChoices(), inSettings: true)
    made.onChange = { [weak window, weak space] draft in
      guard let window, let space else { return }
      window.applyFromSettings(draft, to: space)
    }
    made.deleteButton.isEnabled = window.state.spaces.count > 1
    made.onDelete = { [weak window, weak space] in
      guard let window, let space, window.state.spaces.count > 1 else { return }
      let tabs = (space.pinned + space.today).filter { !$0.isFolder }.count
      SettingsConfirm.ask("deleteSpace", title: "Delete “\(space.name)”?",
                          message: tabs == 0 ? "" : "Its \(tabs == 1 ? "tab closes" : "\(tabs) tabs close"). ⇧⌘T brings them back.",
                          confirm: "Delete") { yes in
        if yes { window.deleteSpace(space) }
      }
    }
    addSubview(made)
    editor = made
    settingsSectionResized()
    needsLayout = true
  }

  /// A profile made or renamed elsewhere: the editor's pop-up lists it (the editor is rebuilt; it holds no typing then).
  func refreshProfiles() {
    guard let editor, let window = SettingsDataProfile.window else { return }
    let names = window.profileChoices().map(\.title)
    if editor.profileTitles != names, !editor.isTyping { show(spaceID) }
  }

  func height(forWidth width: CGFloat) -> CGFloat { editor?.height(forWidth: width) ?? 0 }

  override func layout() {
    super.layout()
    editor?.fit(width: bounds.width)
    editor?.frame.origin = .zero
  }

  var debug: [String: Any] { editor?.debug ?? [:] }
}

// MARK: Profiles

/// Each profile: its avatar, name and Spaces; opened, its name, colour and Delete Profile… (not Default's).
final class ProfilesListView: NSView, SettingsSizing {
  private var rows: [SettingsItemRow] = []
  private var opened: Set<String> = []
  private(set) var infos: [ProfileInfo] = []
  private var nameFields: [String: EditorField] = [:]
  private var deleteButtons: [String: SettingsButton] = [:]

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
    var swatches: [NSView] = []
    for hex in [nil] + SpaceTheme.accents.map(Optional.some) {
      let swatch = SettingsButton(hex == nil ? "None" : " ")
      swatch.wantsLayer = true
      if let hex, let rgb = ProfileColor.parse(hex) {
        swatch.layer?.backgroundColor = NSColor(srgbRed: rgb.r, green: rgb.g, blue: rgb.b, alpha: 1).cgColor
      }
      swatch.onClick = { SettingsDataProfile.window?.setProfileColor(info.directory, hex) }
      swatch.setAccessibilityLabel(hex ?? "None")
      swatches.append(swatch)
    }
    let delete = SettingsButton("Delete Profile…", destructive: true) { [weak self] in self?.askDelete(info) }
    delete.isHidden = info.directory == nil
    deleteButtons[key] = delete
    return ProfileBody(name: name, swatches: swatches, delete: delete)
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
  private let swatches: [NSView]
  private let delete: SettingsButton
  private let colourLabel = settingsLabel("Colour", size: 12, color: .secondaryLabelColor)

  init(name: EditorField, swatches: [NSView], delete: SettingsButton) {
    self.name = name
    self.swatches = swatches
    self.delete = delete
    super.init(frame: .zero)
    ([name, colourLabel, delete] + swatches).forEach(addSubview)
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }

  func height(forWidth width: CGFloat) -> CGFloat { delete.isHidden ? 82 : 120 }

  override func layout() {
    super.layout()
    name.frame = NSRect(x: 0, y: 4, width: min(bounds.width, 280), height: 28)
    let labelHeight = colourLabel.intrinsicContentSize.height
    colourLabel.frame = NSRect(x: 0, y: 44 + (22 - labelHeight) / 2, width: 50, height: labelHeight)
    var x: CGFloat = 54
    for swatch in swatches {
      let width: CGFloat = swatch === swatches.first ? 52 : 22
      swatch.frame = NSRect(x: x, y: 44, width: width, height: 22)
      swatch.layer?.cornerRadius = swatch === swatches.first ? 6 : 11
      x += width + 6
    }
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
    case "name": content.editor.editor?.setName(words.dropFirst().joined(separator: " "))
    case "icon":
      guard let number, content.editor.editor?.choose(iconAt: number) == true else { return "no icon" }
    case "window": content.editor.editor?.choose(window: number.map { $0 + 1 }, accent: nil)
    case "accent": content.editor.editor?.choose(window: nil, accent: number.map { $0 + 1 })
    case "profile":
      guard let number, content.editor.editor?.chooseProfile(number) == true else { return "no profile" }
    case "delete":
      guard let editor = content.editor.editor, editor.deleteButton.isEnabled else { return "can't delete" }
      editor.onDelete?()
    case "confirm": return SettingsConfirm.answer(accept: words.count > 1 && words[1] == "accept")
    case "profileopen":
      guard let number, content.profiles.toggle(number) else { return "no profile" }
    case "profilerename":
      guard let number, content.profiles.rename(number, rest) else { return "no profile" }
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
