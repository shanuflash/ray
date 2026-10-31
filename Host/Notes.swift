import AppKit
import QuartzCore

// Ray's notes: short messages at one of six spots on the page ("Copied Current URL" and the zoom level at the top
// right, a download at the bottom left, …). One note per spot, never stacked: a new note in a taken spot reshapes
// the one there, and notes in different spots show together. Any feature shows one with
// `controller.notes.show(Note(…))`. Glass by default, solid in Settings › Appearance (`noteStyle`).
//
// Motion is the sidebar's spring (response 0.26 s, damping 0.86: no bounce) for entering, reshaping and making way;
// leaving is 160 ms. Reduce Motion keeps only the fades.

/// Where a note sits on the page: a corner, or the middle of the top or bottom edge.
enum NoteSpot: String, CaseIterable {
  case topLeading, top, topTrailing, bottomLeading, bottom, bottomTrailing

  var isTop: Bool { self == .topLeading || self == .top || self == .topTrailing }
  var isCenter: Bool { self == .top || self == .bottom }
  var isLeading: Bool { self == .topLeading || self == .bottomLeading }
}

enum NoteIcon: Equatable {
  /// An SF Symbol in the profile's colour.
  case symbol(String)
  case spinner
  /// 0…1, a ring that fills.
  case progress(Double)
  case done
  case warning
}

/// A button on a note. The last one of a note that asks is the primary (filled in the profile's colour).
struct NoteAction {
  let title: String?
  let symbol: String?
  /// Its name for VoiceOver, tests and the state log.
  let label: String
  /// Whether pressing it closes the note (Share leaves it, so the share menu has somewhere to hang).
  let closesNote: Bool
  let run: (NSView) -> Void

  init(_ title: String, run: @escaping () -> Void) {
    self.title = title
    symbol = nil
    label = title
    closesNote = true
    self.run = { _ in run() }
  }

  /// An icon button; `run` gets the button, for a menu shown from it.
  init(symbol: String, label: String, closesNote: Bool = true, run: @escaping (NSView) -> Void) {
    title = nil
    self.symbol = symbol
    self.label = label
    self.closesNote = closesNote
    self.run = run
  }
}

enum NoteLasting: Equatable {
  /// 2.4 s, longer for longer text (up to 6 s); 6 s with a button; 1.4 s for a figure.
  case auto
  case seconds(TimeInterval)
  /// Until it's replaced or dismissed.
  case held
}

struct Note {
  var text: String
  /// A second line under the text, in grey (a file's size so far, a site).
  var detail: String?
  var icon: NoteIcon?
  /// Bold digits in a compact note ("110%"); a change rolls only the digits that changed.
  var figure: Bool
  var actions: [NoteAction]
  var spot: NoteSpot
  var lasts: NoteLasting
  /// A shown note with the same key is updated in place, wherever it is.
  var key: String?
  /// A question: its buttons ignore clicks for its first 0.5 s, and ignoring it is "no".
  var asks: Bool

  init(_ text: String, detail: String? = nil, icon: NoteIcon? = nil, figure: Bool = false, actions: [NoteAction] = [],
       spot: NoteSpot = .topTrailing, lasts: NoteLasting = .auto, key: String? = nil, asks: Bool = false) {
    self.text = text
    self.detail = detail
    self.icon = icon
    self.figure = figure
    self.actions = actions
    self.spot = spot
    self.lasts = lasts
    self.key = key
    self.asks = asks
  }

  /// How long it stays, or nil for held.
  var lifetime: TimeInterval? {
    switch lasts {
    case .held: return nil
    case .seconds(let seconds): return seconds
    case .auto: break
    }
    if figure { return 1.4 }
    let reading = min(max(2.4, Double(text.count + (detail?.count ?? 0)) * 0.055), 6)
    return actions.isEmpty ? reading : max(reading, 6)
  }

  /// Arc's: what was copied, with a share button.
  static func copied(_ text: String, share: @escaping (NSView) -> Void) -> Note {
    Note(text, icon: .symbol("link"),
         actions: [NoteAction(symbol: "square.and.arrow.up", label: "Share", closesNote: false, run: share)],
         lasts: .seconds(3))
  }

  /// The zoom level after ⌘+ ⌘− ⌘0, at the top right.
  static func zoom(_ factor: Double) -> Note {
    Note("\(Int((factor * 100).rounded()))%", figure: true, key: "zoom")
  }
}

/// A note that was shown, to change or close it later (a no-op once it's gone or replaced).
struct NoteHandle {
  fileprivate weak var notes: Notes?
  fileprivate let serial: Int

  var isShown: Bool { notes?.view(serial: serial) != nil }

  func update(_ change: (inout Note) -> Void) {
    guard let notes, let view = notes.view(serial: serial) else { return }
    var note = view.note
    change(&note)
    notes.show(note, replacing: view)
  }

  func dismiss() { notes?.view(serial: serial)?.leave() }
}

// MARK: Notes

/// One window's notes, in `host` over the page.
final class Notes {
  static let inset: CGFloat = 10
  static let gap: CGFloat = 8
  /// The sidebar's spring.
  static let response: CGFloat = 0.26
  static let dampingRatio: CGFloat = 0.86

