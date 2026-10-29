import AppKit

/// Ray's own Settings window (⌘, in the Ray menu; `ray://settings/<pane>`; the command bar's "Settings: …" rows).
/// Direction G: a sidebar like Ray's own, darker than the content, with a search field on top, the panes as rows of
/// icon and name (the selected one washed in the profile's colour) in three groups, and "All Chrome Settings…" at the
/// bottom; the content is one roomy column (`SettingsPaneView`). Searching replaces the pane list with results;
/// choosing one opens its pane, scrolls to its row and flashes it. Panes and rows come from the catalog
/// (`SettingsCatalog.swift`) and each pane's `SettingsPaneContent` (`SettingsPanes.swift`).
final class SettingsWindowController: NSObject, NSWindowDelegate {
  static let shared = SettingsWindowController()

  static let size = NSSize(width: 780, height: 560)
  static let minSize = NSSize(width: 640, height: 440)
  static let sidebarWidth: CGFloat = 210

  private var window: NSWindow?
  private var root: SettingsRootView?
  private var paneViews: [SettingPane: SettingsPaneView] = [:]
  private(set) var pane: SettingPane?
  /// What ⌘, opens next: the pane last shown.
  private var lastPane: SettingPane?
  private var saveFrame: DispatchWorkItem?
  private var flashing: String?
  private var lastFlash: String?
  private var flashEnd: DispatchWorkItem?

  var isOpen: Bool { window?.isVisible ?? false }
  var isKey: Bool { window?.isKeyWindow ?? false }

  /// Brings the window forward at a pane: `name` is a pane's id (`ray://settings/<name>`); nil is the last pane shown,
  /// or General. A pane the window doesn't list opens the first one it does.
  func show(pane name: String? = nil) {
    let wanted = name.flatMap(SettingPane.init(rawValue:)) ?? lastPane ?? .general
    let shown = SettingPane.shown
    let target = shown.contains(wanted) ? wanted : (shown.first ?? .appearance)
    let window = self.window ?? makeWindow()
    root?.sidebar.reload()
    select(target)
    if launchedInBackground {
      // A test instance never takes focus: the window goes on screen behind everything.
      window.orderBack(nil)
    } else {
      NSApp.activate()
      window.makeKeyAndOrderFront(nil)
    }
    logAll("settingsWindow")
  }

  /// Opens the window at a search result or a command bar row: its pane, scrolled to its row, which flashes.
  func reveal(_ target: SettingsTarget) {
    show(pane: target.pane.rawValue)
    guard let anchor = target.anchor else { return }
    flash(anchor)
  }

  func close() { window?.performClose(nil) }

