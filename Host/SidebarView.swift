import AppKit

enum SidebarRowAction {
  case pin, unpin, addToFavorites, removeFromFavorites, backToPinned, close, unload
}

protocol SidebarViewDelegate: AnyObject {
  func sidebar(_ sidebar: SidebarView, select entry: SidebarEntry)
  func sidebar(_ sidebar: SidebarView, perform action: SidebarRowAction, on entry: SidebarEntry)
  func sidebarNewTab(_ sidebar: SidebarView)
  func sidebarOpenAddress(_ sidebar: SidebarView)
  func sidebarToggle(_ sidebar: SidebarView)
  func sidebarBack(_ sidebar: SidebarView)
  func sidebarForward(_ sidebar: SidebarView)
  func sidebarReload(_ sidebar: SidebarView)
  func sidebarClearToday(_ sidebar: SidebarView)
  func sidebarIcon(for entry: SidebarEntry) -> NSImage?
}

enum SidebarColors {
  private static func dynamic(dark: NSColor, light: NSColor) -> NSColor {
    NSColor(name: nil) { appearance in
      appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
    }
  }

  static let background = dynamic(dark: NSColor(white: 0.075, alpha: 1), light: NSColor(white: 0.9, alpha: 1))
  static let fill = dynamic(dark: NSColor(white: 1, alpha: 0.08), light: NSColor(white: 0, alpha: 0.06))
  static let hover = dynamic(dark: NSColor(white: 1, alpha: 0.06), light: NSColor(white: 0, alpha: 0.05))
  static let selected = dynamic(dark: NSColor(white: 1, alpha: 0.14), light: NSColor(white: 1, alpha: 0.85))
}

final class SidebarView: NSView {
  static let width: CGFloat = 267
  static let rowHeight: CGFloat = 41
  private static let inset: CGFloat = 8
  private static let tileHeight: CGFloat = 46

  weak var delegate: SidebarViewDelegate?
  var trafficLightsCenterY: CGFloat = 20 { didSet { if oldValue != trafficLightsCenterY { needsLayout = true } } }
  var reservesTrafficLights = true { didSet { if oldValue != reservesTrafficLights { needsLayout = true } } }

  private let toggleButton = SidebarView.iconButton("sidebar.left")
  private let backButton = SidebarView.iconButton("arrow.left")
  private let forwardButton = SidebarView.iconButton("arrow.right")
  private let reloadButton = SidebarView.iconButton("arrow.clockwise")
  private let addressPill = AddressPill()
  private let tilesView = FlippedView()
  private let scrollView = NSScrollView()
  private let content = FlippedView()
  private let separator = NSView()
  private let clearButton = NSButton()
  private let newTabRow = SidebarRowView()

  private var tiles: [FavoriteTileView] = []
  private var pinnedRows: [SidebarRowView] = []
  private var todayRows: [SidebarRowView] = []
  private(set) var favorites: [SidebarEntry] = []
  private(set) var pinned: [SidebarEntry] = []
  private(set) var today: [SidebarEntry] = []
  private var active: SidebarEntry?
  private var hovering = false

