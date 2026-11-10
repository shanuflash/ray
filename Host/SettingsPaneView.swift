import AppKit

/// One pane of the Settings window, the scroll view's document: the pane's name large, its call to action, then its
/// groups. Rows come from the catalog (`SettingPane.shownSettings`, grouped by `group`, rare ones at the end of their
/// group); the pane's `SettingsPaneContent` adds sections, header controls, custom controls and live pictures. One
/// column, at most 600 pt wide with 24 pt sides, on the content grey; each group is a header (13 pt semibold, 7 pt
/// above its card) and a rounded card (`SettingsCardBox`: 10 pt corners, rows 14 pt in, 44 pt rows split by inset
/// hairlines), 24 pt apart. Every control sets its setting through `RaySettings.apply`, as the test command `setting`
/// does.
final class SettingsPaneView: NSView {
  static let maxColumn: CGFloat = 600
  static let side: CGFloat = 24
  static let top: CGFloat = 34
  /// Between groups (and sections), and from a header to its card.
  static let groupGap: CGFloat = 24
  static let headerGap: CGFloat = 7
  /// A header's text starts this far in from the card's edge.
  static let headerInset: CGFloat = 4

  let pane: SettingPane

  /// A setting's control, as the pane built it.
  enum Control {
    case toggle(RaySwitch)
    case choice(NSPopUpButton)
    case segmented(RaySegmentedControl, [SettingChoice])
    case picture(PictureChoiceControl)
    case colour(SwatchRow)
    case custom(NSView)
  }

  private enum Block {
    case callToAction(NSView)
    case group(SettingsGroupView)
    case section(id: String, header: NSTextField?, view: NSView, box: SettingsCardBox?)
    /// An untitled section right after a group: it joins that group's card. Only its anchor is the pane's to know.
    case merged(id: String, view: NSView)
  }

  private let titleLabel: NSTextField
  private let subtitleLabel: NSTextField
  private var blocks: [Block] = []
  private(set) var controls: [(key: AnySettingKey, control: Control)] = []
  private var settingsObservation: SettingsObservation?
  /// Called when the pane's height changes.
  var onResize: (() -> Void)?

  override var isFlipped: Bool { true }

  init(pane: SettingPane) {
    self.pane = pane
    titleLabel = settingsLabel(pane.title, size: 22, weight: .semibold)
    subtitleLabel = NSTextField(wrappingLabelWithString: "")  // The pane's title says it; its subtitle is for search.
    super.init(frame: .zero)
    subtitleLabel.font = .systemFont(ofSize: 13)
    subtitleLabel.textColor = .secondaryLabelColor
    subtitleLabel.isSelectable = false
    addSubview(titleLabel)
    addSubview(subtitleLabel)
    build()
    settingsObservation = RaySettings.shared.observe(AnySettingKey.all) { [weak self] in self?.refresh() }
    refresh()
  }

  required init?(coder: NSCoder) { fatalError() }

  private var content: SettingsPaneContent? { SettingsPanes.content(for: pane) }

  private func build() {
    if let strip = content?.callToAction() { add(.callToAction(strip)) }
    let sections = SettingsPanes.sections(for: pane)
    // Sections already in a group's card.
    var joined: Set<String> = []
    func addSections(where test: (SettingsSection.Place) -> Bool) {
      for section in sections where test(section.place) && !joined.contains(section.id) {
        let header = section.title.map { settingsLabel($0, size: 13, weight: .semibold) }
        add(.section(id: section.id, header: header, view: section.view, box: section.card ? SettingsCardBox(section.view) : nil))
      }
    }
    addSections { if case .top = $0 { return true } else { return false } }
    // The catalog's rows, by group in order of first appearance.
    var groups: [(group: SettingGroup, keys: [AnySettingKey])] = []
    for key in pane.shownSettings {
      if let index = groups.firstIndex(where: { $0.group == key.ui.group }) {
        groups[index].keys.append(key)
      } else {
        groups.append((key.ui.group, [key]))
      }
    }
    for (group, keys) in groups {
      let rows = keys.map { (key: $0, row: row(for: $0)) }
      // The group's live picture: the first one its settings have, across the top of its card.
      let picture = keys.lazy.compactMap { key in self.content?.picture(for: key).map { (key: key.id, view: $0) } }.first
      // Untitled sections that follow the group join its card; titled ones are cards of their own.
      let follows = sections.filter { if case .after(let id) = $0.place { return id == group.id } else { return false } }
      let joining = follows.filter { $0.title == nil && $0.card }
      let view = SettingsGroupView(
        group: group, accessory: content?.headerAccessory(for: group),
        rows: rows.filter { !$0.key.ui.rare }.map(\.row) + rows.filter { $0.key.ui.rare }.map(\.row),
        extra: joining.map(\.view), picture: picture)
      add(.group(view))
      for section in joining {
        add(.merged(id: section.id, view: section.view))
        joined.insert(section.id)
      }
      addSections { if case .after(let id) = $0 { return id == group.id } else { return false } }
    }
    // Sections placed after a group this pane doesn't show go at the end with the rest.
    let shownGroups = Set(groups.map(\.group.id))
    addSections {
      switch $0 {
      case .bottom: return true
      case .after(let id): return !shownGroups.contains(id)
      case .top: return false
      }
    }
  }

