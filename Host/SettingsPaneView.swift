import AppKit

/// One pane of the Settings window, the scroll view's document: the pane's name large, a grey line saying what it is
/// for, its call to action, then its groups. Rows come from the catalog (`SettingPane.shownSettings`, grouped by
/// `group`, rare ones under a "More" line at the end of their group); the pane's `SettingsPaneContent` adds sections,
/// header controls, custom controls and live pictures. One column, at most 600 pt wide with 24 pt sides; 44 pt rows
/// split by hairlines, no boxes. Every control sets its setting through `RaySettings.apply`, as the test command
/// `setting` does.
final class SettingsPaneView: NSView {
  static let maxColumn: CGFloat = 600
  static let side: CGFloat = 24
  static let top: CGFloat = 40

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
    case section(id: String, header: NSTextField?, view: NSView)
  }

  private let titleLabel: NSTextField
  private let subtitleLabel: NSTextField
  private var blocks: [Block] = []
  private(set) var controls: [(key: AnySettingKey, control: Control)] = []
  private var settingsObservation: SettingsObservation?
  /// Called when the pane's height changes (a "More" line opened).
  var onResize: (() -> Void)?

  override var isFlipped: Bool { true }

  init(pane: SettingPane) {
    self.pane = pane
    titleLabel = settingsLabel(pane.title, size: 22, weight: .medium)
    subtitleLabel = NSTextField(wrappingLabelWithString: pane.subtitle)
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
    func addSections(where test: (SettingsSection.Place) -> Bool) {
      for section in sections where test(section.place) {
        let header = section.title.map { settingsLabel($0, size: 13, weight: .semibold) }
        add(.section(id: section.id, header: header, view: section.view))
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
      let view = SettingsGroupView(
        group: group, accessory: content?.headerAccessory(for: group),
        rows: rows.filter { !$0.key.ui.rare }.map(\.row), rare: rows.filter { $0.key.ui.rare }.map(\.row))
      view.onToggle = { [weak self] in
        self?.needsLayout = true
        self?.onResize?()
      }
      add(.group(view))
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
    case .section(_, let header, let view):
      if let header { addSubview(header) }
      addSubview(view)
    }
  }

  /// A setting's row: its control on the right (or under its text for swatches and pictures), and its live picture
  /// if the pane has one. Every control sets the setting through `RaySettings.apply`.
  private func row(for key: AnySettingKey) -> SettingsRowView {
    let ui = key.ui
    let picture = content?.picture(for: key)
    let settings = RaySettings.shared
    let made: SettingsRowView
    switch ui.control {
    case .toggle:
      let control = RaySwitch()
      control.setAccessibilityLabel(ui.title)
      control.onChange = { on in settings.apply(key, on ? "on" : "off") }
      controls.append((key, .toggle(control)))
      made = SettingsRowView(title: ui.title, detail: ui.detail, control: control, picture: picture)
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
      made = SettingsRowView(title: ui.title, detail: ui.detail, control: control, picture: picture)
    case .segmented(let options):
      let control = RaySegmentedControl(titles: options.map(\.title))
      control.setAccessibilityLabel(ui.title)
      control.onChoose = { index in settings.apply(key, options[index].value) }
      controls.append((key, .segmented(control, options)))
      made = SettingsRowView(title: ui.title, detail: ui.detail, control: control, picture: picture)
    case .picture(let options, let draw):
      let control = PictureChoiceControl(choices: options, picture: draw)
      control.setAccessibilityLabel(ui.title)
      control.onChoose = { value in settings.apply(key, value) }
      controls.append((key, .picture(control)))
      made = SettingsRowView(title: ui.title, detail: ui.detail, picture: picture, accessory: control)
    case .colour:
      let swatches = SwatchRow()
      swatches.onChoose = { hex in settings.apply(key, hex ?? "default") }
      swatches.onCustom = { [weak self] in self?.openColorPanel(for: key) }
      controls.append((key, .colour(swatches)))
      made = SettingsRowView(title: ui.title, detail: ui.detail, picture: picture, accessory: swatches)
    case .custom(let name):
      let control = content?.control(named: name, for: key)
      if let control { controls.append((key, .custom(control))) }
      // A list (Settings › Search's engines) sits under the row's text at full width, as swatches do.
      let wide = control is SettingsWideControl
      made = SettingsRowView(
        title: ui.title, detail: ui.detail, control: wide ? nil : control, picture: picture, accessory: wide ? control : nil)
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
  /// A rare row's "More" opens first.
  func anchorView(_ id: String) -> NSView? {
    for block in blocks {
      switch block {
      case .group(let group):
        if let row = group.row(anchored: id) {
          group.expandIfHidden(row)
          return row
        }
      case .section(let sectionID, _, let view) where sectionID == id: return view
      default: continue
      }
    }
    return nil
  }

  /// Every row and section the pane shows, by id; rare rows behind a closed "More" too.
  var anchors: [String] {
    blocks.flatMap { block -> [String] in
      switch block {
      case .group(let group): return group.anchors
      case .section(let id, _, _): return [id]
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

  /// The live pictures beside rows, by setting id.
  var picturesDebug: [String: Any] {
    var out: [String: Any] = [:]
    for block in blocks {
      if case .group(let group) = block {
        for row in group.allRows {
          if let anchor = row.anchor, let picture = row.picture as? SettingsLivePicture { out[anchor] = picture.debug }
        }
      }
    }
    return out
  }

  /// Which groups' "More" lines are open.
  var moreOpen: [String: Bool] {
    var out: [String: Bool] = [:]
    for block in blocks {
      if case .group(let group) = block, group.hasRare { out[group.group.id] = group.expanded }
    }
    return out
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
    if apply { titleLabel.frame = NSRect(x: x, y: y, width: inner, height: titleHeight) }
    y += titleHeight + 3
    let subtitleHeight = textHeight(subtitleLabel, width: inner)
    if apply { subtitleLabel.frame = NSRect(x: x, y: y, width: inner, height: subtitleHeight) }
    y += subtitleHeight + 6
    for block in blocks {
      switch block {
      case .callToAction(let view):
        guard !view.isHidden else { continue }  // Done already (Ray is the default browser): no room kept.
        y += 16
        let height = sizedHeight(view, width: inner)
        if apply { view.frame = NSRect(x: x, y: y, width: inner, height: height) }
        y += height
      case .group(let group):
        y += 22
        let height = group.height(forWidth: inner)
        if apply { group.frame = NSRect(x: x, y: y, width: inner, height: height) }
        y += height
      case .section(_, let header, let view):
        y += 22
        if let header {
          let height = ceil(header.intrinsicContentSize.height)
          if apply { header.frame = NSRect(x: x, y: y, width: inner, height: height) }
          y += height + 8
        }
        let height = sizedHeight(view, width: inner)
        if apply { view.frame = NSRect(x: x, y: y, width: inner, height: height) }
        y += height
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

/// A group of rows: its header (13 pt semibold, 8 pt above the rows, with room for one control on the right), its
/// rows with hairlines between them, and its rare rows under a "More" line at the end.
final class SettingsGroupView: NSView {
  let group: SettingGroup
  private let header: NSTextField?
  private let accessory: NSView?
  private let rows: [SettingsRowView]
  private let rare: [SettingsRowView]
  private let more: MoreLine?
  private var lines: [NSView] = []
  private(set) var expanded = false
  var onToggle: (() -> Void)?

  var hasRare: Bool { !rare.isEmpty }
  var allRows: [SettingsRowView] { rows + rare }
  var anchors: [String] { allRows.compactMap(\.anchor) }

  init(group: SettingGroup, accessory: NSView?, rows: [SettingsRowView], rare: [SettingsRowView]) {
    self.group = group
    header = group.title.map { settingsLabel($0, size: 13, weight: .semibold) }
    self.accessory = accessory
    self.rows = rows
    self.rare = rare
    more = rare.isEmpty ? nil : MoreLine()
    super.init(frame: .zero)
    if let header { addSubview(header) }
    if let accessory { addSubview(accessory) }
    for row in rows + rare { addSubview(row) }
    for row in rare { row.isHidden = true }
    if let more {
      more.onClick = { [weak self] in self?.toggle() }
      addSubview(more)
    }
    // A hairline between each two things in the list (rows, the More line).
    for _ in 0..<max(0, rows.count + rare.count + (more == nil ? 0 : 1) - 1) {
      let line = Hairline()
      lines.append(line)
      addSubview(line)
    }
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }

  func row(anchored id: String) -> SettingsRowView? { allRows.first { $0.anchor == id } }

  func expandIfHidden(_ row: SettingsRowView) {
    if rare.contains(where: { $0 === row }), !expanded { toggle() }
  }

  func toggle() {
    expanded.toggle()
    for row in rare { row.isHidden = !expanded }
    more?.expanded = expanded
    needsLayout = true
    onToggle?()
  }

  /// What the list shows, in order.
  private var listed: [NSView] {
    var out: [NSView] = rows
    if expanded { out += rare }
    if let more { out.append(more) }
    return out
  }

  private var headerHeight: CGFloat {
    guard let header else { return 0 }
    return max(ceil(header.intrinsicContentSize.height), accessory?.fittingSize.height ?? 0) + 8
  }

  func height(forWidth width: CGFloat) -> CGFloat {
    headerHeight + listed.reduce(0) { $0 + sizedHeight($1, width: width) }
  }

  override func layout() {
    super.layout()
    var y: CGFloat = 0
    if let header {
      let height = ceil(header.intrinsicContentSize.height)
      let room = headerHeight - 8
      header.frame = NSRect(x: 0, y: ((room - height) / 2).rounded(), width: bounds.width * 0.6, height: height)
      if let accessory {
        let size = accessory.fittingSize
        accessory.frame = NSRect(x: bounds.width - size.width, y: ((room - size.height) / 2).rounded(), width: size.width, height: size.height)
      }
      y = headerHeight
    }
    let shown = listed
    for line in lines { line.isHidden = true }
    for (index, view) in shown.enumerated() {
      let height = sizedHeight(view, width: bounds.width)
      view.frame = NSRect(x: 0, y: y, width: bounds.width, height: height)
      if index > 0, index - 1 < lines.count {
        lines[index - 1].isHidden = false
        lines[index - 1].frame = NSRect(x: 0, y: y, width: bounds.width, height: 1)
      }
      y += height
    }
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

/// "More" at the end of a group with rare rows; "Less" once they show.
final class MoreLine: NSView, SettingsSizing {
  var onClick: (() -> Void)?
  var expanded = false { didSet { update() } }
  private let label = settingsLabel("More", size: 13, color: .secondaryLabelColor)
  private let chevron = NSImageView()

  override init(frame: NSRect) {
    super.init(frame: frame)
    chevron.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
    chevron.contentTintColor = .secondaryLabelColor
    addSubview(label)
    addSubview(chevron)
    setAccessibilityElement(true)
    setAccessibilityRole(.disclosureTriangle)
    update()
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }
  override var mouseDownCanMoveWindow: Bool { false }

  private func update() {
    label.stringValue = expanded ? "Less" : "More"
    chevron.image = NSImage(systemSymbolName: expanded ? "chevron.up" : "chevron.down", accessibilityDescription: nil)
    setAccessibilityLabel(label.stringValue)
    needsLayout = true
  }

  func height(forWidth width: CGFloat) -> CGFloat { 36 }

  override func layout() {
    super.layout()
    let height = ceil(label.intrinsicContentSize.height)
    let width = ceil(label.intrinsicContentSize.width) + 4
    label.frame = NSRect(x: 0, y: ((bounds.height - height) / 2).rounded(), width: width, height: height)
    chevron.frame = NSRect(x: width + 4, y: ((bounds.height - 14) / 2).rounded(), width: 12, height: 14)
  }

  override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
  override func mouseDown(with event: NSEvent) { onClick?() }
  override func accessibilityPerformPress() -> Bool {
    onClick?()
    return true
  }
}

// MARK: Rows

/// One row: a 13 pt title over a 12 pt grey description on the left; a control on the right with a live picture
/// before it; or a wider accessory (swatches, pictures) under the text. At least 44 pt. Panes' own sections use it
/// too (`SettingsRowList`), so they look like the generated rows.
final class SettingsRowView: NSView, SettingsSizing {
  private static let padding = NSEdgeInsets(top: 11, left: 0, bottom: 11, right: 0)
  static let minHeight: CGFloat = 44

  /// The setting id (or a section's own id) search results and links scroll to.
  var anchor: String?
  private let titleLabel: NSTextField
  private let detailLabel: NSTextField
  let control: NSView?
  let picture: NSView?
  let accessory: NSView?

  init(title: String, detail: String, control: NSView? = nil, picture: NSView? = nil, accessory: NSView? = nil) {
    titleLabel = NSTextField(wrappingLabelWithString: title)
    detailLabel = NSTextField(wrappingLabelWithString: detail)
    self.control = control
    self.picture = picture
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
    if let picture { addSubview(picture) }
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
  private var pictureSize: NSSize { picture.map { $0.fittingSize } ?? .zero }

  private func textWidth(_ width: CGFloat) -> CGFloat {
    var used: CGFloat = 0
    if control != nil { used += controlSize.width + 20 }
    if picture != nil { used += pictureSize.width + 20 }
    return max(80, width - used)
  }

  private func textBlock(_ width: CGFloat) -> (title: CGFloat, detail: CGFloat, total: CGFloat) {
    let text = textWidth(width)
    let title = textHeight(titleLabel, width: text), detail = textHeight(detailLabel, width: text)
    return (title, detail, title + (detail > 0 ? 2 + detail : 0))
  }

  func height(forWidth width: CGFloat) -> CGFloat {
    let block = textBlock(width).total
    var height = Self.padding.top + max(block, controlSize.height, pictureSize.height) + Self.padding.bottom
    if let accessory { height += 12 + sizedHeight(accessory, width: width) }
    return max(height, Self.minHeight)
  }

  override var fittingSize: NSSize { NSSize(width: 400, height: height(forWidth: 400)) }

  override func layout() {
    super.layout()
    let pad = Self.padding
    let text = textWidth(bounds.width)
    let (title, detail, block) = textBlock(bounds.width)
    let side = max(block, controlSize.height, pictureSize.height)
    // Centred on the row, or on the top part above an accessory.
    let middle = accessory == nil ? bounds.height / 2 : pad.top + side / 2
    let top = middle - block / 2
    titleLabel.frame = NSRect(x: 0, y: top.rounded(), width: text, height: title)
    detailLabel.frame = NSRect(x: 0, y: (top + title + 2).rounded(), width: text, height: detail)
    var right = bounds.width
    if let control {
      let size = controlSize
      control.frame = NSRect(x: right - size.width, y: (middle - size.height / 2).rounded(), width: size.width, height: size.height)
      right -= size.width + 20
    }
    if let picture {
      let size = pictureSize
      picture.frame = NSRect(x: right - size.width, y: (middle - size.height / 2).rounded(), width: size.width, height: size.height)
    }
    if let accessory {
      let height = sizedHeight(accessory, width: bounds.width)
      accessory.frame = NSRect(x: 0, y: (pad.top + side + 12).rounded(), width: bounds.width, height: height)
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