  override init(frame: NSRect) {
    super.init(frame: frame)
    toggleButton.target = self
    toggleButton.action = #selector(toggle)
    backButton.target = self
    backButton.action = #selector(back)
    forwardButton.target = self
    forwardButton.action = #selector(forward)
    reloadButton.target = self
    reloadButton.action = #selector(reload)
    [toggleButton, backButton, forwardButton, reloadButton, addressPill, tilesView, scrollView].forEach(addSubview)

    addressPill.onClick = { [weak self] in
      guard let self else { return }
      self.delegate?.sidebarOpenAddress(self)
    }

    scrollView.documentView = content
    scrollView.drawsBackground = false
    scrollView.hasVerticalScroller = true
    scrollView.autohidesScrollers = true
    scrollView.automaticallyAdjustsContentInsets = false
    scrollView.contentInsets = NSEdgeInsets()

    separator.wantsLayer = true
    content.addSubview(separator)
    clearButton.title = "↓ Clear"
    clearButton.isBordered = false
    clearButton.font = .systemFont(ofSize: 12, weight: .semibold)
    clearButton.contentTintColor = .tertiaryLabelColor
    clearButton.target = self
    clearButton.action = #selector(clearToday)
    clearButton.refusesFirstResponder = true
    content.addSubview(clearButton)

    newTabRow.showNewTab()
    newTabRow.onClick = { [weak self] _ in
      guard let self else { return }
      self.delegate?.sidebarNewTab(self)
    }
    content.addSubview(newTabRow)

    addTrackingArea(NSTrackingArea(
      rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
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
      separator.layer?.backgroundColor = NSColor.separatorColor.cgColor
    }
  }

  override func mouseEntered(with event: NSEvent) {
    hovering = true
    updateClear()
  }

  override func mouseExited(with event: NSEvent) {
    hovering = false
    updateClear()
  }

  private func updateClear() {
    clearButton.isHidden = !hovering || today.isEmpty || pinned.isEmpty
  }

  func show(favorites: [SidebarEntry], pinned: [SidebarEntry], today: [SidebarEntry], active: SidebarEntry?) {
    self.favorites = favorites
    self.pinned = pinned
    self.today = today
    self.active = active
    tiles = reuse(tiles, count: favorites.count, in: tilesView) { FavoriteTileView() }
    pinnedRows = reuse(pinnedRows, count: pinned.count, in: content) { SidebarRowView() }
    todayRows = reuse(todayRows, count: today.count, in: content) { SidebarRowView() }
    for (tile, entry) in zip(tiles, favorites) {
      tile.show(entry, icon: delegate?.sidebarIcon(for: entry), selected: entry === active)
      tile.onClick = { [weak self] in self?.select(entry) }
      tile.menu = menu(for: entry)
    }
    for (row, entry) in zip(pinnedRows + todayRows, pinned + today) {
      row.show(entry, icon: delegate?.sidebarIcon(for: entry), selected: entry === active)
      row.onClick = { [weak self] part in self?.clicked(entry, part: part) }
      row.onClose = { [weak self] in
        guard let self else { return }
        self.delegate?.sidebar(self, perform: entry.kind == .today ? .close : .unload, on: entry)
      }
      row.menu = menu(for: entry)
    }
    updateClear()
    needsLayout = true
  }

  func refresh(_ entry: SidebarEntry) {
    let icon = delegate?.sidebarIcon(for: entry)
    if let index = favorites.firstIndex(where: { $0 === entry }) {
      tiles[index].show(entry, icon: icon, selected: entry === active)
    } else if let index = pinned.firstIndex(where: { $0 === entry }) {
      pinnedRows[index].show(entry, icon: icon, selected: entry === active)
    } else if let index = today.firstIndex(where: { $0 === entry }) {
      todayRows[index].show(entry, icon: icon, selected: entry === active)
    }
  }

  func showAddress(_ entry: SidebarEntry?) {
    addressPill.show(url: entry?.currentURL ?? "")
  }

  func setNavigation(canGoBack: Bool, canGoForward: Bool) {
    backButton.isEnabled = canGoBack
    forwardButton.isEnabled = canGoForward
  }

  var addressText: String { addressPill.text }

  func setNewTabActive(_ active: Bool) {
    newTabRow.setSelected(active)
  }

  override func layout() {
    super.layout()
    let inset = Self.inset
    let width = bounds.width - inset * 2
    let rowCenter = trafficLightsCenterY
    toggleButton.frame = NSRect(x: reservesTrafficLights ? 70 : 13, y: rowCenter - 16, width: 32, height: 32)
    reloadButton.frame = NSRect(x: bounds.width - inset - 32 - 2, y: rowCenter - 16, width: 32, height: 32)
    forwardButton.frame = reloadButton.frame.offsetBy(dx: -34, dy: 0)
    backButton.frame = forwardButton.frame.offsetBy(dx: -34, dy: 0)

    addressPill.frame = NSRect(x: inset, y: rowCenter + 22, width: width, height: 36)
    var y = addressPill.frame.maxY + 8

    let columns = favorites.isEmpty ? 1 : min(favorites.count, 4)
    let rows = favorites.isEmpty ? 0 : Int(ceil(Double(favorites.count) / Double(columns)))
    let tileWidth = (width - CGFloat(columns - 1) * 8) / CGFloat(columns)
    let tilesHeight = rows == 0 ? 0 : CGFloat(rows) * Self.tileHeight + CGFloat(rows - 1) * 8
    tilesView.frame = NSRect(x: inset, y: y, width: width, height: tilesHeight)
    for (index, tile) in tiles.enumerated() {
      tile.frame = NSRect(
        x: CGFloat(index % columns) * (tileWidth + 8), y: CGFloat(index / columns) * (Self.tileHeight + 8),
        width: tileWidth, height: Self.tileHeight)
    }
    if rows > 0 { y += tilesHeight + 10 }

    scrollView.frame = NSRect(x: 0, y: y, width: bounds.width, height: max(0, bounds.height - y - inset))
    var rowY: CGFloat = 0
    for row in pinnedRows {
      row.frame = NSRect(x: inset, y: rowY, width: width, height: Self.rowHeight)
      rowY += Self.rowHeight
    }
    separator.isHidden = pinned.isEmpty
    if !pinned.isEmpty {
      let lineY = rowY + 12
      let clearWidth = ceil(clearButton.intrinsicContentSize.width)
      clearButton.frame = NSRect(x: bounds.width - 19 - clearWidth, y: lineY - 9, width: clearWidth, height: 18)
      separator.frame = NSRect(x: 22, y: lineY, width: max(0, clearButton.frame.minX - 8.5 - 22), height: 1)
      rowY = lineY + 30 - Self.rowHeight / 2
    }
    newTabRow.frame = NSRect(x: inset, y: rowY, width: width, height: Self.rowHeight)
    rowY += Self.rowHeight
    for row in todayRows {
      row.frame = NSRect(x: inset, y: rowY, width: width, height: Self.rowHeight)
      rowY += Self.rowHeight
    }
    content.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(rowY + inset, scrollView.frame.height))
  }

