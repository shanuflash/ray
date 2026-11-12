import AppKit
import QuartzCore

// Arc's ⌃Tab switcher (its ModalItemSwitcher; sizes measured on Arc 1.170 by Cra, docs/arc-reverse-engineering.md,
// and in the owner's recording): the most recently used tabs as cards with a picture of the page, as ⌘Tab shows
// apps. ⌃Tab starts on the next card and the panel shows after a short hold, so a quick tap just switches; Tab / ⇧Tab
// and ← → move and wrap; the pointer picks the card it moves over. Releasing Control, Return or a click switches;
// Escape, a click elsewhere or the window resigning key cancel. The page behind stays until the switch. No
// animation, as Arc. Ray's look: Panels and notes' surface (`SurfaceBackdrop`), the selected card in the profile's
// colour. Settings › Tabs › recently used order off: ⌃Tab walks the sidebar with no switcher.

/// Pictures of pages for the switcher's cards. Chrome draws nothing for a hidden page, so only the shown one can be
/// copied: a tab is pictured as it's left, and the current one when the switcher opens. In memory, per window.
final class TabPictures {
  /// The card's picture at 2×.
  static let pixels = CGSize(width: TabSwitcherView.thumbnail.width * 2, height: TabSwitcherView.thumbnail.height * 2)
  private var pictures: [UUID: CGImage] = [:]
  var onChange: ((UUID) -> Void)?

  func picture(of entry: SidebarEntry) -> CGImage? { pictures[entry.id] }

  /// Captures asked for and not yet in: a tab is copied once however many callers ask (a switch from Ray's own
  /// command reaches `select` twice, by itself and by the engine's activation), again only after 2 s without an
  /// answer.
  private var pending: [UUID: CFTimeInterval] = [:]
  /// The engine hands over the page at full size; fitting it to a card is 10 ms of colour matching and
  /// interpolation, so it happens here, never on the main thread, one picture at a time.
  private static let work = DispatchQueue(label: "dev.shanus.ray.tab-pictures", qos: .utility)
  /// For the state log: copies asked of the engine (one per tab left).
  private(set) var copies = 0

  func capture(_ entry: SidebarEntry) {
    guard let tab = entry.tab, !tab.closed else { return }
    let id = entry.id
    let now = CACurrentMediaTime()
    if let asked = pending[id], now - asked < 2 { return }
    pending[id] = now
    copies += 1
    tab.copyPicture(1) { [weak self] picture in
      guard let self else { return }
      guard let picture else {
        if self.pending[id] == now { self.pending[id] = nil }
        return
      }
      Self.work.async { [weak self] in
        let small = Self.scaled(picture)
        DispatchQueue.main.async {
          guard let self else { return }
          if self.pending[id] == now { self.pending[id] = nil }
          guard let small else { return }
          self.pictures[id] = small
          self.onChange?(id)
        }
      }
    }
  }

  /// Drops the pictures of tabs no longer open.
  func keep(_ ids: Set<UUID>) { pictures = pictures.filter { ids.contains($0.key) } }

  var count: Int { pictures.count }

  /// Fills the card: the page's top, centred across.
  private static func scaled(_ image: CGImage) -> CGImage? {
    let (w, h) = (CGFloat(image.width), CGFloat(image.height))
    // In the page's own colour space when a bitmap can be in it: the card's layer matches colours as it draws, and
    // converting every pixel of the full page to sRGB first was two thirds of the cost.
    func bitmap(_ space: CGColorSpace) -> CGContext? {
      CGContext(data: nil, width: Int(pixels.width), height: Int(pixels.height), bitsPerComponent: 8, bytesPerRow: 0,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)
    }
    let own = image.colorSpace.flatMap { $0.model == .rgb && $0.supportsOutput ? bitmap($0) : nil }
    guard w > 0, h > 0, let context = own ?? bitmap(CGColorSpace(name: CGColorSpace.sRGB)!) else { return nil }
    let scale = max(pixels.width / w, pixels.height / h)
    let size = CGSize(width: w * scale, height: h * scale)
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: (pixels.width - size.width) / 2, y: pixels.height - size.height,
                                   width: size.width, height: size.height))
    return context.makeImage()
  }
}

