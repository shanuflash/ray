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
  private let hint = ScopeHint()
  /// The site search the bar is scoped to (a keyword, then Tab or a space): what you type searches there.
  private(set) var scope: SearchScope?
  /// The site search Tab would scope to, shown at the field's end (Arc's "Search YouTube  Tab"); `offer(_:)`.
  private(set) var offered: SearchScope?
  /// What the field held before Tab or a space scoped it: Delete with nothing typed puts it back.
  private var scopeFrom: String?
  /// A site search's colour when it has no brand of its own (`SearchScope.brand`): its site's icon colour.
  var iconColor: ((SearchScope) -> NSColor?)?
  /// The scoped site's colour, as a fill readable on the bar: the chip, the glow and the chosen row.
  private(set) var scopeFill: NSColor?
  /// For tests: how many times entering a scope pulsed the bar.
  private(set) var pulses = 0
  private let glow = CALayer()
  private let tint = CALayer()
  private let separator = NSView()
  private let scrollView = QuietScrollView()
  private let tableView = NSTableView()
  private(set) var suggestions: [Suggestion] = []
  /// The typed text's length (UTF-16) while the field shows the leading row's host completed after it, selected.
  private var completedFrom: Int?
  /// Completion follows only typing that added to the field, never Delete (Chrome's rule).
  private var mayComplete = false
  private var lastTyped = ""

  /// The field as it was when ↑ ↓ or Tab first moved the selection (Chrome's temporary text): what Escape, or going
  /// back to `row`, puts back.
  private struct BeforeArrowing {
    var text: String
    var completedFrom: Int?
    var selection: NSRange
    var lastTyped: String
    var mayComplete: Bool
    var row: String?
  }
  private var beforeArrowing: BeforeArrowing?
  /// The row whose text the field shows in place of what was typed (`Suggestion.fieldText`).
  private(set) var filledRow: String?
  private var movingByKey = false

  /// What was typed: the field without its inline completion, or without the row arrowing put in it.
  var typed: String {
    if let beforeArrowing { return Self.typedPart(of: beforeArrowing.text, completedFrom: beforeArrowing.completedFrom) }
    return Self.typedPart(of: field.stringValue, completedFrom: completedFrom)
  }

  private static func typedPart(of text: String, completedFrom: Int?) -> String {
    guard let completedFrom else { return text }
    return (text as NSString).substring(to: min(completedFrom, (text as NSString).length))
  }
  /// For tests: the hint at the field's end, when shown.
  var hintText: String? { hint.isHidden ? nil : hint.text }
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
    hint.isHidden = true
    hint.onClick = { [weak self] in self?.enterOffered() }
    panel.addSubview(hint)

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
    // Entering a site search pulses the bar in the site's colour (Arc's red glow for YouTube): a glow under the panel
    // and a tint over its card.
    layer?.insertSublayer(glow, below: panel.layer)
    panel.layer?.insertSublayer(tint, above: backdrop.layer)
    glow.shadowOpacity = 0
    glow.shadowOffset = .zero
    glow.shadowRadius = 24
    tint.opacity = 0
    tint.cornerRadius = 12
    tint.cornerCurve = .continuous
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
    offered = nil
    updateHint()
    field.stringValue = query
    beforeArrowing = nil
    filledRow = nil
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
    movingByKey = true
    tableView.reloadData()
    movingByKey = false
    if !suggestions.isEmpty {
      let row = keepsSelection ? suggestions.firstIndex { $0.key == previous } ?? 0 : 0
      movingByKey = true
      tableView.selectRowIndexes([row], byExtendingSelection: false)
      movingByKey = false
      // The list's height follows the rows first, so scrolling to the selection lands on whole rows.
      layoutSubtreeIfNeeded()
      if row == 0 { tableView.scroll(.zero) } else { tableView.scrollRowToVisible(row) }
    }
    // New rows that moved the selection off the row arrowed to put what was typed back.
    if beforeArrowing != nil, previous == nil || selectedKey != previous { stopArrowing() }
    // While a row's text is in the field, nothing completes onto it.
    guard beforeArrowing == nil else { return }
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
    // Scoped, the chip sits where the text starts (after the icon, as Arc's) and the text follows it.
    let chipWidth = chip.isHidden ? 0 : chip.intrinsicContentSize.width
    chip.frame = NSRect(x: Self.contentInset - 4, y: ((Self.fieldHeight - 26) / 2).rounded(), width: chipWidth, height: 26)
    let fieldX = chip.isHidden ? Self.contentInset - 2 : chip.frame.maxX + 8
    let hintWidth = hint.isHidden ? 0 : hint.intrinsicContentSize.width
    hint.frame = NSRect(x: width - 18 - hintWidth, y: ((Self.fieldHeight - 22) / 2).rounded(), width: hintWidth, height: 22)
    let fieldEnd = hint.isHidden ? width - 24 : hint.frame.minX - 12
    field.frame = NSRect(x: fieldX, y: (Self.fieldHeight - 26) / 2, width: max(40, fieldEnd - fieldX), height: 26)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    glow.frame = panel.frame
    glow.shadowPath = CGPath(roundedRect: glow.bounds, cornerWidth: 12, cornerHeight: 12, transform: nil)
    tint.frame = panel.bounds
    CATransaction.commit()
    separator.frame = NSRect(x: 11, y: Self.fieldHeight - 1, width: width - 22, height: 1)
    separator.isHidden = suggestions.isEmpty
    scrollView.frame = NSRect(
      x: 0, y: Self.fieldHeight + Self.listPadding, width: width, height: max(0, listHeight - Self.listPadding * 2))
    // Rows that all fit don't bounce under a trackpad; more than fit scroll as a list does.
    scrollView.verticalScrollElasticity = suggestions.count > Self.shownRowLimit ? .automatic : .none
  }

  /// ↑ ↓ and Tab: the selection moves and the field shows the row (Chrome's, Dia's and Ardia's temporary text).
  func moveSelection(by step: Int) {
    guard !suggestions.isEmpty else { return }
    let next = max(0, min(suggestions.count - 1, tableView.selectedRow + step))
    if beforeArrowing == nil, next != tableView.selectedRow {
      let editor = field.currentEditor() as? NSTextView
      beforeArrowing = BeforeArrowing(
        text: field.stringValue, completedFrom: completedFrom,
        selection: editor?.selectedRange() ?? NSRange(location: (field.stringValue as NSString).length, length: 0),
        lastTyped: lastTyped, mayComplete: mayComplete, row: selectedKey)
    }
    movingByKey = true
    tableView.selectRowIndexes([next], byExtendingSelection: false)
    movingByKey = false
    tableView.scrollRowToVisible(next)
    defer { updateHint() }
    guard let before = beforeArrowing else { return }
    let row = suggestions[next]
    // Back on the row you were on, the field is what you typed again (its inline completion too), and Escape closes.
    if row.key == before.row { return stopArrowing() }
    // Menu commands, settings and "Search …" keep what you typed in the field, as Chrome's actions do.
    guard let text = row.fieldText else { return showTyped(before) }
    setField(text, selection: NSRange(location: (text as NSString).length, length: 0))
    completedFrom = nil
    lastTyped = text
    mayComplete = false
    filledRow = row.key
  }

  private var selectedKey: String? {
    let row = tableView.selectedRow
    return row >= 0 && row < suggestions.count ? suggestions[row].key : nil
  }

  /// Escape while the field shows a row: what you typed comes back, on the row you were on. False when there's no row to
  /// take back (Escape then closes the bar).
  private func revertArrowing() -> Bool {
    guard let before = beforeArrowing else { return false }
    if let row = suggestions.firstIndex(where: { $0.key == before.row }) {
      movingByKey = true
      tableView.selectRowIndexes([row], byExtendingSelection: false)
      movingByKey = false
      tableView.scrollRowToVisible(row)
    }
    stopArrowing()
    return true
  }

  /// The field as it was before arrowing, which is what was typed from here on.
  private func stopArrowing() {
    guard let before = beforeArrowing else { return }
    showTyped(before)
    beforeArrowing = nil
    updateHint()
  }

  private func showTyped(_ before: BeforeArrowing) {
    setField(before.text, selection: before.selection)
    completedFrom = before.completedFrom
    lastTyped = before.lastTyped
    mayComplete = before.mayComplete
    filledRow = nil
  }

  private func setField(_ text: String, selection: NSRange) {
    guard let editor = field.currentEditor() as? NSTextView else {
      field.stringValue = text
      return
    }
    if editor.string != text { editor.string = text }
    let length = (text as NSString).length
    editor.setSelectedRange(NSRange(location: min(selection.location, length),
                                    length: min(selection.length, length - min(selection.location, length))))
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
    // Typing replaced (or Delete removed) any completion: the field is what was typed. Typing on a row arrowing put
    // in the field goes on from it.
    beforeArrowing = nil
    filledRow = nil
    completedFrom = nil
    mayComplete = (field.stringValue as NSString).length > (lastTyped as NSString).length
    lastTyped = field.stringValue
    // A keyword and a space (typed, or pasted with more after it) scopes the bar, as Chrome's space trigger does.
    let text = field.stringValue
    if scope == nil, let space = text.firstIndex(of: " "), space != text.startIndex,
       let found = SearchEngines.scope(forKeyword: String(text[..<space])) {
      enter(found, query: String(text[text.index(after: space)...]), from: String(text[..<space]))
      return
    }
    delegate?.commandBar(self, queryChanged: text)
  }

  /// Scopes the bar to `scope`, the field holding `query` (what follows the keyword); Delete with nothing typed puts
  /// `from` back (the keyword by default).
  func enter(_ scope: SearchScope, query: String = "", from: String? = nil) {
    beforeArrowing = nil
    filledRow = nil
    completedFrom = nil
    scopeFrom = from ?? scope.keyword
    setScope(scope)
    if let scopeFill { pulse(scopeFill) }
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
    scopeFill = scope.map(fill(for:))
    chip.isHidden = scope == nil
    chip.name = scope?.name ?? ""
    chip.fill = scopeFill
    field.placeholderString = scope.map { "Search \($0.name)…" } ?? "Search or Enter URL…"
    if scope == nil {
      glow.removeAllAnimations()
      tint.removeAllAnimations()
    }
    updateHint()
    needsLayout = true
  }

  /// The site's colour (its brand, else its icon's, else the profile's), moved just far enough from the bar's card
  /// to show on it: a black brand (GitHub, X) fills grey on a dark bar.
  private func fill(for scope: SearchScope) -> NSColor {
    let brand = scope.brand.flatMap(ProfileColor.parse).map { NSColor(srgbRed: $0.r, green: $0.g, blue: $0.b, alpha: 1) }
    let color = brand ?? iconColor?(scope) ?? NSColor(name: nil) { _ in ProfileColor.accent }
    return ProfileColor.legible(color, on: SurfaceBackdrop.solidFill, minimum: 1.5)
  }

  /// White on a site's colour, as Arc's pill and row (YouTube's red), unless white has under 3:1 there (Amazon's
  /// orange): then black.
  static func brandInk(on fill: NSColor) -> NSColor {
    NSColor(name: nil) { appearance in
      let name = appearance.bestMatch(from: [.darkAqua, .aqua]) ?? .aqua
      return ProfileColor.contrast(.white, fill, appearance: name) >= 3 ? .white : .black
    }
  }

  /// The site search to offer for what was typed (the bar's owner works it out with the rows), or nil.
  func offer(_ scope: SearchScope?) {
    guard scope != offered else { return }
    offered = scope
    updateHint()
  }

  /// The hint shows while there's an offer, nothing is scoped and the field holds what was typed.
  private func updateHint() {
    let shown = scope == nil && beforeArrowing == nil && offered != nil
    hint.name = offered?.name ?? ""
    hint.isHidden = !shown
    needsLayout = true
  }

  /// Tab, or a click on the hint: scope to what's offered, what was typed coming back on Delete.
  private func enterOffered() {
    guard scope == nil, let offered else { return }
    enter(offered, from: typed)
  }

  /// Arc's pulse: a glow under the bar and a tint over it in the site's colour rise in 100 ms and fade out over a
  /// second. Reduce Motion: none (the chip carries the colour).
  private func pulse(_ color: NSColor) {
    pulses += 1
    guard !Panels.reduceMotion else { return }
    var cg = color.cgColor
    effectiveAppearance.performAsCurrentDrawingAppearance { cg = color.cgColor }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    glow.shadowColor = cg
    tint.backgroundColor = cg
    CATransaction.commit()
    for (layer, keyPath, peak) in [(glow, "shadowOpacity", 0.9), (tint, "opacity", 0.14)] as [(CALayer, String, Double)] {
      let rise = CAKeyframeAnimation(keyPath: keyPath)
      rise.values = [0, peak, 0]
      rise.keyTimes = [0, 0.09, 1]
      rise.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeInEaseOut)]
      rise.duration = 1.1
      layer.add(rise, forKey: "pulse")
    }
  }

  /// Tab on an offered site search scopes the bar (Arc's, Chrome's keyword mode); elsewhere it moves down.
  private func tabPressed() {
    if scope == nil, beforeArrowing == nil, offered != nil { return enterOffered() }
    moveSelection(by: 1)
  }

  /// Delete with nothing typed leaves the scope, what was typed before it back in the field (Chrome, Ardia).
  private func leaveScope() -> Bool {
    guard let scope, field.stringValue.isEmpty else { return false }
    setScope(nil)
    let keyword = scopeFrom ?? scope.keyword
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
      if !revertArrowing() { delegate?.commandBarDismiss(self) }
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
    let view = SuggestionRowBackground()
    view.fill = scopeFill
    return view
  }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    let cell = (tableView.makeView(withIdentifier: .init("suggestion"), owner: nil) as? SuggestionCell) ?? SuggestionCell()
    cell.identifier = .init("suggestion")
    // Scoped, the chosen row is filled with the site's colour and its text is white or black on it, as Arc's.
    cell.ink = scopeFill.map(Self.brandInk(on:))
    cell.show(suggestions[row])
    cell.selected = row == tableView.selectedRow
    return cell
  }

  func tableViewSelectionDidChange(_ notification: Notification) {
    defer { onSelectionChange?() }
    // The pointer picking a row puts what was typed back: the field shows only rows the keys went to.
    if !movingByKey { stopArrowing() }
    for row in 0..<suggestions.count {
      (tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? SuggestionCell)?
        .selected = row == tableView.selectedRow
    }
  }
}

