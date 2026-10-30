import AppKit

/// Edit Folder: a folder's name, colour and icon in one panel, shown inside the sidebar in place of the folder's row
/// (no popover). The sidebar places it at its column's width and `height` tall. A colour or icon picked applies at
/// once (`onChange`); Return or a click outside the panel keeps everything (`onEnd(true, …)`), Escape puts back what
/// the folder had (`onEnd(false, …)` with the original values). Picking a colour or icon keeps the name field focused.
final class FolderEditorView: NSView, NSTextFieldDelegate {
  enum Tab: String { case symbols, emoji }

  /// The panel's height: padding 10, name 28, gap 10, colours 18, gap 10, Symbols/Emoji 24, gap 8, search 26, gap 6,
  /// four rows of icons (4 × 27 + 3 × 2), padding 10.
  static let height: CGFloat = 264
  static let padding: CGFloat = 10
  static let columns = 8
  static let cellHeight: CGFloat = 27
  static let cellGap: CGFloat = 2
  static let visibleRows = 4
  private static let gridHeight = CGFloat(visibleRows) * cellHeight + CGFloat(visibleRows - 1) * cellGap

  /// Called on every colour or icon pick with the current name, colour and icon; the sidebar applies them at once.
  /// Typing the name doesn't call it: the name is applied at the end.
  var onChange: ((_ title: String, _ color: String?, _ icon: String?) -> Void)?
  /// Called once when editing ends: keep (Return, a click outside) with what's chosen, or not (Escape) with the
  /// folder's original name, colour and icon.
  var onEnd: ((_ keep: Bool, _ title: String, _ color: String?, _ icon: String?) -> Void)?
  let isToday: Bool

  private let original: (title: String, color: String?, icon: String?)
  private(set) var color: String?
  private(set) var icon: String?
  private(set) var tab: Tab
  private(set) var query = ""
  private(set) var ended = false
  private var monitor: Any?
  private var profileObserver: NSObjectProtocol?
  /// Scrolls the chosen icon into sight on the first layout.
  private var revealChosen = true

  private let iconView = FolderIconView()
  private let nameBox = FolderFieldBox(ring: true)
  private let nameField = FolderEditorField()
  private let swatches = FolderSwatchRow()
  private let segments = FolderTabSegments(titles: ["Symbols", "Emoji"])
  private let searchBox = FolderFieldBox(ring: false)
  private let searchField = FolderEditorField()
  private let scroll = FolderEditorScrollView()
  private let grid = FolderIconGrid()

  init(title: String, color: String?, icon: String?, isToday: Bool) {
    let color = FolderLook.valid(color)
    let icon = FolderLook.validIcon(icon)
    original = (title, color, icon)
    self.color = color
    self.icon = icon
    self.isToday = isToday
    tab = icon == nil || FolderLook.symbolName(icon) != nil ? .symbols : .emoji
    super.init(frame: NSRect(x: 0, y: 0, width: 251, height: Self.height))
    wantsLayer = true
    layer?.cornerRadius = 12
    layer?.cornerCurve = .continuous

    iconView.show(color: color, icon: icon)
    iconView.setState(open: true, hovered: false, dropTarget: false, animated: false)
    addSubview(iconView)

    setUp(nameField, text: title, placeholder: "Folder name", size: 14)
    nameBox.addSubview(nameField)
    addSubview(nameBox)
    nameField.onFocus = { [weak self] focused in self?.nameBox.focused = focused }

    swatches.chosen = color
    swatches.onPick = { [weak self] name in self?.press(color: name) }
    addSubview(swatches)

    segments.selectedIndex = tab == .symbols ? 0 : 1
    segments.onChoose = { [weak self] index in self?.show(tab: index == 0 ? Tab.symbols.rawValue : Tab.emoji.rawValue) }
    addSubview(segments)

    setUp(searchField, text: "", placeholder: "Search", size: 12)
    searchBox.addSubview(searchField)
    addSubview(searchBox)

    nameField.nextKeyView = searchField
    searchField.nextKeyView = nameField

    scroll.drawsBackground = false
    scroll.hasVerticalScroller = true
    scroll.hasHorizontalScroller = false
    scroll.autohidesScrollers = true
    scroll.borderType = .noBorder
    scroll.contentView.drawsBackground = false
    scroll.documentView = grid
    grid.onPick = { [weak self] value in self?.press(icon: value) }
    addSubview(scroll)

    profileObserver = NotificationCenter.default.addObserver(forName: ProfileColor.didChange, object: nil, queue: .main) {
      [weak self] _ in
      self?.nameBox.needsDisplay = true
      self?.grid.needsDisplay = true
    }
    reload()
  }

