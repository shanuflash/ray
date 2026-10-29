import AppKit

// Settings › Search (not the window's own search box, which is SettingsSearch.swift): the default engine as a list with
// Make Default (Ardia's Search pane), search suggestions, and the user's site searches with an editor in the list
// (no sheet or popover). What the settings do is SearchEngines.swift; the command bar reads them.

// MARK: Settings

// The pane's entries in the catalog (`AnySettingKey.all` lists them). They live here, beside their controls.
extension AnySettingKey {
  /// The default engine's id (`SearchEngines.builtIn`).
  static let searchEngine = SettingKey<String>(
    "searchEngine", default: "google", validate: { SearchEngines.engine(id: $0) != nil ? $0 : nil },
    ui: SettingUI(
      pane: .search, group: .searchEngine, title: "Default search engine",
      detail: "What the command bar searches when what you type isn't an address.",
      keywords: ["default search", "engine", "google", "duckduckgo", "bing", "brave", "ecosia", "kagi", "startpage",
                 "perplexity"],
      control: .custom("searchEngine")),
    customTests: (samples: ["duckduckgo", "kagi"], rejects: ["nonsense", "Google", "javascript:alert(1)"]))

  /// Suggestions from the default engine as you type in the command bar.
  static let searchSuggestions = SettingKey<Bool>(
    "searchSuggestions", default: true,
    ui: SettingUI(
      pane: .search, group: .searchSuggestions, title: "Show search suggestions",
      detail: "As you type in the command bar, your search engine suggests searches. Off: nothing you type goes to it "
        + "until you press Return.",
      keywords: ["suggestions", "autocomplete", "predictions", "privacy"], control: .toggle))

  /// The user's site searches: a keyword, then Tab or a space, scopes the command bar to a site.
  static let siteSearches = SettingKey<SiteSearchList>(
    "siteSearches", default: SiteSearchList([]), validate: SiteSearchList.validate,
    ui: SettingUI(
      pane: .search, group: .siteSearches, title: "Search a site from the command bar",
      detail: "Type a site's keyword, then Tab or a space: what you type next searches that site.",
      keywords: ["site search", "keyword", "custom search", "search engines", "tab to search"],
      control: .custom("siteSearches")),
    log: { $0.items.map(\.json) },
    customTests: (
      samples: [#"[{"keyword":"wk","name":"Wiki","url":"https://en.wikipedia.org/w/index.php?search=%s"}]"#, "[]"],
      rejects: [
        "nonsense",
        #"[{"keyword":"wk","name":"Wiki","url":"javascript:alert(1)//%s"}]"#,
        #"[{"keyword":"wk","name":"Wiki","url":"https://en.wikipedia.org/"}]"#,
        #"[{"keyword":"w k","name":"Wiki","url":"https://en.wikipedia.org/?q=%s"}]"#,
        #"[{"keyword":"google.com","name":"G","url":"https://example.com/?q=%s"}]"#,
        #"[{"keyword":"a","name":"A","url":"https://a.example/?q=%s"},{"keyword":"a","name":"B","url":"https://b.example/?q=%s"}]"#,
      ]))
}

extension SettingGroup {
  static let searchEngine = SettingGroup(id: "searchEngine", title: nil)
  static let searchSuggestions = SettingGroup(id: "searchSuggestions", title: "Suggestions")
  static let siteSearches = SettingGroup(id: "siteSearches", title: "Site searches")
}

// MARK: Pane

final class SearchPaneContent: SettingsPaneContent {
  private weak var engines: SearchEngineList?
  private weak var sites: SiteSearchListView?

  func control(named name: String, for key: AnySettingKey) -> NSView? {
    switch name {
    case "searchEngine":
      let list = SearchEngineList()
      engines = list
      return list
    case "siteSearches":
      let list = SiteSearchListView()
      sites = list
      return list
    default: return nil
    }
  }