  private func add(_ block: Block) {
    blocks.append(block)
    switch block {
    case .callToAction(let view): addSubview(view)
    case .group(let view): addSubview(view)
    case .section(_, let header, let view, let box):
      if let header { addSubview(header) }
      addSubview(box ?? view)
    case .merged: break  // The group's card holds it.
    }
  }

  /// A setting's row: its control on the right (pictures and wide lists under its text). Every control sets the
  /// setting through `RaySettings.apply`.
  private func row(for key: AnySettingKey) -> SettingsRowView {
    let ui = key.ui
    let settings = RaySettings.shared
    let made: SettingsRowView
    switch ui.control {
    case .toggle:
      let control = RaySwitch()
      control.setAccessibilityLabel(ui.title)
      control.onChange = { on in settings.apply(key, on ? "on" : "off") }
      controls.append((key, .toggle(control)))
      made = SettingsRowView(title: ui.title, detail: ui.detail, control: control)
    case .choice(let options):
      let control = NSPopUpButton(frame: .zero, pullsDown: false)
      for option in options {
        control.addItem(withTitle: option.title)
        control.lastItem?.representedObject = option.value
      }
      control.target = self
      control.action = #selector(choiceChosen(_:))
      control.setAccessibilityLabel(ui.title)
      controls.append((key, .choice(control)))
      made = SettingsRowView(title: ui.title, detail: ui.detail, control: control)
    case .segmented(let options):
      let control = RaySegmentedControl(titles: options.map(\.title))
      control.setAccessibilityLabel(ui.title)
      control.onChoose = { index in settings.apply(key, options[index].value) }
      controls.append((key, .segmented(control, options)))
      made = SettingsRowView(title: ui.title, detail: ui.detail, control: control)
    case .picture(let options, let draw):
      let control = PictureChoiceControl(choices: options, picture: draw)
      control.setAccessibilityLabel(ui.title)
      control.onChoose = { value in settings.apply(key, value) }
      controls.append((key, .picture(control)))
      // The pictures and their captions say it: no title over them.
      made = SettingsRowView(title: "", detail: ui.detail, accessory: control)
    case .colour:
      let swatches = SwatchRow()
      swatches.compact = true
      swatches.onChoose = { hex in settings.apply(key, hex ?? "default") }
      swatches.onCustom = { [weak self] in self?.openColorPanel(for: key) }
      controls.append((key, .colour(swatches)))
      made = SettingsRowView(title: ui.title, detail: ui.detail, control: swatches)
    case .custom(let name):
      let control = content?.control(named: name, for: key)
      if let control { controls.append((key, .custom(control))) }
      // A list (Settings › Search's engines) sits under the row's text at full width, as swatches do.
      let wide = control is SettingsWideControl
      made = SettingsRowView(title: ui.title, detail: ui.detail, control: wide ? nil : control, accessory: wide ? control : nil)
    }
    made.anchor = key.id
    return made
  }

  /// Shows the settings as they are now.
  func refresh() {
    let settings = RaySettings.shared
    for (key, control) in controls {
      let text = settings.text(of: key)
      switch control {
      case .toggle(let toggle): toggle.isOn = text == "on"
      case .choice(let popup):
        if let index = popup.itemArray.firstIndex(where: { $0.representedObject as? String == text }) { popup.selectItem(at: index) }
      case .segmented(let segmented, let options): segmented.selectedIndex = options.firstIndex { $0.value == text } ?? -1
      case .picture(let pictures): pictures.selection = text
      case .colour(let swatches): swatches.selection = text == "default" ? nil : text
      case .custom: break
      }
    }
  }