  private weak var host: NSView?
  private var views: [NoteSpot: NoteView] = [:]
  private var page: NSRect = .zero
  private var topTrailingClearance: CGFloat = 0
  private var serial = 0
  /// How far each centre note has moved in to keep clear of a corner note.
  private var shifts: [NoteSpot: Spring] = [:]
  private var observation: SettingsObservation?
  /// Animation steps, for the state log: entered, reshaped, rolled, made way, left.
  private(set) var steps: [String: Int] = ["entered": 0, "reshaped": 0, "rolled": 0, "madeWay": 0, "left": 0]
  /// Buttons pressed (and how many clicks were too early), for checks.
  private(set) var pressed = 0
  private(set) var tooEarly = 0
  var onChange: (() -> Void)?

  init(host: NSView) {
    self.host = host
    observation = RaySettings.shared.observe(.noteStyle) { [weak self] _ in
      self?.views.values.forEach { $0.applyStyle() }
      self?.onChange?()
    }
    NotificationCenter.default.addObserver(forName: ProfileColor.didChange, object: nil, queue: .main) { [weak self] _ in
      self?.views.values.forEach { $0.refreshColors() }
    }
  }

  static var style: String { RaySettings.shared[.noteStyle] }
  static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

  @discardableResult
  func show(_ note: Note) -> NoteHandle { show(note, replacing: nil) }

  @discardableResult
  fileprivate func show(_ note: Note, replacing: NoteView?) -> NoteHandle {
    guard let host else { return NoteHandle(notes: nil, serial: 0) }
    // A key lives in one spot: moving it closes it where it was.
    if let key = note.key {
      for (spot, view) in views where spot != note.spot && view.note.key == key && !view.leaving { view.leave() }
    }
    if let replacing, replacing.spot != note.spot { replacing.leave() }
    serial += 1
    if let view = views[note.spot], !view.leaving {
      view.replace(with: note, serial: serial)
    } else {
      views[note.spot]?.removeNow()
      let view = NoteView(note: note, serial: serial, notes: self)
      views[note.spot] = view
      host.addSubview(view, positioned: .above, relativeTo: nil)
      view.enter()
    }
    resolve()
    views[note.spot]?.isNew = false
    onChange?()
    return NoteHandle(notes: self, serial: serial)
  }

  func dismiss(spot: NoteSpot) { views[spot]?.leave() }
  func dismiss(key: String) { views.values.filter { $0.note.key == key }.forEach { $0.leave() } }

  /// The shown note with this key, changed in place; false when none is shown.
  @discardableResult
  func update(key: String, _ change: (inout Note) -> Void) -> Bool {
    guard let view = views.values.first(where: { $0.note.key == key && !$0.leaving }) else { return false }
    var note = view.note
    change(&note)
    show(note, replacing: view)
    return true
  }

  fileprivate func view(serial: Int) -> NoteView? { views.values.first { $0.serial == serial && !$0.leaving } }

  func view(at spot: NoteSpot) -> NSView? { views[spot].flatMap { $0.leaving ? nil : $0 } }

  /// The page's frame in `host`, and how far below the page's top the top-right note keeps (the find bar).
  func layout(in page: NSRect, topTrailingClearance: CGFloat) {
    let changed = page != self.page || topTrailingClearance != self.topTrailingClearance
    self.page = page
    self.topTrailingClearance = topTrailingClearance
    guard changed else { return }
    views.values.forEach { $0.contentLimitChanged() }
    resolve(animated: false)
    views.values.forEach(place)
  }

  var maxWidth: CGFloat { max(120, page.width - Self.inset * 2) }

  fileprivate func place(_ view: NoteView) {
    let size = view.currentSize
    let spot = view.spot
    let x: CGFloat
    if spot.isLeading { x = page.minX + Self.inset }
    else if spot.isCenter { x = page.midX - size.width / 2 }
    else { x = page.maxX - Self.inset - size.width }
    let shift = shifts[spot]?.value ?? 0
    let y: CGFloat
    if spot.isTop {
      let clearance = spot == .topTrailing ? topTrailingClearance : 0
      y = page.maxY - Self.inset - clearance - shift - size.height
    } else {
      y = page.minY + Self.inset + shift
    }
    // Whole points, as the sidebar's frames are: no blurry text mid-move.
    view.frame = NSRect(x: x.rounded(), y: y.rounded(), width: size.width.rounded(), height: size.height.rounded())
  }

  /// A centre note never covers a corner note: when they'd meet, it moves one row in (down at the top, up at the
  /// bottom), on the same spring.
  private func resolve(animated: Bool = true) {
    for (center, sides) in [(NoteSpot.top, [NoteSpot.topLeading, .topTrailing]), (.bottom, [.bottomLeading, .bottomTrailing])] {
      var target: CGFloat = 0
      if let mid = views[center], !mid.leaving {
        let width = mid.targetSize.width
        let left = page.midX - width / 2, right = page.midX + width / 2
        for side in sides {
          guard let corner = views[side], !corner.leaving else { continue }
          let size = corner.targetSize
          let clearance = side == .topTrailing ? topTrailingClearance : 0
          let meets = side.isLeading
            ? page.minX + Self.inset + size.width + Self.gap > left
            : page.maxX - Self.inset - size.width - Self.gap < right
          if meets { target = max(target, size.height + clearance + Self.gap) }
        }
      }
      let spring = shifts[center] ?? Spring(value: 0, response: Self.response, dampingRatio: Self.dampingRatio) {
        [weak self] _ in
        guard let self, let view = self.views[center] else { return }
        self.place(view)
      }
      shifts[center] = spring
      guard abs(spring.target - target) > 0.5 || (!animated && abs(spring.value - target) > 0.5) else { continue }
      if target != spring.target && target > 0 { steps["madeWay", default: 0] += 1 }
      if animated, !Self.reduceMotion, let host, let mid = views[center], !mid.isNew {
        spring.animate(to: target, in: host)
      } else {
        spring.jump(to: target)
      }
    }
  }