  /// "Add…" at the right of the Site searches header (Ardia's place for it).
  func headerAccessory(for group: SettingGroup) -> NSView? {
    guard group == .siteSearches else { return nil }
    let add = LinkButton(title: "Add…")
    add.setAccessibilityLabel("Add a site search")
    add.onClick = { [weak self] in self?.sites?.openEditor(for: nil) }
    return add
  }

  // MARK: Tests

  /// `searchpane state|default <id>|add|edit <keyword>|remove <keyword>|fill <json>|save|cancel`: the pane's own
  /// controls, pressed as a click would (open the pane first: `settings open search`). `state` is one line of JSON.
  static func testCommand(_ argument: String) -> String {
    let words = argument.split(separator: " ", maxSplits: 1).map(String.init)
    guard let content = SettingsPanes.content(for: .search) as? SearchPaneContent else { return "no pane" }
    if words.first == "state" { return content.debugJSON }
    guard let engines = content.engines, let sites = content.sites else { return "no pane" }
    let rest = words.count == 2 ? words[1] : ""
    switch words.first {
    case "default": return engines.press(rest) ? "ok" : "no such engine"
    case "add": sites.openEditor(for: nil)
    case "edit": return sites.pressEdit(rest) ? "ok" : "no such site search"
    case "remove": return sites.pressRemove(rest) ? "ok" : "no such site search"
    case "fill":
      guard let data = rest.data(using: .utf8), let fields = (try? JSONSerialization.jsonObject(with: data)) as? [String: String],
            sites.fill(fields) else { return "no editor" }
    case "save": return sites.pressSave() ? "ok" : "no editor"
    case "cancel": return sites.pressCancel() ? "ok" : "no editor"
    default: return "usage: searchpane state|default <id>|add|edit <keyword>|remove <keyword>|fill <json>|save|cancel"
    }
    return "ok"
  }

  private var debugJSON: String {
    var out: [String: Any] = [
      "suggestURL": SearchEngines.suggestURL ?? NSNull(), "template": AddressInput.searchTemplate,
    ]
    if let engines { out["engines"] = engines.debug }
    if let sites { out["sites"] = sites.debug }
    guard let data = try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys, .withoutEscapingSlashes]),
          let text = String(data: data, encoding: .utf8) else { return "{}" }
    return text
  }
}

/// Tells the pane its height changed (a row came or went, the editor opened): it lays out again.
private func paneNeedsLayout(from view: NSView) {
  var current: NSView? = view
  while let each = current {
    each.needsLayout = true
    if let pane = each as? SettingsPaneView {
      pane.onResize?()
      return
    }
    current = each.superview
  }
}

// MARK: Engine list

/// The engines, one row each: a letter mark, the name and its keyword, then "Default" with a check on the chosen one
/// and Make Default on the rest. Follows the setting.
final class SearchEngineList: NSView, SettingsWideControl {
  private var rows: [SearchListRow] = []
  private var lines: [Hairline] = []
  private var observation: SettingsObservation?

  init() {
    super.init(frame: .zero)
    for engine in SearchEngines.builtIn {
      let row = SearchListRow(mark: engine.name, title: engine.name, detail: engine.keyword)
      row.identifier = NSUserInterfaceItemIdentifier(engine.id)
      row.onMakeDefault = { RaySettings.shared.apply(AnySettingKey.searchEngine, engine.id) }
      rows.append(row)
      addSubview(row)
    }
    for _ in rows.dropFirst() {
      let line = Hairline()
      lines.append(line)
      addSubview(line)
    }
    observation = RaySettings.shared.observe(.searchEngine) { [weak self] _ in self?.refresh() }
    refresh()
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }

  private func refresh() {
    let chosen = SearchEngines.chosen.id
    for row in rows { row.isDefault = row.identifier?.rawValue == chosen }
  }

  func height(forWidth width: CGFloat) -> CGFloat { CGFloat(rows.count) * SearchListRow.height }

