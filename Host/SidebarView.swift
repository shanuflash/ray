import AppKit

enum SidebarRowAction {
  case pin, unpin, addToFavorites, removeFromFavorites, backToPinned, close, unload
  case toggleFolder, newFolder, newNestedFolder, renameFolder, removeFromFolder, deleteFolder
  case moveToFolder(UUID)
}

/// Where a dragged entry lands. Indexes count the section without the dragged entry (for a folder, without
/// everything inside it too); `pinned` also says which folder it lands in, `folder` drops into one at its end.
enum SidebarDropTarget: Equatable {
  case favorites(Int), pinned(Int, parent: UUID?), folder(UUID), today(Int)
}

protocol SidebarViewDelegate: AnyObject {
  func sidebar(_ sidebar: SidebarView, select entry: SidebarEntry)
  func sidebar(_ sidebar: SidebarView, perform action: SidebarRowAction, on entry: SidebarEntry)
  func sidebar(_ sidebar: SidebarView, move entry: SidebarEntry, to target: SidebarDropTarget)
  func sidebar(_ sidebar: SidebarView, rename entry: SidebarEntry, to title: String)
  func sidebarNewTab(_ sidebar: SidebarView)
  func sidebarOpenAddress(_ sidebar: SidebarView)
  func sidebarToggle(_ sidebar: SidebarView)
  func sidebarBack(_ sidebar: SidebarView)
  func sidebarForward(_ sidebar: SidebarView)
  func sidebarReload(_ sidebar: SidebarView)
  func sidebarIcon(for entry: SidebarEntry) -> NSImage?
  func sidebarExtensions(_ sidebar: SidebarView, anchor: NSView)
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
  static let lightsIdle = dynamic(dark: NSColor(white: 1, alpha: 0.18), light: NSColor(white: 0, alpha: 0.15))
  static let selected = dynamic(dark: NSColor(white: 1, alpha: 0.14), light: NSColor(white: 1, alpha: 0.85))
  static let lifted = dynamic(dark: NSColor(white: 0.2, alpha: 1), light: NSColor(white: 1, alpha: 1))
}

private final class SidebarDrag {
  let entry: SidebarEntry
  let view: NSView
  let press: NSPoint
  var ghost: NSView?
  var pointer: NSPoint
  var grab = NSPoint.zero
  var lifted = false
  var target: SidebarDropTarget?

  init(entry: SidebarEntry, view: NSView, press: NSPoint) {
    self.entry = entry
    self.view = view
    self.press = press
    pointer = press
  }
}

/// Neighbours make room and the dropped item settles on a critically damped spring (ω 90 rad/s, about 70 ms),
/// as Ardia measured Dia's sidebar.
private enum Slide {
  static func move(_ view: NSView, to frame: NSRect) {
    guard view.frame != frame else { return }
    guard let layer = view.layer else {
      view.frame = frame
      return
    }
    let source = layer.animation(forKey: "slide.position") != nil ? (layer.presentation() ?? layer) : layer
    let fromPosition = source.position, fromBounds = source.bounds
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    view.frame = frame
    CATransaction.commit()
    add("position", from: NSValue(point: fromPosition), to: NSValue(point: layer.position), on: layer)
    add("bounds", from: NSValue(rect: fromBounds), to: NSValue(rect: layer.bounds), on: layer)
  }

  static func stop(_ view: NSView) {
    view.layer?.removeAnimation(forKey: "slide.position")
    view.layer?.removeAnimation(forKey: "slide.bounds")
  }

  private static func add(_ key: String, from: NSValue, to: NSValue, on layer: CALayer) {
    guard from != to else {
      layer.removeAnimation(forKey: "slide." + key)
      return
    }
    let animation = CASpringAnimation(keyPath: key)
    animation.mass = 1
    animation.stiffness = 8100
    animation.damping = 180
    animation.fromValue = from
    animation.toValue = to
    animation.duration = animation.settlingDuration
    layer.add(animation, forKey: "slide." + key)
  }
}

private protocol Liftable: NSView {
  func setLifted(_ lifted: Bool)
}

final class SidebarView: NSView {
  static let width: CGFloat = 267
  static let rowHeight: CGFloat = 41
  private static let inset: CGFloat = 8
  private static let tileHeight: CGFloat = 46

  weak var delegate: SidebarViewDelegate?
  var trafficLightsCenterY: CGFloat = 20 { didSet { if oldValue != trafficLightsCenterY { needsLayout = true } } }
  var reservesTrafficLights = true { didSet { if oldValue != reservesTrafficLights { needsLayout = true } } }

  private let windowLights = WindowLights()
  private let toggleButton = SidebarView.iconButton("sidebar.left")
  private let backButton = SidebarView.iconButton("arrow.left")
  private let forwardButton = SidebarView.iconButton("arrow.right")
  private let reloadButton = SidebarView.iconButton("arrow.clockwise")
  private let addressPill = AddressPill()
  private let tilesView = FlippedView()
  private let scrollView = NSScrollView()
  private let content = FlippedView()
  private let separator = NSView()
  private let newTabRow = SidebarRowView()
  private let favoriteHint = DropHintView(symbol: "star", title: "Add to Favorites", inset: 0)
  private let favoritesGlow = DropHintView(symbol: nil, title: "", inset: 0)

  private var tiles: [FavoriteTileView] = []
  private var pinnedRows: [SidebarRowView] = []
  private var todayRows: [SidebarRowView] = []
  private(set) var favorites: [SidebarEntry] = []
  private(set) var pinned: [SidebarEntry] = []
  private(set) var today: [SidebarEntry] = []
  private var active: SidebarEntry?
  private var drag: SidebarDrag?
  private var pendingShow: (() -> Void)?
  private var landing: [UUID: NSRect] = [:]
  private var autoscroll: CADisplayLink?
  private static let liftDistance: CGFloat = 4
  private static let folderIndent: CGFloat = 16
  private var pendingRename: UUID?
  private static let scrollEdge: CGFloat = 28

  var isDragging: Bool { drag?.lifted == true }

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
    [windowLights, toggleButton, backButton, forwardButton, reloadButton, addressPill, tilesView, scrollView]
      .forEach(addSubview)

    addressPill.onClick = { [weak self] in
      guard let self else { return }
      self.delegate?.sidebarOpenAddress(self)
    }
    addressPill.onExtensions = { [weak self] anchor in
      guard let self else { return }
      self.delegate?.sidebarExtensions(self, anchor: anchor)
    }

    scrollView.documentView = content
    scrollView.drawsBackground = false
    scrollView.hasVerticalScroller = true
    scrollView.autohidesScrollers = true
    scrollView.automaticallyAdjustsContentInsets = false
    scrollView.contentInsets = NSEdgeInsets()

    separator.wantsLayer = true
    content.addSubview(separator)