  required init?(coder: NSCoder) { fatalError() }

  deinit {
    if let monitor { NSEvent.removeMonitor(monitor) }
    if let profileObserver { NotificationCenter.default.removeObserver(profileObserver) }
  }

  override var isFlipped: Bool { true }
  override var wantsUpdateLayer: Bool { true }
  override var mouseDownCanMoveWindow: Bool { false }

  override func updateLayer() {
    layer?.backgroundColor = SidebarColors.fill.cgColor
  }

  private func setUp(_ field: FolderEditorField, text: String, placeholder: String, size: CGFloat) {
    let font = NSFont.systemFont(ofSize: size)
    field.stringValue = text
    field.font = font
    field.textColor = .labelColor
    field.isBordered = false
    field.drawsBackground = false
    field.focusRingType = .none
    field.lineBreakMode = .byTruncatingTail
    field.cell?.isScrollable = true
    field.cell?.wraps = false
    field.cell?.usesSingleLineMode = true
    field.placeholderAttributedString = NSAttributedString(
      string: placeholder, attributes: [.font: font, .foregroundColor: NSColor.tertiaryLabelColor])
    field.delegate = self
  }

  override func layout() {
    super.layout()
    let pad = Self.padding
    let width = bounds.width - pad * 2
    var y = pad
    iconView.frame = NSRect(x: pad, y: y + (28 - FolderIconView.size.height) / 2, width: FolderIconView.size.width,
                            height: FolderIconView.size.height)
    nameBox.frame = NSRect(x: pad + 18 + 9, y: y, width: width - 27, height: 28)
    place(nameField, in: nameBox)
    y += 28 + 10
    // The chosen colour's ring reaches 4 pt past its swatch.
    swatches.frame = NSRect(x: pad - FolderSwatchRow.margin, y: y - FolderSwatchRow.margin,
                            width: width + FolderSwatchRow.margin * 2, height: 18 + FolderSwatchRow.margin * 2)
    y += 18 + 10
    segments.frame = NSRect(x: pad, y: y, width: width, height: 24)
    y += 24 + 8
    searchBox.frame = NSRect(x: pad, y: y, width: width, height: 26)
    place(searchField, in: searchBox)
    y += 26 + 6
    scroll.frame = NSRect(x: pad, y: y, width: width, height: Self.gridHeight)
    grid.cellWidth = (width - CGFloat(Self.columns - 1) * Self.cellGap) / CGFloat(Self.columns)
    grid.frame = NSRect(x: 0, y: 0, width: width, height: max(grid.contentHeight, Self.gridHeight))
    if revealChosen {
      revealChosen = false
      if let rect = grid.cellRect(grid.chosen) { grid.scrollToVisible(rect.insetBy(dx: 0, dy: -Self.cellGap)) }
    }
  }

  /// A field one line tall, centred in its box, its text 8 pt from the box's edge (the cell adds 2).
  private func place(_ field: NSTextField, in box: NSView) {
    let height = ceil(field.intrinsicContentSize.height)
    field.frame = NSRect(x: 6, y: ((box.bounds.height - height) / 2).rounded(), width: box.bounds.width - 12, height: height)
  }

