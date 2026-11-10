import AppKit

protocol CommandBarDelegate: AnyObject {
  func commandBar(_ bar: CommandBarView, queryChanged query: String)
  func commandBar(_ bar: CommandBarView, choose suggestion: Suggestion)
  func commandBarDismiss(_ bar: CommandBarView)
}

final class CommandBarView: NSView, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
  private static let fieldHeight: CGFloat = 62
  private static let rowHeight: CGFloat = 50
  private static let listPadding: CGFloat = 7
  private static let maxWidth: CGFloat = 765
  /// Rows shown at once (Arc's five); more scroll.
  private static let shownRowLimit = Suggestions.visibleRows
  static let contentInset: CGFloat = 52
  static let iconCenter: CGFloat = 31
  static let rowInset: CGFloat = 9

  weak var delegate: CommandBarDelegate?
  var onSelectionChange: (() -> Void)?
  let field = NSTextField()
  private let panel = FlippedView()
  private let backdrop = SurfaceBackdrop(radius: 12)
  private let searchIcon = NSImageView()
  private let chip = ScopeChip()
  /// The site search the bar is scoped to (a keyword, then Tab or a space): what you type searches there.
  private(set) var scope: SearchScope?
  private let separator = NSView()
  private let scrollView = QuietScrollView()
  private let tableView = NSTableView()
  private(set) var suggestions: [Suggestion] = []
  /// The typed text's length (UTF-16) while the field shows the leading row's host completed after it, selected.
  private var completedFrom: Int?
  /// Completion follows only typing that added to the field, never Delete (Chrome's rule).
  private var mayComplete = false
  private var lastTyped = ""

  /// What was typed: the field without its inline completion.
  var typed: String {
    guard let completedFrom else { return field.stringValue }
    return (field.stringValue as NSString).substring(to: min(completedFrom, (field.stringValue as NSString).length))
  }
  /// For tests: the host completed inline, if any.
  var inlineCompletion: String? { completedFrom == nil ? nil : field.stringValue }

  var selectedIndex: Int { tableView.selectedRow }
  /// For test snapshots: where the panel sits in the bar.
  var panelFrame: NSRect { panel.frame }

  /// For tests: the rows the list shows whole (`first` is where it's scrolled to).
  var shownRows: (first: Int, count: Int) {
    layoutSubtreeIfNeeded()
    let visible = scrollView.contentView.documentVisibleRect.insetBy(dx: 0, dy: -0.5)
    let whole = suggestions.indices.filter { visible.contains(tableView.rect(ofRow: $0)) }
    return (whole.first ?? 0, whole.count)
  }

  /// For tests: the list shows as many rows as it can (up to five) and none of them cut off, with the selected one among
  /// them.
  var rowsFullyVisible: Bool {
    layoutSubtreeIfNeeded()
    let visible = scrollView.contentView.documentVisibleRect.insetBy(dx: 0, dy: -0.5)
    let touched = suggestions.indices.filter { visible.intersects(tableView.rect(ofRow: $0).insetBy(dx: 0, dy: 1)) }
    let whole = touched.filter { visible.contains(tableView.rect(ofRow: $0)) }
    let selected = tableView.selectedRow
    let fits = whole.count == touched.count && whole.count == min(suggestions.count, Self.shownRowLimit)
      && (selected < 0 || whole.contains(selected))
    if !fits {
      TestEnvironment.log(
        "command bar rows cut off: visible \(NSStringFromRect(visible)), whole \(whole), touched \(touched), selected \(selected)")
    }
    return fits
  }

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true

    // The panels' look (glass or solid, Settings › Appearance › Panels and notes), the panels' shadow.
    panel.wantsLayer = true
    panel.addSubview(backdrop)
    addSubview(panel)

    searchIcon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
    // Sizes measured against Arc's command bar (2026-10-28): field 18 pt, icon 13 pt, rows 13 pt medium.
    searchIcon.symbolConfiguration = .init(pointSize: 13, weight: .semibold)
    searchIcon.contentTintColor = .secondaryLabelColor
    panel.addSubview(searchIcon)
    chip.isHidden = true
    panel.addSubview(chip)

    field.isBordered = false
    field.drawsBackground = false
    field.focusRingType = .none
    field.font = .systemFont(ofSize: 18)
    field.placeholderString = "Search or Enter URL…"
    field.cell?.isScrollable = true
    field.cell?.usesSingleLineMode = true
    field.delegate = self
    panel.addSubview(field)

    separator.wantsLayer = true
    panel.addSubview(separator)

    tableView.addTableColumn(NSTableColumn(identifier: .init("suggestion")))
    tableView.headerView = nil
    tableView.style = .plain
    tableView.rowHeight = Self.rowHeight
    tableView.intercellSpacing = .zero
    tableView.backgroundColor = .clear
    tableView.focusRingType = .none
    tableView.refusesFirstResponder = true
    tableView.selectionHighlightStyle = .regular
    tableView.dataSource = self
    tableView.delegate = self
    tableView.target = self
    tableView.action = #selector(rowClicked)
    scrollView.documentView = tableView
    scrollView.drawsBackground = false
    scrollView.contentView.drawsBackground = false
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = false
    scrollView.autohidesScrollers = true
    scrollView.horizontalScrollElasticity = .none
    scrollView.automaticallyAdjustsContentInsets = false
    scrollView.contentInsets = NSEdgeInsets()
    panel.addSubview(scrollView)
    scrollView.addTrackingArea(NSTrackingArea(
      rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    updateColors()
  }

  /// Where the pointer was at the last hover: the list scrolling under a still pointer sends `mouseMoved` too, and
  /// that must not move the selection away from the keyboard's.
  private var lastPointer: NSPoint?

  override func mouseMoved(with event: NSEvent) {
    let pointer = NSEvent.mouseLocation
    defer { lastPointer = pointer }
    guard pointer != lastPointer else { return }
    let row = tableView.row(at: tableView.convert(event.locationInWindow, from: nil))
    if row >= 0, row != tableView.selectedRow { tableView.selectRowIndexes([row], byExtendingSelection: false) }
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    updateColors()
  }

  private func updateColors() {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      separator.layer?.backgroundColor = NSColor.separatorColor.cgColor
    }
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    super.hitTest(point) ?? (isHidden ? nil : self)
  }

  override func mouseDown(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    if !panel.frame.contains(point) { delegate?.commandBarDismiss(self) }
  }

  func present(query: String) {
    lastPointer = NSEvent.mouseLocation
    setScope(nil)
    field.stringValue = query
    completedFrom = nil
    mayComplete = false
    lastTyped = query
    window?.makeFirstResponder(field)
    field.currentEditor()?.selectAll(nil)
    // Grows a little about its middle on the panels' spring, fading in over 140 ms (Reduce Motion: the fade only).
    layoutSubtreeIfNeeded()
    guard let layer = panel.layer else { return }
    if !Panels.reduceMotion {
      let size = panel.bounds.size
      let pivot = CGPoint(x: size.width / 2 - layer.anchorPoint.x * size.width, y: size.height / 2 - layer.anchorPoint.y * size.height)
      var from = CATransform3DMakeTranslation(pivot.x, pivot.y, 0)
      from = CATransform3DScale(from, 0.97, 0.97, 1)
      from = CATransform3DTranslate(from, -pivot.x, -pivot.y, 0)
      let grow = Spring.caAnimation(keyPath: "transform", from: NSValue(caTransform3D: from),
                                    to: NSValue(caTransform3D: CATransform3DIdentity))
      layer.add(grow, forKey: "present")
    }
    let fade = CABasicAnimation(keyPath: "opacity")
    fade.fromValue = 0
    fade.toValue = 1
    fade.duration = 0.14
    fade.timingFunction = CAMediaTimingFunction(controlPoints: 0, 0, 0.2, 1)
    layer.add(fade, forKey: "presentFade")
  }

  func show(_ suggestions: [Suggestion]) {
    let previous = tableView.selectedRow >= 0 && tableView.selectedRow < self.suggestions.count
      ? self.suggestions[tableView.selectedRow].key : nil
    let keepsSelection = previous != nil && self.suggestions.first?.key == suggestions.first?.key
    self.suggestions = suggestions
    needsLayout = true
    tableView.reloadData()
    if !suggestions.isEmpty {
      let row = keepsSelection ? suggestions.firstIndex { $0.key == previous } ?? 0 : 0
      tableView.selectRowIndexes([row], byExtendingSelection: false)
      // The list's height follows the rows first, so scrolling to the selection lands on whole rows.
      layoutSubtreeIfNeeded()
      if row == 0 { tableView.scroll(.zero) } else { tableView.scrollRowToVisible(row) }
    }
    complete(with: suggestions.first?.completion)
    needsLayout = true
  }

  /// Arc's and Chrome's inline autocomplete: the leading row's host after what was typed, the rest selected, so
  /// typing on replaces it, Delete removes it and Enter goes to that row.
  private func complete(with completion: String?) {
    guard let editor = field.currentEditor() as? NSTextView else { return }
    let typed = self.typed
    let length = (typed as NSString).length
    let selection = editor.selectedRange()
    let atEnd = selection.location + selection.length == (editor.string as NSString).length
    if let completion, mayComplete, scope == nil, atEnd, completion.hasPrefix(typed.lowercased()),
       (completion as NSString).length > length {
      let full = typed + String(completion.dropFirst(typed.count))
      if editor.string != full { editor.string = full }
      editor.setSelectedRange(NSRange(location: length, length: (full as NSString).length - length))
      completedFrom = length
    } else if completedFrom != nil {
      editor.string = typed
      editor.setSelectedRange(NSRange(location: length, length: 0))
      completedFrom = nil
    }
  }

  override func layout() {
    super.layout()
    let width = min(Self.maxWidth, bounds.width - 80)
    let shown = min(suggestions.count, Self.shownRowLimit)
    let listHeight = suggestions.isEmpty ? 0 : CGFloat(shown) * Self.rowHeight + Self.listPadding * 2
    let height = Self.fieldHeight + listHeight
    let restingHeight = Self.fieldHeight + CGFloat(Self.shownRowLimit) * Self.rowHeight + Self.listPadding * 2
    let top = max(20, (bounds.height - restingHeight) / 2)
    panel.frame = NSRect(x: (bounds.width - width) / 2, y: top, width: width, height: height)
    backdrop.frame = panel.bounds
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    SurfaceBackdrop.shadow(on: panel, radius: 12)
    CATransaction.commit()
    searchIcon.frame = NSRect(x: Self.iconCenter - 9, y: (Self.fieldHeight - 18) / 2, width: 18, height: 18)
    // Scoped, the chip takes the icon's place and the text follows it.
    let chipWidth = chip.isHidden ? 0 : chip.intrinsicContentSize.width
    chip.frame = NSRect(x: Self.rowInset + 7, y: ((Self.fieldHeight - 28) / 2).rounded(), width: chipWidth, height: 28)
    let fieldX = chip.isHidden ? Self.contentInset - 2 : chip.frame.maxX + 10
    field.frame = NSRect(x: fieldX, y: (Self.fieldHeight - 26) / 2, width: width - fieldX - 24, height: 26)
    separator.frame = NSRect(x: 11, y: Self.fieldHeight - 1, width: width - 22, height: 1)
    separator.isHidden = suggestions.isEmpty
    scrollView.frame = NSRect(
      x: 0, y: Self.fieldHeight + Self.listPadding, width: width, height: max(0, listHeight - Self.listPadding * 2))
    // Rows that all fit don't bounce under a trackpad; more than fit scroll as a list does.
    scrollView.verticalScrollElasticity = suggestions.count > Self.shownRowLimit ? .automatic : .none
  }

  func moveSelection(by step: Int) {
    guard !suggestions.isEmpty else { return }
    let next = max(0, min(suggestions.count - 1, tableView.selectedRow + step))
    tableView.selectRowIndexes([next], byExtendingSelection: false)
    tableView.scrollRowToVisible(next)
  }

  func chooseSelected() {
    let row = tableView.selectedRow
    guard row >= 0, row < suggestions.count else { return }
    delegate?.commandBar(self, choose: suggestions[row])
  }

  @objc private func rowClicked() {
    let row = tableView.clickedRow
    guard row >= 0, row < suggestions.count else { return }
    delegate?.commandBar(self, choose: suggestions[row])
  }

  func controlTextDidChange(_ notification: Notification) {
    // Typing replaced (or Delete removed) any completion: the field is what was typed.
    completedFrom = nil
    mayComplete = (field.stringValue as NSString).length > (lastTyped as NSString).length
    lastTyped = field.stringValue
    // A keyword and a space (typed, or pasted with more after it) scopes the bar, as Chrome's space trigger does.
    let text = field.stringValue
    if scope == nil, let space = text.firstIndex(of: " "), space != text.startIndex,
       let found = SearchEngines.scope(forKeyword: String(text[..<space])) {
      enter(found, query: String(text[text.index(after: space)...]))
      return
    }
    delegate?.commandBar(self, queryChanged: text)
  }

  /// Scopes the bar to `scope`, the field holding `query` (what follows the keyword).
  func enter(_ scope: SearchScope, query: String = "") {
    completedFrom = nil
    setScope(scope)
    if let editor = field.currentEditor() as? NSTextView {
      editor.string = query
      editor.setSelectedRange(NSRange(location: (query as NSString).length, length: 0))
    } else {
      field.stringValue = query
    }
    delegate?.commandBar(self, queryChanged: field.stringValue)
  }

  private func setScope(_ scope: SearchScope?) {
    self.scope = scope
    chip.isHidden = scope == nil
    searchIcon.isHidden = scope != nil
    chip.name = scope?.name ?? ""
    field.placeholderString = scope.map { "Search \($0.name)…" } ?? "Search or Enter URL…"
    needsLayout = true
  }

  /// Tab on a keyword (the typed text, or the selected "Search …" row) scopes the bar; elsewhere it moves down.
  private func tabPressed() {
    if scope == nil {
      let row = selectedIndex >= 0 && selectedIndex < suggestions.count ? suggestions[selectedIndex] : nil
      if case .scope(let offered)? = row?.kind { return enter(offered) }
      let text = field.stringValue.trimmingCharacters(in: .whitespaces)
      if !text.isEmpty, !text.contains(" "), let found = SearchEngines.scope(forKeyword: text) { return enter(found) }
    }
    moveSelection(by: 1)
  }

  /// Delete with nothing typed leaves the scope, the keyword back in the field (Chrome, Ardia).
  private func leaveScope() -> Bool {
    guard let scope, field.stringValue.isEmpty else { return false }
    setScope(nil)
    let keyword = scope.keyword
    if let editor = field.currentEditor() as? NSTextView {
      editor.string = keyword
      editor.setSelectedRange(NSRange(location: (keyword as NSString).length, length: 0))
    } else {
      field.stringValue = keyword
    }
    delegate?.commandBar(self, queryChanged: field.stringValue)
    return true
  }

  func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
    switch selector {
    case #selector(NSResponder.insertNewline(_:)):
      chooseSelected()
    case #selector(NSResponder.cancelOperation(_:)):
      delegate?.commandBarDismiss(self)
    case #selector(NSResponder.deleteBackward(_:)):
      return leaveScope()
    case #selector(NSResponder.insertTab(_:)):
      tabPressed()
    case #selector(NSResponder.moveDown(_:)):
      moveSelection(by: 1)
    case #selector(NSResponder.moveUp(_:)), #selector(NSResponder.insertBacktab(_:)):
      moveSelection(by: -1)
    default:
      return false
    }
    return true
  }

  func numberOfRows(in tableView: NSTableView) -> Int { suggestions.count }

  func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
    SuggestionRowBackground()
  }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    let cell = (tableView.makeView(withIdentifier: .init("suggestion"), owner: nil) as? SuggestionCell) ?? SuggestionCell()
    cell.identifier = .init("suggestion")
    cell.show(suggestions[row])
    cell.selected = row == tableView.selectedRow
    return cell
  }

  func tableViewSelectionDidChange(_ notification: Notification) {
    defer { onSelectionChange?() }
    for row in 0..<suggestions.count {
      (tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? SuggestionCell)?
        .selected = row == tableView.selectedRow
    }
  }
}