  private func makeWindow() -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: Self.size),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered, defer: false)
    window.title = "Settings"
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.isReleasedWhenClosed = false
    window.isRestorable = false
    window.animationBehavior = .none
    window.tabbingMode = .disallowed
    window.minSize = Self.minSize
    window.backgroundColor = SettingsColors.content
    window.delegate = self
    for pane in SettingPane.allCases {
      let view = SettingsPaneView(pane: pane)
      view.onResize = { [weak self] in self?.root?.fitDocument() }
      paneViews[pane] = view
    }
    let root = SettingsRootView(frame: NSRect(origin: .zero, size: Self.size))
    root.sidebar.onSelect = { [weak self] pane in self?.select(pane) }
    root.sidebar.onChoose = { [weak self] target in self?.reveal(target) }
    root.sidebar.onAllSettings = { [weak self] in self?.openAllSettings() }
    root.sidebar.onSearch = { [weak self] in self?.logAll("settingsSearch") }
    window.contentView = root
    self.root = root
    if let text = RaySettings.shared.windowFrame {
      let frame = NSRectFromString(text)
      // Only where it still lands on a screen, and never smaller than the window's minimum.
      if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }),
         frame.width >= Self.minSize.width, frame.height >= Self.minSize.height {
        window.setFrame(frame, display: false)
      } else {
        window.center()
      }
    } else {
      window.center()
    }
    NotificationCenter.default.addObserver(self, selector: #selector(accentChanged), name: ProfileColor.didChange, object: nil)
    self.window = window
    return window
  }

  /// Shows a pane in the content column, from its top.
  private func select(_ pane: SettingPane) {
    guard let root, let view = paneViews[pane] else { return }
    if self.pane != pane {
      self.pane = pane
      root.show(view)
    }
    lastPane = pane
    root.sidebar.selected = pane
    logAll("settingsPane")
  }

  /// Scrolls the current pane to a row (or section) and flashes it.
  private func flash(_ anchor: String) {
    guard let root, let pane, let view = paneViews[pane] else { return }
    // A rare row's "More" opens before the pane is measured.
    guard let target = view.anchorView(anchor) else { return }
    root.fitDocument()
    root.layoutSubtreeIfNeeded()
    let rect = target.convert(target.bounds, to: view)
    view.scrollToVisible(rect.insetBy(dx: 0, dy: -48))
    SettingsFlash.run(on: target)
    flashing = anchor
    lastFlash = anchor
    flashEnd?.cancel()
    let work = DispatchWorkItem { [weak self] in
      self?.flashing = nil
      self?.logAll("settingsFlash")
    }
    flashEnd = work
    DispatchQueue.main.asyncAfter(deadline: .now() + SettingsFlash.duration, execute: work)
    logAll("settingsFlash")
  }

  func openAllSettings() { AppController.shared.openChromeSettings() }

  @objc private func accentChanged() {
    window?.contentView?.setNeedsDisplayRecursively()
    for view in paneViews.values where view.superview == nil { view.setNeedsDisplayRecursively() }
    logAll("settingsColour")
  }

  // MARK: NSWindowDelegate

  func windowDidResize(_ notification: Notification) { rememberFrameSoon() }

  func windowDidMove(_ notification: Notification) { rememberFrameSoon() }

  func windowWillClose(_ notification: Notification) {
    paneViews.values.forEach { $0.closeColorPanel() }
    if let window { RaySettings.shared.rememberWindowFrame(window.frame) }
    logAll("settingsWindow")
  }

  private func rememberFrameSoon() {
    saveFrame?.cancel()
    let work = DispatchWorkItem { [weak self] in
      guard let window = self?.window else { return }
      RaySettings.shared.rememberWindowFrame(window.frame)
    }
    saveFrame = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
  }

  private func logAll(_ event: String) {
    // The window's state is part of every browser window's state log; a test reads whichever logged last.
    DispatchQueue.main.async { AppController.shared.current?.logState(event) }
  }

  // MARK: Tests

  var debug: [String: Any] {
    var controls: [String: Any] = ["allSettingsLink": root?.sidebar.linkTitle ?? ""]
    var rows: [String: Any] = [:]
    var more: [String: Any] = [:]
    var pictures: [String: Any] = [:]
    for pane in SettingPane.allCases {
      guard let view = paneViews[pane] else { continue }
      controls.merge(view.controlsDebug) { a, _ in a }
      pictures.merge(view.picturesDebug) { a, _ in a }
      if pane.isShown { rows[pane.rawValue] = view.anchors }
      if !view.moreOpen.isEmpty { more[pane.rawValue] = view.moreOpen }
    }
    let colours: [String: Any] = [
      "fill": ProfileColor.hex(of: SettingsColors.selectedFill),
      "fillDark": ProfileColor.hex(of: SettingsColors.selectedFill, appearance: .darkAqua),
      "ink": ProfileColor.hex(of: SettingsColors.selectedInk),
      "inkDark": ProfileColor.hex(of: SettingsColors.selectedInk, appearance: .darkAqua),
      "contrast": ProfileColor.contrast(SettingsColors.selectedInk, SettingsColors.selectedFill, appearance: .aqua),
      "contrastDark": ProfileColor.contrast(SettingsColors.selectedInk, SettingsColors.selectedFill, appearance: .darkAqua),
      "sidebar": ProfileColor.hex(of: SettingsColors.sidebar),
      "sidebarDark": ProfileColor.hex(of: SettingsColors.sidebar, appearance: .darkAqua),
      "content": ProfileColor.hex(of: SettingsColors.content),
      "contentDark": ProfileColor.hex(of: SettingsColors.content, appearance: .darkAqua),
      "drawnFill": root?.sidebar.selectedRowFill ?? NSNull(),
    ]
    return [
      "open": isOpen, "pane": pane?.rawValue ?? NSNull(),
      "panes": SettingPane.shown.map(\.rawValue), "sidebarPanes": root?.sidebar.listedPanes ?? [],
      "windows": NSApp.windows.filter { $0.title == "Settings" && $0.isVisible }.count,
      "frame": window.map { NSStringFromRect($0.frame) } ?? "", "title": window?.title ?? "",
      "controls": controls, "rows": rows, "more": more, "pictures": pictures,
      "search": root?.sidebar.searchDebug ?? NSNull(),
      "flashing": flashing ?? NSNull(), "lastFlash": lastFlash ?? NSNull(),
      "flashVisible": lastFlash.map(anchorVisible) ?? false,
      "selectedRow": colours, "looksLikeRayApp": AnySettingKey.looksLikeRayApp,
    ]
  }

  /// Whether a row of the current pane is inside the visible part of the content.
  private func anchorVisible(_ anchor: String) -> Bool {
    guard let pane, let view = paneViews[pane], view.anchors.contains(anchor), let target = view.anchorView(anchor),
          let clip = view.enclosingScrollView?.contentView else { return false }
    let rect = target.convert(target.bounds, to: view)
    return clip.documentVisibleRect.contains(rect)
  }

  /// For tests: draws the window into PNGs (light and dark), to look at its design.
  func snapshot(to path: String) -> Bool {
    guard let window, let content = window.contentView else { return false }
    for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
      let old = window.appearance
      window.appearance = NSAppearance(named: appearance)
      defer { window.appearance = old }
      content.layoutSubtreeIfNeeded()
      content.setNeedsDisplayRecursively()
      content.displayIfNeeded()
      guard let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return false }
      content.cacheDisplay(in: content.bounds, to: rep)
      guard let png = rep.representation(using: .png, properties: [:]) else { return false }
      guard (try? png.write(to: URL(fileURLWithPath: path.replacingOccurrences(of: ".png", with: "-\(name).png")))) != nil
      else { return false }
    }
    return true
  }

  /// For tests: the "All Chrome Settings…" link.
  func pressAllSettings() -> Bool {
    guard window != nil else { return false }
    openAllSettings()
    return true
  }

  /// For tests: a control pressed as a click would (a switch by name, `<id> <n>` for a pop-up's item, a segment, a
  /// picture or a swatch), in whichever pane it is.
  func press(_ words: [String]) -> Bool {
    for view in paneViews.values where view.press(words) { return true }
    return false
  }

  /// For tests: `settings open <pane>`; false for a name that is no pane.
  func open(paneNamed name: String) -> Bool {
    guard SettingPane(rawValue: name) != nil else { return false }
    show(pane: name)
    return true
  }

  /// For tests: types into the sidebar's search field, as the keyboard would.
  func search(_ text: String) -> Bool {
    if window == nil { show() }
    root?.sidebar.type(text)
    return true
  }

  /// For tests: picks search result `index` as a click would.
  func chooseResult(_ index: Int) -> Bool { root?.sidebar.choose(index) ?? false }

  /// For tests: ↑ ↓ ⏎ or Escape in the search field.
  func searchKey(_ name: String) -> Bool {
    let selector: Selector
    switch name {
    case "up": selector = #selector(NSResponder.moveUp(_:))
    case "down": selector = #selector(NSResponder.moveDown(_:))
    case "enter": selector = #selector(NSResponder.insertNewline(_:))
    case "escape": selector = #selector(NSResponder.cancelOperation(_:))
    default: return false
    }
    return root?.sidebar.command(selector) ?? false
  }

  /// For tests: lists panes and rows as Ray.app would (unbuilt rows and empty panes hidden), or as test builds do.
  func lookLikeRayApp(_ on: Bool) {
    AnySettingKey.looksLikeRayApp = on
    // Rows are built once: rebuild the panes so they follow.
    guard window != nil else { return logAll("settingsWindow") }
    for pane in SettingPane.allCases {
      let view = SettingsPaneView(pane: pane)
      view.onResize = { [weak self] in self?.root?.fitDocument() }
      paneViews[pane] = view
    }
    pane = nil
    root?.sidebar.reload()
    if isOpen { show(pane: lastPane?.rawValue) }
    logAll("settingsWindow")
  }
}