  // MARK: Ending

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window == nil {
      removeMonitor()
    } else if !ended, monitor == nil {
      // App-local, clicks only: a click anywhere but the panel keeps the edit (never a global monitor).
      monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
        guard let self, !self.ended else { return event }
        if event.window === self.window, self.bounds.contains(self.convert(event.locationInWindow, from: nil)) {
          return event
        }
        self.end(keep: true, afterClick: true)
        return event
      }
    }
  }

  private func removeMonitor() {
    if let monitor { NSEvent.removeMonitor(monitor) }
    monitor = nil
  }

  /// Ends once. After an outside click the result waits for the click to land first, so a row the user clicked is
  /// still where they clicked it when the panel closes.
  private func end(keep: Bool, afterClick: Bool = false) {
    guard !ended else { return }
    ended = true
    removeMonitor()
    let result = keep ? (title: nameField.stringValue, color: color, icon: icon) : original
    let callback = onEnd
    if afterClick {
      DispatchQueue.main.async { callback?(keep, result.title, result.color, result.icon) }
    } else {
      callback?(keep, result.title, result.color, result.icon)
    }
  }

  func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
    if selector == #selector(NSResponder.insertNewline(_:)) {
      pressReturn()
      return true
    }
    if selector == #selector(NSResponder.cancelOperation(_:)) {
      pressEscape()
      return true
    }
    return false
  }

  func controlTextDidChange(_ notification: Notification) {
    guard (notification.object as? NSTextField) === searchField else { return }
    search(searchField.stringValue)
  }

  override func cancelOperation(_ sender: Any?) { pressEscape() }

  override func keyDown(with event: NSEvent) {
    switch event.keyCode {
    case 36, 76: pressReturn()
    case 53: pressEscape()
    default: super.keyDown(with: event)
    }
  }

  // MARK: Picking

  /// Puts the name field in focus with its text selected.
  func focus() {
    guard let window else { return }
    window.makeFirstResponder(nameField)
    nameField.currentEditor()?.selectAll(nil)
  }

  private var cells: [String?] {
    switch tab {
    case .symbols: return (query.isEmpty ? [nil] : []) + FolderLook.symbols(matching: query)
    case .emoji: return FolderLook.emoji(matching: query)
    }
  }

  private func reload() {
    grid.items = cells
    grid.chosenValue = icon
    needsLayout = true
  }

  // Plain methods the test commands call too.

  func press(color name: String?) {
    guard !ended else { return }
    color = FolderLook.valid(name)
    swatches.chosen = color
    iconView.show(color: color, icon: icon)
    onChange?(nameField.stringValue, color, icon)
  }

  func press(icon value: String?) {
    guard !ended else { return }
    icon = FolderLook.validIcon(value)
    grid.chosenValue = icon
    iconView.show(color: color, icon: icon)
    onChange?(nameField.stringValue, color, icon)
  }

  /// "symbols" or "emoji".
  func show(tab name: String) {
    guard let next = Tab(rawValue: name) else { return }
    segments.selectedIndex = next == .symbols ? 0 : 1
    guard next != tab else { return }
    tab = next
    reload()
    scroll.contentView.scroll(to: .zero)
    scroll.reflectScrolledClipView(scroll.contentView)
  }

  func search(_ text: String) {
    if searchField.stringValue != text { searchField.stringValue = text }
    guard text != query else { return }
    query = text
    reload()
    scroll.contentView.scroll(to: .zero)
    scroll.reflectScrolledClipView(scroll.contentView)
  }

  func setTitle(_ text: String) { nameField.stringValue = text }

  func pressReturn() { end(keep: true) }

  func pressEscape() { end(keep: false) }

  /// For checks: what the panel shows and holds.
  var debug: [String: Any] {
    [
      "title": nameField.stringValue, "color": color ?? NSNull(), "icon": icon ?? NSNull(), "tab": tab.rawValue,
      "query": query, "cells": grid.items.count, "chosen": grid.chosen ?? -1, "isToday": isToday, "ended": ended,
      "focused": nameBox.focused, "iconView": iconView.debug,
    ]
  }
}

// MARK: Pieces

/// A text field that says when it gains and loses focus, for its box's ring.
private final class FolderEditorField: NSTextField {
  var onFocus: ((Bool) -> Void)?

  override func becomeFirstResponder() -> Bool {
    let became = super.becomeFirstResponder()
    if became { onFocus?(true) }
    return became
  }

  override func textDidEndEditing(_ notification: Notification) {
    super.textDidEndEditing(notification)
    onFocus?(false)
  }
}

/// A field's rounded box in the sidebar's selected-row fill, with a 2 pt ring in the profile's colour while focused.
private final class FolderFieldBox: NSView {
  private let ring = CALayer()
  private let showsRing: Bool
  var focused = false {
    didSet { if oldValue != focused { needsDisplay = true } }
  }

  init(ring showsRing: Bool) {
    self.showsRing = showsRing
    super.init(frame: .zero)
    wantsLayer = true
    layer?.cornerRadius = 7
    layer?.cornerCurve = .continuous
    ring.cornerRadius = 9
    ring.cornerCurve = .continuous
    ring.borderWidth = 2
    ring.isHidden = true
    layer?.addSublayer(ring)
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }
  override var wantsUpdateLayer: Bool { true }