  private func clicked(_ entry: SidebarEntry, part: SidebarRowView.Part) {
    if part == .icon, entry.isAwayFromPinned, entry.isLive {
      delegate?.sidebar(self, perform: .backToPinned, on: entry)
    } else {
      select(entry)
    }
  }

  private func select(_ entry: SidebarEntry) {
    delegate?.sidebar(self, select: entry)
  }

  private func menu(for entry: SidebarEntry) -> NSMenu {
    let menu = NSMenu()
    func add(_ title: String, _ action: SidebarRowAction) {
      let item = NSMenuItem(title: title, action: #selector(menuAction(_:)), keyEquivalent: "")
      item.target = self
      item.representedObject = RowMenuChoice(action: action, entry: entry)
      menu.addItem(item)
    }
    switch entry.kind {
    case .today:
      add("Pin Tab", .pin)
      add("Add to Favorites", .addToFavorites)
      menu.addItem(.separator())
      add("Close Tab", .close)
    case .pinned:
      if entry.isAwayFromPinned { add("Back to Pinned URL", .backToPinned) }
      add("Add to Favorites", .addToFavorites)
      add("Unpin Tab", .unpin)
      if entry.isLive {
        menu.addItem(.separator())
        add("Close Tab", .unload)
      }
    case .favorite:
      if entry.isAwayFromPinned { add("Back to Favorite URL", .backToPinned) }
      add("Remove from Favorites", .removeFromFavorites)
      if entry.isLive {
        menu.addItem(.separator())
        add("Close Tab", .unload)
      }
    }
    return menu
  }

  @objc private func menuAction(_ item: NSMenuItem) {
    guard let choice = item.representedObject as? RowMenuChoice else { return }
    delegate?.sidebar(self, perform: choice.action, on: choice.entry)
  }

  @objc private func toggle() { delegate?.sidebarToggle(self) }
  @objc private func back() { delegate?.sidebarBack(self) }
  @objc private func forward() { delegate?.sidebarForward(self) }
  @objc private func reload() { delegate?.sidebarReload(self) }
  @objc private func clearToday() { delegate?.sidebarClearToday(self) }

  private func reuse<V: NSView>(_ views: [V], count: Int, in parent: NSView, make: () -> V) -> [V] {
    var views = views
    while views.count > count { views.removeLast().removeFromSuperview() }
    while views.count < count {
      let view = make()
      parent.addSubview(view)
      views.append(view)
    }
    return views
  }

  private static func iconButton(_ symbol: String) -> NSButton {
    let button = HoverIconButton()
    button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    button.symbolConfiguration = .init(pointSize: 15, weight: .medium)
    button.isBordered = false
    button.bezelStyle = .regularSquare
    button.imagePosition = .imageOnly
    button.contentTintColor = .secondaryLabelColor
    button.refusesFirstResponder = true
    return button
  }
}

final class HoverIconButton: NSButton {
  private var hovered = false

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.cornerRadius = 8
    layer?.cornerCurve = .continuous
    addTrackingArea(NSTrackingArea(
      rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
  }

  required init?(coder: NSCoder) { fatalError() }

  override var wantsUpdateLayer: Bool { true }
  override var mouseDownCanMoveWindow: Bool { false }

  override func updateLayer() {
    layer?.backgroundColor = (hovered && isEnabled ? SidebarColors.fill : .clear).cgColor
  }

  override func mouseEntered(with event: NSEvent) {
    hovered = true
    needsDisplay = true
  }

  override func mouseExited(with event: NSEvent) {
    hovered = false
    needsDisplay = true
  }
}

private final class RowMenuChoice {
  let action: SidebarRowAction
  let entry: SidebarEntry