  override func layout() {
    super.layout()
    for (index, row) in rows.enumerated() {
      row.frame = NSRect(x: 0, y: CGFloat(index) * SearchListRow.height, width: bounds.width, height: SearchListRow.height)
      if index > 0 { lines[index - 1].frame = NSRect(x: 0, y: row.frame.minY, width: bounds.width, height: 1) }
    }
  }

  /// For tests: Make Default on an engine's row; false when it isn't there or is already the default.
  func press(_ id: String) -> Bool {
    guard let row = rows.first(where: { $0.identifier?.rawValue == id }), !row.isDefault else { return false }
    row.onMakeDefault?()
    return true
  }

  var debug: [[String: Any]] {
    rows.map { ["id": $0.identifier?.rawValue ?? "", "default": $0.isDefault, "makeDefaultShown": !$0.isDefault] }
  }
}

/// A row of the engine or site search list: a letter mark, a title and a grey detail on one line, then on the right
/// either the default's check, Make Default, or (site searches) edit and remove buttons.
private final class SearchListRow: NSView {
  static let height: CGFloat = 40

  var onMakeDefault: (() -> Void)?
  var isDefault = false { didSet { update() } }
  private let mark: LetterMark
  private let titleLabel: NSTextField
  private let detailLabel: NSTextField
  private var makeDefault: LinkButton?
  private let check = NSImageView()
  private let defaultLabel = settingsLabel("Default", size: 12, color: .secondaryLabelColor)
  private var buttons: [NSButton] = []

  init(mark text: String, title: String, detail: String, buttons: [NSButton] = []) {
    mark = LetterMark(text)
    titleLabel = settingsLabel(title, size: 13)
    detailLabel = settingsLabel(detail, size: 12, color: .secondaryLabelColor)
    detailLabel.lineBreakMode = .byTruncatingMiddle
    self.buttons = buttons
    super.init(frame: .zero)
    [mark, titleLabel, detailLabel].forEach(addSubview)
    if buttons.isEmpty {
      let link = LinkButton(title: "Make Default")
      link.setAccessibilityLabel("Make \(title) the default search engine")
      link.onClick = { [weak self] in self?.onMakeDefault?() }
      makeDefault = link
      check.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)
      check.symbolConfiguration = .init(pointSize: 11, weight: .semibold)
      // The profile's colour, readable on the content.
      check.contentTintColor = SettingsColors.mark
      [link, check, defaultLabel].forEach(addSubview)
    } else {
      buttons.forEach(addSubview)
    }
    setAccessibilityElement(false)
    update()
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }

  private func update() {
    makeDefault?.isHidden = isDefault
    check.isHidden = !isDefault || makeDefault == nil
    defaultLabel.isHidden = !isDefault || makeDefault == nil
    needsLayout = true
  }

  override func layout() {
    super.layout()
    let mid = bounds.height / 2
    mark.frame = NSRect(x: 0, y: (mid - 11).rounded(), width: 22, height: 22)
    var right = bounds.width
    if let makeDefault {
      if isDefault {
        let width = fullWidth(defaultLabel), height = ceil(defaultLabel.intrinsicContentSize.height)
        defaultLabel.frame = NSRect(x: right - width, y: (mid - height / 2).rounded(), width: width, height: height)
        check.frame = NSRect(x: defaultLabel.frame.minX - 18, y: (mid - 7).rounded(), width: 14, height: 14)
        right = check.frame.minX
      } else {
        let size = makeDefault.intrinsicContentSize
        makeDefault.frame = NSRect(x: right - size.width, y: (mid - size.height / 2).rounded(), width: size.width, height: size.height)
        right = makeDefault.frame.minX
      }
    }
    for button in buttons.reversed() {
      button.frame = NSRect(x: right - 24, y: (mid - 12).rounded(), width: 24, height: 24)
      right -= 28
    }
    right -= 16
    let x: CGFloat = 34
    let titleWidth = min(fullWidth(titleLabel), max(0, right - x))
    let titleHeight = ceil(titleLabel.intrinsicContentSize.height)
    titleLabel.frame = NSRect(x: x, y: (mid - titleHeight / 2).rounded(), width: titleWidth, height: titleHeight)
    let detailX = titleLabel.frame.maxX + 8
    let detailHeight = ceil(detailLabel.intrinsicContentSize.height)
    detailLabel.frame = NSRect(x: detailX, y: (mid - detailHeight / 2).rounded(), width: max(0, right - detailX), height: detailHeight)
  }
}

