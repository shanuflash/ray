import AppKit

// Back and forward's history lists (Chrome's back/forward menu, `back_forward_menu_model.cc`): a right-click, ⌃-click,
// a press held 0.5 s or a drag down on either button (the page bar's or the sidebar's, `HistoryButton.onHistory`)
// lists the pages that way, nearest first, at most 12, then Show Full History (not in private windows). Ray's own
// panel (owner's pick 2026-11-05, `docs/mocks/tab-details.html`): 300 pt wide, 32 pt rows (Ardia's), favicons from
// Chrome's favicon store, titles from the engine's `navigationEntries`. A click goes there (`goToOffset`), ⌘-click
// opens it in a new background tab; ↑ ↓ ⏎ and Escape work. Dia's two-finger swipe-and-hold list is a later step.

struct BackForwardItem: Equatable {
  let title: String
  let url: String
  /// Steps from the current entry: -1 is one back, 1 one forward.
  let offset: Int
}

enum HistoryList {
  static let limit = 12
  static let width: CGFloat = 300
  static let rowHeight: CGFloat = 32
  static let padding: CGFloat = 6
  /// Page favicons, kept for the run (`ac_favicons_get`).
  static let favicons = FaviconCache()

  /// The pages back (or forward) from the current entry, nearest first. A page with no title shows its address.
  static func items(_ entries: [[String: Any]], forward: Bool) -> [BackForwardItem] {
    guard let current = entries.firstIndex(where: { $0["current"] as? Bool == true }) else { return [] }
    let indices = forward ? Array(entries.indices.filter { $0 > current }) : entries.indices.filter { $0 < current }.reversed()
    return indices.prefix(limit).map { index in
      let url = entries[index]["url"] as? String ?? ""
      let title = (entries[index]["title"] as? String ?? "")
        .components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
      return BackForwardItem(title: title.isEmpty ? AddressInput.addressParts(for: url).text : String(title.prefix(200)),
                         url: url, offset: index - current)
    }
  }
}

/// The panel's content: the pages, a hairline, Show Full History.
final class HistoryListView: NSView {
  enum Choice {
    case item(BackForwardItem, newTab: Bool)
    case fullHistory
  }

  var onChoose: ((Choice) -> Void)?
  let items: [BackForwardItem]
  private var rows: [HistoryRowView] = []
  /// The row ↑ ↓ (or the pointer) lit last, in `rows`.
  private(set) var highlighted: Int?
  private var monitor: Any?

  init(items: [BackForwardItem], fullHistoryKey: String?, showsFullHistory: Bool) {
    self.items = items
    super.init(frame: .zero)
    var y = HistoryList.padding
    let width = HistoryList.width - HistoryList.padding * 2
    for item in items {
      let row = HistoryRowView(title: item.title, symbol: nil, key: nil)
      row.frame = NSRect(x: HistoryList.padding, y: y, width: width, height: HistoryList.rowHeight)
      addSubview(row)
      rows.append(row)
      y += HistoryList.rowHeight
    }
    if showsFullHistory {
      let line = NSBox(frame: NSRect(x: HistoryList.padding + 8, y: y + 4, width: width - 16, height: 1))
      line.boxType = .separator
      addSubview(line)
      y += 9
      let row = HistoryRowView(title: "Show Full History", symbol: "clock", key: fullHistoryKey)
      row.frame = NSRect(x: HistoryList.padding, y: y, width: width, height: HistoryList.rowHeight)
      addSubview(row)
      rows.append(row)
      y += HistoryList.rowHeight
    }
    frame = NSRect(x: 0, y: 0, width: HistoryList.width, height: y + HistoryList.padding)
    for (index, row) in rows.enumerated() {
      row.onClick = { [weak self] newTab in self?.choose(index, newTab: newTab) }
      row.onHover = { [weak self] in self?.highlight(index) }
    }
    reloadIcons()
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }
  override var mouseDownCanMoveWindow: Bool { false }

  /// Favicons that came in since the list opened.
  func reloadIcons() {
    for (row, item) in zip(rows, items) { row.setIcon(HistoryList.favicons.image(for: item.url)) }
  }

  var iconsShown: Int { zip(rows, items).filter { $0.0.hasFavicon }.count }

  func choose(_ index: Int, newTab: Bool = false) {
    guard rows.indices.contains(index) else { return }
    onChoose?(index < items.count ? .item(items[index], newTab: newTab) : .fullHistory)
  }

  func returnPressed() { if let highlighted { choose(highlighted) } }