    newTabRow.showNewTab()
    newTabRow.onClick = { [weak self] _ in
      guard let self else { return }
      self.delegate?.sidebarNewTab(self)
    }
    content.addSubview(newTabRow)
    favoriteHint.isHidden = true
    tilesView.addSubview(favoriteHint)
    favoritesGlow.isHidden = true
    tilesView.addSubview(favoritesGlow, positioned: .below, relativeTo: nil)
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

  func show(favorites: [SidebarEntry], pinned: [SidebarEntry], today: [SidebarEntry], active: SidebarEntry?) {
    if isDragging {
      pendingShow = { [weak self] in self?.show(favorites: favorites, pinned: pinned, today: today, active: active) }
      return
    }
    pendingShow = nil
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
      tile.onPointer = { [weak self, weak tile] event in
        if let self, let tile { self.pointer(event, on: tile, entry: entry) }
      }
      tile.menu = menu(for: entry)
    }
    for (row, entry) in zip(pinnedRows + todayRows, pinned + today) {
      row.show(entry, icon: entry.isFolder ? nil : delegate?.sidebarIcon(for: entry), selected: entry === active)
      row.onClick = { [weak self] part in self?.clicked(entry, part: part) }
      row.onDoubleClick = entry.isFolder ? { [weak self] in self?.beginRename(entry) } : nil
      row.onPointer = { [weak self, weak row] event in
        if let self, let row { self.pointer(event, on: row, entry: entry) }
      }
      row.onClose = { [weak self] in
        guard let self else { return }
        self.delegate?.sidebar(self, perform: entry.kind == .today ? .close : .unload, on: entry)
      }
      row.menu = menu(for: entry)
    }
    needsLayout = true
  }

  func refresh(_ entry: SidebarEntry) {
    let icon = entry.isFolder ? nil : delegate?.sidebarIcon(for: entry)
    if let index = favorites.firstIndex(where: { $0 === entry }) {
      tiles[index].show(entry, icon: icon, selected: entry === active)
    } else if let index = pinned.firstIndex(where: { $0 === entry }) {
      pinnedRows[index].show(entry, icon: icon, selected: entry === active)
    } else if let index = today.firstIndex(where: { $0 === entry }) {
      todayRows[index].show(entry, icon: icon, selected: entry === active)
    }
  }

  func showAddress(_ entry: SidebarEntry?) {
    let level = entry.flatMap { $0.isLive ? $0.tab?.securityInfo["level"] as? String : nil }
    addressPill.show(url: entry?.currentURL ?? "", security: level)
  }

  func setNavigation(canGoBack: Bool, canGoForward: Bool) {
    backButton.isEnabled = canGoBack
    forwardButton.isEnabled = canGoForward
  }

  var addressText: String { addressPill.text }

  func flashAddress(_ message: String) { addressPill.flash(message) }
  func setExtensionsShown(_ shown: Bool) { addressPill.extensionsShown = shown }
  var extensionsAnchor: NSView { addressPill.extensionsButton }
  var addressLabel: String { addressPill.shownText }

  var debugToggleCenter: String {
    let frame = toggleButton.convert(toggleButton.bounds, to: nil)
    return String(format: "%.1f,%.1f", frame.midX, (window?.contentView?.bounds.height ?? 0) - frame.midY)
  }

  func setNewTabActive(_ active: Bool) {
    newTabRow.setSelected(active)
  }

  override func layout() {
    super.layout()
    let inset = Self.inset
    let width = bounds.width - inset * 2
    let rowCenter = trafficLightsCenterY
    windowLights.isHidden = !reservesTrafficLights
    windowLights.frame = NSRect(x: 14, y: rowCenter - 8, width: WindowLights.width, height: 16)
    toggleButton.frame = NSRect(x: reservesTrafficLights ? 88 : 13, y: rowCenter - 16, width: 32, height: 32)
    reloadButton.frame = NSRect(x: bounds.width - inset - 32 - 2, y: rowCenter - 16, width: 32, height: 32)
    forwardButton.frame = reloadButton.frame.offsetBy(dx: -34, dy: 0)
    backButton.frame = forwardButton.frame.offsetBy(dx: -34, dy: 0)

    addressPill.frame = NSRect(x: inset, y: rowCenter + 24, width: width, height: 36)
    var y = addressPill.frame.maxY + 8

    let dragged = isDragging ? drag?.entry : nil
    let target = dragged == nil ? nil : drag?.target
    func slots<V: NSView>(_ views: [V], _ entries: [SidebarEntry], gap: Int?) -> [(V, SidebarEntry)?] {
      var list: [(V, SidebarEntry)?] = zip(views, entries).filter { $0.1 !== dragged }
      if let gap { list.insert(nil, at: min(gap, list.count)) }
      return list
    }
    var favoriteGap: Int?, todayGap: Int?
    switch target {
    case .favorites(let index): favoriteGap = index
    case .pinned, .folder: break
    case .today(let index): todayGap = index
    case nil: break
    }
    // Rows open a gap where the tab will land, pinned or not; with nothing pinned, the gap opens above a divider.
    // Favorites, as in Arc, light up as a whole when a tab comes from elsewhere and take it at the end; with no
    // favorites, aiming above the list opens one lit "Add to Favorites" tile.
    let noFavorites = !favorites.contains { $0 !== dragged }
    let favoriteBand = favoriteGap != nil && noFavorites
    let favoritesLit = favoriteGap != nil && !noFavorites && dragged?.kind != .favorite
    let tileSlots = slots(tiles, favorites, gap: favoritesLit ? nil : favoriteGap)
    let pinnedRest = visiblePinned(without: dragged)
    var pinnedGapSlot: Int?
    var litFolder: UUID?
    switch target {
    case .pinned(let index, _): pinnedGapSlot = pinnedRest.filter { $0.index < index }.count
    case .folder(let id): litFolder = id
    default: break
    }
    let rowFor = Dictionary(zip(pinned.map(\.id), pinnedRows), uniquingKeysWith: { first, _ in first })
    let shownPinned = Set(pinnedRest.map { ObjectIdentifier($0.entry) })
    for (row, entry) in zip(pinnedRows, pinned) {
      row.isHidden = !shownPinned.contains(ObjectIdentifier(entry)) && entry !== dragged
      row.dropTarget = entry.id == litFolder
    }
    var pinnedSlots: [(SidebarRowView, SidebarEntry, Int)?] = pinnedRest.compactMap { item in
      rowFor[item.entry.id].map { ($0, item.entry, item.depth) }
    }
    if let pinnedGapSlot { pinnedSlots.insert(nil, at: min(pinnedGapSlot, pinnedSlots.count)) }
    let todaySlots = slots(todayRows, today, gap: todayGap)

    let columns = tileSlots.isEmpty ? 1 : min(tileSlots.count, 4)
    let rows = tileSlots.isEmpty ? 0 : Int(ceil(Double(tileSlots.count) / Double(columns)))
    let tileWidth = (width - CGFloat(columns - 1) * 8) / CGFloat(columns)
    let tilesHeight = rows == 0 ? 0 : CGFloat(rows) * Self.tileHeight + CGFloat(rows - 1) * 8
    place(tilesView, NSRect(x: inset, y: y, width: width, height: tilesHeight), entry: nil)
    var gapFrame: NSRect?
    for (index, slot) in tileSlots.enumerated() {
      let frame = NSRect(
        x: CGFloat(index % columns) * (tileWidth + 8), y: CGFloat(index / columns) * (Self.tileHeight + 8),
        width: tileWidth, height: Self.tileHeight)
      guard case let (tile, entry)? = slot else {
        gapFrame = frame
        continue
      }
      place(tile, frame, entry: entry)
    }
    show(favoriteHint, at: favoriteBand ? gapFrame : nil)
    show(favoritesGlow, at: favoritesLit ? NSRect(origin: .zero, size: tilesView.frame.size).insetBy(dx: -4, dy: -4) : nil)
    if rows > 0 { y += tilesHeight + 10 }

    place(scrollView, NSRect(x: 0, y: y, width: bounds.width, height: max(0, bounds.height - y - inset)), entry: nil)
    var rowY: CGFloat = 0
    for slot in pinnedSlots {
      if case let (row, entry, depth)? = slot {
        // Each folder level steps in 16 pt, as Arc's and Ardia's folders do.
        let indent = CGFloat(depth) * Self.folderIndent
        place(row, NSRect(x: inset + indent, y: rowY, width: width - indent, height: Self.rowHeight), entry: entry)
      }
      rowY += Self.rowHeight
    }
    separator.isHidden = pinnedSlots.isEmpty
    if !separator.isHidden {
      let lineY = rowY + 12
      place(separator, NSRect(x: 22, y: lineY, width: max(0, bounds.width - 44), height: 1), entry: nil)
      rowY = lineY + 30 - Self.rowHeight / 2
    }
    place(newTabRow, NSRect(x: inset, y: rowY, width: width, height: Self.rowHeight), entry: nil)
    rowY += Self.rowHeight
    for slot in todaySlots {
      if case let (row, entry)? = slot { place(row, NSRect(x: inset, y: rowY, width: width, height: Self.rowHeight), entry: entry) }
      rowY += Self.rowHeight
    }
    content.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(rowY + inset, scrollView.frame.height))
    landing = [:]
  }

  /// The pinned rows that show, in order, with their depth and their index in the pinned list without `dragged`
  /// (and, for a dragged folder, without what's inside it). A closed folder hides what's inside, except the active
  /// tab, which stays in sight as Ardia and Crest keep it.
  private func visiblePinned(without dragged: SidebarEntry?) -> [(index: Int, entry: SidebarEntry, depth: Int)] {
    let byID = Dictionary(pinned.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    func ancestors(_ entry: SidebarEntry) -> [SidebarEntry] {
      var list: [SidebarEntry] = []
      var parent = entry.parentID
      while let id = parent, let folder = byID[id], list.count < 64 {
        list.append(folder)
        parent = folder.parentID
      }
      return list
    }
    var result: [(index: Int, entry: SidebarEntry, depth: Int)] = []
    var index = 0
    for entry in pinned {
      let chain = ancestors(entry)
      if let dragged, entry === dragged || chain.contains(where: { $0 === dragged }) { continue }
      defer { index += 1 }
      if entry !== active, chain.contains(where: { !($0.isOpen ?? true) }) { continue }
      result.append((index, entry, chain.count))
    }
    return result
  }

  /// Starts renaming a folder in place (a new folder starts this way).
  func beginRename(_ entry: SidebarEntry) {
    pendingRename = entry.id
    DispatchQueue.main.async { [weak self] in
      guard let self, self.pendingRename == entry.id else { return }
      self.pendingRename = nil
      self.layoutSubtreeIfNeeded()
      guard let index = self.pinned.firstIndex(where: { $0 === entry }), index < self.pinnedRows.count else { return }
      let row = self.pinnedRows[index]
      row.scrollToVisible(row.bounds)
      row.beginRename { [weak self] name in
        guard let self, let name else { return }
        self.delegate?.sidebar(self, rename: entry, to: name)
      }
    }
  }

  /// Shows a drop hint at a frame (appearing in place, then following the layout), or hides it.
  private func show(_ hint: NSView, at frame: NSRect?) {
    if let frame, hint.isHidden { hint.frame = frame }
    hint.isHidden = frame == nil
    if let frame { place(hint, frame, entry: nil) }
  }

  /// Sets a frame: springs there while a drag is lifted, lands from where a dropped item was, else jumps.
  private func place(_ view: NSView, _ frame: NSRect, entry: SidebarEntry?) {
    if let entry, let start = landing[entry.id], let parent = view.superview {
      Slide.stop(view)
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      view.frame = parent.convert(start, from: self)
      CATransaction.commit()
      Slide.move(view, to: frame)
    } else if isDragging {
      Slide.move(view, to: frame)
    } else if view.frame != frame {
      Slide.stop(view)
      view.frame = frame
    }
  }

  // MARK: Drag and drop

  private func pointer(_ event: NSEvent, on view: NSView & Liftable, entry: SidebarEntry) {
    let point = convert(event.locationInWindow, from: nil)
    switch event.type {
    case .leftMouseDown:
      guard drag == nil else { return }
      drag = SidebarDrag(entry: entry, view: view, press: point)
    case .leftMouseDragged:
      guard let drag, drag.view === view else { return }
      drag.pointer = point
      if !drag.lifted {
        guard hypot(point.x - drag.press.x, point.y - drag.press.y) >= Self.liftDistance, lift(drag) else { return }
      }
      follow(drag)
    case .leftMouseUp:
      guard let drag, drag.view === view else { return }
      drag.pointer = point
      if !drag.lifted, drag.entry.isFolder {
        self.drag = nil
        delegate?.sidebar(self, perform: .toggleFolder, on: drag.entry)
        return
      }
      drop(drag)
    default:
      break
    }
  }

  private func lift(_ drag: SidebarDrag) -> Bool {
    // The press may have changed the lists (selecting reloads them); only lift what the view still shows.
    guard shownViews.contains(where: { $0.0 === drag.view && $0.1 === drag.entry }) else {
      self.drag = nil
      return false
    }
    // The pressed view keeps getting the mouse events (AppKit stops sending them to a view that leaves its
    // superview), so it stays put, invisible, and a lifted copy follows the pointer above everything.
    let frame = drag.view.convert(drag.view.bounds, to: self)
    drag.grab = NSPoint(x: drag.press.x - frame.minX, y: drag.press.y - frame.minY)
    drag.lifted = true
    let icon = delegate?.sidebarIcon(for: drag.entry)
    let ghost: NSView & Liftable
    if drag.view is FavoriteTileView {
      let tile = FavoriteTileView()
      tile.show(drag.entry, icon: icon, selected: drag.entry === active)
      ghost = tile
    } else {
      let row = SidebarRowView()
      row.show(drag.entry, icon: icon, selected: drag.entry === active)
      ghost = row
    }
    ghost.frame = frame
    ghost.setLifted(true)
    addSubview(ghost)
    drag.ghost = ghost
    drag.view.alphaValue = 0
    let link = displayLink(target: self, selector: #selector(autoscrollStep(_:)))
    link.add(to: .main, forMode: .common)
    autoscroll = link
    return true
  }

  private func follow(_ drag: SidebarDrag) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    drag.ghost?.setFrameOrigin(NSPoint(x: drag.pointer.x - drag.grab.x, y: drag.pointer.y - drag.grab.y))
    CATransaction.commit()
    retarget(drag)
  }

  private func retarget(_ drag: SidebarDrag) {
    let target = dropTarget(for: drag)
    guard target != drag.target else { return }
    drag.target = target
    needsLayout = true
    layoutSubtreeIfNeeded()
  }

  private func dropTarget(for drag: SidebarDrag) -> SidebarDropTarget? {
    let point = drag.pointer
    guard point.x > -40, point.x < bounds.width + 40 else { return nil }
    let inset = Self.inset
    if point.y < scrollView.frame.minY {
      if drag.entry.isFolder { return nil }
      let others = favorites.filter { $0 !== drag.entry }.count
      let count = others + 1
      let columns = min(count, 4)
      let rows = Int(ceil(Double(count) / Double(columns)))
      let tileWidth = (bounds.width - inset * 2 - CGFloat(columns - 1) * 8) / CGFloat(columns)
      let column = min(max(Int((point.x - inset) / (tileWidth + 8)), 0), columns - 1)
      let row = min(max(Int((point.y - tilesView.frame.minY) / (Self.tileHeight + 8)), 0), rows - 1)
      // Into favorites from elsewhere, they light up as a whole and the tab goes at the end, as in Arc.
      if drag.entry.kind != .favorite { return .favorites(others) }
      return .favorites(min(row * columns + column, others))
    }
    let height = Self.rowHeight
    let centre = convert(point, to: content).y - drag.grab.y + (drag.ghost?.frame.height ?? height) / 2
    let top = centre - height / 2
    let rest = visiblePinned(without: drag.entry)
    let pinnedCount = rest.count
    let restCount = pinned.count - (pinned.filter { $0 === drag.entry }.count
      + pinned.filter { drag.entry.isFolder && isInside($0, drag.entry) }.count)
    let todayCount = today.filter { $0 !== drag.entry }.count
    // With nothing pinned, the pinned gap opens once the tab reaches the top half of New Tab; while it's open, all
    // of it down to the divider pins (no flicker at the edge).
    // While a gap is open in the pinned rows, the divider sits a row lower; measure against where it shows.
    let pinning: Bool, gapOpen: Bool
    switch drag.target {
    case .pinned: (pinning, gapOpen) = (true, true)
    case .folder: (pinning, gapOpen) = (true, false)
    default: (pinning, gapOpen) = (false, false)
    }
    let slots = pinnedCount + (gapOpen ? 1 : 0)
    let lineY = CGFloat(slots) * height + 12
    let newTabY = slots > 0 ? lineY + 30 - height / 2 : 0
    func index(_ value: CGFloat, _ count: Int) -> Int { min(max(Int((value / height).rounded()), 0), count) }
    let pinLimit = pinnedCount > 0 ? newTabY + height / 2 : pinning ? lineY : height / 2
    if centre < pinLimit {
      // The middle half of a folder row drops into it (Crest's band; Ardia uses the middle two thirds).
      let over = Int(floor(centre / height))
      if over >= 0, over < rest.count, rest[over].entry.isFolder,
         abs(centre - (CGFloat(over) + 0.5) * height) < height / 4 {
        return .folder(rest[over].entry.id)
      }
      let gap = index(top, pinnedCount)
      let above = gap > 0 ? rest[gap - 1] : nil
      let below = gap < rest.count ? rest[gap] : nil
      // Between rows the gap can sit at any level the neighbours allow; how far right the tab is picks it.
      let deepest = above.map { $0.entry.isFolder && ($0.entry.isOpen ?? true) ? $0.depth + 1 : $0.depth } ?? 0
      let shallowest = min(below?.depth ?? 0, deepest)
      let wanted = Int((((drag.ghost?.frame.minX ?? 0) - Self.inset) / Self.folderIndent).rounded())
      let depth = min(max(wanted, shallowest), deepest)
      var parent: UUID?
      if depth > 0, let above {
        if above.entry.isFolder && depth == above.depth + 1 {
          parent = above.entry.id
        } else {
          var node: SidebarEntry? = above.entry
          var level = above.depth
          while let current = node, level >= depth {
            node = current.parentID.flatMap { id in pinned.first { $0.id == id } }
            level -= 1
          }
          parent = node?.id
        }
      }
      return .pinned(below?.index ?? restCount, parent: parent)
    }
    if drag.entry.isFolder { return nil }
    return .today(index(top - newTabY - height, todayCount))
  }

  @objc private func autoscrollStep(_ link: CADisplayLink) {
    guard let drag, drag.lifted else { return }
    let frame = scrollView.frame
    let y = drag.pointer.y
    guard y >= frame.minY else { return }
    let speed: CGFloat
    if y < frame.minY + Self.scrollEdge {
      speed = -ceil((frame.minY + Self.scrollEdge - y) / 4)
    } else if y > frame.maxY - Self.scrollEdge {
      speed = ceil((y - (frame.maxY - Self.scrollEdge)) / 4)
    } else {
      return
    }
    let clip = scrollView.contentView
    let limit = max(0, content.frame.height - clip.bounds.height)
    let next = min(max(clip.bounds.origin.y + speed, 0), limit)
    guard next != clip.bounds.origin.y else { return }
    clip.scroll(to: NSPoint(x: 0, y: next))
    scrollView.reflectScrolledClipView(clip)
    retarget(drag)
  }

  private func drop(_ drag: SidebarDrag) {
    self.drag = nil
    guard drag.lifted else { return }
    autoscroll?.invalidate()
    autoscroll = nil
    let target = dropTarget(for: drag)
    var frames: [UUID: NSRect] = [:]
    for (view, entry) in shownViews where view !== drag.view {
      guard let parent = view.superview else { continue }
      let frame = view.layer?.animation(forKey: "slide.position") != nil ? view.layer?.presentation()?.frame : nil
      frames[entry.id] = convert(frame ?? view.frame, from: parent)
    }
    frames[drag.entry.id] = drag.ghost?.frame
    drag.ghost?.removeFromSuperview()
    drag.view.alphaValue = 1
    landing = frames
    if let target {
      delegate?.sidebar(self, move: drag.entry, to: target)
    }
    pendingShow?()
    needsLayout = true
    layoutSubtreeIfNeeded()
  }

  private func isInside(_ entry: SidebarEntry, _ folder: SidebarEntry) -> Bool {
    var parent = entry.parentID
    var steps = 0
    while let id = parent, steps < 64 {
      if id == folder.id { return true }
      parent = pinned.first { $0.id == id }?.parentID
      steps += 1
    }
    return false
  }

  private var shownViews: [(NSView, SidebarEntry)] {
    Array(zip(tiles as [NSView], favorites)) + Array(zip(pinnedRows as [NSView], pinned))
      + Array(zip(todayRows as [NSView], today))
  }

  /// Frames of the tiles and rows in window coordinates with a top-left origin, for tests.
  var debugFrames: [String: String] {
    guard let window, let height = window.contentView?.bounds.height else { return [:] }
    layoutSubtreeIfNeeded()
    var frames: [String: String] = [:]
    for (view, entry) in shownViews {
      let frame = view.convert(view.bounds, to: nil)
      frames[entry.id.uuidString] = String(format: "%.1f,%.1f,%.1f,%.1f", frame.minX, height - frame.maxY, frame.width, frame.height)
    }
    if !favoriteHint.isHidden {
      let frame = favoriteHint.convert(favoriteHint.bounds, to: nil)
      frames["favoriteHint"] = String(format: "%.1f,%.1f,%.1f,%.1f", frame.minX, height - frame.maxY, frame.width, frame.height)
    }
    for (name, glow) in [("favoritesGlow", favoritesGlow)] where !glow.isHidden {
      let frame = glow.convert(glow.bounds, to: nil)
      frames[name] = String(format: "%.1f,%.1f,%.1f,%.1f", frame.minX, height - frame.maxY, frame.width, frame.height)
    }
    frames["hidden"] = shownViews.filter { view, _ in view.isHidden }.map { $0.1.id.uuidString }.joined(separator: ",")
    frames["litFolder"] = zip(pinnedRows, pinned).first { $0.0.dropTarget }?.1.id.uuidString ?? ""
    frames["renaming"] = zip(pinnedRows, pinned).first { $0.0.isRenaming }?.1.id.uuidString ?? ""
    frames["alive"] = shownViews.filter { view, _ in
      (view as? SidebarRowView)?.residency.showsDot ?? (view as? FavoriteTileView)?.residency.showsDot ?? false
    }.map { $0.1.id.uuidString }.joined(separator: ",")
    frames["newTab"] = {
      let frame = newTabRow.convert(newTabRow.bounds, to: nil)
      return String(format: "%.1f,%.1f,%.1f,%.1f", frame.minX, height - frame.maxY, frame.width, frame.height)
    }()
    return frames
  }

  private func clicked(_ entry: SidebarEntry, part: SidebarRowView.Part) {
    // A folder opens or closes on release, so pressing one to drag it doesn't toggle it.
    if entry.isFolder { return }
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
    func addFolderMenu() {
      let folders = NSMenu()
      let fresh = NSMenuItem(title: "New Folder", action: #selector(menuAction(_:)), keyEquivalent: "")
      fresh.target = self
      fresh.representedObject = RowMenuChoice(action: .newFolder, entry: entry)
      folders.addItem(fresh)
      let choices = pinned.filter { $0.isFolder && $0.id != entry.parentID }
      if !choices.isEmpty { folders.addItem(.separator()) }
      for folder in choices {
        let item = NSMenuItem(title: folder.title, action: #selector(menuAction(_:)), keyEquivalent: "")
        item.target = self
        item.indentationLevel = min(depthOf(folder), 8)
        item.representedObject = RowMenuChoice(action: .moveToFolder(folder.id), entry: entry)
        folders.addItem(item)
      }
      let holder = NSMenuItem(title: "Add to Folder", action: nil, keyEquivalent: "")
      holder.submenu = folders
      menu.addItem(holder)
    }
    switch entry.kind {
    case .today:
      add("Pin Tab", .pin)
      add("Add to Favorites", .addToFavorites)
      addFolderMenu()
      menu.addItem(.separator())
      add("Close Tab", .close)
    case .pinned:
      if entry.isAwayFromPinned { add("Back to Pinned URL", .backToPinned) }
      add("Add to Favorites", .addToFavorites)
      addFolderMenu()
      if entry.parentID != nil { add("Remove from Folder", .removeFromFolder) }
      add("Unpin Tab", .unpin)
      if entry.isLive {
        menu.addItem(.separator())
        add("Close Tab", .unload)
      }
    case .folder:
      add("Rename…", .renameFolder)
      add("New Nested Folder", .newNestedFolder)
      if entry.parentID != nil { add("Remove from Folder", .removeFromFolder) }
      menu.addItem(.separator())
      add("Delete Folder", .deleteFolder)
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
    if case .renameFolder = choice.action {
      beginRename(choice.entry)
      return
    }
    delegate?.sidebar(self, perform: choice.action, on: choice.entry)
  }

  private func depthOf(_ entry: SidebarEntry) -> Int {
    var depth = 0
    var parent = entry.parentID
    while let id = parent, let folder = pinned.first(where: { $0.id == id }), depth < 64 {
      depth += 1
      parent = folder.parentID
    }
    return depth
  }

  @objc private func toggle() { delegate?.sidebarToggle(self) }
  @objc private func back() { delegate?.sidebarBack(self) }
  @objc private func forward() { delegate?.sidebarForward(self) }
  @objc private func reload() { delegate?.sidebarReload(self) }

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

final class WindowLights: NSView {
  static let width: CGFloat = 12 * 3 + 11 * 2
  private let buttons: [WindowLightButton] = [
    WindowLightButton(kind: .close), WindowLightButton(kind: .minimize), WindowLightButton(kind: .zoom),
  ]

  override init(frame: NSRect) {
    super.init(frame: frame)
    buttons.forEach(addSubview)
    addTrackingArea(NSTrackingArea(
      rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
  }

  required init?(coder: NSCoder) { fatalError() }

  override var mouseDownCanMoveWindow: Bool { false }

  override func layout() {
    super.layout()
    for (index, button) in buttons.enumerated() {
      button.frame = NSRect(x: CGFloat(index) * 23 + 2, y: (bounds.height - 12) / 2, width: 12, height: 12)
    }
  }

  override func mouseEntered(with event: NSEvent) { buttons.forEach { $0.lit = true } }
  override func mouseExited(with event: NSEvent) { buttons.forEach { $0.lit = false } }
}

final class WindowLightButton: NSView {
  enum Kind { case close, minimize, zoom }

  let kind: Kind
  private let glyph = NSImageView()
  var lit = false {
    didSet { needsDisplay = true }
  }

  init(kind: Kind) {
    self.kind = kind
    super.init(frame: .zero)
    wantsLayer = true
    layer?.cornerRadius = 6
    let symbol: String
    switch kind {
    case .close: symbol = "xmark"
    case .minimize: symbol = "minus"
    case .zoom: symbol = "arrow.up.left.and.arrow.down.right"
    }
    glyph.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    glyph.symbolConfiguration = .init(pointSize: kind == .zoom ? 6 : 7, weight: .bold)
    glyph.contentTintColor = NSColor.black.withAlphaComponent(0.55)
    addSubview(glyph)
    setAccessibilityRole(.button)
    setAccessibilityLabel(kind == .close ? "Close" : kind == .minimize ? "Minimize" : "Full Screen")
  }

  required init?(coder: NSCoder) { fatalError() }

  override var wantsUpdateLayer: Bool { true }
  override var mouseDownCanMoveWindow: Bool { false }

  override func layout() {
    super.layout()
    glyph.frame = bounds
  }

  override func updateLayer() {
    let colour: NSColor
    if lit {
      switch kind {
      case .close: colour = NSColor(srgbRed: 1, green: 0.373, blue: 0.341, alpha: 1)
      case .minimize: colour = NSColor(srgbRed: 0.996, green: 0.737, blue: 0.180, alpha: 1)
      case .zoom: colour = NSColor(srgbRed: 0.157, green: 0.784, blue: 0.251, alpha: 1)
      }
    } else {
      colour = SidebarColors.lightsIdle
    }
    layer?.backgroundColor = colour.cgColor
    glyph.isHidden = !lit
  }

  override func mouseUp(with event: NSEvent) {
    guard let window, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
    switch kind {
    case .close: window.performClose(nil)
    case .minimize: window.performMiniaturize(nil)
    case .zoom:
      if event.modifierFlags.contains(.option) { window.performZoom(nil) } else { window.toggleFullScreen(nil) }
    }
  }

  override func mouseDown(with event: NSEvent) {}

  override func accessibilityPerformPress() -> Bool {
    guard let window else { return false }
    switch kind {
    case .close: window.performClose(nil)
    case .minimize: window.performMiniaturize(nil)
    case .zoom: window.toggleFullScreen(nil)
    }
    return true
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
  /// Arc keeps extensions behind a button at the end of the address field; shown once any are installed.
  let extensionsButton = HoverIconButton()
  var onExtensions: ((NSView) -> Void)?
  var extensionsShown = false {
    didSet {
      guard oldValue != extensionsShown else { return }
      extensionsButton.isHidden = !extensionsShown
      needsLayout = true
    }
  }
  private(set) var text = ""

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.cornerRadius = 10
    layer?.cornerCurve = .continuous
    label.font = .systemFont(ofSize: 13)
    label.textColor = .secondaryLabelColor
    label.lineBreakMode = .byTruncatingHead
    securityIcon.image = NSImage(systemSymbolName: "lock.slash.fill", accessibilityDescription: "Not secure")
    securityIcon.symbolConfiguration = .init(pointSize: 12, weight: .medium)
    securityIcon.contentTintColor = .systemRed
    searchIcon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
    searchIcon.symbolConfiguration = .init(pointSize: 12, weight: .semibold)
    searchIcon.contentTintColor = .tertiaryLabelColor
    extensionsButton.image = NSImage(systemSymbolName: "puzzlepiece.extension", accessibilityDescription: "Extensions")
    extensionsButton.symbolConfiguration = .init(pointSize: 13, weight: .medium)
    extensionsButton.isBordered = false
    extensionsButton.bezelStyle = .regularSquare
    extensionsButton.imagePosition = .imageOnly
    extensionsButton.contentTintColor = .secondaryLabelColor
    extensionsButton.refusesFirstResponder = true
    extensionsButton.isHidden = true
    extensionsButton.target = self
    extensionsButton.action = #selector(showExtensions)
    addSubview(extensionsButton)
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

  @objc private func showExtensions() { onExtensions?(extensionsButton) }

  private var flashMessage: String?
  private var flashGeneration = 0
  private var lastShown = (url: "", security: String?.none)
  var shownText: String { label.stringValue }

  /// Shows a short message in place of the address for a moment (updates meanwhile land underneath), then the
  /// address again.
  func flash(_ message: String) {
    flashGeneration += 1
    let generation = flashGeneration
    flashMessage = message
    show(url: lastShown.url, security: lastShown.security)
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
      guard let self, self.flashGeneration == generation else { return }
      self.flashMessage = nil
      self.show(url: self.lastShown.url, security: self.lastShown.security)
    }
  }

  func show(url: String, security: String?) {
    lastShown = (url, security)
    defer {
      if let flashMessage {
        label.stringValue = flashMessage
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
      }
    }
    let components = URLComponents(string: url)
    let hasHost = !(components?.host ?? "").isEmpty
    text = AddressInput.pillText(for: url)
    let empty = text.isEmpty
    label.stringValue = empty ? "Search or Enter URL…" : text
    label.lineBreakMode = hasHost ? .byTruncatingHead : .byTruncatingTail
    label.textColor = empty ? .tertiaryLabelColor : .secondaryLabelColor
    searchIcon.isHidden = !empty
    let level = security ?? (components?.scheme == "http" ? "insecure" : "none")
    switch level {
    case "insecure", "certificateError":
      securityIcon.image = NSImage(systemSymbolName: "lock.slash.fill", accessibilityDescription: "Not secure")
      securityIcon.contentTintColor = .systemRed
      securityIcon.isHidden = empty
    case "mixed":
      securityIcon.image = NSImage(
        systemSymbolName: "lock.trianglebadge.exclamationmark.fill", accessibilityDescription: "Partly secure")
      securityIcon.contentTintColor = .systemOrange
      securityIcon.isHidden = empty
    default:
      securityIcon.isHidden = true
    }
    needsLayout = true
  }

  override func layout() {
    super.layout()
    let mid = bounds.height / 2
    securityIcon.frame = NSRect(x: 12, y: mid - 8, width: 16, height: 16)
    searchIcon.frame = securityIcon.frame
    let x: CGFloat = securityIcon.isHidden && searchIcon.isHidden ? 12 : 34
    extensionsButton.frame = NSRect(x: bounds.width - 32, y: mid - 13, width: 26, height: 26)
    let right: CGFloat = extensionsShown ? 36 : 12
    label.frame = NSRect(x: x, y: mid - 10, width: bounds.width - x - right, height: 20)
  }
}

final class FavoriteTileView: NSView, Liftable {
  var onClick: (() -> Void)?
  var onPointer: ((NSEvent) -> Void)?
  private let icon = NSImageView()
  private var selected = false
  private var lifted = false

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
    layer?.backgroundColor = (lifted ? SidebarColors.lifted : selected ? SidebarColors.selected : SidebarColors.fill).cgColor
    Lift.shadow(layer, lifted, radius: 10)
  }

  func setLifted(_ lifted: Bool) {
    self.lifted = lifted
    needsDisplay = true
  }

  // The icon would take the press and keep the drag for itself.
  override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func layout() {
    super.layout()
    icon.frame = NSRect(x: (bounds.width - 20) / 2, y: (bounds.height - 20) / 2, width: 20, height: 20)
    residency.placeDot(at: CGPoint(x: bounds.midX, y: 6))
  }

  override func mouseDown(with event: NSEvent) {
    onPointer?(event)
    onClick?()
  }

  override func mouseDragged(with event: NSEvent) { onPointer?(event) }
  override func mouseUp(with event: NSEvent) { onPointer?(event) }

  let residency = TabResidency()

  func show(_ entry: SidebarEntry, icon image: NSImage?, selected: Bool) {
    self.selected = selected
    icon.image = image ?? NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
    icon.contentTintColor = image == nil ? .secondaryLabelColor : nil
    residency.show(entry, in: self)
    toolTip = entry.displayTitle
    needsDisplay = true
  }
}

final class SidebarRowView: NSView, Liftable, NSTextFieldDelegate {
  enum Part { case icon, body }

  let residency = TabResidency()

  var onClick: ((Part) -> Void)?
  var onDoubleClick: (() -> Void)?
  var onPointer: ((NSEvent) -> Void)?
  private var lifted = false
  private let chevron = NSImageView()
  private(set) var isFolderRow = false
  private var editor: NSTextField?
  private var onRenamed: ((String?) -> Void)?
  /// Lit while a dragged tab would drop into this folder.
  var dropTarget = false {
    didSet { if oldValue != dropTarget { needsDisplay = true } }
  }
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
    // Measured against Arc (2026-10-27): titles 14 pt regular, the host under them 11 pt.
    title.font = .systemFont(ofSize: 14)
    title.lineBreakMode = .byTruncatingTail
    subtitle.font = .systemFont(ofSize: 11)
    subtitle.textColor = .secondaryLabelColor
    subtitle.lineBreakMode = .byTruncatingTail
    closeButton.isBordered = false
    closeButton.imagePosition = .imageOnly
    closeButton.symbolConfiguration = .init(pointSize: 11, weight: .bold)
    closeButton.contentTintColor = .secondaryLabelColor
    closeButton.target = self
    closeButton.action = #selector(close)
    closeButton.refusesFirstResponder = true
    chevron.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
    chevron.symbolConfiguration = .init(pointSize: 9, weight: .semibold)
    chevron.contentTintColor = .tertiaryLabelColor
    chevron.isHidden = true
    chevron.wantsLayer = true
    [icon, slash, title, subtitle, closeButton, chevron].forEach(addSubview)
    addTrackingArea(NSTrackingArea(
      rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }
  override var wantsUpdateLayer: Bool { true }
  override var mouseDownCanMoveWindow: Bool { false }

  override func updateLayer() {
    let color: NSColor = dropTarget ? NSColor.controlAccentColor.withAlphaComponent(0.22)
      : lifted ? SidebarColors.lifted : selected ? SidebarColors.selected : hovered ? SidebarColors.hover : .clear
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    fill.backgroundColor = color.cgColor
    fill.borderWidth = dropTarget ? 1 : 0
    fill.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.65).cgColor
    Lift.shadow(fill, lifted, radius: 8)
    CATransaction.commit()
  }

  func setLifted(_ lifted: Bool) {
    self.lifted = lifted
    needsDisplay = true
  }

  // Only the close button handles its own clicks; the icon and labels would keep a drag for themselves.
  override func hitTest(_ point: NSPoint) -> NSView? {
    guard let hit = super.hitTest(point) else { return nil }
    if let editor, hit === editor || hit.isDescendant(of: editor) { return hit }
    return hit === closeButton || hit.isDescendant(of: closeButton) ? hit : self
  }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

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
    if event.clickCount == 2, let onDoubleClick {
      onDoubleClick()
      return
    }
    onPointer?(event)
    let point = convert(event.locationInWindow, from: nil)
    onClick?(point.x < title.frame.minX - 2 ? .icon : .body)
  }

  override func mouseDragged(with event: NSEvent) { onPointer?(event) }
  override func mouseUp(with event: NSEvent) { onPointer?(event) }

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
    if entry.isFolder {
      showFolder(entry)
      return
    }
    isFolderRow = false
    chevron.isHidden = true
    self.selected = selected
    away = entry.isAwayFromPinned && entry.isLive
    closable = entry.kind == .today || entry.isLive
    icon.image = image ?? NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
    icon.contentTintColor = image == nil ? .secondaryLabelColor : nil
    icon.alphaValue = entry.kind == .today && !entry.isLive ? 0.45 : 1
    residency.show(entry, in: self)
    slash.isHidden = !away
    title.stringValue = entry.displayTitle
    title.textColor = .labelColor
    subtitle.stringValue = entry.host
    // Arc shows a closed tab by its title alone; the host only tells you a pinned tab has wandered off its page.
    let showsHost = entry.isLive && entry.isAwayFromPinned
    subtitle.isHidden = !showsHost || entry.host.isEmpty || entry.host == entry.displayTitle
    closeButton.image = NSImage(
      systemSymbolName: entry.kind == .today ? "xmark" : "minus", accessibilityDescription: "Close")
    toolTip = away ? "Click the icon to go back to the pinned page" : nil
    updateClose()
    needsLayout = true
    needsDisplay = true
  }

  /// A pinned folder: folder icon, its name, and a chevron that points down while it's open.
  private func showFolder(_ entry: SidebarEntry) {
    isFolderRow = true
    selected = false
    away = false
    closable = false
    let open = entry.isOpen ?? true
    icon.image = NSImage(systemSymbolName: open ? "folder" : "folder.fill", accessibilityDescription: "Folder")
    icon.contentTintColor = .secondaryLabelColor
    icon.alphaValue = 1
    residency.show(entry, in: self)
    slash.isHidden = true
    title.stringValue = entry.title
    title.textColor = .labelColor
    subtitle.isHidden = true
    chevron.isHidden = false
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    chevron.layer?.setAffineTransform(.identity)
    CATransaction.commit()
    chevron.image = NSImage(systemSymbolName: open ? "chevron.down" : "chevron.right", accessibilityDescription: nil)
    toolTip = nil
    updateClose()
    needsLayout = true
    needsDisplay = true
  }

  /// Edits the title in place: Return keeps it, Escape or an empty name keeps the old one.
  func beginRename(_ done: @escaping (String?) -> Void) {
    editor?.removeFromSuperview()
    let field = NSTextField(string: title.stringValue)
    field.font = title.font
    field.isBordered = false
    field.drawsBackground = false
    field.focusRingType = .none
    field.delegate = self
    field.frame = title.frame.insetBy(dx: -2, dy: 0)
    addSubview(field)
    editor = field
    onRenamed = done
    title.isHidden = true
    window?.makeFirstResponder(field)
    field.currentEditor()?.selectAll(nil)
  }

  var isRenaming: Bool { editor != nil }

  private func endRename(_ name: String?) {
    guard let editor else { return }
    self.editor = nil
    editor.removeFromSuperview()
    title.isHidden = false
    let done = onRenamed
    onRenamed = nil
    done?(name)
  }

  func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
    if selector == #selector(NSResponder.cancelOperation(_:)) {
      endRename(nil)
      return true
    }
    if selector == #selector(NSResponder.insertNewline(_:)) {
      endRename(editor?.stringValue)
      return true
    }
    return false
  }

  func controlTextDidEndEditing(_ notification: Notification) {
    endRename(editor?.stringValue)
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
    residency.placeDot(at: CGPoint(x: 3.5, y: mid))
    slash.frame = NSRect(x: 28, y: mid - 11, width: 10, height: 22)
    let textX: CGFloat = away ? 41 : 35
    closeButton.frame = NSRect(x: bounds.width - 30, y: mid - 11, width: 22, height: 22)
    chevron.frame = NSRect(x: bounds.width - 26, y: mid - 7, width: 14, height: 14)
    let trailing = isFolderRow ? chevron.frame.minX - 4 : closeButton.isHidden ? bounds.width - 10 : closeButton.frame.minX - 4
    let textWidth = trailing - textX
    if subtitle.isHidden {
      title.frame = NSRect(x: textX, y: mid - 8.5, width: textWidth, height: 20)
    } else {
      title.frame = NSRect(x: textX, y: mid - 15, width: textWidth, height: 18)
      subtitle.frame = NSRect(x: textX, y: mid + 1.5, width: textWidth, height: 14)
    }
  }
}

