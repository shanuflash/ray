import AppKit

// The Bookmarks panel (the owner's pick, `docs/mocks/bookmarks.html` B): a `Panels` panel over the sidebar from the
// bookmark button in its footer (⌥⌘B), as the downloads list is. "Bookmarks" with an add button, a search field that
// has the keys while it's open, then the tree as sidebar-like rows (favicon or folder icon, title, the host or the
// folder's count in grey), folders opening in place; "Bookmark Manager" (Chrome's page) at the bottom.
//
// A click opens a page in a new Today tab and closes the panel (⌘-click: in the background, the panel stays); a click
// on a folder opens or closes it. ↑ ↓ pick a row, Return opens it, → ← open and close a folder while nothing is typed,
// Escape clears the search, then closes. Right-click: a page's Open in New Tab, Copy Link, Add to Pinned, Rename…, Delete; a
// folder's Open All, Add to Pinned, Rename…, Delete. Delete has Undo in a note. Rename… edits in the row.

final class BookmarksPanelView: NSView, NSTextFieldDelegate {
  static let width: CGFloat = 300
  static let rowHeight: CGFloat = 30
  /// Which folders are open, for the whole run (every window's panel).
  static var expanded: Set<String> = []
  private static var expandedFirst = false

  var onOpen: ((Bookmark, _ foreground: Bool) -> Void)?
  var onOpenAll: ((Bookmark) -> Void)?
  var onPin: ((Bookmark) -> Void)?
  var onCopy: ((String) -> Void)?
  var onDelete: ((Bookmarks.Removed) -> Void)?
  var onBookmarkTab: (() -> Void)?
  var canBookmarkTab: () -> Bool = { false }
  /// Pinning puts entries in the normal window's sidebar: never from a private window.
  var canPin = true
  var onManager: (() -> Void)?
  var onClose: (() -> Void)?
  /// Its height changed (rows opened, a search): the panel reshapes.
  var onResize: (() -> Void)?
  var onChange: (() -> Void)?
  /// The tallest it may be (the window's height less some room).
  var maxHeight: CGFloat = 520 { didSet { if oldValue != maxHeight { rebuild() } } }

  private let titleLabel = NSTextField(labelWithString: "Bookmarks")
  private let addButton = DownloadsListView.iconButton("plus", "Add")
  private let searchBox = NSView()
  private let searchIcon = NSImageView()
  let field = BookmarksSearchField()
  private let scroll = NSScrollView()
  private let document = PanelColumn()
  private let empty = NSTextField(labelWithString: "")
  private let footerLine = NSBox()
  private let manager = LinkButton(title: "Bookmark Manager")
  private var rows: [(node: Bookmark, depth: Int)] = []
  private var rowViews: [BookmarkRowView] = []
  private(set) var selectedID: String?
  private(set) var renamingID: String?
  private var renameField: NSTextField?
  private var rebuildWhenRenamed = false
  private var observer: NSObjectProtocol?
  private var query: String { field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }

  override init(frame: NSRect) {
    super.init(frame: frame)
    titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
    titleLabel.textColor = .secondaryLabelColor
    addButton.target = self
    addButton.action = #selector(showAddMenu)
    searchBox.wantsLayer = true
    searchBox.layer?.cornerRadius = 7
    searchBox.layer?.cornerCurve = .continuous
    searchIcon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
    searchIcon.symbolConfiguration = .init(pointSize: 11, weight: .medium)
    searchIcon.contentTintColor = .secondaryLabelColor
    field.isBordered = false
    field.drawsBackground = false
    field.focusRingType = .none
    field.font = .systemFont(ofSize: 13)
    field.placeholderString = "Search Bookmarks"
    field.cell?.isScrollable = true
    field.cell?.wraps = false
    field.delegate = self
    field.setAccessibilityLabel("Search Bookmarks")
    searchBox.addSubview(searchIcon)
    searchBox.addSubview(field)
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = true
    scroll.scrollerStyle = .overlay
    scroll.autohidesScrollers = true
    scroll.documentView = document
    scroll.contentView.drawsBackground = false
    empty.font = .systemFont(ofSize: 13)
    empty.textColor = .secondaryLabelColor
    empty.alignment = .center
    footerLine.boxType = .separator
    manager.font = .systemFont(ofSize: 12.5, weight: .medium)
    manager.background = SurfaceBackdrop.solidFill
    manager.onClick = { [weak self] in self?.onManager?() }
    [titleLabel, addButton, searchBox, scroll, empty, footerLine, manager].forEach(addSubview)
    observer = NotificationCenter.default.addObserver(forName: Bookmarks.didChange, object: nil, queue: .main) {
      [weak self] _ in self?.storeChanged()
    }
    // The first time any panel opens: a bar holding just one folder ("Imported from Chrome") shows it open.
    if !Self.expandedFirst, let bar = Bookmarks.shared.bar {
      Self.expandedFirst = true
      if bar.children.count == 1, let only = bar.children.first, only.isFolder { Self.expanded.insert(only.id) }
    }
    rebuild()
  }