/// One ⌃Tab walk: the cards, which one is chosen, and the keys and clicks while Control is held.
final class TabSwitcher {
  static let maxCards = 5
  /// ⌃Tab to panel: Arc showed it 0.18–0.26 s after the key and never for a 0.13 s tap (Cra); Ardia waits 0.14 s.
  static let showDelay: TimeInterval = 0.15

  private(set) var items: [SidebarEntry] = []
  private(set) var index = 0
  private(set) var shown = false
  var isOpen: Bool { !items.isEmpty }
  let view = TabSwitcherView()
  /// How the last walk ended, for the state log: the tab chosen, how, and whether the panel had shown.
  private(set) var lastResult: [String: Any]?

  var onShow: (() -> Void)?
  var onHide: (() -> Void)?
  var onChange: (() -> Void)?
  var onCommit: ((SidebarEntry) -> Void)?
  var describe: ((SidebarEntry) -> TabSwitcherView.Card)?

  private var showWork: DispatchWorkItem?
  private var monitor: Any?
  private var pointerAtShow: NSPoint?
  private var movedByTab: TimeInterval?

  init() {
    view.onHover = { [weak self] index in self?.hover(index) }
    view.onClick = { [weak self] index in self?.click(index) }
  }

  /// ⌃Tab (step 1) or ⌃⇧Tab (-1): opens on the next (or last) card, or moves. `held`: Control is down, so the walk
  /// waits for its release; from a menu click nothing is held and it switches at once.
  func step(_ step: Int, order: [SidebarEntry], cards: Int, held: Bool) {
    if isOpen { return tabPressed(NSApp.currentEvent, step) }
    let list = Array(order.prefix(max(2, min(Self.maxCards, cards))))
    guard list.count > 1 else { return }
    items = list
    index = step > 0 ? 1 : list.count - 1
    movedByTab = NSApp.currentEvent?.timestamp
    guard held else { return finish("menu", choose: true) }
    monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
      self?.handle(event) ?? event
    }
    let work = DispatchWorkItem { [weak self] in self?.show() }
    showWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.showDelay, execute: work)
    onChange?()
  }

  func move(_ step: Int) {
    guard isOpen else { return }
    index = ((index + step) % items.count + items.count) % items.count
    view.select(index)
    onChange?()
  }

  /// One Tab press reaches the switcher by more than one road (its own monitor, the menu's ⌃Tab, and again when
  /// Chrome hands back a key it didn't use), so each press moves once.
  private func tabPressed(_ event: NSEvent?, _ step: Int) {
    if let event, event.type == .keyDown {
      if event.timestamp == movedByTab { return }
      movedByTab = event.timestamp
    }
    move(step)
  }

  /// Control was let go: switch to the chosen card.
  func commit(_ how: String) { finish(how, choose: true) }

  /// Escape, a click elsewhere, the window resigning or a tab chosen some other way: the tab stays.
  func cancel(_ how: String) { finish(how, choose: false) }

  /// A picture came in while the panel is up.
  func pictureChanged(_ id: UUID) {
    guard shown, items.contains(where: { $0.id == id }) else { return }
    reloadCards()
  }

  /// The pointer moved over a card. A panel that opens under a resting pointer keeps the keyboard's choice until the
  /// pointer moves (`force` for tests).
  func hover(_ card: Int, force: Bool = false) {
    guard shown, items.indices.contains(card) else { return }
    if !force, let at = pointerAtShow, NSEvent.mouseLocation == at { return }
    pointerAtShow = nil
    guard card != index else { return }
    index = card
    view.select(index)
    onChange?()
  }

  func click(_ card: Int) {
    guard shown, items.indices.contains(card) else { return }
    index = card
    finish("click", choose: true)
  }

  private func show() {
    guard isOpen, !shown else { return }
    shown = true
    pointerAtShow = NSEvent.mouseLocation
    reloadCards()
    onShow?()
    onChange?()
  }

  private func reloadCards() {
    guard let describe else { return }
    view.show(items.map(describe), selected: index)
  }

  private func finish(_ how: String, choose: Bool) {
    guard isOpen else { return }
    let chosen = choose && items.indices.contains(index) ? items[index] : nil
    lastResult = [
      "how": how, "shown": shown, "index": index, "chosen": chosen?.id.uuidString ?? NSNull(),
      "items": items.map(\.id.uuidString),
    ]
    showWork?.cancel()
    showWork = nil
    if let monitor { NSEvent.removeMonitor(monitor) }
    monitor = nil
    pointerAtShow = nil
    let wasShown = shown
    items = []
    shown = false
    if wasShown { onHide?() }
    if let chosen, chosen.isLive { onCommit?(chosen) }
    onChange?()
  }

  /// The switcher's keys while Control is held; any other key (⌘Q, ⌘W…) or a click outside cancels it and goes on.
  private func handle(_ event: NSEvent) -> NSEvent? {
    if event.type == .leftMouseDown || event.type == .rightMouseDown {
      let inside = shown && event.window === view.window
        && view.bounds.contains(view.convert(event.locationInWindow, from: nil))
      if !inside { cancel("click outside") }
      return event
    }
    switch event.keyCode {
    case 48: tabPressed(event, event.modifierFlags.contains(.shift) ? -1 : 1)
    case 124: move(1)  // →
    case 123: move(-1)  // ←
    case 53: cancel("escape")
    case 36, 76: commit("return")  // Return, Enter
    default:
      cancel("other key")
      return event
    }
    return nil
  }

  var debug: [String: Any] {
    [
      "open": isOpen, "shown": shown, "index": index, "items": items.map(\.id.uuidString),
      "titles": view.titles, "pictures": view.pictured, "frame": shown ? NSStringFromRect(view.frame) : NSNull(),
      "style": view.backdropStyle, "last": lastResult ?? NSNull(),
    ]
  }
}