  fileprivate func gone(_ view: NoteView) {
    if views[view.spot] === view { views[view.spot] = nil }
    resolve()
    onChange?()
  }

  fileprivate func step(_ name: String) { steps[name, default: 0] += 1 }
  fileprivate func notePressed(early: Bool) { if early { tooEarly += 1 } else { pressed += 1 }; onChange?() }
  fileprivate func changed() { onChange?() }

  // MARK: Notes state

  /// For the state log: each spot's note, the style, the steps.
  var state: [String: Any] {
    var spots: [String: Any] = [:]
    for (spot, view) in views where !view.leaving {
      let note = view.note
      spots[spot.rawValue] = [
        "text": note.text, "detail": note.detail ?? NSNull(), "figure": note.figure, "key": note.key ?? NSNull(),
        "icon": note.icon.map { "\($0)" } ?? NSNull(), "actions": note.actions.map(\.label), "asks": note.asks,
        "held": note.lifetime == nil, "truncated": view.truncated, "style": view.style,
        "frame": "\(Int(view.frame.minX)),\(Int(view.frame.minY)),\(Int(view.frame.width)),\(Int(view.frame.height))",
        "target": "\(Int(view.targetSize.width)),\(Int(view.targetSize.height))",
      ]
    }
    return [
      "spots": spots, "style": Self.style, "steps": steps, "pressed": pressed, "tooEarly": tooEarly,
      "shift": ["top": shifts[.top]?.target ?? 0, "bottom": shifts[.bottom]?.target ?? 0],
    ]
  }

  /// Every shown note's text, for checks: "" with none.
  var text: String {
    NoteSpot.allCases.compactMap { spot in views[spot].flatMap { $0.leaving ? nil : $0.note.text } }.joined(separator: " | ")
  }

  // MARK: Notes test commands

  /// `note show|ask <spot> <text>`, `note press <spot> [n]`, `note dismiss <spot>`, `note hover <spot> on|off`,
  /// `note progress <spot> <0…1>`.
  func test(_ argument: String) -> String? {
    let words = argument.split(separator: " ", maxSplits: 2).map(String.init)
    guard words.count >= 2, let spot = NoteSpot(rawValue: words[1]) else { return "usage: note show|ask|press|dismiss|hover|progress <spot> …" }
    let rest = words.count > 2 ? words[2] : ""
    switch words[0] {
    case "show":
      show(Note(rest, icon: .symbol("info.circle"), spot: spot))
    case "ask":
      show(Note(rest, detail: "example.test", icon: .symbol("questionmark.circle"),
                actions: [NoteAction("Don't Allow") {}, NoteAction("Allow") {}], spot: spot, lasts: .held, asks: true))
    case "press":
      guard let view = views[spot], !view.leaving else { return "no note" }
      return view.press(Int(rest) ?? view.note.actions.count) ? nil : "no such button"
    case "dismiss":
      dismiss(spot: spot)
    case "hover":
      views[spot]?.hover(rest == "on")
    case "progress":
      guard let value = Double(rest) else { return "usage: note progress <spot> <0…1>" }
      show(Note("Downloading", detail: "\(Int(value * 100))%", icon: .progress(value), spot: spot, lasts: .held, key: "test.progress"))
    default:
      return "usage: note show|ask|press|dismiss|hover|progress <spot> …"
    }
    return nil
  }
}

// MARK: Note view

/// One note: the shadow, the glass or solid body with its hairline edge, and the content, which a new note in the
/// same spot crossfades while the box reshapes on the spring.
final class NoteView: NSView {
  let spot: NoteSpot
  private(set) var note: Note
  private(set) var serial: Int
  private weak var notes: Notes?
  private let body = NSView()
  private var effect: NSVisualEffectView?
  /// Over the frost (glass) or the whole fill (solid).
  private let wash = NSView()
  private var content: NoteContentView
  private var sizeSpring: Spring!
  private var fromSize = NSSize.zero
  private(set) var targetSize = NSSize.zero
  private(set) var currentSize = NSSize.zero
  private(set) var leaving = false
  /// Just made: a centre note takes its row at once instead of moving into it.
  fileprivate var isNew = true
  private var hideWork: DispatchWorkItem?
  private var hideAt: Date?
  private var hovering = false
  private var shownAt = Date()
  private(set) var style = "glass"
  static let radius: CGFloat = 12

  fileprivate init(note: Note, serial: Int, notes: Notes) {
    spot = note.spot
    self.note = note
    self.serial = serial
    self.notes = notes
    content = NoteContentView(note: note)
    super.init(frame: .zero)
    wantsLayer = true
    layer?.shadowColor = NSColor.black.cgColor
    layer?.shadowRadius = 14
    layer?.shadowOffset = CGSize(width: 0, height: -6)
    body.wantsLayer = true
    body.layer?.cornerRadius = Self.radius
    body.layer?.cornerCurve = .continuous
    body.layer?.masksToBounds = true
    body.layer?.borderWidth = 0.5
    addSubview(body)
    wash.wantsLayer = true
    wash.autoresizingMask = [.width, .height]
    body.addSubview(wash)
    sizeSpring = Spring(value: 1, response: Notes.response, dampingRatio: Notes.dampingRatio) { [weak self] t in
      guard let self else { return }
      self.currentSize = NSSize(width: self.fromSize.width + (self.targetSize.width - self.fromSize.width) * t,
                                height: self.fromSize.height + (self.targetSize.height - self.fromSize.height) * t)
      self.notes?.place(self)
    }
    applyStyle()
    content.onPress = { [weak self] index, button in self?.pressed(index, from: button) }
    body.addSubview(content)
    targetSize = content.size(limit: notes.maxWidth)
    fromSize = targetSize
    currentSize = targetSize
    notes.place(self)
    setAccessibilityElement(true)
    setAccessibilityRole(.group)
    setAccessibilityLabel(note.text)
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }
  override var mouseDownCanMoveWindow: Bool { false }