// MARK: Root

/// The window's content: the sidebar on the left (under the traffic lights) and the pane's scroll view.
private final class SettingsRootView: NSView {
  let sidebar = SettingsSidebarView()
  private let scroll = NSScrollView()

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.scrollerStyle = .overlay
    scroll.automaticallyAdjustsContentInsets = false
    addSubview(scroll)
    addSubview(sidebar)
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }
  override var wantsUpdateLayer: Bool { true }
  override func updateLayer() { layer?.backgroundColor = SettingsColors.content.cgColor }

  func show(_ pane: SettingsPaneView) {
    scroll.documentView = pane
    fitDocument()
    pane.scroll(.zero)
  }

  /// The document is as wide as the scroll view and as tall as its pane (at least the scroll view).
  func fitDocument() {
    guard let pane = scroll.documentView as? SettingsPaneView else { return }
    let width = scroll.contentSize.width
    pane.frame = NSRect(x: 0, y: pane.frame.minY, width: width, height: max(scroll.contentSize.height, pane.height(forWidth: width)))
    pane.needsLayout = true
  }

  override func layout() {
    super.layout()
    let width = SettingsWindowController.sidebarWidth
    sidebar.frame = NSRect(x: 0, y: 0, width: width, height: bounds.height)
    scroll.frame = NSRect(x: width, y: 0, width: bounds.width - width, height: bounds.height)
    fitDocument()
  }
}