/// The switcher's panel: a row of cards on the panels' surface, centred on the window.
final class TabSwitcherView: NSView {
  struct Card {
    let title: String
    let icon: NSImage?
    let picture: CGImage?
  }

  static let card = CGSize(width: 180, height: 158)
  static let thumbnail = CGSize(width: 158, height: 105)
  static let pitch: CGFloat = 182
  static let padding = NSEdgeInsets(top: 16, left: 16.5, bottom: 16, right: 16.5)
  static let radius: CGFloat = 22

  /// How many cards fit a window this wide (at most `TabSwitcher.maxCards`).
  static func cards(fitting width: CGFloat) -> Int {
    Int((width - 48 - padding.left - padding.right + pitch - card.width) / pitch)
  }

  static func size(cards: Int) -> NSSize {
    let n = CGFloat(max(cards, 1))
    return NSSize(width: padding.left + padding.right + card.width + (n - 1) * pitch,
                  height: padding.top + padding.bottom + card.height)
  }

  var onHover: ((Int) -> Void)?
  var onClick: ((Int) -> Void)?
  private let backdrop = SurfaceBackdrop(radius: TabSwitcherView.radius)
  private var cardViews: [TabSwitcherCard] = []
  private var tracking: NSTrackingArea?

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    addSubview(backdrop)
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }

  var titles: [String] { cardViews.map(\.title) }
  var pictured: [Bool] { cardViews.map(\.hasPicture) }
  var backdropStyle: String { backdrop.style }

  func show(_ cards: [Card], selected: Int) {
    while cardViews.count < cards.count {
      let view = TabSwitcherCard()
      cardViews.append(view)
      addSubview(view)
    }
    while cardViews.count > cards.count { cardViews.removeLast().removeFromSuperview() }
    for (i, card) in cards.enumerated() {
      cardViews[i].frame = NSRect(x: Self.padding.left + CGFloat(i) * Self.pitch, y: Self.padding.top,
                                  width: Self.card.width, height: Self.card.height)
      cardViews[i].show(card)
    }
    select(selected)
    setFrameSize(Self.size(cards: cards.count))
    needsLayout = true
  }

  func select(_ index: Int) {
    for (i, card) in cardViews.enumerated() { card.selected = i == index }
  }

  override func layout() {
    super.layout()
    backdrop.frame = bounds
    SurfaceBackdrop.shadow(on: self, radius: Self.radius)
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let tracking { removeTrackingArea(tracking) }
    let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                              owner: self, userInfo: nil)
    addTrackingArea(area)
    tracking = area
  }

  private func card(at event: NSEvent) -> Int? {
    let point = convert(event.locationInWindow, from: nil)
    return cardViews.firstIndex { $0.frame.contains(point) }
  }

  override func mouseMoved(with event: NSEvent) { card(at: event).map { onHover?($0) } }
  override func mouseEntered(with event: NSEvent) { card(at: event).map { onHover?($0) } }
  override func mouseDown(with event: NSEvent) { card(at: event).map { onClick?($0) } }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// One card: the page's picture (or an empty one with the favicon), then the favicon and title under it.