  @objc private func choiceChosen(_ popup: NSPopUpButton) {
    guard let entry = controls.first(where: { if case .choice(let control) = $0.control { return control === popup } else { return false } }),
          let value = popup.selectedItem?.representedObject as? String else { return }
    RaySettings.shared.apply(entry.key, value)
  }

  // MARK: Anchors

  /// The view a search result or `ray://settings/<pane>` names: a setting's row by its id, or a section by its id.
  func anchorView(_ id: String) -> NSView? {
    for block in blocks {
      switch block {
      case .group(let group):
        if let row = group.row(anchored: id) { return row }
      case .section(let sectionID, _, let view, _) where sectionID == id: return view
      case .merged(let sectionID, let view) where sectionID == id: return view
      default: continue
      }
    }
    return nil
  }

  /// Every row and section the pane shows, by id.
  var anchors: [String] {
    blocks.flatMap { block -> [String] in
      switch block {
      case .group(let group): return group.anchors
      case .section(let id, _, _, _), .merged(let id, _): return [id]
      case .callToAction: return []
      }
    }
  }

  // MARK: Tests

  /// `<id>` presses a switch; `<id> <n>` picks a pop-up's item, a segment, a picture or a colour's swatch.
  func press(_ words: [String]) -> Bool {
    guard let id = words.first, let entry = controls.first(where: { $0.key.id == id }) else { return false }
    let index = words.count == 2 ? Int(words[1]) : nil
    switch entry.control {
    case .toggle(let toggle):
      guard words.count == 1 else { return false }
      toggle.press()
      return true
    case .choice(let popup):
      guard let index, index >= 0, index < popup.numberOfItems else { return false }
      popup.selectItem(at: index)
      choiceChosen(popup)
      return true
    case .segmented(let segmented, _):
      guard let index else { return false }
      return segmented.press(index)
    case .picture(let pictures):
      guard let index else { return false }
      return pictures.press(index: index)
    case .colour(let swatches):
      guard let index else { return false }
      return swatches.press(index: index)
    case .custom: return false
    }
  }

  /// Each control by its setting's id: a switch's state, a pop-up's or segmented control's title (`<id>Options`: all of
  /// them), a picture choice's value (`<id>Selected`: which), a colour's selection (`<id>Swatches`, `<id>Selected`).
  var controlsDebug: [String: Any] {
    var out: [String: Any] = [:]
    for (key, control) in controls {
      switch control {
      case .toggle(let toggle): out[key.id] = toggle.isOn
      case .choice(let popup):
        out[key.id] = popup.titleOfSelectedItem ?? ""
        out["\(key.id)Options"] = popup.itemTitles
      case .segmented(let segmented, _):
        out[key.id] = segmented.titles.indices.contains(segmented.selectedIndex) ? segmented.titles[segmented.selectedIndex] : ""
        out["\(key.id)Options"] = segmented.titles
      case .picture(let pictures):
        out[key.id] = pictures.selection ?? ""
        out["\(key.id)Selected"] = pictures.selectedIndex
      case .colour(let swatches):
        out[key.id] = swatches.selection ?? "default"
        out["\(key.id)Swatches"] = swatches.count
        out["\(key.id)Selected"] = swatches.selectedIndex
      case .custom: out[key.id] = "custom"
      }
    }
    return out
  }

  /// The live pictures on top of groups' cards, by the setting id that gave them.
  var picturesDebug: [String: Any] {
    var out: [String: Any] = [:]
    for block in blocks {
      if case .group(let group) = block, let picture = group.picture, let live = picture.view as? SettingsLivePicture {
        out[picture.key] = live.debug
      }
    }
    return out
  }

  /// Rows the pane has but doesn't show (none: every row shows, rare ones last).
  var hiddenRows: [String] {
    blocks.flatMap { block -> [String] in
      guard case .group(let group) = block else { return [] }
      return group.allRows.filter(\.isHidden).compactMap(\.anchor)
    }
  }

  // MARK: Colour panel

  /// The shared colour panel is also what a page's colour input uses: only close it if Settings opened it.
  private var ownsColorPanel = false
  /// The setting the colour panel is choosing for.
  private var colourKey: AnySettingKey?