final class FlippedView: NSView {
  override var isFlipped: Bool { true }
}

/// The site a scoped bar searches, before the text: "Wikipedia" on a wash of the profile's colour.
private final class ScopeChip: NSView {
  private let icon = NSImageView()
  private let label = NSTextField(labelWithString: "")
  var name = "" {
    didSet {
      label.stringValue = name
      setAccessibilityLabel("Searching \(name)")
      invalidateIntrinsicContentSize()
      needsLayout = true
    }
  }

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.cornerRadius = 7
    layer?.cornerCurve = .continuous
    icon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
    icon.symbolConfiguration = .init(pointSize: 11, weight: .semibold)
    label.font = .systemFont(ofSize: 14, weight: .medium)
    label.lineBreakMode = .byTruncatingTail
    addSubview(icon)
    addSubview(label)
    setAccessibilityElement(true)
    setAccessibilityRole(.staticText)
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }
  override var wantsUpdateLayer: Bool { true }
  override var intrinsicContentSize: NSSize {
    NSSize(width: min(220, ceil(label.attributedStringValue.size().width) + 4) + 10 + 14 + 6 + 10, height: 28)
  }

  /// A wash of the profile's colour over the panels' card (what the bar sits on).
  private var fill: NSColor {
    ProfileColor.mix(NSColor(name: nil) { _ in ProfileColor.accent }, over: SurfaceBackdrop.solidFill, 0.16, dark: 0.28)
  }

  override func updateLayer() {
    let fill = fill
    layer?.backgroundColor = fill.cgColor
    let ink = ProfileColor.legible(NSColor(name: nil) { _ in ProfileColor.accent }, on: fill, minimum: 4.5)
    label.textColor = ink
    icon.contentTintColor = ink
  }

  override func layout() {
    super.layout()
    icon.frame = NSRect(x: 10, y: ((bounds.height - 14) / 2).rounded(), width: 14, height: 14)
    let height = ceil(label.intrinsicContentSize.height)
    label.frame = NSRect(x: 30, y: ((bounds.height - height) / 2).rounded(), width: bounds.width - 40, height: height)
  }
}