  init(action: SidebarRowAction, entry: SidebarEntry) {
    self.action = action
    self.entry = entry
  }
}

final class AddressPill: NSView {
  var onClick: (() -> Void)?
  private let label = NSTextField(labelWithString: "")
  private let securityIcon = NSImageView()
  private let searchIcon = NSImageView()
  private(set) var text = ""

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.cornerRadius = 10
    layer?.cornerCurve = .continuous
    label.font = .systemFont(ofSize: 14)
    label.textColor = .secondaryLabelColor
    label.lineBreakMode = .byTruncatingHead
    securityIcon.image = NSImage(systemSymbolName: "lock.slash.fill", accessibilityDescription: "Not secure")
    securityIcon.symbolConfiguration = .init(pointSize: 12, weight: .medium)
    securityIcon.contentTintColor = .systemRed
    searchIcon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
    searchIcon.symbolConfiguration = .init(pointSize: 12, weight: .semibold)
    searchIcon.contentTintColor = .tertiaryLabelColor
    addSubview(searchIcon)
    addSubview(securityIcon)
    addSubview(label)
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }
  override var wantsUpdateLayer: Bool { true }
  override var mouseDownCanMoveWindow: Bool { false }

  override func updateLayer() {
    layer?.backgroundColor = SidebarColors.fill.cgColor
  }

  override func mouseDown(with event: NSEvent) { onClick?() }

  func show(url: String) {
    let components = URLComponents(string: url)
    let host = components?.host ?? ""
    text = host.isEmpty ? url : (host.hasPrefix("www.") ? String(host.dropFirst(4)) : host)
    let empty = text.isEmpty
    label.stringValue = empty ? "Search or Enter URL…" : text
    label.textColor = empty ? .tertiaryLabelColor : .secondaryLabelColor
    searchIcon.isHidden = !empty
    securityIcon.isHidden = empty || components?.scheme != "http"
    needsLayout = true
  }

  override func layout() {
    super.layout()
    let mid = bounds.height / 2
    securityIcon.frame = NSRect(x: 12, y: mid - 8, width: 16, height: 16)
    searchIcon.frame = securityIcon.frame
    let x: CGFloat = securityIcon.isHidden && searchIcon.isHidden ? 12 : 34
    label.frame = NSRect(x: x, y: mid - 10, width: bounds.width - x - 12, height: 20)
  }
}

final class FavoriteTileView: NSView {
  var onClick: (() -> Void)?
  private let icon = NSImageView()
  private var selected = false

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.cornerRadius = 10
    layer?.cornerCurve = .continuous
    icon.imageScaling = .scaleProportionallyUpOrDown
    addSubview(icon)
  }

  required init?(coder: NSCoder) { fatalError() }

  override var wantsUpdateLayer: Bool { true }
  override var mouseDownCanMoveWindow: Bool { false }

  override func updateLayer() {
    layer?.backgroundColor = (selected ? SidebarColors.selected : SidebarColors.fill).cgColor
  }

  override func layout() {
    super.layout()
    icon.frame = NSRect(x: (bounds.width - 20) / 2, y: (bounds.height - 20) / 2, width: 20, height: 20)
  }

  override func mouseDown(with event: NSEvent) {
    onClick?()
  }

  func show(_ entry: SidebarEntry, icon image: NSImage?, selected: Bool) {
    self.selected = selected
    icon.image = image ?? NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
    icon.contentTintColor = image == nil ? .secondaryLabelColor : nil
    toolTip = entry.displayTitle
    needsDisplay = true
  }
}

final class SidebarRowView: NSView {
  enum Part { case icon, body }