// MARK: Sidebar

/// The window's sidebar: search on top, the panes (or search results while there is a query), and the link to
/// Chrome's own settings at the bottom.
private final class SettingsSidebarView: NSView, NSTextFieldDelegate {
  var onSelect: ((SettingPane) -> Void)?
  var onChoose: ((SettingsTarget) -> Void)?
  var onAllSettings: (() -> Void)?
  var onSearch: (() -> Void)?
  var selected: SettingPane? {
    didSet { navRows.forEach { $0.isSelected = $0.pane == selected } }
  }

  private let searchField = SettingsSearchField()
  private let scroll = NSScrollView()
  private let list = FlippedView()
  private let link = LinkButton(title: "All Chrome Settings…")
  private var navRows: [SettingsNavRow] = []
  private var headers: [NSTextField] = []
  private var resultRows: [SettingsResultRow] = []
  private var results: [SettingsTarget] = []
  private var selectedResult = 0
  private let empty = settingsLabel("No Results", size: 13, weight: .medium, color: .secondaryLabelColor)

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    searchField.field.delegate = self
    searchField.onClear = { [weak self] in self?.refreshResults() }
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.scrollerStyle = .overlay
    scroll.automaticallyAdjustsContentInsets = false
    scroll.documentView = list
    link.background = SettingsColors.sidebar
    link.font = .systemFont(ofSize: 12, weight: .medium)
    link.onClick = { [weak self] in self?.onAllSettings?() }
    empty.alignment = .center
    addSubview(searchField)
    addSubview(scroll)
    addSubview(link)
    reload()
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }
  override var wantsUpdateLayer: Bool { true }
  override func updateLayer() { layer?.backgroundColor = SettingsColors.sidebar.cgColor }

  var linkTitle: String { link.title }
  var listedPanes: [String] { query.isEmpty ? navRows.map(\.pane.rawValue) : [] }
  private var query: String { searchField.field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }

  /// The selected row's fill as drawn now (for the state log).
  var selectedRowFill: String? {
    guard let row = navRows.first(where: \.isSelected), let color = row.layer?.backgroundColor,
          let ns = NSColor(cgColor: color) else { return nil }
    return ProfileColor.hex(of: ns)
  }

  /// The pane list again, if the panes shown changed.
  func reload() {
    guard navRows.map(\.pane) != SettingPane.shown else { return }
    navRows.forEach { $0.removeFromSuperview() }
    headers.forEach { $0.removeFromSuperview() }
    navRows = []
    headers = []
    var section: SettingPane.Section?
    for pane in SettingPane.shown {
      if pane.section != section, let title = pane.section.title {
        let header = settingsLabel(title, size: 11, weight: .semibold, color: .tertiaryLabelColor)
        header.identifier = NSUserInterfaceItemIdentifier(pane.section.rawValue)
        headers.append(header)
        list.addSubview(header)
      }
      section = pane.section
      let row = SettingsNavRow(pane: pane)
      row.isSelected = pane == selected
      row.onClick = { [weak self] in self?.onSelect?(pane) }
      navRows.append(row)
      list.addSubview(row)
    }
    refreshResults()
  }

  // MARK: Search

  func controlTextDidChange(_ notification: Notification) { refreshResults() }

  func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
    command(selector)
  }

  /// ↑ ↓ move through the results, ⏎ opens the one picked, Escape clears the search.
  @discardableResult
  func command(_ selector: Selector) -> Bool {
    switch selector {
    case #selector(NSResponder.moveUp(_:)):
      guard !results.isEmpty else { return false }
      pick(max(0, selectedResult - 1))
    case #selector(NSResponder.moveDown(_:)):
      guard !results.isEmpty else { return false }
      pick(min(results.count - 1, selectedResult + 1))
    case #selector(NSResponder.insertNewline(_:)):
      guard results.indices.contains(selectedResult) else { return false }
      onChoose?(results[selectedResult])
    case #selector(NSResponder.cancelOperation(_:)):
      guard !searchField.field.stringValue.isEmpty else { return false }
      searchField.field.stringValue = ""
      refreshResults()
    default: return false
    }
    return true
  }

  /// For tests: the text typed, as the keyboard would leave it.
  func type(_ text: String) {
    searchField.field.stringValue = text
    refreshResults()
  }

  func choose(_ index: Int) -> Bool {
    guard results.indices.contains(index) else { return false }
    pick(index)
    onChoose?(results[index])
    return true
  }

  private func pick(_ index: Int) {
    selectedResult = index
    for (offset, row) in resultRows.enumerated() { row.isSelected = offset == index }
    if resultRows.indices.contains(index) { list.scrollToVisible(resultRows[index].frame.insetBy(dx: 0, dy: -8)) }
    onSearch?()
  }

  private func refreshResults() {
    resultRows.forEach { $0.removeFromSuperview() }
    resultRows = []
    results = query.isEmpty ? [] : SettingsSearch.search(query)
    selectedResult = 0
    for (index, target) in results.enumerated() {
      let row = SettingsResultRow(target: target)
      row.isSelected = index == 0
      row.onClick = { [weak self] in _ = self?.choose(index) }
      resultRows.append(row)
      list.addSubview(row)
    }
    let searching = !query.isEmpty
    navRows.forEach { $0.isHidden = searching }
    headers.forEach { $0.isHidden = searching }
    if searching, results.isEmpty { list.addSubview(empty) } else { empty.removeFromSuperview() }
    searchField.showsClear = searching
    needsLayout = true
    onSearch?()
  }

  var searchDebug: [String: Any] {
    [
      "query": searchField.field.stringValue, "selected": results.isEmpty ? -1 : selectedResult,
      "results": results.map { ["id": $0.id, "kind": $0.kind.rawValue, "pane": $0.pane.rawValue, "title": $0.title] },
    ]
  }

  // MARK: Layout

  override func layout() {
    super.layout()
    let inset: CGFloat = 10
    // Under the traffic lights.
    searchField.frame = NSRect(x: inset, y: 42, width: bounds.width - inset * 2, height: 30)
    let linkSize = link.intrinsicContentSize
    link.frame = NSRect(x: inset + 10, y: bounds.height - 18 - linkSize.height, width: linkSize.width, height: linkSize.height)
    scroll.frame = NSRect(x: 0, y: 82, width: bounds.width, height: max(0, link.frame.minY - 12 - 82))
    let width = scroll.contentSize.width
    var y: CGFloat = 0
    if query.isEmpty {
      var headerIndex = 0
      var section: SettingPane.Section?
      for row in navRows {
        if row.pane.section != section, row.pane.section.title != nil, headerIndex < headers.count {
          y += 12
          let header = headers[headerIndex]
          let height = ceil(header.intrinsicContentSize.height)
          header.frame = NSRect(x: inset + 10, y: y, width: width - inset * 2 - 10, height: height)
          y += height + 6
          headerIndex += 1
        }
        section = row.pane.section
        row.frame = NSRect(x: inset, y: y, width: width - inset * 2, height: 34)
        y += 34 + 1
      }
    } else if results.isEmpty {
      empty.frame = NSRect(x: inset, y: 24, width: width - inset * 2, height: ceil(empty.intrinsicContentSize.height))
      y = empty.frame.maxY
    } else {
      for row in resultRows {
        row.frame = NSRect(x: inset, y: y, width: width - inset * 2, height: 42)
        y += 42 + 1
      }
    }
    list.frame = NSRect(x: 0, y: 0, width: width, height: max(y + 8, scroll.contentSize.height))
  }
}

