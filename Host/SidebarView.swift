import AppKit

protocol SidebarViewDelegate: AnyObject {
  func sidebar(_ sidebar: SidebarView, didSelect tab: ArdiaCoreTab)
  func sidebar(_ sidebar: SidebarView, close tab: ArdiaCoreTab)
  func sidebarNewTab(_ sidebar: SidebarView)
  func sidebarOpenAddress(_ sidebar: SidebarView)
}

final class AddressField: NSTextField {
  var onClick: (() -> Void)?

  override func mouseDown(with event: NSEvent) {
    onClick?()
  }
}

final class SidebarView: NSView, NSTableViewDataSource, NSTableViewDelegate {
  static let width: CGFloat = 260
  private static let topInset: CGFloat = 40

  weak var delegate: SidebarViewDelegate?
  let addressField = AddressField()
  private let scrollView = NSScrollView()
  private let tableView = NSTableView()
  private let newTabButton = NSButton()
  private(set) var tabs: [ArdiaCoreTab] = []
  private var applyingSelection = false

  override init(frame: NSRect) {
    super.init(frame: frame)

    addressField.placeholderString = "Search or enter address"
    addressField.font = .systemFont(ofSize: 13)
    addressField.bezelStyle = .roundedBezel
    addressField.focusRingType = .none
    addressField.lineBreakMode = .byTruncatingHead
    addressField.cell?.isScrollable = true
    addressField.cell?.usesSingleLineMode = true
    addressField.isEditable = false
    addressField.isSelectable = false
    addressField.refusesFirstResponder = true
    addressField.onClick = { [weak self] in
      guard let self else { return }
      self.delegate?.sidebarOpenAddress(self)
    }
    addSubview(addressField)

    let column = NSTableColumn(identifier: .init("tab"))
    tableView.addTableColumn(column)
    tableView.headerView = nil
    tableView.style = .sourceList
    tableView.rowHeight = 30
    tableView.intercellSpacing = NSSize(width: 0, height: 2)
    tableView.backgroundColor = .clear
    tableView.focusRingType = .none
    tableView.refusesFirstResponder = true
    tableView.dataSource = self
    tableView.delegate = self
    tableView.menu = rowMenu()
    scrollView.documentView = tableView
    scrollView.drawsBackground = false
    scrollView.hasVerticalScroller = true
    scrollView.autohidesScrollers = true
    addSubview(scrollView)

    newTabButton.title = "New Tab"
    newTabButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
    newTabButton.imagePosition = .imageLeading
    newTabButton.bezelStyle = .recessed
    newTabButton.isBordered = false
    newTabButton.alignment = .left
    newTabButton.contentTintColor = .secondaryLabelColor
    newTabButton.target = self
    newTabButton.action = #selector(newTab)
    newTabButton.refusesFirstResponder = true
    addSubview(newTabButton)
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }

  override func layout() {
    super.layout()
    let inset: CGFloat = 10
    let width = bounds.width - inset * 2
    addressField.frame = NSRect(x: inset, y: Self.topInset, width: width, height: 28)
    newTabButton.frame = NSRect(x: inset, y: bounds.height - 40, width: width, height: 28)
    let listTop = addressField.frame.maxY + 10
    scrollView.frame = NSRect(x: 4, y: listTop, width: bounds.width - 8, height: newTabButton.frame.minY - listTop - 6)
  }

  func setTabs(_ tabs: [ArdiaCoreTab], active: ArdiaCoreTab?) {
    self.tabs = tabs
    tableView.reloadData()
    select(active)
  }

  func select(_ tab: ArdiaCoreTab?) {
    applyingSelection = true
    defer { applyingSelection = false }
    guard let tab, let row = tabs.firstIndex(where: { $0 === tab }) else {
      tableView.deselectAll(nil)
      return
    }
    tableView.selectRowIndexes([row], byExtendingSelection: false)
    tableView.scrollRowToVisible(row)
  }

  func refresh(_ tab: ArdiaCoreTab) {
    guard let row = tabs.firstIndex(where: { $0 === tab }) else { return }
    tableView.reloadData(forRowIndexes: [row], columnIndexes: [0])
  }

  func showAddress(_ text: String) {
    addressField.stringValue = text
  }

  func numberOfRows(in tableView: NSTableView) -> Int { tabs.count }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    let cell = (tableView.makeView(withIdentifier: .init("tabCell"), owner: nil) as? TabRowView) ?? TabRowView()
    cell.identifier = .init("tabCell")
    cell.show(tabs[row])
    return cell
  }

  func tableViewSelectionDidChange(_ notification: Notification) {
    guard !applyingSelection, tableView.selectedRow >= 0, tableView.selectedRow < tabs.count else { return }
    delegate?.sidebar(self, didSelect: tabs[tableView.selectedRow])
  }

  @objc private func newTab() { delegate?.sidebarNewTab(self) }

  private func rowMenu() -> NSMenu {
    let menu = NSMenu()
    menu.addItem(NSMenuItem(title: "Close Tab", action: #selector(closeClickedTab), keyEquivalent: ""))
    menu.items.forEach { $0.target = self }
    return menu
  }

  @objc private func closeClickedTab() {
    let row = tableView.clickedRow
    guard row >= 0, row < tabs.count else { return }
    delegate?.sidebar(self, close: tabs[row])
  }
}

final class TabRowView: NSTableCellView {
  private let icon = NSImageView()
  private let title = NSTextField(labelWithString: "")

  init() {
    super.init(frame: .zero)
    icon.imageScaling = .scaleProportionallyUpOrDown
    title.font = .systemFont(ofSize: 13)
    title.lineBreakMode = .byTruncatingTail
    addSubview(icon)
    addSubview(title)
    imageView = icon
    textField = title
  }

  required init?(coder: NSCoder) { fatalError() }

  override func layout() {
    super.layout()
    icon.frame = NSRect(x: 8, y: (bounds.height - 16) / 2, width: 16, height: 16)
    title.frame = NSRect(x: 32, y: (bounds.height - 17) / 2, width: bounds.width - 40, height: 17)
  }

  func show(_ tab: ArdiaCoreTab) {
    icon.image = tab.favicon ?? NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
    title.stringValue = tab.title.isEmpty ? AddressInput.display(for: tab.url) : tab.title
  }
}