/// A one-line label's whole text width (a truncating label's intrinsic width runs short), with room for its insets.
private func fullWidth(_ label: NSTextField) -> CGFloat { ceil(label.attributedStringValue.size().width) + 4 }

/// A rounded square with a name's first letter: the engine or site, without fetching its icon from the network.
private final class LetterMark: NSView {
  private let label: NSTextField

  init(_ name: String) {
    label = settingsLabel(String(name.prefix(1)).uppercased(), size: 12, weight: .semibold, color: .secondaryLabelColor)
    label.alignment = .center
    super.init(frame: .zero)
    wantsLayer = true
    layer?.cornerRadius = 6
    layer?.cornerCurve = .continuous
    addSubview(label)
  }

  required init?(coder: NSCoder) { fatalError() }

  override var wantsUpdateLayer: Bool { true }
  override func updateLayer() { layer?.backgroundColor = SettingsColors.track.cgColor }

  override func layout() {
    super.layout()
    let height = ceil(label.intrinsicContentSize.height)
    label.frame = NSRect(x: 0, y: ((bounds.height - height) / 2).rounded(), width: bounds.width, height: height)
  }
}

// MARK: Site searches

/// The user's site searches: one row each (name, keyword · address, edit and remove), a line saying how to add one
/// when there are none, and the editor, in the list itself, when adding or editing. Follows the setting.
final class SiteSearchListView: NSView, SettingsWideControl {
  private var rows: [SearchListRow] = []
  private var empty: SettingsRowView?
  private var lines: [Hairline] = []
  private let editor = SiteSearchEditor()
  /// The keyword of the site search being edited; nil while adding (or with the editor closed).
  private var editing: String?
  private var editorOpen = false
  private var observation: SettingsObservation?

  init() {
    super.init(frame: .zero)
    editor.isHidden = true
    editor.onSave = { [weak self] in self?.save() }
    editor.onCancel = { [weak self] in self?.closeEditor() }
    editor.onRemove = { [weak self] in
      guard let self, let keyword = self.editing else { return }
      self.remove(keyword)
    }
    addSubview(editor)
    observation = RaySettings.shared.observe(.siteSearches) { [weak self] _ in self?.rebuild() }
    rebuild()
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }

  private var sites: [SiteSearch] { RaySettings.shared[.siteSearches].items }

  private func rebuild() {
    rows.forEach { $0.removeFromSuperview() }
    lines.forEach { $0.removeFromSuperview() }
    empty?.removeFromSuperview()
    rows = []
    lines = []
    empty = nil
    for site in sites {
      let edit = iconButton("pencil", label: "Edit \(site.name)")
      let remove = iconButton("minus.circle", label: "Remove \(site.name)")
      let row = SearchListRow(mark: site.name, title: site.name, detail: "\(site.keyword) · \(Self.shortTemplate(site.url))",
                              buttons: [edit, remove])
      row.identifier = NSUserInterfaceItemIdentifier(site.keyword)
      edit.onPress = { [weak self] in self?.openEditor(for: site) }
      remove.onPress = { [weak self] in self?.remove(site.keyword) }
      rows.append(row)
      addSubview(row)
    }
    if sites.isEmpty {
      let row = SettingsRowView(
        title: "No site searches yet",
        detail: "Add one with the address of the site's results, %s where the search goes: "
          + "https://en.wikipedia.org/w/index.php?search=%s")
      empty = row
      addSubview(row)
    }
    // The site being edited may be gone (removed elsewhere): the editor closes.
    if let keyword = editing, !sites.contains(where: { $0.keyword == keyword }) { closeEditor() }
    paneNeedsLayout(from: self)
  }