/// The search field: the sidebar's fill, a magnifier, and a clear button while there is text.
private final class SettingsSearchField: NSView {
  let field = NSTextField()
  private let icon = NSImageView()
  private let clear = NSButton()
  var showsClear = false { didSet { clear.isHidden = !showsClear } }

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.cornerRadius = 8
    layer?.cornerCurve = .continuous
    icon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
    icon.symbolConfiguration = .init(pointSize: 12, weight: .semibold)
    icon.contentTintColor = .tertiaryLabelColor
    field.isBezeled = false
    field.isBordered = false
    field.drawsBackground = false
    field.focusRingType = .none
    field.font = .systemFont(ofSize: 13)
    field.placeholderString = "Search"
    field.cell?.isScrollable = true
    field.cell?.wraps = false
    field.setAccessibilityLabel("Search settings")
    clear.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Clear")
    clear.isBordered = false
    clear.bezelStyle = .regularSquare
    clear.imagePosition = .imageOnly
    clear.contentTintColor = .tertiaryLabelColor
    clear.refusesFirstResponder = true
    clear.target = self
    clear.action = #selector(clearText)
    clear.isHidden = true
    addSubview(icon)
    addSubview(field)
    addSubview(clear)
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }
  override var wantsUpdateLayer: Bool { true }
  override var mouseDownCanMoveWindow: Bool { false }
  override func updateLayer() { layer?.backgroundColor = SettingsColors.track.cgColor }

  override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(field) }

  var onClear: (() -> Void)?

  @objc private func clearText() {
    field.stringValue = ""
    onClear?()
  }

  override func layout() {
    super.layout()
    icon.frame = NSRect(x: 9, y: ((bounds.height - 16) / 2).rounded(), width: 16, height: 16)
    let height = ceil(field.intrinsicContentSize.height)
    field.frame = NSRect(x: 30, y: ((bounds.height - height) / 2).rounded(), width: bounds.width - 30 - 26, height: height)
    clear.frame = NSRect(x: bounds.width - 24, y: ((bounds.height - 18) / 2).rounded(), width: 18, height: 18)
  }
}