  /// ↑ ↓: the next row lit, wrapping; the first press lights the first (or last) row.
  func move(_ step: Int) {
    guard !rows.isEmpty else { return }
    let next = highlighted.map { ($0 + step + rows.count) % rows.count } ?? (step > 0 ? 0 : rows.count - 1)
    highlight(next)
  }

  private func highlight(_ index: Int?) {
    highlighted = index
    for (i, row) in rows.enumerated() { row.lit = i == index }
  }

  // Arrow keys while the list shows; Return and Escape are the panel's.
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window != nil, monitor == nil {
      monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
        guard let self, event.window === self.window, self.onChoose != nil else { return event }
        switch event.keyCode {
        case 126: self.move(-1)
        case 125: self.move(1)
        default: return event
        }
        return nil
      }
    } else if window == nil, let monitor {
      NSEvent.removeMonitor(monitor)
      self.monitor = nil
    }
  }

  /// The list is going: no more keys or choices.
  func stop() {
    onChoose = nil
    if let monitor { NSEvent.removeMonitor(monitor) }
    monitor = nil
  }
}

/// One row: a 16 pt favicon (a globe until one comes; Show Full History's clock), the title, and a key on the right.
final class HistoryRowView: NSView {
  var onClick: ((_ newTab: Bool) -> Void)?
  var onHover: (() -> Void)?
  var lit = false {
    didSet { if lit != oldValue { needsDisplay = true } }
  }
  private let icon = NSImageView()
  private let label = NSTextField(labelWithString: "")
  private let keyLabel = NSTextField(labelWithString: "")
  private let isCommand: Bool
  private(set) var hasFavicon = false

  init(title: String, symbol: String?, key: String?) {
    isCommand = symbol != nil
    super.init(frame: .zero)
    wantsLayer = true
    layer?.cornerRadius = 8
    layer?.cornerCurve = .continuous
    icon.imageScaling = .scaleProportionallyUpOrDown
    icon.symbolConfiguration = .init(pointSize: 13, weight: .regular)
    icon.image = NSImage(systemSymbolName: symbol ?? "globe", accessibilityDescription: nil)
    icon.contentTintColor = .secondaryLabelColor
    label.stringValue = title
    label.font = .systemFont(ofSize: 13)
    label.textColor = isCommand ? .secondaryLabelColor : .labelColor
    label.lineBreakMode = .byTruncatingTail
    label.maximumNumberOfLines = 1
    keyLabel.stringValue = key ?? ""
    keyLabel.font = .systemFont(ofSize: 12)
    keyLabel.textColor = .tertiaryLabelColor
    keyLabel.isHidden = (key ?? "").isEmpty
    [icon, label, keyLabel].forEach(addSubview)
    setAccessibilityElement(true)
    setAccessibilityRole(.button)
    setAccessibilityLabel(title)
    addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }
  override var wantsUpdateLayer: Bool { true }
  override var mouseDownCanMoveWindow: Bool { false }
  override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }

  func setIcon(_ image: NSImage?) {
    guard !isCommand, let image else { return }
    hasFavicon = true
    icon.image = image
    icon.contentTintColor = nil
  }

  override func updateLayer() {
    layer?.backgroundColor = lit ? Self.litFill.cgColor : NSColor.clear.cgColor
  }

  /// The lit row: a solid wash of the profile's colour over the panel's card, Settings' selected row's mix (it
  /// follows dark mode and a black profile colour).
  static let litFill = ProfileColor.mix(NSColor(name: nil) { _ in ProfileColor.accent }, over: SurfaceBackdrop.solidFill, 0.17, dark: 0.26)

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    needsDisplay = true
  }

  override func layout() {
    super.layout()
    let mid = bounds.height / 2
    icon.frame = NSRect(x: 9, y: mid - 8, width: 16, height: 16)
    let keyWidth = keyLabel.isHidden ? 0 : ceil(keyLabel.intrinsicContentSize.width) + 2
    keyLabel.frame = NSRect(x: bounds.width - 10 - keyWidth, y: (mid - ceil(keyLabel.intrinsicContentSize.height) / 2).rounded(),
                            width: keyWidth, height: ceil(keyLabel.intrinsicContentSize.height))
    let right = keyLabel.isHidden ? bounds.width - 10 : keyLabel.frame.minX - 8
    let height = ceil(label.intrinsicContentSize.height)
    label.frame = NSRect(x: 34, y: (mid - height / 2).rounded(), width: max(0, right - 34), height: height)
  }

  override func mouseEntered(with event: NSEvent) { onHover?() }
  override func mouseDown(with event: NSEvent) { onClick?(event.modifierFlags.contains(.command)) }
}