  var onClick: ((Part) -> Void)?
  var onClose: (() -> Void)?
  private let icon = NSImageView()
  private let slash = NSTextField(labelWithString: "/")
  private let title = NSTextField(labelWithString: "")
  private let subtitle = NSTextField(labelWithString: "")
  private let closeButton = NSButton()
  private var selected = false
  private var hovered = false
  private var isNewTab = false
  private var away = false
  private var closable = false
  private let fill = CALayer()
  static let fillInset: CGFloat = 3

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    fill.cornerRadius = 8
    fill.cornerCurve = .continuous
    layer?.addSublayer(fill)
    icon.imageScaling = .scaleProportionallyUpOrDown
    slash.font = .systemFont(ofSize: 16, weight: .light)
    slash.textColor = .tertiaryLabelColor
    title.font = .systemFont(ofSize: 14, weight: .medium)
    title.lineBreakMode = .byTruncatingTail
    subtitle.font = .systemFont(ofSize: 12)
    subtitle.textColor = .secondaryLabelColor
    subtitle.lineBreakMode = .byTruncatingTail
    closeButton.isBordered = false
    closeButton.imagePosition = .imageOnly
    closeButton.symbolConfiguration = .init(pointSize: 11, weight: .bold)
    closeButton.contentTintColor = .secondaryLabelColor
    closeButton.target = self
    closeButton.action = #selector(close)
    closeButton.refusesFirstResponder = true
    [icon, slash, title, subtitle, closeButton].forEach(addSubview)
    addTrackingArea(NSTrackingArea(
      rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }
  override var wantsUpdateLayer: Bool { true }
  override var mouseDownCanMoveWindow: Bool { false }

  override func updateLayer() {
    let color: NSColor = selected ? SidebarColors.selected : hovered ? SidebarColors.hover : .clear
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    fill.backgroundColor = color.cgColor
    CATransaction.commit()
  }

  override func mouseEntered(with event: NSEvent) {
    hovered = true
    updateClose()
    needsDisplay = true
  }

  override func mouseExited(with event: NSEvent) {
    hovered = false
    updateClose()
    needsDisplay = true
  }

  override func mouseDown(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    onClick?(point.x < title.frame.minX - 2 ? .icon : .body)
  }

  override func otherMouseDown(with event: NSEvent) {
    if event.buttonNumber == 2, closable { onClose?() }
  }

  @objc private func close() { onClose?() }

  func setSelected(_ selected: Bool) {
    guard self.selected != selected else { return }
    self.selected = selected
    needsDisplay = true
  }

  func showNewTab() {
    isNewTab = true
    icon.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
    icon.symbolConfiguration = .init(pointSize: 14, weight: .medium)
    icon.contentTintColor = .secondaryLabelColor
    title.stringValue = "New Tab"
    title.textColor = .secondaryLabelColor
    title.font = .systemFont(ofSize: 14)
    subtitle.isHidden = true
    slash.isHidden = true
    closeButton.isHidden = true
  }

  func show(_ entry: SidebarEntry, icon image: NSImage?, selected: Bool) {
    self.selected = selected
    away = entry.isAwayFromPinned && entry.isLive
    closable = entry.kind == .today || entry.isLive
    icon.image = image ?? NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
    icon.contentTintColor = image == nil ? .secondaryLabelColor : nil
    icon.alphaValue = entry.kind == .today && !entry.isLive ? 0.45 : 1
    slash.isHidden = !away
    title.stringValue = entry.displayTitle
    title.textColor = .labelColor
    subtitle.stringValue = entry.host
    let showsHost = !entry.isLive || entry.isAwayFromPinned
    subtitle.isHidden = !showsHost || entry.host.isEmpty || entry.host == entry.displayTitle
    closeButton.image = NSImage(
      systemSymbolName: entry.kind == .today ? "xmark" : "minus", accessibilityDescription: "Close")
    toolTip = away ? "Click the icon to go back to the pinned page" : nil
    updateClose()
    needsLayout = true
    needsDisplay = true
  }

  private func updateClose() {
    closeButton.isHidden = isNewTab || !closable || !(hovered || selected)
  }

  override func layout() {
    super.layout()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    fill.frame = bounds.insetBy(dx: 0, dy: Self.fillInset)
    CATransaction.commit()
    let mid = bounds.height / 2
    let iconSize: CGFloat = isNewTab ? 14 : 16
    icon.frame = NSRect(x: 17 - iconSize / 2, y: mid - iconSize / 2, width: iconSize, height: iconSize)
    slash.frame = NSRect(x: 28, y: mid - 11, width: 10, height: 22)
    let textX: CGFloat = away ? 41 : 35
    closeButton.frame = NSRect(x: bounds.width - 30, y: mid - 11, width: 22, height: 22)
    let textWidth = (closeButton.isHidden ? bounds.width - 10 : closeButton.frame.minX - 4) - textX
    if subtitle.isHidden {
      title.frame = NSRect(x: textX, y: mid - 10, width: textWidth, height: 20)
    } else {
      title.frame = NSRect(x: textX, y: mid - 16, width: textWidth, height: 18)
      subtitle.frame = NSRect(x: textX, y: mid + 1, width: textWidth, height: 15)
    }
  }
}