  /// An address without its scheme, as the row shows it.
  private static func shortTemplate(_ url: String) -> String {
    for prefix in ["https://", "http://"] where url.lowercased().hasPrefix(prefix) { return String(url.dropFirst(prefix.count)) }
    return url
  }

  private func iconButton(_ symbol: String, label: String) -> PressButton {
    let button = PressButton()
    button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
    button.symbolConfiguration = .init(pointSize: 12, weight: .medium)
    button.contentTintColor = .secondaryLabelColor
    button.setAccessibilityLabel(label)
    button.toolTip = label
    return button
  }

  /// What the list shows, top to bottom: the editor when adding, the rows (the editor in place of the one being
  /// edited), or the empty line.
  private var listed: [NSView] {
    var out: [NSView] = []
    if editorOpen, editing == nil { out.append(editor) }
    for row in rows {
      if editorOpen, row.identifier?.rawValue == editing { out.append(editor) } else { out.append(row) }
    }
    if let empty, !(editorOpen && editing == nil) { out.append(empty) }
    return out
  }

  private func height(of view: NSView, width: CGFloat) -> CGFloat {
    view === editor ? editor.height(forWidth: width) : view is SearchListRow ? SearchListRow.height : sizedHeight(view, width: width)
  }

  func height(forWidth width: CGFloat) -> CGFloat { listed.reduce(0) { $0 + height(of: $1, width: width) } }

  override func layout() {
    super.layout()
    let shown = listed
    for row in rows { row.isHidden = !shown.contains { $0 === row } }
    empty?.isHidden = !shown.contains { $0 === empty }
    editor.isHidden = !editorOpen
    while lines.count < max(0, shown.count - 1) {
      let line = Hairline()
      lines.append(line)
      addSubview(line)
    }
    lines.forEach { $0.isHidden = true }
    var y: CGFloat = 0
    for (index, view) in shown.enumerated() {
      let height = height(of: view, width: bounds.width)
      view.frame = NSRect(x: 0, y: y, width: bounds.width, height: height)
      if index > 0 {
        lines[index - 1].isHidden = false
        lines[index - 1].frame = NSRect(x: 0, y: y, width: bounds.width, height: 1)
      }
      y += height
    }
  }

  // MARK: Editing

  /// Opens the editor for a new site search (nil) or to change `site`.
  func openEditor(for site: SiteSearch?) {
    editing = site?.keyword
    editorOpen = true
    editor.show(site)
    paneNeedsLayout(from: self)
    // The editor may open below the window's fold ("Add…" is in the header above it): bring it into view.
    window?.contentView?.layoutSubtreeIfNeeded()
    editor.scrollToVisible(editor.bounds.insetBy(dx: 0, dy: -16))
    window?.makeFirstResponder(editor.firstField)
  }

  private func closeEditor() {
    guard editorOpen else { return }
    editorOpen = false
    editing = nil
    editor.show(nil)
    paneNeedsLayout(from: self)
  }

  private func save() {
    let others = sites.filter { $0.keyword != editing }
    let fields = editor.values
    switch SiteSearch.make(name: fields.name, keyword: fields.keyword, url: fields.url, among: others) {
    case .failure(let problem):
      editor.problem = problem.message
      paneNeedsLayout(from: self)
    case .success(let site):
      var list = sites
      if let editing, let index = list.firstIndex(where: { $0.keyword == editing }) { list[index] = site } else { list.append(site) }
      guard RaySettings.shared.set(.siteSearches, SiteSearchList(list)) else {
        editor.problem = "You have as many site searches as Ray keeps (\(SiteSearch.most))."
        paneNeedsLayout(from: self)
        return
      }
      closeEditor()
    }
  }

  private func remove(_ keyword: String) {
    if editing == keyword { closeEditor() }
    RaySettings.shared.set(.siteSearches, SiteSearchList(sites.filter { $0.keyword != keyword }))
  }