private final class TabSwitcherCard: NSView {
  private let holder = CALayer()
  private let picture = CALayer()
  private let emptyIcon = CALayer()
  private let icon = NSImageView()
  private let placeholder = CALayer()
  private let label = NSTextField(labelWithString: "")
  private(set) var hasPicture = false
  var title: String { label.stringValue }
  var selected = false {
    didSet { if selected != oldValue { needsDisplay = true } }
  }

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.cornerRadius = 8
    layer?.cornerCurve = .continuous
    holder.frame = CGRect(origin: CGPoint(x: 11.5, y: 12), size: TabSwitcherView.thumbnail)
    holder.shadowRadius = 4
    holder.shadowOffset = .zero
    holder.shadowColor = NSColor.black.cgColor
    holder.shadowPath = CGPath(roundedRect: holder.bounds, cornerWidth: 6.5, cornerHeight: 6.5, transform: nil)
    picture.frame = holder.bounds
    picture.cornerRadius = 6.5
    picture.cornerCurve = .continuous
    picture.masksToBounds = true
    picture.borderWidth = 0.5
    picture.contentsGravity = .resizeAspectFill
    emptyIcon.bounds = CGRect(x: 0, y: 0, width: 24, height: 24)
    emptyIcon.position = CGPoint(x: holder.bounds.midX, y: holder.bounds.midY)
    emptyIcon.contentsGravity = .resizeAspect
    emptyIcon.opacity = 0.6
    picture.addSublayer(emptyIcon)
    holder.addSublayer(picture)
    layer?.addSublayer(holder)
    icon.frame = NSRect(x: 13.5, y: 130.5, width: 16, height: 16)
    icon.imageScaling = .scaleProportionallyUpOrDown
    icon.wantsLayer = true
    addSubview(icon)
    placeholder.frame = icon.frame
    placeholder.cornerRadius = 4.5
    placeholder.cornerCurve = .continuous
    layer?.addSublayer(placeholder)
    label.font = .systemFont(ofSize: 14, weight: .medium)
    label.textColor = .labelColor
    label.lineBreakMode = .byTruncatingTail
    label.maximumNumberOfLines = 1
    label.cell?.truncatesLastVisibleLine = true
    addSubview(label)
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }
  override var wantsUpdateLayer: Bool { true }

  func show(_ card: TabSwitcherView.Card) {
    label.stringValue = card.title
    icon.image = card.icon
    icon.isHidden = card.icon == nil
    placeholder.isHidden = card.icon != nil
    hasPicture = card.picture != nil
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    picture.contents = card.picture
    emptyIcon.contents = card.picture == nil ? card.icon : nil
    CATransaction.commit()
    let height = label.intrinsicContentSize.height
    label.frame = NSRect(x: icon.frame.maxX + 8, y: icon.frame.midY - height / 2,
                         width: bounds.width - icon.frame.maxX - 8 - 10.5, height: height)
    needsDisplay = true
  }

  override func updateLayer() {
    let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    // The chosen card: `SelectedRow`'s wash, as every list of Ray's marks its choice.
    layer?.backgroundColor = selected ? SelectedRow.fill(over: SurfaceBackdrop.solidFill).cgColor : nil
    // Arc's empty card (#1C1C1C) for a tab not seen since launch.
    picture.backgroundColor = dark ? NSColor(white: 28 / 255, alpha: 1).cgColor : NSColor(white: 0.9, alpha: 1).cgColor
    picture.borderColor = SurfaceBackdrop.edge.cgColor
    holder.shadowOpacity = dark ? 0.3 : 0.15
    placeholder.backgroundColor = dark ? NSColor(white: 1, alpha: 0.14).cgColor : NSColor(white: 0, alpha: 0.1).cgColor
    CATransaction.commit()
  }
}
