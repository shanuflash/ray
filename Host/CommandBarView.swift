import AppKit

protocol CommandBarDelegate: AnyObject {
  func commandBar(_ bar: CommandBarView, queryChanged query: String)
  func commandBar(_ bar: CommandBarView, choose suggestion: Suggestion)
  func commandBarDismiss(_ bar: CommandBarView)
}

final class CommandBarView: NSView, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
  private static let fieldHeight: CGFloat = 60
  private static let rowHeight: CGFloat = 44
  private static let maxWidth: CGFloat = 760

  weak var delegate: CommandBarDelegate?
  let field = NSTextField()
  private let panel = NSView()
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
    panel.layer?.cornerRadius = 14
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
    searchIcon.symbolConfiguration = .init(pointSize: 18, weight: .medium)
    searchIcon.contentTintColor = .secondaryLabelColor
    panel.addSubview(searchIcon)

    field.isBordered = false
    field.drawsBackground = false
    field.focusRingType = .none
    field.font = .systemFont(ofSize: 22)
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
    tableView.selectionHighlightStyle = .none
    tableView.dataSource = self
    tableView.delegate = self
    tableView.target = self
    tableView.action = #selector(rowClicked)
    scrollView.documentView = tableView
    scrollView.drawsBackground = false
    scrollView.hasVerticalScroller = false
    panel.addSubview(scrollView)
    updateColors()
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
    let listHeight = CGFloat(suggestions.count) * Self.rowHeight + (suggestions.isEmpty ? 0 : 12)
    let height = Self.fieldHeight + listHeight
    panel.frame = NSRect(x: (bounds.width - width) / 2, y: max(20, bounds.height * 0.16), width: width, height: height)
    panel.layer?.anchorPoint = CGPoint(x: 0.5, y: 0.5)
    panel.layer?.position = CGPoint(x: panel.frame.midX, y: panel.frame.midY)
    searchIcon.frame = NSRect(x: 20, y: (Self.fieldHeight - 22) / 2, width: 22, height: 22)
    field.frame = NSRect(x: 54, y: (Self.fieldHeight - 28) / 2, width: width - 74, height: 28)
    separator.frame = NSRect(x: 0, y: Self.fieldHeight - 1, width: width, height: 1)
    separator.isHidden = suggestions.isEmpty
    scrollView.frame = NSRect(x: 8, y: Self.fieldHeight + 6, width: width - 16, height: max(0, listHeight - 12))
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
    return cell
  }

  func tableViewSelectionDidChange(_ notification: Notification) {
    for row in 0..<suggestions.count {
      (tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? SuggestionCell)?
        .selected = row == tableView.selectedRow
    }
  }
}

private final class SuggestionRowBackground: NSTableRowView {
  override func drawSelection(in dirtyRect: NSRect) {
    NSColor.labelColor.withAlphaComponent(0.08).setFill()
    NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 2), xRadius: 8, yRadius: 8).fill()
  }

  override var isEmphasized: Bool {
    get { false }
    set {}
  }
}

private final class SuggestionCell: NSTableCellView {
  private let icon = NSImageView()
  private let title = NSTextField(labelWithString: "")
  private let detail = NSTextField(labelWithString: "")
  private let action = NSTextField(labelWithString: "Switch to Tab")
  private let arrow = NSImageView()
  private var isTab = false

  var selected = false {
    didSet { updateAccessory() }
  }

  init() {
    super.init(frame: .zero)
    icon.imageScaling = .scaleProportionallyUpOrDown
    title.font = .systemFont(ofSize: 15, weight: .medium)
    title.lineBreakMode = .byTruncatingTail
    detail.font = .systemFont(ofSize: 13)
    detail.textColor = .secondaryLabelColor
    detail.lineBreakMode = .byTruncatingHead
    action.font = .systemFont(ofSize: 14, weight: .medium)
    arrow.image = NSImage(systemSymbolName: "arrow.right", accessibilityDescription: nil)
    arrow.symbolConfiguration = .init(pointSize: 14, weight: .semibold)
    [icon, title, detail, action, arrow].forEach(addSubview)
  }

  required init?(coder: NSCoder) { fatalError() }

  override func layout() {
    super.layout()
    let mid = bounds.height / 2
    icon.frame = NSRect(x: 12, y: mid - 10, width: 20, height: 20)
    arrow.frame = NSRect(x: bounds.width - 30, y: mid - 9, width: 18, height: 18)
    let actionWidth: CGFloat = isTab ? 110 : 0
    action.frame = NSRect(x: arrow.frame.minX - actionWidth - 6, y: mid - 9, width: actionWidth, height: 18)
    action.alignment = .right
    let right = (isTab ? action.frame.minX : arrow.frame.minX) - 12
    let titleWidth = min(title.intrinsicContentSize.width, (right - 44) * 0.7)
    title.frame = NSRect(x: 44, y: mid - 10, width: titleWidth, height: 20)
    detail.frame = NSRect(x: title.frame.maxX + 10, y: mid - 9, width: max(0, right - title.frame.maxX - 10), height: 18)
  }

  func show(_ suggestion: Suggestion) {
    icon.image = suggestion.icon
    title.stringValue = suggestion.title
    if case .tab = suggestion.kind { isTab = true } else { isTab = false }
    detail.stringValue = suggestion.detail == suggestion.title ? "" : suggestion.detail
    updateAccessory()
    needsLayout = true
  }

  private func updateAccessory() {
    action.isHidden = !isTab
    action.textColor = selected ? .labelColor : .tertiaryLabelColor
    arrow.isHidden = !(isTab || selected)
    arrow.contentTintColor = selected ? .labelColor : .tertiaryLabelColor
  }
}