  // MARK: Tests

  func pressEdit(_ keyword: String) -> Bool {
    guard let site = sites.first(where: { $0.keyword == keyword }) else { return false }
    openEditor(for: site)
    return true
  }

  func pressRemove(_ keyword: String) -> Bool {
    guard sites.contains(where: { $0.keyword == keyword }) else { return false }
    remove(keyword)
    return true
  }

  func fill(_ fields: [String: String]) -> Bool {
    guard editorOpen else { return false }
    editor.fill(fields)
    return true
  }

  func pressSave() -> Bool {
    guard editorOpen else { return false }
    save()
    return true
  }

  func pressCancel() -> Bool {
    guard editorOpen else { return false }
    closeEditor()
    return true
  }

  var debug: [String: Any] {
    [
      "rows": rows.compactMap { $0.identifier?.rawValue }, "empty": empty != nil, "editorOpen": editorOpen,
      "editing": editing ?? NSNull(), "problem": editor.problem ?? NSNull(),
      "height": height(forWidth: max(bounds.width, 400)),
    ]
  }
}

/// A borderless icon button that runs a closure.
private final class PressButton: NSButton {
  var onPress: (() -> Void)?

  init() {
    super.init(frame: .zero)
    isBordered = false
    bezelStyle = .regularSquare
    imagePosition = .imageOnly
    target = self
    action = #selector(pressed)
  }

  required init?(coder: NSCoder) { fatalError() }

  override var mouseDownCanMoveWindow: Bool { false }
  @objc private func pressed() { onPress?() }
}

/// The site search editor, in the list: name and keyword side by side, the address under them, what's wrong (if
/// anything), then Remove (when editing), Cancel and Add or Save. Return saves, Escape cancels.
private final class SiteSearchEditor: NSView, NSTextFieldDelegate {
  var onSave: (() -> Void)?
  var onCancel: (() -> Void)?
  var onRemove: (() -> Void)?
  var problem: String? {
    didSet {
      problemLabel.stringValue = problem ?? ""
      problemLabel.isHidden = problem == nil
      needsLayout = true
    }
  }

  private let name = EditorField(placeholder: "Name, e.g. Wikipedia")
  private let keyword = EditorField(placeholder: "Keyword, e.g. w")
  private let address = EditorField(placeholder: "https://en.wikipedia.org/w/index.php?search=%s")
  private let problemLabel = NSTextField(wrappingLabelWithString: "")
  private let save = AccentButton(title: "Add")
  private let saveTitle = AccentButton(title: "Save")
  private let cancel = LinkButton(title: "Cancel")
  private let removeLink = LinkButton(title: "Remove")
  private var isEditingExisting = false

  var firstField: NSView { name.field }

  var values: (name: String, keyword: String, url: String) {
    (name.field.stringValue, keyword.field.stringValue, address.field.stringValue)
  }

  override init(frame: NSRect) {
    super.init(frame: frame)
    name.field.setAccessibilityLabel("Name")
    keyword.field.setAccessibilityLabel("Keyword")
    address.field.setAccessibilityLabel("Search address, with %s where the search terms go")
    for field in [name, keyword, address] {
      field.field.delegate = self
      addSubview(field)
    }
    problemLabel.font = .systemFont(ofSize: 12)
    problemLabel.textColor = .systemRed
    problemLabel.isSelectable = false
    problemLabel.isHidden = true
    save.onClick = { [weak self] in self?.onSave?() }
    saveTitle.onClick = { [weak self] in self?.onSave?() }
    cancel.onClick = { [weak self] in self?.onCancel?() }
    removeLink.onClick = { [weak self] in self?.onRemove?() }
    [problemLabel, save, saveTitle, cancel, removeLink].forEach(addSubview)
    show(nil)
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }

  /// Empty for a new site search, or `site`'s values to change.
  func show(_ site: SiteSearch?) {
    isEditingExisting = site != nil
    name.field.stringValue = site?.name ?? ""
    keyword.field.stringValue = site?.keyword ?? ""
    address.field.stringValue = site?.url ?? ""
    problem = nil
    save.isHidden = isEditingExisting
    saveTitle.isHidden = !isEditingExisting
    removeLink.isHidden = !isEditingExisting
    needsLayout = true
  }

  func fill(_ fields: [String: String]) {
    if let text = fields["name"] { name.field.stringValue = text }
    if let text = fields["keyword"] { keyword.field.stringValue = text }
    if let text = fields["url"] { address.field.stringValue = text }
  }

  private static let pad: CGFloat = 12
  private static let fieldHeight: CGFloat = 28
  private static let gap: CGFloat = 8

  private func problemHeight(_ width: CGFloat) -> CGFloat { problem == nil ? 0 : textHeight(problemLabel, width: width) + Self.gap }

  func height(forWidth width: CGFloat) -> CGFloat {
    Self.pad + Self.fieldHeight + Self.gap + Self.fieldHeight + Self.gap + problemHeight(width) + 28 + Self.pad
  }

  override func layout() {
    super.layout()
    let width = bounds.width
    var y = Self.pad
    let keywordWidth = min(160, (width - Self.gap) * 0.35)
    name.frame = NSRect(x: 0, y: y, width: width - keywordWidth - Self.gap, height: Self.fieldHeight)
    keyword.frame = NSRect(x: name.frame.maxX + Self.gap, y: y, width: keywordWidth, height: Self.fieldHeight)
    y += Self.fieldHeight + Self.gap
    address.frame = NSRect(x: 0, y: y, width: width, height: Self.fieldHeight)
    y += Self.fieldHeight + Self.gap
    if problem != nil {
      let height = textHeight(problemLabel, width: width)
      problemLabel.frame = NSRect(x: 0, y: y, width: width, height: height)
      y += height + Self.gap
    }
    let button = isEditingExisting ? saveTitle : save
    let size = button.intrinsicContentSize
    button.frame = NSRect(x: width - size.width, y: y, width: size.width, height: size.height)
    let cancelSize = cancel.intrinsicContentSize
    cancel.frame = NSRect(x: button.frame.minX - 16 - cancelSize.width, y: y + ((size.height - cancelSize.height) / 2).rounded(),
                          width: cancelSize.width, height: cancelSize.height)
    let removeSize = removeLink.intrinsicContentSize
    removeLink.frame = NSRect(x: 0, y: cancel.frame.minY, width: removeSize.width, height: removeSize.height)
  }

  func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
    switch selector {
    case #selector(NSResponder.insertNewline(_:)): onSave?()
    case #selector(NSResponder.cancelOperation(_:)): onCancel?()
    default: return false
    }
    return true
  }
}

/// A one-line text field on a rounded fill, as the window's search field is: no system focus ring.
private final class EditorField: NSView {
  let field = NSTextField()

  init(placeholder: String) {
    super.init(frame: .zero)
    wantsLayer = true
    layer?.cornerRadius = 7
    layer?.cornerCurve = .continuous
    field.isBezeled = false
    field.isBordered = false
    field.drawsBackground = false
    field.focusRingType = .none
    field.font = .systemFont(ofSize: 13)
    field.placeholderString = placeholder
    field.cell?.isScrollable = true
    field.cell?.wraps = false
    field.cell?.usesSingleLineMode = true
    addSubview(field)
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }
  override var wantsUpdateLayer: Bool { true }
  override var mouseDownCanMoveWindow: Bool { false }
  override func updateLayer() { layer?.backgroundColor = SettingsColors.track.cgColor }
  override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(field) }

  override func layout() {
    super.layout()
    let height = ceil(field.intrinsicContentSize.height)
    field.frame = NSRect(x: 9, y: ((bounds.height - height) / 2).rounded(), width: bounds.width - 18, height: height)
  }
}