  private func openColorPanel(for key: AnySettingKey) {
    let panel = NSColorPanel.shared
    ownsColorPanel = true
    colourKey = key
    panel.showsAlpha = false
    panel.setTarget(self)
    panel.setAction(#selector(colorPanelChanged(_:)))
    if let rgb = ProfileColor.parse(ProfileColor.hex(of: ProfileColor.accent)) {
      panel.color = NSColor(srgbRed: rgb.r, green: rgb.g, blue: rgb.b, alpha: 1)
    }
    panel.orderFront(nil)
  }

  @objc private func colorPanelChanged(_ panel: NSColorPanel) {
    guard let key = colourKey, let rgb = panel.color.usingColorSpace(.sRGB) else { return }
    func byte(_ v: CGFloat) -> Int { Int((min(1, max(0, v)) * 255).rounded()) }
    RaySettings.shared.apply(key, String(format: "#%02X%02X%02X", byte(rgb.redComponent), byte(rgb.greenComponent), byte(rgb.blueComponent)))
  }

  func closeColorPanel() {
    guard ownsColorPanel else { return }
    ownsColorPanel = false
    let panel = NSColorPanel.shared
    panel.setTarget(nil)
    panel.setAction(nil)
    panel.close()
  }

  // MARK: Layout

  /// The column: at most 600 pt, 24 pt sides, centred when the window is wider.
  private func column(_ width: CGFloat) -> (x: CGFloat, width: CGFloat) {
    let inner = min(Self.maxColumn, max(200, width - Self.side * 2))
    return (((width - inner) / 2).rounded(), inner)
  }

  /// Lays the pane out at `width` and returns its height.
  @discardableResult
  private func place(width: CGFloat, apply: Bool) -> CGFloat {
    let (x, inner) = column(width)
    var y = Self.top
    let titleHeight = ceil(titleLabel.intrinsicContentSize.height)
    if apply { titleLabel.frame = NSRect(x: x + 2, y: y, width: inner - 2, height: titleHeight) }
    y += titleHeight
    let subtitleHeight = textHeight(subtitleLabel, width: inner)
    if apply { subtitleLabel.frame = NSRect(x: x, y: y, width: inner, height: subtitleHeight) }
    y += subtitleHeight > 0 ? subtitleHeight + 6 : 0
    for block in blocks {
      switch block {
      case .callToAction(let view):
        guard !view.isHidden else { continue }  // Done already (Ray is the default browser): no room kept.
        y += 20
        let height = sizedHeight(view, width: inner)
        if apply { view.frame = NSRect(x: x, y: y, width: inner, height: height) }
        y += height
      case .group(let group):
        y += Self.groupGap
        let height = group.height(forWidth: inner)
        if apply { group.frame = NSRect(x: x, y: y, width: inner, height: height) }
        y += height
      case .section(_, let header, let view, let box):
        y += Self.groupGap
        if let header {
          let height = ceil(header.intrinsicContentSize.height)
          if apply { header.frame = NSRect(x: x + Self.headerInset, y: y, width: inner - Self.headerInset, height: height) }
          y += height + Self.headerGap
        }
        let shown: NSView = box ?? view
        let height = sizedHeight(shown, width: inner)
        if apply { shown.frame = NSRect(x: x, y: y, width: inner, height: height) }
        y += height
      case .merged: continue
      }
    }
    return y + 32
  }

  func height(forWidth width: CGFloat) -> CGFloat { place(width: width, apply: false) }

  override func layout() {
    super.layout()
    place(width: bounds.width, apply: true)
  }
}

func sizedHeight(_ view: NSView, width: CGFloat) -> CGFloat {
  (view as? SettingsSizing)?.height(forWidth: width) ?? view.fittingSize.height
}

// MARK: Group

/// A group: its header (13 pt semibold, 4 pt in, 7 pt above the card, with room for one control on the right), then
/// its card: the group's live picture across the top on a band, if it has one, then its rows (rare ones last, and
/// untitled sections placed after the group) with inset hairlines between them.
final class SettingsGroupView: NSView {
  let group: SettingGroup
  private let header: NSTextField?
  private let accessory: NSView?
  private let rows: [SettingsRowView]
  private let extra: [NSView]
  /// The live picture on top of the card, and the setting it came from.
  let picture: (key: String, view: NSView)?
  private let card: SettingsCardBox
  private let list: SettingsRowList
  private let band: SettingsPictureBand?