  // MARK: Note look

  func applyStyle() {
    style = Notes.style == "solid" ? "solid" : "glass"
    if style == "glass" {
      if effect == nil {
        // Within the window: it frosts the page under it (Chrome's layer included), never the desktop.
        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .withinWindow
        effect.state = .active
        effect.autoresizingMask = [.width, .height]
        effect.frame = body.bounds
        body.addSubview(effect, positioned: .below, relativeTo: wash)
        self.effect = effect
      }
    } else {
      effect?.removeFromSuperview()
      effect = nil
    }
    refreshColors()
  }

  /// Glass: a light wash over the frost (the mock's 68 % white, 66 % graphite); solid: the card.
  static let solidFill = NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
      ? NSColor(srgbRed: 0x2C / 255.0, green: 0x2C / 255.0, blue: 0x31 / 255.0, alpha: 1) : .white
  }
  private static let glassWash = NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
      ? NSColor(srgbRed: 0.16, green: 0.16, blue: 0.18, alpha: 0.35) : NSColor(white: 1, alpha: 0.4)
  }
  private static let edge = NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.1) : NSColor(white: 0, alpha: 0.08)
  }

  func refreshColors() {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
      wash.layer?.backgroundColor = (style == "glass" ? Self.glassWash : Self.solidFill).cgColor
      body.layer?.borderColor = Self.edge.cgColor
      layer?.shadowOpacity = dark ? 0.45 : 0.16
    }
    content.refreshColors()
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    refreshColors()
  }

  override func layout() {
    super.layout()
    body.frame = bounds
    effect?.frame = body.bounds
    wash.frame = body.bounds
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: Self.radius, cornerHeight: Self.radius, transform: nil)
    CATransaction.commit()
    for case let content as NoteContentView in body.subviews {
      content.frame = anchored(content.laidSize, in: bounds.size)
    }
  }

  /// Content keeps to the note's anchor (its corner or centre) while the box reshapes under it.
  private func anchored(_ size: NSSize, in box: NSSize) -> NSRect {
    let x: CGFloat
    if spot.isLeading { x = 0 } else if spot.isCenter { x = (box.width - size.width) / 2 } else { x = box.width - size.width }
    return NSRect(x: x.rounded(), y: ((box.height - size.height) / 2).rounded(), width: size.width, height: size.height)
  }

  var truncated: Bool { content.truncated }

  // MARK: Note motion

  private var reduce: Bool { Notes.reduceMotion }

  /// 8 pt in from its edge on the sidebar's spring, fading in over 160 ms.
  fileprivate func enter() {
    guard let layer else { return }
    notes?.step("entered")
    announce()
    if !reduce {
      let slide = springAnimation("transform.translation.y", from: spot.isTop ? 8 : -8, to: 0)
      layer.add(slide, forKey: "enter")
    }
    let fade = CABasicAnimation(keyPath: "opacity")
    fade.fromValue = 0
    fade.toValue = 1
    fade.duration = 0.16
    fade.timingFunction = CAMediaTimingFunction(controlPoints: 0, 0, 0.2, 1)
    layer.opacity = 1
    layer.add(fade, forKey: "fade")
    arm()
  }

  private func springAnimation(_ keyPath: String, from: CGFloat, to: CGFloat) -> CASpringAnimation {
    let spring = CASpringAnimation(keyPath: keyPath)
    spring.fromValue = from
    spring.toValue = to
    spring.mass = 1
    spring.stiffness = pow(2 * .pi / Notes.response, 2)
    spring.damping = 4 * .pi * Notes.dampingRatio / Notes.response
    spring.duration = spring.settlingDuration
    return spring
  }

  /// A new note in this spot: the same shape updates its words in place (a download's size so far), a figure rolls
  /// its changed digits, anything else crossfades while the box reshapes.
  fileprivate func replace(with new: Note, serial: Int) {
    let old = note
    note = new
    self.serial = serial
    setAccessibilityLabel(new.text)
    if content.canUpdate(to: new) {
      content.update(to: new)
      if old.figure { notes?.step("rolled") }
    } else {
      notes?.step("reshaped")
      let outgoing = content
      content = NoteContentView(note: new)
      content.onPress = { [weak self] index, button in self?.pressed(index, from: button) }
      body.addSubview(content)
      content.frame = anchored(content.size(limit: notes?.maxWidth ?? 400), in: currentSize)
      outgoing.onPress = nil
      fade(outgoing, to: 0, duration: 0.12, delay: 0) { outgoing.removeFromSuperview() }
      content.layer?.opacity = 0
      fade(content, to: 1, duration: 0.18, delay: reduce ? 0 : 0.07)
      announce()
    }
    shownAt = Date()
    resize(to: content.size(limit: notes?.maxWidth ?? 400))
    arm()
  }

  private func fade(_ view: NSView, to opacity: Float, duration: CFTimeInterval, delay: CFTimeInterval,
                    done: (() -> Void)? = nil) {
    guard let layer = view.layer else { return }
    let animation = CABasicAnimation(keyPath: "opacity")
    animation.fromValue = layer.presentation()?.opacity ?? layer.opacity
    animation.toValue = opacity
    animation.duration = duration
    animation.beginTime = CACurrentMediaTime() + delay
    animation.fillMode = .backwards
    animation.timingFunction = CAMediaTimingFunction(controlPoints: opacity == 0 ? 0.4 : 0, 0, opacity == 0 ? 1 : 0.2, 1)
    CATransaction.begin()
    CATransaction.setCompletionBlock(done)
    layer.opacity = opacity
    layer.add(animation, forKey: "fade")
    CATransaction.commit()
  }

  private func resize(to size: NSSize) {
    guard size != targetSize else { return }
    fromSize = currentSize
    targetSize = size
    if reduce || window == nil {
      sizeSpring.jump(to: 1)
    } else {
      sizeSpring.jump(to: 0)
      sizeSpring.animate(to: 1, in: self)
    }
  }

  /// The page got narrower or wider: the content may need to truncate, or may have room again.
  fileprivate func contentLimitChanged() {
    let size = content.size(limit: notes?.maxWidth ?? 400)
    guard size != targetSize else { return }
    targetSize = size
    fromSize = size
    sizeSpring.jump(to: 1)
  }

  /// 160 ms back toward its edge, fading; then gone.
  func leave() {
    guard !leaving, let layer else { return }
    leaving = true
    hideWork?.cancel()
    notes?.step("left")
    let group = CAAnimationGroup()
    let fade = CABasicAnimation(keyPath: "opacity")
    fade.fromValue = layer.presentation()?.opacity ?? 1
    fade.toValue = 0
    var animations: [CAAnimation] = [fade]
    if !reduce {
      let lift = CABasicAnimation(keyPath: "transform.translation.y")
      lift.fromValue = 0
      lift.toValue = spot.isTop ? 6 : -6
      animations.append(lift)
    }
    group.animations = animations
    group.duration = 0.16
    group.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 1, 1)
    group.fillMode = .forwards
    group.isRemovedOnCompletion = false
    CATransaction.begin()
    CATransaction.setCompletionBlock { [weak self] in self?.removeNow() }
    layer.opacity = 0
    layer.removeAnimation(forKey: "enter")
    layer.add(group, forKey: "leave")
    CATransaction.commit()
    notes?.gone(self)
  }

  /// Off the page at once (a new note took the spot while this one was leaving).
  fileprivate func removeNow() {
    hideWork?.cancel()
    leaving = true
    removeFromSuperview()
    notes?.gone(self)
  }

  // MARK: Note timing

  private func arm(after delay: TimeInterval? = nil) {
    hideWork?.cancel()
    hideWork = nil
    guard let lifetime = note.lifetime, !hovering else { return }
    let wait = delay ?? lifetime
    let work = DispatchWorkItem { [weak self] in self?.leave() }
    hideWork = work
    hideAt = Date().addingTimeInterval(wait)
    DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: work)
  }

  /// Hovering holds the note; leaving it gives back what was left, and at least 1.2 s.
  fileprivate func hover(_ on: Bool) {
    guard on != hovering else { return }
    hovering = on
    if on {
      hideWork?.cancel()
    } else {
      arm(after: max(1.2, hideAt.map { $0.timeIntervalSinceNow } ?? 1.2))
    }
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    trackingAreas.forEach(removeTrackingArea)
    addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                   owner: self, userInfo: nil))
  }

  override func mouseEntered(with event: NSEvent) { hover(true) }
  override func mouseExited(with event: NSEvent) { hover(false) }

  // MARK: Note buttons

  /// A note that asks ignores clicks for its first 0.5 s, so a click meant for the page never answers it.
  private func pressed(_ index: Int, from button: NSView) {
    guard !leaving, note.actions.indices.contains(index) else { return }
    let early = note.asks && Date().timeIntervalSince(shownAt) < 0.5
    notes?.notePressed(early: early)
    guard !early else { return }
    let action = note.actions[index]
    if action.closesNote { leave() }
    action.run(button)
  }

  /// For tests: press the nth button (1-based), through the same path as a click.
  fileprivate func press(_ number: Int) -> Bool {
    guard let button = content.button(number - 1) else { return false }
    pressed(number - 1, from: button)
    return true
  }

  private func announce() {
    let text = [note.text, note.detail].compactMap { $0 }.joined(separator: ", ")
    NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                         userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
  }
}