/// A row that lights on hover and washes in the profile's colour when selected (Ray's sidebar rows).
private class SettingsSidebarRow: NSView {
  var onClick: (() -> Void)?
  var isSelected = false { didSet { if oldValue != isSelected { needsDisplay = true } } }
  private var hovered = false { didSet { if oldValue != hovered { needsDisplay = true } } }

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.cornerRadius = 9
    layer?.cornerCurve = .continuous
    addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }
  override var wantsUpdateLayer: Bool { true }
  override var mouseDownCanMoveWindow: Bool { false }

  override func updateLayer() {
    layer?.backgroundColor = (isSelected ? SettingsColors.selectedFill : hovered ? SettingsColors.hover : .clear).cgColor
    updateInk(isSelected ? SettingsColors.selectedInk : nil)
  }

  /// Text and icon colours: the selected ink, or nil for the usual ones.
  func updateInk(_ ink: NSColor?) {}

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    needsDisplay = true
  }

  override func mouseEntered(with event: NSEvent) { hovered = true }
  override func mouseExited(with event: NSEvent) { hovered = false }
  override func mouseDown(with event: NSEvent) { onClick?() }
  override func accessibilityPerformPress() -> Bool {
    onClick?()
    return true
  }
}

/// A pane in the sidebar: its icon and name, 34 pt.
private final class SettingsNavRow: SettingsSidebarRow {
  let pane: SettingPane
  private let icon = NSImageView()
  private let label: NSTextField