/// The list's scroll view: its scroller shows only while it scrolls (overlay style, whatever System Settings says), as
/// in the onboarding's list.
private final class QuietScrollView: NSScrollView {
  override init(frame: NSRect) {
    super.init(frame: frame)
    super.scrollerStyle = .overlay
  }

  required init?(coder: NSCoder) { fatalError() }

  override var scrollerStyle: NSScroller.Style {
    get { .overlay }
    set { super.scrollerStyle = .overlay }
  }
}

private final class SuggestionRowBackground: NSTableRowView {
  override func drawSelection(in dirtyRect: NSRect) {
    SelectedRow.fill(over: SurfaceBackdrop.solidFill).setFill()
    let rect = bounds.insetBy(dx: CommandBarView.rowInset, dy: 2)
    NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
  }

  override var isEmphasized: Bool {
    get { false }
    set {}
  }
}

private final class SuggestionCell: NSTableCellView {
  private let iconBox = NSView()
  private let icon = NSImageView()
  private let label = NSTextField(labelWithString: "")
  /// On the right: "Switch to Tab" on a tab, "Bookmark" on a bookmark, an action's keyboard shortcut (Ardia's hint).
  private let action = NSTextField(labelWithString: "Switch to Tab")
  private let arrowBox = NSView()
  private let arrow = NSImageView()
  private var isTab = false
  private var shortcut = ""
  private var suggestion: Suggestion?

