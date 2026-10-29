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
  private let searchIcon = NSImageView()
  private let separator = NSView()
  private let scrollView = QuietScrollView()
  private let tableView = NSTableView()
  private(set) var suggestions: [Suggestion] = []

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

    panel.wantsLayer = true
    panel.layer?.cornerRadius = 12
    panel.layer?.cornerCurve = .continuous
    panel.layer?.borderWidth = 1
    panel.shadow = {
      let shadow = NSShadow()
      shadow.shadowBlurRadius = 30
      shadow.shadowOffset = NSSize(width: 0, height: -8)
      shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
      return shadow
    }()
    addSubview(panel)

    searchIcon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
    // Sizes measured against Arc's command bar (2026-10-28): field 18 pt, icon 13 pt, rows 13 pt medium.
    searchIcon.symbolConfiguration = .init(pointSize: 13, weight: .semibold)
    searchIcon.contentTintColor = .secondaryLabelColor
    panel.addSubview(searchIcon)

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
      let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
      panel.layer?.backgroundColor = (dark ? NSColor(white: 0.115, alpha: 1) : NSColor(white: 1, alpha: 1)).cgColor
      panel.layer?.borderColor = (dark ? NSColor(white: 1, alpha: 0.1) : NSColor(white: 0, alpha: 0.1)).cgColor
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
    field.stringValue = query
    window?.makeFirstResponder(field)
    field.currentEditor()?.selectAll(nil)
    let layer = panel.layer
    let fade = CABasicAnimation(keyPath: "opacity")
    fade.fromValue = 0
    fade.toValue = 1
    let grow = CABasicAnimation(keyPath: "transform.scale")
    grow.fromValue = 0.97
    grow.toValue = 1
    let group = CAAnimationGroup()
    group.animations = [fade, grow]
    group.duration = 0.14
    group.timingFunction = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
    layer?.add(group, forKey: "present")
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
    needsLayout = true
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
    searchIcon.frame = NSRect(x: Self.iconCenter - 9, y: (Self.fieldHeight - 18) / 2, width: 18, height: 18)
    field.frame = NSRect(
      x: Self.contentInset - 2, y: (Self.fieldHeight - 26) / 2, width: width - Self.contentInset - 24, height: 26)
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
    delegate?.commandBar(self, queryChanged: field.stringValue)
  }

  func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
    switch selector {
    case #selector(NSResponder.insertNewline(_:)):
      chooseSelected()
    case #selector(NSResponder.cancelOperation(_:)):
      delegate?.commandBarDismiss(self)
    case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.insertTab(_:)):
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
    ProfileColor.accent.withAlphaComponent(0.22).setFill()
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
  /// On the right: "Switch to Tab" on a tab, an action's keyboard shortcut (Ardia's hint) on an action.
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
    let actionWidth = hasAccessory ? ceil(action.intrinsicContentSize.width) : 0
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
    if case .action = suggestion.kind { shortcut = suggestion.detail } else { shortcut = "" }
    action.stringValue = isTab ? "Switch to Tab" : shortcut
    action.font = isTab ? .systemFont(ofSize: 13, weight: .medium) : .systemFont(ofSize: 12)
    let text = NSMutableAttributedString(
      string: suggestion.title,
      attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.labelColor])
    let detail: String
    switch suggestion.kind {
    case .tab: detail = suggestion.detail == suggestion.title ? "" : suggestion.detail
    case .search: detail = suggestion.detail
    case .url, .history: detail = suggestion.detail == suggestion.title ? "" : suggestion.detail
    case .action: detail = ""
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
      iconBox.layer?.backgroundColor =
        symbol ? NSColor.labelColor.withAlphaComponent(0.08).cgColor
        : selected ? NSColor.white.cgColor : NSColor.clear.cgColor
    }
  }
}