final class FlippedView: NSView {
  override var isFlipped: Bool { true }
}

/// The site a scoped bar searches, before the text: Arc's pill, "YouTube" in white on YouTube's red, with a soft glow
/// of that colour.
private final class ScopeChip: NSView {
  private let label = NSTextField(labelWithString: "")
  var name = "" {
    didSet {
      label.stringValue = name
      setAccessibilityLabel("Searching \(name)")
      invalidateIntrinsicContentSize()
      needsLayout = true
    }
  }
  /// The site's colour (`CommandBarView.scopeFill`).
  var fill: NSColor? {
    didSet { needsDisplay = true }
  }

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.masksToBounds = false
    layer?.shadowOffset = .zero
    layer?.shadowRadius = 5
    layer?.shadowOpacity = 0.45
    label.font = .systemFont(ofSize: 14, weight: .semibold)
    label.lineBreakMode = .byTruncatingTail
    addSubview(label)
    setAccessibilityElement(true)
    setAccessibilityRole(.staticText)
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }
  override var wantsUpdateLayer: Bool { true }
  override var intrinsicContentSize: NSSize {
    NSSize(width: min(220, ceil(label.attributedStringValue.size().width) + 4) + 22, height: 26)
  }

  override func updateLayer() {
    let fill = fill ?? NSColor(name: nil) { _ in ProfileColor.accent }
    layer?.backgroundColor = fill.cgColor
    layer?.shadowColor = fill.cgColor
    layer?.cornerRadius = bounds.height / 2
    label.textColor = CommandBarView.brandInk(on: fill)
  }

  override func layout() {
    super.layout()
    layer?.cornerRadius = bounds.height / 2
    let height = ceil(label.intrinsicContentSize.height)
    label.frame = NSRect(x: 11, y: ((bounds.height - height) / 2).rounded(), width: bounds.width - 20, height: height)
  }
}