// MARK: Note content

/// What a note says, laid out for one of three shapes: a figure ("110%"), one line (icon, text, buttons), or two
/// lines (a tile, text over detail, buttons).
final class NoteContentView: NSView {
  private(set) var note: Note
  private var icon: NoteIconView?
  private let title = NSTextField(labelWithString: "")
  private let detail = NSTextField(labelWithString: "")
  private var buttons: [NoteButton] = []
  private var figure: NoteFigureView?
  private let tile = CALayer()
  var onPress: ((Int, NSView) -> Void)?
  private(set) var laidSize = NSSize.zero
  private var limit: CGFloat = 400

  private static let lineHeight: CGFloat = 40
  private static let figureHeight: CGFloat = 34
  private static let titleFont = NSFont.systemFont(ofSize: 13, weight: .medium)
  private static let boldFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
  private static let detailFont = NSFont.systemFont(ofSize: 12)

  init(note: Note) {
    self.note = note
    super.init(frame: .zero)
    wantsLayer = true
    if note.figure {
      let figure = NoteFigureView(text: note.text)
      addSubview(figure)
      self.figure = figure
      return
    }
    if let kind = note.icon {
      let icon = NoteIconView(kind)
      addSubview(icon)
      self.icon = icon
    }
    for label in [title, detail] {
      label.lineBreakMode = .byTruncatingTail
      label.maximumNumberOfLines = 1
      label.cell?.truncatesLastVisibleLine = true
      addSubview(label)
    }
    title.font = note.detail == nil ? Self.titleFont : Self.boldFont
    title.stringValue = note.text
    detail.font = Self.detailFont
    detail.textColor = .secondaryLabelColor
    detail.stringValue = note.detail ?? ""
    detail.isHidden = note.detail == nil
    if note.detail != nil, icon != nil {
      tile.cornerRadius = 8
      tile.cornerCurve = .continuous
      layer?.insertSublayer(tile, at: 0)
    }
    for (index, action) in note.actions.enumerated() {
      let primary = note.asks && index == note.actions.count - 1 && action.title != nil
      let button = NoteButton(action, primary: primary)
      button.onClick = { [weak self, weak button] in
        guard let self, let button else { return }
        self.onPress?(index, button)
      }
      addSubview(button)
      buttons.append(button)
    }
    refreshColors()
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }

  private var twoLines: Bool { note.detail != nil }

  func button(_ index: Int) -> NSView? { buttons.indices.contains(index) ? buttons[index] : nil }

  /// The same shape with new words or progress: changed in place, no crossfade.
  func canUpdate(to new: Note) -> Bool {
    if note.figure || new.figure { return note.figure && new.figure }
    let sameIcon: Bool
    switch (note.icon, new.icon) {
    case (.progress, .progress), (nil, nil): sameIcon = true
    case let (a?, b?): sameIcon = a == b
    default: sameIcon = false
    }
    return sameIcon && (note.detail == nil) == (new.detail == nil) && note.text == new.text && note.asks == new.asks
      && note.actions.map(\.label) == new.actions.map(\.label)
  }

  /// Buttons keep their place: a press goes by index to the note shown now.
  func update(to new: Note) {
    note = new
    if let figure { figure.set(new.text) }
    if case .progress(let value)? = new.icon { icon?.progress = value }
    detail.stringValue = new.detail ?? ""
    needsLayout = true
  }

  /// Its natural size, at most `limit` wide (the text truncates past that).
  func size(limit: CGFloat) -> NSSize {
    self.limit = limit
    let size: NSSize
    if let figure {
      size = NSSize(width: min(limit, figure.naturalWidth + 26), height: Self.figureHeight)
    } else {
      let natural = naturalWidth
      size = NSSize(width: min(limit, natural), height: twoLines ? 52 : Self.lineHeight)
    }
    laidSize = NSSize(width: ceil(size.width), height: size.height)
    frame.size = laidSize
    needsLayout = true
    return laidSize
  }

  private func textWidth(_ label: NSTextField) -> CGFloat {
    ceil((label.stringValue as NSString).size(withAttributes: [.font: label.font!]).width) + 4
  }

  private var buttonsWidth: CGFloat {
    buttons.isEmpty ? 0 : buttons.map(\.width).reduce(0, +) + CGFloat(buttons.count - 1) * 6
  }

  private var naturalWidth: CGFloat {
    let words = twoLines ? max(textWidth(title), textWidth(detail)) : textWidth(title)
    if twoLines {
      let lead: CGFloat = icon == nil ? 13 : 11 + 30 + 11
      return lead + words + (buttons.isEmpty ? 14 : 10 + buttonsWidth + 10)
    }
    let lead: CGFloat = icon == nil ? 15 : 12 + 18 + 9
    return lead + words + (buttons.isEmpty ? 15 : 3 + 9 + buttonsWidth + 6)
  }

  var truncated: Bool {
    guard figure == nil else { return false }
    layoutSubtreeIfNeeded()
    return title.frame.width < textWidth(title) - 4 || (!detail.isHidden && detail.frame.width < textWidth(detail) - 4)
  }

  override func layout() {
    super.layout()
    let size = laidSize
    if let figure {
      figure.frame = NSRect(x: 13, y: ((size.height - figure.lineHeight) / 2).rounded(), width: size.width - 26,
                            height: figure.lineHeight)
      return
    }
    // Buttons from the right edge in.
    var right = size.width - (twoLines ? 10 : 6)
    for button in buttons.reversed() {
      right -= button.width
      button.frame = NSRect(x: right, y: ((size.height - 28) / 2).rounded(), width: button.width, height: 28)
      right -= 6
    }
    let wordsRight = buttons.isEmpty ? size.width - (twoLines ? 14 : 15) : (buttons.first?.frame.minX ?? size.width) - (twoLines ? 10 : 12)
    var x: CGFloat
    if twoLines {
      x = icon == nil ? 13 : 11
      if let icon {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tile.frame = CGRect(x: x, y: ((size.height - 30) / 2).rounded(), width: 30, height: 30)
        CATransaction.commit()
        icon.frame = NSRect(x: x + 6, y: ((size.height - 18) / 2).rounded(), width: 18, height: 18)
        x += 30 + 11
      }
      let titleHeight = ceil(title.intrinsicContentSize.height), detailHeight = ceil(detail.intrinsicContentSize.height)
      let top = ((size.height - titleHeight - detailHeight) / 2).rounded()
      title.frame = NSRect(x: x - 2, y: top, width: max(0, wordsRight - x + 2), height: titleHeight)
      detail.frame = NSRect(x: x - 2, y: top + titleHeight, width: max(0, wordsRight - x + 2), height: detailHeight)
    } else {
      x = icon == nil ? 15 : 12
      if let icon {
        icon.frame = NSRect(x: x, y: ((size.height - 18) / 2).rounded(), width: 18, height: 18)
        x += 18 + 9
      }
      // One line tall and centred: a label draws from the top of its frame.
      let height = ceil(title.intrinsicContentSize.height)
      title.frame = NSRect(x: x - 2, y: ((size.height - height) / 2).rounded(), width: max(0, wordsRight - x + 2), height: height)
    }
  }