  var selected = false {
    didSet { updateAccessory() }
  }

  init() {
    super.init(frame: .zero)
    icon.imageScaling = .scaleProportionallyUpOrDown
    iconBox.wantsLayer = true
    iconBox.layer?.cornerRadius = 6
    iconBox.layer?.cornerCurve = .continuous
    iconBox.addSubview(icon)
    label.lineBreakMode = .byTruncatingTail
    label.cell?.truncatesLastVisibleLine = true
    action.font = .systemFont(ofSize: 13, weight: .medium)
    action.alignment = .right
    arrowBox.wantsLayer = true
    arrowBox.layer?.cornerRadius = 6
    arrowBox.layer?.cornerCurve = .continuous
    arrow.image = NSImage(systemSymbolName: "arrow.right", accessibilityDescription: nil)
    arrow.symbolConfiguration = .init(pointSize: 13, weight: .semibold)
    arrowBox.addSubview(arrow)
    [iconBox, label, action, arrowBox].forEach(addSubview)
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }

  override func layout() {
    super.layout()
    let mid = bounds.height / 2
    iconBox.frame = NSRect(x: CommandBarView.iconCenter - 12, y: mid - 12, width: 24, height: 24)
    icon.frame = iconBox.bounds.insetBy(dx: 4, dy: 4)
    arrowBox.frame = NSRect(x: bounds.width - 22 - 24, y: mid - 12, width: 24, height: 24)
    arrow.frame = arrowBox.bounds.insetBy(dx: 4, dy: 4)
    let hasAccessory = isTab || !shortcut.isEmpty
    // A label's own size leaves its last glyph a hair short ("Switch to Tab" lost its b): room for it.
    let actionWidth = hasAccessory ? ceil(action.intrinsicContentSize.width) + 4 : 0
    // The shortcut's frame is one line tall and centred (a label draws from its top); "Switch to Tab" keeps its own.
    let actionHeight = isTab ? 20 : ceil(action.intrinsicContentSize.height)
    action.frame = NSRect(
      x: arrowBox.frame.minX - 9 - actionWidth, y: isTab ? mid - 10 : (mid - actionHeight / 2).rounded(),
      width: actionWidth, height: actionHeight)
    let right = (hasAccessory ? action.frame.minX : arrowBox.frame.minX) - 16
    // Row text lines up with the typed text above it, as in Arc.
    let textX = CommandBarView.contentInset - 3
    label.frame = NSRect(x: textX, y: mid - 9, width: max(0, right - textX), height: 18)
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    updateAccessory()
  }