private enum Lift {
  static func shadow(_ layer: CALayer?, _ on: Bool, radius: CGFloat) {
    guard let layer else { return }
    layer.shadowOpacity = on ? 0.3 : 0
    layer.shadowRadius = 10
    layer.shadowOffset = CGSize(width: 0, height: -3)
    layer.shadowColor = NSColor.black.cgColor
    layer.shadowPath = on ? CGPath(roundedRect: layer.bounds, cornerWidth: radius, cornerHeight: radius, transform: nil) : nil
  }
}

/// Where a drag would land in favorites, lit Arc's way (accent tint and border): all of them, or the one tile that
/// opens when there are none.
final class DropHintView: NSView {
  private let outline = CAShapeLayer()
  private let label: NSTextField
  private let icon = NSImageView()
  private let inset: CGFloat
  /// Lit while the dragged tab would land here; dim while it's only on offer.
  var active = true {
    didSet { if oldValue != active { needsDisplay = true } }
  }

  init(symbol: String?, title: String, inset: CGFloat = SidebarRowView.fillInset) {
    label = NSTextField(labelWithString: title)
    self.inset = inset
    super.init(frame: .zero)
    wantsLayer = true
    outline.lineWidth = 1
    layer?.addSublayer(outline)
    icon.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
    icon.isHidden = symbol == nil
    icon.symbolConfiguration = .init(pointSize: 12, weight: .medium)
    icon.contentTintColor = .secondaryLabelColor
    label.font = .systemFont(ofSize: 13, weight: .medium)
    label.textColor = .secondaryLabelColor
    addSubview(icon)
    addSubview(label)
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }
  override var wantsUpdateLayer: Bool { true }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func updateLayer() {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    let accent = NSColor.controlAccentColor
    outline.fillColor = accent.withAlphaComponent(active ? 0.22 : 0.1).cgColor
    outline.strokeColor = accent.withAlphaComponent(active ? 0.65 : 0.3).cgColor
    CATransaction.commit()
    label.textColor = active ? .labelColor : .secondaryLabelColor
    icon.contentTintColor = accent
  }