  var allRows: [SettingsRowView] { rows }
  var anchors: [String] { allRows.compactMap(\.anchor) }

  init(group: SettingGroup, accessory: NSView?, rows: [SettingsRowView], extra: [NSView] = [],
       picture: (key: String, view: NSView)? = nil) {
    self.group = group
    header = group.title.map { settingsLabel($0, size: 13, weight: .semibold) }
    self.accessory = accessory
    self.rows = rows
    self.extra = extra
    self.picture = picture
    list = SettingsRowList(rows: rows + extra)
    band = picture.map { SettingsPictureBand($0.view) }
    let content: NSView
    if let band {
      let stack = SettingsStack()
      stack.set([.init(view: band, bleeds: true), .init(view: list)])
      content = stack
    } else {
      content = list
    }
    card = SettingsCardBox(content)
    super.init(frame: .zero)
    if let header { addSubview(header) }
    if let accessory { addSubview(accessory) }
    addSubview(card)
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }

  func row(anchored id: String) -> SettingsRowView? { allRows.first { $0.anchor == id } }

  private var headerHeight: CGFloat {
    guard let header else { return 0 }
    return max(ceil(header.intrinsicContentSize.height), accessory?.fittingSize.height ?? 0) + SettingsPaneView.headerGap
  }

  func height(forWidth width: CGFloat) -> CGFloat {
    headerHeight + card.height(forWidth: width)
  }

  override func layout() {
    super.layout()
    if let header {
      let height = ceil(header.intrinsicContentSize.height)
      let room = headerHeight - SettingsPaneView.headerGap
      // On the line's baseline with a taller control beside it: the text sits at the bottom of the room.
      header.frame = NSRect(x: SettingsPaneView.headerInset, y: room - height, width: bounds.width * 0.6, height: height)
      if let accessory {
        let size = accessory.fittingSize
        accessory.frame = NSRect(x: bounds.width - size.width, y: room - size.height, width: size.width, height: size.height)
      }
    }
    card.frame = NSRect(x: 0, y: headerHeight, width: bounds.width, height: card.height(forWidth: bounds.width))
  }
}

// MARK: Card

/// A group's card: rounded (10 pt), the card colour with a 0.5 pt edge, its content 14 pt in from each side. Groups,
/// pane sections (unless they draw their own, `SettingsSection.card`) and the data panes' stacks
/// (`SettingsStack.cards`) sit on one.
final class SettingsCardBox: NSView, SettingsSizing {
  static let inset: CGFloat = 14
  static let radius: CGFloat = 10
  let content: NSView
  private let back = SettingsCardBackground()

  init(_ content: NSView) {
    self.content = content
    super.init(frame: .zero)
    addSubview(back)
    addSubview(content)
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }

  func height(forWidth width: CGFloat) -> CGFloat { sizedHeight(content, width: width - Self.inset * 2) }

  override func layout() {
    super.layout()
    back.frame = bounds
    content.frame = NSRect(x: Self.inset, y: 0, width: bounds.width - Self.inset * 2, height: bounds.height)
  }
}

/// The card's look alone, behind rows laid out by someone else (`SettingsStack`'s runs).
final class SettingsCardBackground: NSView {
  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.cornerRadius = SettingsCardBox.radius
    layer?.cornerCurve = .continuous
    layer?.borderWidth = 0.5
  }

  required init?(coder: NSCoder) { fatalError() }

  override var wantsUpdateLayer: Bool { true }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
  override func updateLayer() {
    layer?.backgroundColor = SettingsColors.card.cgColor
    layer?.borderColor = SettingsColors.cardEdge.cgColor
  }
}

/// A group's live picture on top of its card: centred on a band in a slightly different grey, 16 pt above and below,
/// a hairline under it. It spans the card edge to edge (the card's inset is undone), its top corners the card's.
final class SettingsPictureBand: NSView, SettingsSizing {
  private let picture: NSView
  private let line = Hairline()
  private static let padding: CGFloat = 16