  init(pane: SettingPane) {
    self.pane = pane
    label = settingsLabel(pane.title, size: 13)
    super.init(frame: .zero)
    icon.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: nil)
    icon.symbolConfiguration = .init(pointSize: 14, weight: .medium)
    icon.imageScaling = .scaleNone
    addSubview(icon)
    addSubview(label)
    setAccessibilityElement(true)
    setAccessibilityRole(.button)
    setAccessibilityLabel(pane.title)
  }

  required init?(coder: NSCoder) { fatalError() }

  override func updateInk(_ ink: NSColor?) {
    icon.contentTintColor = ink ?? .secondaryLabelColor
    label.textColor = ink ?? .labelColor
    label.font = .systemFont(ofSize: 13, weight: ink == nil ? .regular : .medium)
  }

  override func layout() {
    super.layout()
    icon.frame = NSRect(x: 8, y: ((bounds.height - 20) / 2).rounded(), width: 22, height: 20)
    let height = ceil(label.intrinsicContentSize.height)
    label.frame = NSRect(x: 36, y: ((bounds.height - height) / 2).rounded(), width: bounds.width - 44, height: height)
  }
}

/// A search result: its title, and under it where it lives ("Appearance › Address bar").
private final class SettingsResultRow: SettingsSidebarRow {
  private let icon = NSImageView()
  private let title: NSTextField
  private let caption: NSTextField

  init(target: SettingsTarget) {
    title = settingsLabel(target.kind == .pane ? target.pane.title : target.title, size: 13)
    caption = settingsLabel(target.caption, size: 11, color: .secondaryLabelColor)
    super.init(frame: .zero)
    icon.image = NSImage(systemSymbolName: target.pane.symbol, accessibilityDescription: nil)
    icon.symbolConfiguration = .init(pointSize: 12, weight: .medium)
    icon.imageScaling = .scaleNone
    addSubview(icon)
    addSubview(title)
    addSubview(caption)
    setAccessibilityElement(true)
    setAccessibilityRole(.button)
    setAccessibilityLabel(target.title)
  }

  required init?(coder: NSCoder) { fatalError() }

  override func updateInk(_ ink: NSColor?) {
    icon.contentTintColor = ink ?? .tertiaryLabelColor
    title.textColor = ink ?? .labelColor
    caption.textColor = ink?.withAlphaComponent(0.8) ?? .secondaryLabelColor
  }

  override func layout() {
    super.layout()
    icon.frame = NSRect(x: 6, y: ((bounds.height - 18) / 2).rounded(), width: 20, height: 18)
    let titleHeight = ceil(title.intrinsicContentSize.height), captionHeight = ceil(caption.intrinsicContentSize.height)
    let top = ((bounds.height - titleHeight - captionHeight) / 2).rounded()
    title.frame = NSRect(x: 30, y: top, width: bounds.width - 38, height: titleHeight)
    caption.frame = NSRect(x: 30, y: top + titleHeight, width: bounds.width - 38, height: captionHeight)
  }
}
