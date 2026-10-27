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
  private static let restingRows: CGFloat = 5
  static let contentInset: CGFloat = 52
  static let iconCenter: CGFloat = 31
  static let rowInset: CGFloat = 9

  weak var delegate: CommandBarDelegate?
  let field = NSTextField()
  private let panel = FlippedView()
  private let searchIcon = NSImageView()
  private let separator = NSView()
  private let scrollView = NSScrollView()
  private let tableView = NSTableView()
  private(set) var suggestions: [Suggestion] = []

  var selectedIndex: Int { tableView.selectedRow }

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
    searchIcon.symbolConfiguration = .init(pointSize: 15, weight: .semibold)
    searchIcon.contentTintColor = .secondaryLabelColor
    panel.addSubview(searchIcon)

    field.isBordered = false
    field.drawsBackground = false
    field.focusRingType = .none
    field.font = .systemFont(ofSize: 20)
    field.placeholderString = "Search or Enter URL…"
    field.cell?.isScrollable = true
    field.cell?.usesSingleLineMode = true
    field.delegate = self
    panel.addSubview(field)

    separator.wantsLayer = true
    panel.addSubview(separator)

    tableView.addTableColumn(NSTableColumn(identifier: .init("suggestion")))
    tableView.headerView = nil
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
    scrollView.hasVerticalScroller = false
    panel.addSubview(scrollView)
    scrollView.addTrackingArea(NSTrackingArea(
      rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    updateColors()
  }

  override func mouseMoved(with event: NSEvent) {
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
      panel.layer?.backgroundColor = NSColor.windowBackgroundColor.blended(withFraction: 0.04, of: .labelColor)?.cgColor
      panel.layer?.borderColor = NSColor.separatorColor.cgColor
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
    self.suggestions = suggestions
    tableView.reloadData()
    if !suggestions.isEmpty { tableView.selectRowIndexes([0], byExtendingSelection: false) }
    needsLayout = true
  }

  override func layout() {
    super.layout()
    let width = min(Self.maxWidth, bounds.width - 80)
    let listHeight = suggestions.isEmpty ? 0 : CGFloat(suggestions.count) * Self.rowHeight + Self.listPadding * 2
    let height = Self.fieldHeight + listHeight
    let restingHeight = Self.fieldHeight + Self.restingRows * Self.rowHeight + Self.listPadding * 2
    let top = max(20, (bounds.height - restingHeight) / 2)
    panel.frame = NSRect(x: (bounds.width - width) / 2, y: top, width: width, height: height)
    searchIcon.frame = NSRect(x: Self.iconCenter - 9, y: (Self.fieldHeight - 18) / 2, width: 18, height: 18)
    field.frame = NSRect(
      x: Self.contentInset - 2, y: (Self.fieldHeight - 26) / 2, width: width - Self.contentInset - 24, height: 26)
    separator.frame = NSRect(x: 11, y: Self.fieldHeight - 1, width: width - 22, height: 1)
    separator.isHidden = suggestions.isEmpty
    scrollView.frame = NSRect(
      x: 0, y: Self.fieldHeight + Self.listPadding, width: width, height: max(0, listHeight - Self.listPadding * 2))
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
    for row in 0..<suggestions.count {
      (tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? SuggestionCell)?
        .selected = row == tableView.selectedRow
    }
  }
}

final class FlippedView: NSView {
  override var isFlipped: Bool { true }
}

private final class SuggestionRowBackground: NSTableRowView {
  override func drawSelection(in dirtyRect: NSRect) {
    NSColor.controlAccentColor.withAlphaComponent(0.22).setFill()
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
  private let action = NSTextField(labelWithString: "Switch to Tab")
  private let arrowBox = NSView()
  private let arrow = NSImageView()
  private var isTab = false
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
    action.font = .systemFont(ofSize: 15, weight: .medium)
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
    let actionWidth = isTab ? ceil(action.intrinsicContentSize.width) : 0
    action.frame = NSRect(x: arrowBox.frame.minX - 9 - actionWidth, y: mid - 10, width: actionWidth, height: 20)
    let right = (isTab ? action.frame.minX : arrowBox.frame.minX) - 16
    label.frame = NSRect(
      x: CommandBarView.contentInset, y: mid - 10, width: max(0, right - CommandBarView.contentInset), height: 20)
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    updateAccessory()
  }

  func show(_ suggestion: Suggestion) {
    self.suggestion = suggestion
    icon.image = suggestion.icon
    if case .tab = suggestion.kind { isTab = true } else { isTab = false }
    let text = NSMutableAttributedString(
      string: suggestion.title,
      attributes: [.font: NSFont.systemFont(ofSize: 15, weight: .semibold), .foregroundColor: NSColor.labelColor])
    let detail: String
    switch suggestion.kind {
    case .tab: detail = ""
    case .search: detail = suggestion.detail
    case .url, .history: detail = suggestion.detail == suggestion.title ? "" : suggestion.detail
    }
    if !detail.isEmpty {
      text.append(NSAttributedString(
        string: " — " + detail,
        attributes: [.font: NSFont.systemFont(ofSize: 15, weight: .medium), .foregroundColor: NSColor.secondaryLabelColor]))
    }
    label.attributedStringValue = text
    updateAccessory()
    needsLayout = true
  }

  private func updateAccessory() {
    action.isHidden = !isTab
    arrowBox.isHidden = !(isTab || selected)
    effectiveAppearance.performAsCurrentDrawingAppearance {
      action.textColor = selected ? .labelColor : .tertiaryLabelColor
      arrowBox.layer?.backgroundColor = (selected ? NSColor.labelColor : NSColor.labelColor.withAlphaComponent(0.08)).cgColor
      arrow.contentTintColor = selected ? .windowBackgroundColor : .tertiaryLabelColor
      iconBox.layer?.backgroundColor = selected ? NSColor.white.cgColor : NSColor.clear.cgColor
    }
  }
}