  init(_ picture: NSView) {
    self.picture = picture
    super.init(frame: .zero)
    wantsLayer = true
    layer?.cornerRadius = SettingsCardBox.radius
    layer?.cornerCurve = .continuous
    layer?.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]  // The top ones (layers aren't flipped).
    addSubview(picture)
    addSubview(line)
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }
  override var wantsUpdateLayer: Bool { true }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
  override func updateLayer() { layer?.backgroundColor = SettingsColors.band.cgColor }

  func height(forWidth width: CGFloat) -> CGFloat { picture.fittingSize.height + Self.padding * 2 + 1 }

  override func layout() {
    super.layout()
    let size = picture.fittingSize
    picture.frame = NSRect(x: ((bounds.width - size.width) / 2).rounded(), y: Self.padding, width: size.width, height: size.height)
    line.frame = NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1)
  }
}

/// A hairline between rows.
final class Hairline: NSView {
  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
  }

  required init?(coder: NSCoder) { fatalError() }

  override var wantsUpdateLayer: Bool { true }
  override func updateLayer() { layer?.backgroundColor = SettingsColors.separator.cgColor }
  override func layout() {
    super.layout()
    // One device pixel.
    layer?.contentsScale = window?.backingScaleFactor ?? 2
  }
}

// MARK: Rows

/// One row: a 13 pt title over a 12 pt grey description on the left and a control on the right; or a wider accessory
/// (picture choices, a list) under the text, or alone with no title. At least 44 pt. Panes' own sections use it too
/// (`SettingsRowList`), so they look like the generated rows.
final class SettingsRowView: NSView, SettingsSizing {
  private static let padding = NSEdgeInsets(top: 11, left: 0, bottom: 11, right: 0)
  static let minHeight: CGFloat = 44

  /// The setting id (or a section's own id) search results and links scroll to.
  var anchor: String?
  private let titleLabel: NSTextField
  private let detailLabel: NSTextField
  let control: NSView?
  let accessory: NSView?

  init(title: String, detail: String, control: NSView? = nil, accessory: NSView? = nil) {
    titleLabel = NSTextField(wrappingLabelWithString: title)
    detailLabel = NSTextField(wrappingLabelWithString: detail)
    self.control = control
    self.accessory = accessory
    super.init(frame: .zero)
    wantsLayer = true
    titleLabel.font = .systemFont(ofSize: 13)
    detailLabel.font = .systemFont(ofSize: 12)
    detailLabel.textColor = .secondaryLabelColor
    for label in [titleLabel, detailLabel] {
      label.isSelectable = false
      label.cell?.wraps = true
      label.cell?.truncatesLastVisibleLine = false
      addSubview(label)
    }
    if let control { addSubview(control) }
    if let accessory { addSubview(accessory) }
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }

  var title: String { titleLabel.stringValue }
  /// The grey line under the title. A pane's own row may say something new (a folder, a status); then call
  /// `settingsPaneChanged()` so the pane makes room.
  var detail: String {
    get { detailLabel.stringValue }
    set {
      detailLabel.stringValue = newValue
      needsLayout = true
    }
  }

  private var controlSize: NSSize { control.map { $0.fittingSize } ?? .zero }

  private func textWidth(_ width: CGFloat) -> CGFloat {
    max(80, width - (control != nil ? controlSize.width + 20 : 0))
  }

  private func textBlock(_ width: CGFloat) -> (title: CGFloat, detail: CGFloat, total: CGFloat) {
    let text = textWidth(width)
    let title = textHeight(titleLabel, width: text), detail = textHeight(detailLabel, width: text)
    return (title, detail, title + (detail > 0 ? (title > 0 ? 2 : 0) + detail : 0))
  }

  /// The part above an accessory: the text and the control, or nothing with neither.
  private func topHeight(_ width: CGFloat) -> CGFloat { max(textBlock(width).total, controlSize.height) }

  /// From the top part to the accessory: 12 pt, or 3 pt for an accessory alone (with the padding, 14 pt from the top).
  private func accessoryGap(_ width: CGFloat) -> CGFloat { topHeight(width) > 0 ? 12 : 3 }

  func height(forWidth width: CGFloat) -> CGFloat {
    var height = Self.padding.top + topHeight(width) + Self.padding.bottom
    if let accessory { height += accessoryGap(width) + sizedHeight(accessory, width: width) }
    return max(height, Self.minHeight)
  }

  override var fittingSize: NSSize { NSSize(width: 400, height: height(forWidth: 400)) }