  func show(_ suggestion: Suggestion) {
    self.suggestion = suggestion
    icon.image = suggestion.icon
    if case .tab = suggestion.kind { isTab = true } else { isTab = false }
    switch suggestion.kind {
    case .action, .scope: shortcut = suggestion.detail
    // A bookmark says so where a tab says "Switch to Tab", in the quieter look of a shortcut.
    case .bookmark: shortcut = "Bookmark"
    default: shortcut = ""
    }
    action.stringValue = isTab ? "Switch to Tab" : shortcut
    action.font = isTab ? .systemFont(ofSize: 13, weight: .medium) : .systemFont(ofSize: 12)
    let text = NSMutableAttributedString(
      string: suggestion.title,
      attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.labelColor])
    let detail: String
    switch suggestion.kind {
    case .tab: detail = suggestion.detail == suggestion.title ? "" : suggestion.detail
    case .search: detail = suggestion.detail
    case .url, .history, .bookmark: detail = suggestion.detail == suggestion.title ? "" : suggestion.detail
    case .action, .scope: detail = ""
    case .setting: detail = suggestion.detail
    }
    if !detail.isEmpty {
      text.append(NSAttributedString(
        string: " — " + detail,
        attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.secondaryLabelColor]))
    }
    label.attributedStringValue = text
    updateAccessory()
    needsLayout = true
  }

  private func updateAccessory() {
    action.isHidden = !isTab && shortcut.isEmpty
    arrowBox.isHidden = !(isTab || selected)
    effectiveAppearance.performAsCurrentDrawingAppearance {
      action.textColor = selected ? (isTab ? .labelColor : .secondaryLabelColor) : .tertiaryLabelColor
      arrowBox.layer?.backgroundColor = (selected ? NSColor.labelColor : NSColor.labelColor.withAlphaComponent(0.08)).cgColor
      arrow.contentTintColor = selected ? .windowBackgroundColor : .tertiaryLabelColor
      let symbol = icon.image?.isTemplate ?? false
      icon.contentTintColor = symbol ? .secondaryLabelColor : nil
      // As Arc: a tile behind the icon only on the selected row.
      iconBox.layer?.backgroundColor =
        !selected ? NSColor.clear.cgColor : symbol ? NSColor.labelColor.withAlphaComponent(0.08).cgColor : NSColor.white.cgColor
    }
  }
}