/// What Tab would do, at the field's end: "Search YouTube" in grey and a "Tab" key cap (Arc's). A click does it too.
private final class ScopeHint: NSView {
  private let label = NSTextField(labelWithString: "")
  private let key = NSTextField(labelWithString: "Tab")
  private let keyBox = NSView()
  var onClick: (() -> Void)?
  var name = "" {
    didSet {
      guard name != oldValue else { return }
      label.stringValue = "Search \(name)"
      setAccessibilityLabel("Search \(name), Tab")
      invalidateIntrinsicContentSize()
      needsLayout = true
    }
  }
  var text: String { label.stringValue }

  override init(frame: NSRect) {
    super.init(frame: frame)
    label.font = .systemFont(ofSize: 14)
    label.textColor = .tertiaryLabelColor
    key.font = .systemFont(ofSize: 11, weight: .semibold)
    key.textColor = .secondaryLabelColor
    keyBox.wantsLayer = true
    keyBox.layer?.cornerRadius = 5
    keyBox.layer?.cornerCurve = .continuous
    keyBox.addSubview(key)
    addSubview(label)
    addSubview(keyBox)
    setAccessibilityElement(true)
    setAccessibilityRole(.button)
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }
  override var intrinsicContentSize: NSSize {
    NSSize(width: ceil(label.intrinsicContentSize.width) + 7 + ceil(key.intrinsicContentSize.width) + 12, height: 22)
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    needsLayout = true
  }