  func refreshColors() {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      tile.backgroundColor = ProfileColor.mix(ProfileColor.accent, over: NoteView.solidFill, 0.12, dark: 0.22).cgColor
    }
    title.textColor = .labelColor
    icon?.refreshColors()
    figure?.refreshColors()
    buttons.forEach { $0.needsDisplay = true }
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    refreshColors()
  }
}

// MARK: Note icon

/// An 18 pt icon: a symbol, the done tick or warning, a spinner, or a progress ring, in the profile's colour.
final class NoteIconView: NSView {
  private let kind: NoteIcon
  private let image = NSImageView()
  private let track = CAShapeLayer()
  private let arc = CAShapeLayer()

  var progress: Double = 0 {
    didSet { arc.strokeEnd = CGFloat(min(1, max(0, progress))) }
  }

  init(_ kind: NoteIcon) {
    self.kind = kind
    super.init(frame: NSRect(x: 0, y: 0, width: 18, height: 18))
    wantsLayer = true
    switch kind {
    case .symbol(let name):
      symbol(name, weight: .medium)
    case .done:
      symbol("checkmark.circle.fill", weight: .regular)
    case .warning:
      symbol("exclamationmark.triangle.fill", weight: .regular)
    case .spinner, .progress:
      // From twelve o'clock, clockwise (the view's layer is y-up).
      let path = CGMutablePath()
      path.addArc(center: CGPoint(x: 9, y: 9), radius: 7, startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi, clockwise: true)
      for shape in [track, arc] {
        shape.path = path
        shape.fillColor = nil
        shape.lineWidth = 2
        shape.lineCap = .round
        shape.frame = bounds
        layer?.addSublayer(shape)
      }
      if case .progress(let value) = kind {
        arc.strokeEnd = CGFloat(value)
      } else {
        arc.strokeEnd = 0.26
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = -2 * Double.pi
        spin.duration = 0.8
        spin.repeatCount = .infinity
        arc.add(spin, forKey: "spin")
      }
    }
    refreshColors()
  }

  required init?(coder: NSCoder) { fatalError() }

  private func symbol(_ name: String, weight: NSFont.Weight) {
    image.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
    image.symbolConfiguration = .init(pointSize: 14, weight: weight)
    image.frame = bounds
    image.imageScaling = .scaleProportionallyDown
    addSubview(image)
  }

  /// The profile's colour, moved just far enough to read on the note (a warning stays grey).
  static var accent: NSColor { ProfileColor.visible(on: NoteView.solidFill, minimum: 3) }

  func refreshColors() {
    image.contentTintColor = kind == .warning ? .secondaryLabelColor : Self.accent
    effectiveAppearance.performAsCurrentDrawingAppearance {
      track.strokeColor = Self.accent.withAlphaComponent(0.2).cgColor
      arc.strokeColor = Self.accent.cgColor
    }
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    refreshColors()
  }
}

// MARK: Note figure

/// Bold monospaced digits; a new value rolls only the characters that changed, up for a bigger number, down for a
/// smaller one, on the sidebar's spring.
final class NoteFigureView: NSView {
  private static let font = NSFont.monospacedDigitSystemFont(ofSize: 14.5, weight: .semibold)
  private var text: String
  private var cells: [CALayer] = []
  let lineHeight: CGFloat = ceil(NoteFigureView.font.ascender - NoteFigureView.font.descender + NoteFigureView.font.leading)