  override func updateLayer() {
    layer?.backgroundColor = SidebarColors.selected.cgColor
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    ring.borderColor = ProfileColor.accent.cgColor
    ring.isHidden = !(showsRing && focused)
    CATransaction.commit()
  }

  override func layout() {
    super.layout()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    ring.frame = bounds.insetBy(dx: -2, dy: -2)
    CATransaction.commit()
  }
}

/// None and Chrome's eight colours as 18 pt dots 7 pt apart; the chosen one ringed in the label colour.
private final class FolderSwatchRow: NSView {
  /// Room around the dots for the chosen one's ring.
  static let margin: CGFloat = 4
  private static let size: CGFloat = 18
  private static let gap: CGFloat = 7
  private let names: [String?] = [nil] + FolderLook.colors
  var onPick: ((String?) -> Void)?
  var chosen: String? {
    didSet { if oldValue != chosen { needsDisplay = true } }
  }

  override var isFlipped: Bool { true }
  override var mouseDownCanMoveWindow: Bool { false }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  private func dot(_ index: Int) -> NSRect {
    NSRect(x: Self.margin + CGFloat(index) * (Self.size + Self.gap), y: Self.margin, width: Self.size, height: Self.size)
  }

  override func draw(_ dirtyRect: NSRect) {
    for (index, name) in names.enumerated() {
      let rect = dot(index)
      if let name {
        FolderLook.color(name).setFill()
        NSBezierPath(ovalIn: rect).fill()
      } else {
        drawNone(in: rect)
      }
      if name == chosen {
        NSColor.labelColor.setStroke()
        let ring = NSBezierPath(ovalIn: rect.insetBy(dx: -3, dy: -3))
        ring.lineWidth = 2
        ring.stroke()
      }
    }
  }

  /// The mock's none swatch: a 1.5 pt ring and a slash, top right to bottom left (this view is flipped).
  private func drawNone(in rect: NSRect) {
    NSColor.tertiaryLabelColor.setStroke()
    let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 0.75, dy: 0.75))
    ring.lineWidth = 1.5
    ring.stroke()
    let half: CGFloat = 4.95
    let slash = NSBezierPath()
    slash.move(to: NSPoint(x: rect.midX + half, y: rect.midY - half))
    slash.line(to: NSPoint(x: rect.midX - half, y: rect.midY + half))
    slash.lineWidth = 1.5
    slash.stroke()
  }

  override func mouseDown(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    guard let index = names.indices.first(where: { dot($0).insetBy(dx: -Self.gap / 2, dy: -Self.margin).contains(point) })
    else { return }
    onPick?(names[index])
  }
}

/// The Symbols / Emoji switch, as the mock's `.seg`: a track in the sidebar's fill, the chosen half in the selected
/// row's fill.
private final class FolderTabSegments: NSView {
  let titles: [String]
  var onChoose: ((Int) -> Void)?
  var selectedIndex = 0 {
    didSet { if oldValue != selectedIndex { needsDisplay = true } }
  }

  init(titles: [String]) {
    self.titles = titles
    super.init(frame: .zero)
    setAccessibilityRole(.radioGroup)
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }
  override var mouseDownCanMoveWindow: Bool { false }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  private var segmentWidth: CGFloat { (bounds.width - 4) / CGFloat(max(1, titles.count)) }

  override func draw(_ dirtyRect: NSRect) {
    SidebarColors.fill.setFill()
    NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
    let thumb = NSRect(x: 2 + CGFloat(selectedIndex) * segmentWidth, y: 2, width: segmentWidth, height: bounds.height - 4)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor(white: 0, alpha: 0.15)
    shadow.shadowOffset = NSSize(width: 0, height: -0.5)
    shadow.shadowBlurRadius = 1
    shadow.set()
    SidebarColors.selected.setFill()
    NSBezierPath(roundedRect: thumb, xRadius: 5, yRadius: 5).fill()
    NSGraphicsContext.restoreGraphicsState()
    for (index, title) in titles.enumerated() {
      let text = NSAttributedString(string: title, attributes: [
        .font: NSFont.systemFont(ofSize: 12),
        .foregroundColor: index == selectedIndex ? NSColor.labelColor : NSColor.secondaryLabelColor,
      ])
      let size = text.size()
      let cell = NSRect(x: 2 + CGFloat(index) * segmentWidth, y: 0, width: segmentWidth, height: bounds.height)
      text.draw(at: NSPoint(x: (cell.midX - size.width / 2).rounded(), y: (cell.midY - size.height / 2).rounded()))
    }
  }