  override func layout() {
    super.layout()
    let pad = Self.padding
    let text = textWidth(bounds.width)
    let (title, detail, block) = textBlock(bounds.width)
    let side = topHeight(bounds.width)
    // Centred on the row, or on the top part above an accessory.
    let middle = accessory == nil ? bounds.height / 2 : pad.top + side / 2
    let top = middle - block / 2
    titleLabel.frame = NSRect(x: 0, y: top.rounded(), width: text, height: title)
    detailLabel.frame = NSRect(x: 0, y: (top + title + (title > 0 ? 2 : 0)).rounded(), width: text, height: detail)
    if let control {
      let size = controlSize
      control.frame = NSRect(x: bounds.width - size.width, y: (middle - size.height / 2).rounded(), width: size.width, height: size.height)
    }
    if let accessory {
      let height = sizedHeight(accessory, width: bounds.width)
      accessory.frame = NSRect(x: 0, y: (pad.top + side + accessoryGap(bounds.width)).rounded(), width: bounds.width, height: height)
    }
  }
}

/// Rows with hairlines between them, for a pane's own section.
final class SettingsRowList: NSView, SettingsSizing {
  let rows: [NSView]
  private var lines: [Hairline] = []

  init(rows: [NSView]) {
    self.rows = rows
    super.init(frame: .zero)
    for (index, row) in rows.enumerated() {
      addSubview(row)
      if index > 0 {
        let line = Hairline()
        lines.append(line)
        addSubview(line)
      }
    }
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }

  func height(forWidth width: CGFloat) -> CGFloat { rows.reduce(0) { $0 + sizedHeight($1, width: width) } }

  override func layout() {
    super.layout()
    var y: CGFloat = 0
    for (index, row) in rows.enumerated() {
      let height = sizedHeight(row, width: bounds.width)
      row.frame = NSRect(x: 0, y: y, width: bounds.width, height: height)
      if index > 0 { lines[index - 1].frame = NSRect(x: 0, y: y, width: bounds.width, height: 1) }
      y += height
    }
  }
}

/// A row's value as grey text on the right (a version number), selectable so it can be copied.
final class SettingsValueLabel: NSTextField {
  init(_ text: String) {
    super.init(frame: .zero)
    stringValue = text
    isBezeled = false
    isBordered = false
    drawsBackground = false
    isEditable = false
    isSelectable = true
    font = .systemFont(ofSize: 13)
    textColor = .secondaryLabelColor
    // One line: a wrapping field measures itself against its current frame.
    usesSingleLineMode = true
    cell?.wraps = false
    lineBreakMode = .byClipping
  }

  required init?(coder: NSCoder) { fatalError() }

  override var fittingSize: NSSize {
    let size = NSAttributedString(string: stringValue, attributes: [.font: font ?? .systemFont(ofSize: 13)]).size()
    return NSSize(width: ceil(size.width) + 6, height: ceil(intrinsicContentSize.height))
  }
}

// MARK: Flash

/// A search hit's flash: a soft wash of the profile's colour over the row, 120 ms in, 900 ms held, 700 ms out, on a
/// layer behind the row's content.
enum SettingsFlash {
  static let fadeIn = 0.12, hold = 0.9, fadeOut = 0.7
  static var duration: Double { fadeIn + hold + fadeOut }

  static func run(on view: NSView) {
    view.wantsLayer = true
    guard let host = view.layer else { return }
    host.sublayers?.filter { $0.name == "settings.flash" }.forEach { $0.removeFromSuperlayer() }
    let wash = CALayer()
    wash.name = "settings.flash"
    wash.frame = view.bounds.insetBy(dx: -10, dy: 1)
    wash.cornerRadius = 8
    wash.cornerCurve = .continuous
    view.effectiveAppearance.performAsCurrentDrawingAppearance {
      wash.backgroundColor = SettingsColors.flash.cgColor
    }
    wash.opacity = 0
    host.insertSublayer(wash, at: 0)
    let animation = CAKeyframeAnimation(keyPath: "opacity")
    animation.values = [0, 1, 1, 0]
    animation.keyTimes = [0, fadeIn / duration, (fadeIn + hold) / duration, 1].map { NSNumber(value: $0) }
    animation.duration = duration
    CATransaction.begin()
    CATransaction.setCompletionBlock { wash.removeFromSuperlayer() }
    wash.add(animation, forKey: "flash")
    CATransaction.commit()
  }
}