  required init?(coder: NSCoder) { fatalError() }

  deinit { observer.map(NotificationCenter.default.removeObserver) }

  override var isFlipped: Bool { true }
  override var mouseDownCanMoveWindow: Bool { false }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    tintSearchBox()
  }

  /// A layer's colour is fixed when set: resolved in the panel's own appearance (light or dark).
  private func tintSearchBox() {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      searchBox.layer?.backgroundColor = SidebarColors.fill.cgColor
    }
  }

  // MARK: Rows

  private func visibleRows() -> [(node: Bookmark, depth: Int)] {
    let store = Bookmarks.shared
    if !query.isEmpty {
      let tokens = query.lowercased().split(separator: " ").map(String.init)
      return store.allLinks.filter { node in
        let title = node.title.lowercased()
        let url = Suggestions.matchable(node.url ?? "")
        return tokens.allSatisfy { title.contains($0) || url.contains($0) }
      }.prefix(200).map { ($0, 0) }
    }
    var out: [(node: Bookmark, depth: Int)] = []
    func walk(_ nodes: [Bookmark], _ depth: Int) {
      for node in nodes {
        out.append((node, depth))
        if node.isFolder, Self.expanded.contains(node.id), depth < 32 { walk(node.children, depth + 1) }
      }
    }
    walk(store.bar?.children ?? [], 0)
    if let other = store.other, !other.children.isEmpty { walk([other], 0) }
    return out
  }

  /// Rows again from the store, keeping the pick and the scroll.
  func rebuild() {
    if renamingID != nil {
      rebuildWhenRenamed = true
      return
    }
    rows = visibleRows()
    while rowViews.count > rows.count { rowViews.removeLast().removeFromSuperview() }
    while rowViews.count < rows.count {
      let view = BookmarkRowView()
      view.panel = self
      document.addSubview(view)
      rowViews.append(view)
    }
    if let selectedID, !rows.contains(where: { $0.node.id == selectedID }) { self.selectedID = nil }
    let searching = !query.isEmpty
    for (index, row) in rows.enumerated() {
      rowViews[index].show(row.node, depth: row.depth, expanded: Self.expanded.contains(row.node.id),
                           selected: row.node.id == selectedID, searching: searching)
    }
    empty.stringValue = searching ? "No Matches" : (Bookmarks.shared.loaded ? "No Bookmarks" : "")
    empty.isHidden = !rows.isEmpty
    loadIcons()
    layoutContent()
    onChange?()
  }

  private func storeChanged() { rebuild() }

  private func loadIcons() {
    guard let profile = Bookmarks.shared.profile else { return }
    let pages = rows.compactMap(\.node.url)
    Bookmarks.shared.favicons.load(pages, profile: profile) { [weak self] in
      self?.rowViews.forEach { $0.refreshIcon() }
    }
  }

  // MARK: Layout

  private static let top: CGFloat = 8
  private static let listTop: CGFloat = 74
  private static let footer: CGFloat = 38

  private var listHeight: CGFloat {
    let wanted = rows.isEmpty ? 64 : CGFloat(rows.count) * Self.rowHeight + 8
    return max(64, min(wanted, maxHeight - Self.listTop - Self.footer))
  }

  private func layoutContent() {
    let width = Self.width
    let height = Self.listTop + listHeight + Self.footer
    let resized = frame.size != NSSize(width: width, height: height)
    setFrameSize(NSSize(width: width, height: height))
    titleLabel.frame = NSRect(x: 16, y: Self.top + 6, width: 160, height: ceil(titleLabel.intrinsicContentSize.height))
    addButton.frame = NSRect(x: width - 10 - 26, y: Self.top + 2, width: 26, height: 24)
    searchBox.frame = NSRect(x: 10, y: Self.top + 32, width: width - 20, height: 28)
    searchIcon.frame = NSRect(x: 8, y: 6, width: 16, height: 16)
    let fieldHeight = ceil(field.intrinsicContentSize.height)
    field.frame = NSRect(x: 26, y: ((28 - fieldHeight) / 2).rounded(), width: searchBox.frame.width - 32, height: fieldHeight)
    scroll.frame = NSRect(x: 0, y: Self.listTop, width: width, height: listHeight)
    document.frame = NSRect(x: 0, y: 0, width: width, height: max(listHeight, CGFloat(rows.count) * Self.rowHeight + 8))
    for (index, view) in rowViews.enumerated() {
      view.frame = NSRect(x: 6, y: 4 + CGFloat(index) * Self.rowHeight, width: width - 12, height: Self.rowHeight)
    }
    let emptyHeight = ceil(empty.intrinsicContentSize.height)
    empty.frame = NSRect(x: 0, y: Self.listTop + (listHeight - emptyHeight) / 2, width: width, height: emptyHeight)
    footerLine.frame = NSRect(x: 0, y: Self.listTop + listHeight + 4, width: width, height: 1)
    manager.sizeToFit()
    manager.frame = NSRect(x: 16, y: Self.listTop + listHeight + 12, width: manager.frame.width + 4, height: 18)
    tintSearchBox()
    if resized { onResize?() }
  }

  // MARK: Actions

  func click(_ node: Bookmark, modifiers: NSEvent.ModifierFlags = []) {
    select(node.id)
    if node.isFolder {
      toggle(node)
    } else if node.opens {
      onOpen?(node, !modifiers.contains(.command))
    }
  }

  func toggle(_ node: Bookmark, open: Bool? = nil) {
    guard node.isFolder else { return }
    let opening = open ?? !Self.expanded.contains(node.id)
    if opening { Self.expanded.insert(node.id) } else { Self.expanded.remove(node.id) }
    rebuild()
  }

  private func select(_ id: String?) {
    selectedID = id
    for (index, row) in rows.enumerated() { rowViews[index].isSelected = row.node.id == id }
    if let id, let index = rows.firstIndex(where: { $0.node.id == id }) {
      document.scrollToVisible(rowViews[index].frame.insetBy(dx: 0, dy: -4))
    }
    onChange?()
  }

  /// Shows a bookmark: its folders open, the search cleared, its row picked and scrolled to; `rename` starts its field.
  func reveal(_ id: String, rename: Bool = false) {
    guard let node = Bookmarks.shared.node(id) else { return }
    var parent = node.parent
    while let folder = parent, !(folder.id == Bookmarks.barID) {
      Self.expanded.insert(folder.id)
      parent = folder.parent
    }
    field.stringValue = ""
    rebuild()
    select(id)
    if rename { beginRename(id) }
  }

  private func moveSelection(_ step: Int) {
    guard !rows.isEmpty else { return }
    let at = selectedID.flatMap { id in rows.firstIndex { $0.node.id == id } }
    let next = at.map { max(0, min(rows.count - 1, $0 + step)) } ?? (step > 0 ? 0 : rows.count - 1)
    select(rows[next].node.id)
  }

  private var selectedNode: Bookmark? { selectedID.flatMap(Bookmarks.shared.node) }

  @objc private func showAddMenu() {
    let menu = NSMenu()
    let tab = NSMenuItem(title: "Bookmark This Tab", action: #selector(addTab), keyEquivalent: "")
    tab.target = self
    tab.isEnabled = canBookmarkTab()
    menu.autoenablesItems = false
    menu.addItem(tab)
    let folder = NSMenuItem(title: "New Folder", action: #selector(addFolder), keyEquivalent: "")
    folder.target = self
    menu.addItem(folder)
    menu.popUp(positioning: nil, at: NSPoint(x: addButton.frame.minX, y: addButton.frame.maxY + 4), in: self)
  }

  @objc func addTab() { onBookmarkTab?() }

  /// A new folder at the end of the bar, its name being typed.
  @objc func addFolder() {
    Bookmarks.shared.addFolder("New Folder") { [weak self] id in self?.reveal(id, rename: true) }
  }

  // MARK: Row menus

  func menu(for node: Bookmark) -> NSMenu {
    select(node.id)
    let menu = NSMenu()
    menu.autoenablesItems = false
    func add(_ title: String, enabled: Bool = true, _ run: @escaping () -> Void) {
      let item = NSMenuItem(title: title, action: #selector(BookmarkMenuAction.run(_:)), keyEquivalent: "")
      let action = BookmarkMenuAction(run)
      item.target = action
      item.representedObject = action
      item.isEnabled = enabled
      menu.addItem(item)
    }
    if let url = node.url {
      add("Open in New Tab", enabled: node.opens) { [weak self] in self?.onOpen?(node, true) }
      add("Copy Link") { [weak self] in self?.onCopy?(url) }
      menu.addItem(.separator())
      add("Add to Pinned", enabled: canPin && node.opens) { [weak self] in self?.onPin?(node) }
    } else {
      let links = node.links.filter(\.opens)
      add("Open All (\(links.count))", enabled: !links.isEmpty) { [weak self] in self?.onOpenAll?(node) }
      add("Add to Pinned", enabled: canPin && !links.isEmpty) { [weak self] in self?.onPin?(node) }
    }
    if !node.isRoot {
      if node.isFolder { menu.addItem(.separator()) }
      add("Rename…") { [weak self] in self?.beginRename(node.id) }
      menu.addItem(.separator())
      add("Delete") { [weak self] in self?.delete(node) }
    }
    return menu
  }

  func delete(_ node: Bookmark) {
    guard let removed = Bookmarks.shared.remove(node.id) else { return }
    onDelete?(removed)
  }

  // MARK: Rename

  func beginRename(_ id: String) {
    guard let node = Bookmarks.shared.node(id), !node.isRoot,
          let index = rows.firstIndex(where: { $0.node.id == id }) else { return }
    endRename(commit: false)
    let row = rowViews[index]
    let editor = NSTextField(string: node.title)
    editor.font = .systemFont(ofSize: 13)
    editor.isBordered = false
    editor.focusRingType = .none
    editor.drawsBackground = true
    editor.backgroundColor = .textBackgroundColor
    editor.wantsLayer = true
    editor.layer?.cornerRadius = 6
    editor.cell?.isScrollable = true
    editor.cell?.wraps = false
    editor.delegate = self
    editor.setAccessibilityLabel("Name")
    renamingID = id
    renameField = editor
    row.beginRename(editor)
    window?.makeFirstResponder(editor)
    editor.currentEditor()?.selectAll(nil)
    onChange?()
  }

  /// Ends the row's name field: what's typed becomes the name (an empty one is refused), or nothing changes.
  func endRename(commit: Bool) {
    guard let id = renamingID, let editor = renameField else { return }
    let text = editor.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    renamingID = nil
    renameField = nil
    editor.delegate = nil
    let refocus = window?.firstResponder === editor.currentEditor()
    editor.removeFromSuperview()
    if commit, !text.isEmpty { Bookmarks.shared.rename(id, to: String(text.prefix(1000))) }
    if refocus { window?.makeFirstResponder(field) }
    rowViews.forEach { $0.endRename() }
    if rebuildWhenRenamed {
      rebuildWhenRenamed = false
      rebuild()
    }
    onChange?()
  }

  /// For tests: types into the open name field and presses Return.
  func debugRename(_ text: String) -> Bool {
    guard let renameField else { return false }
    renameField.stringValue = text
    endRename(commit: true)
    return true
  }

  // MARK: Keys

  func controlTextDidChange(_ notification: Notification) {
    guard notification.object as AnyObject === field else { return }
    selectedID = nil
    rebuild()
    if !query.isEmpty, let first = rows.first { select(first.node.id) }
  }

  func controlTextDidEndEditing(_ notification: Notification) {
    guard let editor = renameField, notification.object as AnyObject === editor else { return }
    endRename(commit: true)
  }

  func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
    if control === renameField {
      switch selector {
      case #selector(NSResponder.insertNewline(_:)): endRename(commit: true)
      case #selector(NSResponder.cancelOperation(_:)): endRename(commit: false)
      default: return false
      }
      return true
    }
    return key(selector)
  }

  /// The search field's keys; also the test command's.
  @discardableResult
  func key(_ selector: Selector) -> Bool {
    switch selector {
    case #selector(NSResponder.moveDown(_:)): moveSelection(1)
    case #selector(NSResponder.moveUp(_:)): moveSelection(-1)
    case #selector(NSResponder.insertNewline(_:)):
      if let node = selectedNode ?? (query.isEmpty ? nil : rows.first?.node) { click(node) }
    case #selector(NSResponder.moveRight(_:)) where field.stringValue.isEmpty:
      if let node = selectedNode, node.isFolder { toggle(node, open: true) }
    case #selector(NSResponder.moveLeft(_:)) where field.stringValue.isEmpty:
      guard let node = selectedNode else { return true }
      if node.isFolder, Self.expanded.contains(node.id) {
        toggle(node, open: false)
      } else if let parent = node.parent, parent.id != Bookmarks.barID {
        select(parent.id)
      }
    case #selector(NSResponder.cancelOperation(_:)):
      if field.stringValue.isEmpty {
        onClose?()
      } else {
        field.stringValue = ""
        selectedID = nil
        rebuild()
      }
    default: return false
    }
    return true
  }

  /// For tests: what the search field would get from typing.
  func debugSearch(_ text: String) {
    field.stringValue = text
    controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
  }

  func row(for id: String) -> Bookmark? { rows.first { $0.node.id == id }?.node }

  // MARK: State

  var debug: [String: Any] {
    [
      "query": field.stringValue, "selected": selectedID ?? NSNull(), "renaming": renamingID ?? NSNull(),
      "height": Int(frame.height), "searchFocused": window?.firstResponder === field.currentEditor(),
      "rows": rows.map { row -> [String: Any] in
        var out: [String: Any] = ["id": row.node.id, "title": BookmarkRowView.title(of: row.node), "depth": row.depth,
                                  "folder": row.node.isFolder]
        if row.node.isFolder {
          out["open"] = Self.expanded.contains(row.node.id)
        } else {
          out["host"] = AddressInput.host(of: row.node.url ?? "")
          out["opens"] = row.node.opens
        }
        return out
      },
      "empty": empty.isHidden ? NSNull() : empty.stringValue,
    ]
  }
}

/// The panel's search field: the keys go to the panel while it's open.
final class BookmarksSearchField: NSTextField {
  override var mouseDownCanMoveWindow: Bool { false }
}

/// A menu item's closure.
final class BookmarkMenuAction: NSObject {
  private let action: () -> Void
  init(_ action: @escaping () -> Void) { self.action = action }
  @objc func run(_ sender: Any?) { action() }
}

// MARK: Row

/// One row: a chevron for a folder, its icon (the page's favicon, a globe, or Ray's folder icon), the title, and the
/// host or the folder's count in grey on the right. Indented 16 pt a level.
final class BookmarkRowView: NSView {
  weak var panel: BookmarksPanelView?
  private(set) var node: Bookmark?
  private let fill = CALayer()
  private let chevron = NSImageView()
  private let favicon = NSImageView()
  private let folderIcon = FolderIconView(frame: NSRect(origin: .zero, size: FolderIconView.size))
  private let title = NSTextField(labelWithString: "")
  private let trailing = NSTextField(labelWithString: "")
  private var depth = 0
  private var expanded = false
  private var hovered = false
  private var editor: NSTextField?
  var isSelected = false { didSet { if oldValue != isSelected { needsDisplay = true } } }

  private static let globe = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
  /// The picked row: Settings' selected-row wash of the profile's colour (`SettingsColors.selectedFill`), over the panel.
  private static let selectedFill = ProfileColor.mix(
    NSColor(name: nil) { _ in ProfileColor.accent }, over: SurfaceBackdrop.solidFill, 0.17, dark: 0.26)
  private static let chevronRight = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
  private static let chevronDown = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)

  init() {
    super.init(frame: .zero)
    wantsLayer = true
    fill.cornerRadius = 8
    fill.cornerCurve = .continuous
    layer?.addSublayer(fill)
    chevron.symbolConfiguration = .init(pointSize: 9, weight: .semibold)
    chevron.contentTintColor = .tertiaryLabelColor
    favicon.imageScaling = .scaleProportionallyUpOrDown
    title.font = .systemFont(ofSize: 13)
    title.lineBreakMode = .byTruncatingTail
    trailing.font = .systemFont(ofSize: 12)
    trailing.textColor = .secondaryLabelColor
    trailing.lineBreakMode = .byTruncatingHead
    trailing.alignment = .right
    [chevron, favicon, folderIcon, title, trailing].forEach(addSubview)
    addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    setAccessibilityElement(true)
    setAccessibilityRole(.button)
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }
  override var wantsUpdateLayer: Bool { true }
  override var mouseDownCanMoveWindow: Bool { false }

  static func title(of node: Bookmark) -> String {
    node.id == Bookmarks.otherID ? "Other Bookmarks" : BookmarksMenu.menuTitle(node.shownTitle)
  }

  func show(_ node: Bookmark, depth: Int, expanded: Bool, selected: Bool, searching: Bool) {
    let same = self.node === node || self.node?.id == node.id
    self.node = node
    self.depth = depth
    self.expanded = expanded
    isSelected = selected
    title.stringValue = Self.title(of: node)
    title.textColor = node.isFolder || node.opens ? .labelColor : .tertiaryLabelColor
    if node.isFolder {
      trailing.stringValue = "\(node.links.count)"
    } else {
      trailing.stringValue = node.url.map(AddressInput.host(of:)).map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 } ?? ""
    }
    chevron.isHidden = !node.isFolder
    folderIcon.isHidden = !node.isFolder
    favicon.isHidden = node.isFolder
    folderIcon.setState(open: expanded, hovered: hovered, dropTarget: false, animated: same && window != nil)
    chevron.image = expanded ? Self.chevronDown : Self.chevronRight
    refreshIcon()
    setAccessibilityLabel(title.stringValue)
    needsLayout = true
    needsDisplay = true
  }

  func refreshIcon() {
    guard let node, let url = node.url else { return }
    favicon.image = Bookmarks.shared.favicons.image(for: url) ?? Self.globe
    favicon.contentTintColor = Bookmarks.shared.favicons.image(for: url) == nil ? .secondaryLabelColor : nil
  }

  override func updateLayer() {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    fill.backgroundColor = (isSelected ? Self.selectedFill : hovered ? SidebarColors.hover : .clear).cgColor
    CATransaction.commit()
  }

  override func layout() {
    super.layout()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    fill.frame = bounds
    CATransaction.commit()
    let indent = CGFloat(depth) * 16
    let mid = bounds.height / 2
    chevron.frame = NSRect(x: 6 + indent, y: mid - 6, width: 12, height: 12)
    let iconX = 22 + indent
    favicon.frame = NSRect(x: iconX, y: mid - 8, width: 16, height: 16)
    folderIcon.frame = NSRect(x: iconX - 2, y: (mid - FolderIconView.size.height / 2).rounded(),
                              width: FolderIconView.size.width, height: FolderIconView.size.height)
    let textX = iconX + 24
    trailing.sizeToFit()
    let trailingWidth = min(ceil(trailing.frame.width) + 2, 110)
    let lineHeight = ceil(title.intrinsicContentSize.height)
    trailing.frame = NSRect(x: bounds.width - 10 - trailingWidth, y: (mid - ceil(trailing.intrinsicContentSize.height) / 2).rounded(),
                            width: trailingWidth, height: ceil(trailing.intrinsicContentSize.height))
    title.frame = NSRect(x: textX, y: (mid - lineHeight / 2).rounded(), width: max(0, trailing.frame.minX - 8 - textX),
                         height: lineHeight)
    if let editor {
      let height = ceil(editor.intrinsicContentSize.height) + 2
      editor.frame = NSRect(x: textX - 3, y: (mid - height / 2).rounded(), width: bounds.width - textX - 6, height: height)
    }
  }

  func beginRename(_ editor: NSTextField) {
    self.editor = editor
    addSubview(editor)
    title.isHidden = true
    trailing.isHidden = true
    needsLayout = true
  }

  func endRename() {
    editor = nil
    title.isHidden = false
    trailing.isHidden = false
    needsLayout = true
  }

  override func mouseEntered(with event: NSEvent) {
    hovered = true
    if let node, node.isFolder { folderIcon.setState(open: expanded, hovered: true, dropTarget: false, animated: true) }
    needsDisplay = true
  }

  override func mouseExited(with event: NSEvent) {
    hovered = false
    if let node, node.isFolder { folderIcon.setState(open: expanded, hovered: false, dropTarget: false, animated: true) }
    needsDisplay = true
  }

  override func mouseDown(with event: NSEvent) {}

  override func mouseUp(with event: NSEvent) {
    guard editor == nil, let node, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
    panel?.click(node, modifiers: event.modifierFlags)
  }

  override func menu(for event: NSEvent) -> NSMenu? {
    guard editor == nil, let node else { return nil }
    return panel?.menu(for: node)
  }

  override func accessibilityPerformPress() -> Bool {
    guard let node else { return false }
    panel?.click(node)
    return true
  }
}