  override func layout() {
    super.layout()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    let rect = bounds.insetBy(dx: 0.5, dy: inset + 0.5)
    let radius: CGFloat = inset == 0 ? 10 : 8
    outline.frame = bounds
    outline.path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    CATransaction.commit()
    let mid = bounds.height / 2
    if label.stringValue.isEmpty {
      icon.frame = NSRect(x: (bounds.width - 16) / 2, y: mid - 8, width: 16, height: 16)
    } else if inset == 0 {
      // A tile: icon and title centred together.
      let width = min(ceil(label.intrinsicContentSize.width), bounds.width - 40)
      let x = (bounds.width - width - 22) / 2
      icon.frame = NSRect(x: x, y: mid - 8, width: 16, height: 16)
      label.frame = NSRect(x: x + 22, y: mid - 10, width: width, height: 20)
    } else {
      icon.frame = NSRect(x: 9, y: mid - 8, width: 16, height: 16)
      label.frame = NSRect(x: 35, y: mid - 10, width: bounds.width - 45, height: 20)
    }
  }
}

/// Whether a pinned tab or favorite is open: a tiny grey dot, like the Dock's running-app dot, that fades in when the
/// tab opens and out when it closes. Kept quiet on purpose (an accent dot with a glow and a pulse read as too loud).
/// Today's tabs are open by nature and get no dot.
final class TabResidency {
  private var entryID: UUID?
  private var live = false
  private let dot = CALayer()
  private weak var host: NSView?