  override func layout() {
    super.layout()
    let keyWidth = ceil(key.intrinsicContentSize.width) + 12
    keyBox.frame = NSRect(x: bounds.width - keyWidth, y: 1, width: keyWidth, height: 20)
    let keyHeight = ceil(key.intrinsicContentSize.height)
    key.frame = NSRect(x: 6, y: ((20 - keyHeight) / 2).rounded(), width: keyWidth - 12, height: keyHeight)
    let height = ceil(label.intrinsicContentSize.height)
    label.frame = NSRect(x: 0, y: ((bounds.height - height) / 2).rounded(), width: keyBox.frame.minX - 7, height: height)
    effectiveAppearance.performAsCurrentDrawingAppearance {
      keyBox.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
    }
  }

  override func mouseDown(with event: NSEvent) { onClick?() }
  override func accessibilityPerformPress() -> Bool {
    onClick?()
    return true
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
  /// A scoped bar's site colour for the chosen row, in place of the usual wash.
  var fill: NSColor?

  override func drawSelection(in dirtyRect: NSRect) {
    (fill ?? SelectedRow.fill(over: SurfaceBackdrop.solidFill)).setFill()
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
  /// Text and icon colour on a scoped bar's filled row (white or black on the site's colour); nil elsewhere.
  var ink: NSColor?

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
    case .action: shortcut = suggestion.detail
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
    case .action: detail = ""
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
    arrowBox.isHidden = !(isTab || selected) || ink != nil
    if let ink, let text = label.attributedStringValue.mutableCopy() as? NSMutableAttributedString {
      text.addAttribute(.foregroundColor, value: selected ? ink : NSColor.labelColor, range: NSRange(location: 0, length: text.length))
      label.attributedStringValue = text
      icon.contentTintColor = selected ? ink : .secondaryLabelColor
      return
    }
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