  override func mouseDown(with event: NSEvent) {
    let x = convert(event.locationInWindow, from: nil).x
    let index = min(titles.count - 1, max(0, Int((x - 2) / segmentWidth)))
    selectedIndex = index
    onChoose?(index)
  }
}

/// The icons as an 8-column grid of 27 pt cells 2 pt apart. A nil item is "none", drawn as an en dash; the chosen
/// cell is filled in the profile's colour with its glyph in the white or black that reads on it.
private final class FolderIconGrid: NSView {
  var items: [String?] = [] {
    didSet { hovered = nil; needsDisplay = true }
  }
  var chosenValue: String? {
    didSet { needsDisplay = true }
  }
  var cellWidth: CGFloat = 27 {
    didSet { if oldValue != cellWidth { needsDisplay = true } }
  }
  var onPick: ((String?) -> Void)?
  private var hovered: Int?

  override var isFlipped: Bool { true }
  override var mouseDownCanMoveWindow: Bool { false }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  private var rows: Int { (items.count + FolderEditorView.columns - 1) / FolderEditorView.columns }

  var contentHeight: CGFloat {
    rows == 0 ? 0 : CGFloat(rows) * FolderEditorView.cellHeight + CGFloat(rows - 1) * FolderEditorView.cellGap
  }

  /// The chosen item's index among those shown, nil when it isn't shown.
  var chosen: Int? { items.firstIndex { $0 == chosenValue } }

  func cellRect(_ index: Int?) -> NSRect? {
    guard let index, items.indices.contains(index) else { return nil }
    let column = index % FolderEditorView.columns, row = index / FolderEditorView.columns
    return NSRect(x: CGFloat(column) * (cellWidth + FolderEditorView.cellGap),
                  y: CGFloat(row) * (FolderEditorView.cellHeight + FolderEditorView.cellGap),
                  width: cellWidth, height: FolderEditorView.cellHeight)
  }

  private func index(at point: NSPoint) -> Int? {
    let column = Int(point.x / (cellWidth + FolderEditorView.cellGap))
    let row = Int(point.y / (FolderEditorView.cellHeight + FolderEditorView.cellGap))
    guard point.x >= 0, point.y >= 0, column < FolderEditorView.columns else { return nil }
    let index = row * FolderEditorView.columns + column
    guard let rect = cellRect(index), rect.contains(point) else { return nil }
    return index
  }

  override func draw(_ dirtyRect: NSRect) {
    let chosen = self.chosen
    for index in items.indices {
      guard let rect = cellRect(index), rect.intersects(dirtyRect) else { continue }
      let isChosen = index == chosen
      if isChosen || index == hovered {
        (isChosen ? ProfileColor.accent : SidebarColors.fill).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
      }
      let ink = isChosen ? ProfileColor.foreground(on: ProfileColor.accent) : NSColor.labelColor
      let item = items[index]
      if let name = FolderLook.symbolName(item),
         let image = FolderLook.symbolImage(name, size: 14, weight: .regular, color: ink) {
        let size = image.size
        image.draw(in: NSRect(x: (rect.midX - size.width / 2).rounded(), y: (rect.midY - size.height / 2).rounded(),
                              width: size.width, height: size.height))
      } else {
        let text = NSAttributedString(string: item ?? "\u{2013}", attributes: [
          .font: NSFont.systemFont(ofSize: 15), .foregroundColor: ink,
        ])
        let size = text.size()
        text.draw(at: NSPoint(x: (rect.midX - size.width / 2).rounded(), y: (rect.midY - size.height / 2).rounded()))
      }
    }
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    trackingAreas.forEach(removeTrackingArea)
    addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                   owner: self))
  }

  private func hover(_ index: Int?) {
    guard index != hovered else { return }
    for old in [hovered, index] { if let rect = cellRect(old) { setNeedsDisplay(rect) } }
    hovered = index
  }

  override func mouseMoved(with event: NSEvent) { hover(index(at: convert(event.locationInWindow, from: nil))) }
  override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
  override func mouseExited(with event: NSEvent) { hover(nil) }

  override func mouseDown(with event: NSEvent) {
    guard let index = index(at: convert(event.locationInWindow, from: nil)) else { return }
    onPick?(items[index])
  }
}

/// The grid's scroll view: its scroller shows only while scrolling, whatever System Settings says.
private final class FolderEditorScrollView: NSScrollView {
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