  var showsDot: Bool { live && !dot.isHidden }

  func show(_ entry: SidebarEntry, in host: NSView) {
    attach(to: host)
    let wanted = entry.kind != .today && entry.isLive
    let woke = entry.id == entryID && !live && wanted
    let slept = entry.id == entryID && live && !wanted
    entryID = entry.id
    live = wanted
    host.effectiveAppearance.performAsCurrentDrawingAppearance {
      dot.backgroundColor = NSColor.secondaryLabelColor.cgColor
    }
    if woke {
      dot.isHidden = false
      fadeDot(to: 1)
    } else if slept {
      fadeDot(to: 0)
    } else {
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      dot.isHidden = !wanted
      dot.opacity = 1
      CATransaction.commit()
    }
  }

  func placeDot(at centre: CGPoint) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    dot.position = centre
    CATransaction.commit()
  }

  private func attach(to host: NSView) {
    guard self.host !== host, let layer = host.layer else { return }
    self.host = host
    dot.bounds = CGRect(x: 0, y: 0, width: 3, height: 3)
    dot.cornerRadius = 1.5
    dot.isHidden = true
    dot.zPosition = 5
    layer.addSublayer(dot)
  }

  private func fadeDot(to value: Float) {
    let fade = CABasicAnimation(keyPath: "opacity")
    fade.fromValue = 1 - value
    fade.toValue = value
    fade.duration = 0.25
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    dot.opacity = value
    CATransaction.commit()
    dot.add(fade, forKey: "fade")
  }
}