  init(text: String) {
    self.text = text
    super.init(frame: .zero)
    wantsLayer = true
    rebuild(rolling: nil)
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { false }

  var naturalWidth: CGFloat { ceil(text.map(Self.width).reduce(0, +)) }

  private static func width(_ character: Character) -> CGFloat {
    (String(character) as NSString).size(withAttributes: [.font: font]).width
  }

  private static func number(_ text: String) -> Double { Double(text.filter { $0.isNumber || $0 == "." }) ?? 0 }

  func set(_ new: String) {
    guard new != text else { return }
    let old = text
    text = new
    rebuild(rolling: (old, Self.number(new) >= Self.number(old)))
  }

  private var ink: CGColor {
    var color = NSColor.labelColor.cgColor
    effectiveAppearance.performAsCurrentDrawingAppearance { color = NSColor.labelColor.cgColor }
    return color
  }

  private func textLayer(_ character: String) -> CATextLayer {
    let layer = CATextLayer()
    layer.string = character
    layer.font = Self.font
    layer.fontSize = Self.font.pointSize
    layer.foregroundColor = ink
    layer.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    layer.alignmentMode = .center
    return layer
  }

  /// Lays the characters out right-aligned (units stay put; "90%" to "100%" adds a digit on the left) and rolls
  /// those that differ from the old string at the same place from the right.
  private func rebuild(rolling: (old: String, up: Bool)?) {
    cells.forEach { $0.removeFromSuperlayer() }
    cells = []
    let characters = Array(text)
    let old = rolling.map { Array($0.old) } ?? []
    let reduce = Notes.reduceMotion
    var x = max(0, bounds.width - naturalWidth)
    for (index, character) in characters.enumerated() {
      let width = Self.width(character)
      let cell = CALayer()
      cell.masksToBounds = true
      cell.frame = CGRect(x: x, y: 0, width: width, height: lineHeight)
      layer?.addSublayer(cell)
      cells.append(cell)
      x += width
      let fromEnd = characters.count - index
      let previous = old.count >= fromEnd ? old[old.count - fromEnd] : nil
      let incoming = textLayer(String(character))
      incoming.frame = cell.bounds
      cell.addSublayer(incoming)
      guard let rolling, previous != character, !reduce else { continue }
      // Up: the old character leaves through the top and the new one comes from below; down, the other way.
      let travel = rolling.up ? lineHeight : -lineHeight
      let delay = Double(fromEnd - 1) * 0.018
      roll(incoming, from: -travel, to: 0, delay: delay)
      if let previous {
        let outgoing = textLayer(String(previous))
        outgoing.frame = cell.bounds.offsetBy(dx: 0, dy: travel)
        cell.addSublayer(outgoing)
        roll(outgoing, from: 0, to: travel, delay: delay)
      } else {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.16
        incoming.add(fade, forKey: "fade")
      }
    }
  }

  private func roll(_ layer: CALayer, from: CGFloat, to: CGFloat, delay: Double) {
    let spring = CASpringAnimation(keyPath: "transform.translation.y")
    spring.fromValue = from
    spring.toValue = to
    spring.stiffness = pow(2 * .pi / Notes.response, 2)
    spring.damping = 4 * .pi * Notes.dampingRatio / Notes.response
    spring.duration = spring.settlingDuration
    spring.beginTime = CACurrentMediaTime() + delay
    spring.fillMode = .backwards
    layer.add(spring, forKey: "roll")
  }

  override func layout() {
    super.layout()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    var x = max(0, bounds.width - naturalWidth)
    for (cell, character) in zip(cells, text) {
      let width = Self.width(character)
      cell.frame = CGRect(x: x, y: 0, width: width, height: lineHeight)
      x += width
    }
    CATransaction.commit()
  }

  func refreshColors() {
    let ink = self.ink
    for cell in cells { for case let text as CATextLayer in cell.sublayers ?? [] { text.foregroundColor = ink } }
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    refreshColors()
  }

  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    let scale = window?.backingScaleFactor ?? 2
    cells.forEach { $0.sublayers?.forEach { $0.contentsScale = scale } }
  }
}

// MARK: Note button

/// A 28 pt button on a note: a grey wash, or the profile's colour for a question's primary answer; a title or an
/// icon.
final class NoteButton: NSView {
  let action: NoteAction
  private let primary: Bool
  private let label = NSTextField(labelWithString: "")
  private let image = NSImageView()
  private var hovered = false
  private var down = false
  var onClick: (() -> Void)?
  private static let font = NSFont.systemFont(ofSize: 12.5, weight: .medium)
  private static let boldFont = NSFont.systemFont(ofSize: 12.5, weight: .semibold)

  init(_ action: NoteAction, primary: Bool) {
    self.action = action
    self.primary = primary
    super.init(frame: .zero)
    wantsLayer = true
    layer?.cornerRadius = 8
    layer?.cornerCurve = .continuous
    if let title = action.title {
      label.stringValue = title
      label.font = primary ? Self.boldFont : Self.font
      label.alignment = .center
      addSubview(label)
    } else if let symbol = action.symbol {
      image.image = NSImage(systemSymbolName: symbol, accessibilityDescription: action.label)
      image.symbolConfiguration = .init(pointSize: 13, weight: .medium)
      image.contentTintColor = .labelColor
      addSubview(image)
    }
    setAccessibilityElement(true)
    setAccessibilityRole(.button)
    setAccessibilityLabel(action.label)
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }
  override var wantsUpdateLayer: Bool { true }
  override var mouseDownCanMoveWindow: Bool { false }

  var width: CGFloat {
    guard let title = action.title else { return 28 }
    return ceil((title as NSString).size(withAttributes: [.font: label.font!]).width) + 4 + 22
  }

  override func updateLayer() {
    let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    if primary {
      layer?.backgroundColor = ProfileColor.accent.cgColor
      layer?.opacity = down ? 0.85 : 1
      label.textColor = ProfileColor.foreground(on: ProfileColor.accent)
    } else {
      let alpha: CGFloat = (down ? 0.14 : hovered ? 0.09 : 0.055) * (dark ? 1.7 : 1)
      layer?.backgroundColor = (dark ? NSColor(white: 1, alpha: alpha) : NSColor(white: 0, alpha: alpha)).cgColor
      label.textColor = .labelColor
    }
  }

  override func layout() {
    super.layout()
    let height = ceil(label.intrinsicContentSize.height)
    label.frame = NSRect(x: 0, y: ((bounds.height - height) / 2).rounded(), width: bounds.width, height: height)
    image.frame = bounds.insetBy(dx: 6, dy: 6)
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    trackingAreas.forEach(removeTrackingArea)
    addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                   owner: self, userInfo: nil))
  }

  override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
  override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
  override func mouseDown(with event: NSEvent) { down = true; needsDisplay = true }

  override func mouseUp(with event: NSEvent) {
    down = false
    needsDisplay = true
    if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
  }

  override func accessibilityPerformPress() -> Bool {
    onClick?()
    return true
  }
}
