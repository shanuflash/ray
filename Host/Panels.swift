import AppKit
import QuartzCore

// Ray's panels: anything that opens from a button over the page (site controls today; prompts and pickers next).
// The notes' look (`SurfaceBackdrop`: glass or solid) and spring (the sidebar's: response 0.26 s, damping 0.86). One
// panel per window: opening another closes the open one. It grows out of its button (8 pt and 97 % scale, held at
// the button's corner), reshapes on the spring when its content changes (old content fades out, new fades in), and
// closes in 140 ms toward the button. A click outside, Escape, a tab switch, the window going to the background or
// (per panel) another site closes it; a panel that asks never closes on an outside click. Reduce Motion: fades only.

enum PanelClose: Hashable {
  case outsideClick, escape, tabSwitch, windowInactive
  /// A navigation of the active tab to a different origin than `PanelSpec.origin`.
  case otherSite
}

enum PanelAlign: String { case leading, center, trailing }

/// What a panel hangs from.
struct PanelAnchor {
  /// The button's frame in the host's coordinates, asked again on every layout (the toolbar moves, the sidebar
  /// slides).
  var rect: () -> NSRect
  /// Below the button (it opens downward) or above it.
  var below = true
  /// Its trailing edge on the button's, its leading edge on the button's, or centred on it (questions drop from the
  /// page's top centre, as a sheet would).
  var align = PanelAlign.trailing
  /// The button: a click on it isn't an outside click (it toggles the panel), and it's held while the panel is open.
  weak var button: NSView?
  var hold: ((Bool) -> Void)?
}

/// Any feature's panel. The content view sizes itself (its frame's size); `PanelHandle.contentChanged()` after it
/// grows or shrinks.
struct PanelSpec {
  var name: String
  var content: NSView
  var anchor: PanelAnchor
  var closesOn: Set<PanelClose> = [.outsideClick, .escape, .tabSwitch, .windowInactive]
  /// The site it's about, for `.otherSite`.
  var origin: String?
  /// A question: an outside click never closes it (Escape does, and closing is "no").
  var asks = false
  /// Over the sidebar (its button is in it): above a peeking sidebar too, and the peek stays out while it's open.
  var overSidebar = false
  /// What Return does (a question's default answer); nil leaves Return to the focused control.
  var onReturn: (() -> Void)?
  var onClose: (() -> Void)?
}

/// The open panel, to change or close later (a no-op once it's closed).
struct PanelHandle {
  fileprivate weak var panels: Panels?
  fileprivate let serial: Int

  var isOpen: Bool { panels?.view(serial: serial) != nil }
  /// New content in the same panel: it reshapes on the spring while the old content fades out.
  func show(_ content: NSView) { panels?.view(serial: serial)?.show(content) }
  /// The content's own size changed: reshape to it.
  func contentChanged() { panels?.view(serial: serial)?.contentChanged() }
  func close() { if panels?.view(serial: serial) != nil { panels?.close() } }
}

// MARK: Panels

final class Panels {
  static let radius: CGFloat = 14
  static let gap: CGFloat = 6

  private weak var host: NSView?
  /// The view panels go below (the floating sidebar): a peeking sidebar still covers them.
  private let below: () -> NSView?
  private var open: PanelView?
  private var spec: PanelSpec?
  private var serial = 0
  private var monitor: Any?
  private var resignObserver: NSObjectProtocol?
  /// Animation steps, for the state log: opened, reshaped, closed.
  private(set) var steps: [String: Int] = ["opened": 0, "reshaped": 0, "closed": 0]
  private(set) var lastClosedBy: String?
  var onChange: (() -> Void)?
  /// A panel opened here (its frame in the host): notes under it get out of the way.
  var onOpen: ((NSRect) -> Void)?

  init(host: NSView, below: @escaping () -> NSView?) {
    self.host = host
    self.below = below
  }

  static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

  var isOpen: Bool { open != nil }
  var name: String? { spec?.name }
  /// A panel from the sidebar is open: a peeking sidebar stays out.
  var holdsSidebar: Bool { spec?.overSidebar == true }

  @discardableResult
  func open(_ spec: PanelSpec) -> PanelHandle {
    guard let host else { return PanelHandle(panels: nil, serial: 0) }
    close(by: "another", fast: true)
    serial += 1
    let view = PanelView(spec: spec, serial: serial, panels: self)
    if !spec.overSidebar, let below = below(), below.superview === host {
      host.addSubview(view, positioned: .below, relativeTo: below)
    } else {
      host.addSubview(view, positioned: .above, relativeTo: nil)
    }
    open = view
    self.spec = spec
    spec.anchor.hold?(true)
    place(view)
    view.enter()
    onOpen?(view.frame)
    steps["opened", default: 0] += 1
    watch(view)
    onChange?()
    return PanelHandle(panels: self, serial: serial)
  }

  func close() { close(by: "code") }

  fileprivate func close(by reason: String, fast: Bool = false) {
    guard let view = open, let spec else { return }
    open = nil
    self.spec = nil
    if let monitor { NSEvent.removeMonitor(monitor) }
    monitor = nil
    if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
    resignObserver = nil
    spec.anchor.hold?(false)
    steps["closed", default: 0] += 1
    lastClosedBy = reason
    view.leave(fast: fast)
    spec.onClose?()
    onChange?()
  }

  fileprivate func view(serial: Int) -> PanelView? { open?.serial == serial ? open : nil }

  /// The window's layout moved: the panel follows its button.
  func layout() {
    if let open { place(open) }
  }

  func tabSwitched() { if spec?.closesOn.contains(.tabSwitch) == true { close(by: "tabSwitch") } }

  /// The active tab committed a page from `origin`.
  func navigated(to origin: String?) {
    guard let spec, spec.closesOn.contains(.otherSite), spec.origin != origin else { return }
    close(by: "otherSite")
  }

  /// Its frame against the button: under (or over) it, a 6 pt gap, its trailing (or leading) edge on the button's,
  /// kept inside the host by 8 pt.
  fileprivate func place(_ view: PanelView) {
    guard let host else { return }
    let spec = view.spec
    let anchor = spec.anchor.rect()
    let size = view.currentSize
    var x: CGFloat
    switch spec.anchor.align {
    case .trailing: x = anchor.maxX - size.width
    case .leading: x = anchor.minX
    case .center: x = anchor.midX - size.width / 2
    }
    x = max(8, min(x, host.bounds.width - size.width - 8))
    let y = spec.anchor.below ? anchor.minY - Self.gap - size.height : anchor.maxY + Self.gap
    view.frame = NSRect(x: x.rounded(), y: y.rounded(), width: size.width.rounded(), height: size.height.rounded())
  }

  /// A click elsewhere in the window or Escape closes it (app-local: only Ray's own events); so does the window
  /// going to the background.
  private func watch(_ view: PanelView) {
    monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) {
      [weak self, weak view] event in
      guard let self, let view, self.open === view, let spec = self.spec, let host = self.host,
            event.window === host.window else { return event }
      if event.type == .keyDown {
        if event.keyCode == 36 || event.keyCode == 76, let onReturn = spec.onReturn {
          onReturn()
          return nil
        }
        guard event.keyCode == 53, spec.closesOn.contains(.escape) else { return event }
        self.close(by: "escape")
        return nil
      }
      guard spec.closesOn.contains(.outsideClick), !spec.asks else { return event }
      let point = host.convert(event.locationInWindow, from: nil)
      if view.frame.contains(point) { return event }
      if let button = spec.anchor.button, button.window != nil, !button.isHiddenOrHasHiddenAncestor,
         button.convert(button.bounds, to: host).contains(point) { return event }
      self.close(by: "outsideClick")
      return event
    }
    if spec?.closesOn.contains(.windowInactive) == true, let window = host?.window {
      resignObserver = NotificationCenter.default.addObserver(
        forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
        self?.close(by: "windowInactive")
      }
    }
  }

  fileprivate func step(_ name: String) { steps[name, default: 0] += 1 }
  fileprivate func changed() { onChange?() }

  // MARK: Panels state

  var state: [String: Any] {
    var open: Any = NSNull()
    if let view = self.open, let spec {
      open = [
        "name": spec.name, "asks": spec.asks, "style": view.style,
        "frame": "\(Int(view.frame.minX)),\(Int(view.frame.minY)),\(Int(view.frame.width)),\(Int(view.frame.height))",
        "target": "\(Int(view.targetSize.width)),\(Int(view.targetSize.height))",
        "anchor": { let r = spec.anchor.rect(); return "\(Int(r.minX)),\(Int(r.minY)),\(Int(r.width)),\(Int(r.height))" }(),
        "below": spec.anchor.below, "align": spec.anchor.align.rawValue, "overSidebar": spec.overSidebar,
      ] as [String: Any]
    }
    return ["open": open, "steps": steps, "lastClosedBy": lastClosedBy ?? NSNull(), "style": SurfaceBackdrop.style]
  }
}

// MARK: Panel view

/// One open panel: the shadow, the glass or solid backdrop, and its content held at the button's corner while the
/// box reshapes on the spring.
final class PanelView: NSView {
  fileprivate let spec: PanelSpec
  fileprivate let serial: Int
  private weak var panels: Panels?
  /// Clips the content to the corners; the backdrop is its bottom view.
  private let body = NSView()
  private let backdrop = SurfaceBackdrop(radius: Panels.radius)
  private var content: NSView
  private var sizeSpring: Spring!
  private var fromSize = NSSize.zero
  private(set) var targetSize = NSSize.zero
  private(set) var currentSize = NSSize.zero
  var style: String { backdrop.style }

  fileprivate init(spec: PanelSpec, serial: Int, panels: Panels) {
    self.spec = spec
    self.serial = serial
    self.panels = panels
    content = spec.content
    super.init(frame: .zero)
    wantsLayer = true
    body.wantsLayer = true
    body.layer?.cornerRadius = Panels.radius
    body.layer?.cornerCurve = .continuous
    body.layer?.masksToBounds = true
    addSubview(body)
    body.addSubview(backdrop)
    body.addSubview(content)
    targetSize = content.frame.size
    fromSize = targetSize
    currentSize = targetSize
    sizeSpring = Spring(value: 1, response: Notes.response, dampingRatio: Notes.dampingRatio) { [weak self] t in
      guard let self else { return }
      self.currentSize = NSSize(width: self.fromSize.width + (self.targetSize.width - self.fromSize.width) * t,
                                height: self.fromSize.height + (self.targetSize.height - self.fromSize.height) * t)
      self.panels?.place(self)
    }
    setAccessibilityElement(true)
    setAccessibilityRole(.popover)
    setAccessibilityLabel(spec.name)
  }

  required init?(coder: NSCoder) { fatalError() }

  override var mouseDownCanMoveWindow: Bool { false }
  // Its padding swallows clicks so they never reach the page below.
  override func mouseDown(with event: NSEvent) {}

  override func layout() {
    super.layout()
    body.frame = bounds
    backdrop.frame = body.bounds
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    SurfaceBackdrop.shadow(on: self, radius: Panels.radius)
    CATransaction.commit()
    for view in body.subviews where view !== backdrop {
      view.setFrameOrigin(anchored(view.frame.size))
    }
  }

  /// Content keeps to the button's corner: the top (opening down) or bottom, the trailing or leading edge.
  private func anchored(_ size: NSSize) -> NSPoint {
    let x: CGFloat
    switch spec.anchor.align {
    case .trailing: x = bounds.width - size.width
    case .leading: x = 0
    case .center: x = (bounds.width - size.width) / 2
    }
    let y = spec.anchor.below ? bounds.height - size.height : 0
    return NSPoint(x: x.rounded(), y: y.rounded())
  }

  // MARK: Panel motion

  private var reduce: Bool { Panels.reduceMotion }

  /// The corner at the button, in the layer's own terms (AppKit sets the anchor point; scale about this corner).
  private func scale(_ amount: CGFloat, lift: CGFloat) -> CATransform3D {
    guard let layer else { return CATransform3DIdentity }
    let edgeX: CGFloat
    switch spec.anchor.align {
    case .trailing: edgeX = bounds.width
    case .leading: edgeX = 0
    case .center: edgeX = bounds.width / 2
    }
    let corner = CGPoint(x: edgeX, y: spec.anchor.below ? bounds.height : 0)
    let pivot = CGPoint(x: corner.x - layer.anchorPoint.x * bounds.width, y: corner.y - layer.anchorPoint.y * bounds.height)
    var transform = CATransform3DMakeTranslation(pivot.x, pivot.y, 0)
    transform = CATransform3DScale(transform, amount, amount, 1)
    transform = CATransform3DTranslate(transform, -pivot.x, -pivot.y, 0)
    return CATransform3DConcat(transform, CATransform3DMakeTranslation(0, lift, 0))
  }

  /// Grows out of the button: 8 pt and 97 % at its corner, on the spring; fading in over 140 ms.
  fileprivate func enter() {
    guard let layer else { return }
    layoutSubtreeIfNeeded()
    if !reduce {
      let grow = CASpringAnimation(keyPath: "transform")
      grow.fromValue = NSValue(caTransform3D: scale(0.97, lift: spec.anchor.below ? 8 : -8))
      grow.toValue = NSValue(caTransform3D: CATransform3DIdentity)
      grow.stiffness = pow(2 * .pi / Notes.response, 2)
      grow.damping = 4 * .pi * Notes.dampingRatio / Notes.response
      grow.duration = grow.settlingDuration
      layer.add(grow, forKey: "grow")
    }
    let fade = CABasicAnimation(keyPath: "opacity")
    fade.fromValue = 0
    fade.toValue = 1
    fade.duration = 0.14
    fade.timingFunction = CAMediaTimingFunction(controlPoints: 0, 0, 0.2, 1)
    layer.opacity = 1
    layer.add(fade, forKey: "fade")
  }

  /// 140 ms toward the button (90 ms when another panel takes its place), then gone.
  fileprivate func leave(fast: Bool) {
    guard let layer else { return removeFromSuperview() }
    let fade = CABasicAnimation(keyPath: "opacity")
    fade.fromValue = layer.presentation()?.opacity ?? 1
    fade.toValue = 0
    var animations: [CAAnimation] = [fade]
    if !reduce {
      let shrink = CABasicAnimation(keyPath: "transform")
      shrink.fromValue = NSValue(caTransform3D: CATransform3DIdentity)
      shrink.toValue = NSValue(caTransform3D: scale(0.98, lift: spec.anchor.below ? 4 : -4))
      animations.append(shrink)
    }
    let group = CAAnimationGroup()
    group.animations = animations
    group.duration = fast ? 0.09 : 0.14
    group.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 1, 1)
    group.fillMode = .forwards
    group.isRemovedOnCompletion = false
    CATransaction.begin()
    CATransaction.setCompletionBlock { [weak self] in self?.removeFromSuperview() }
    layer.opacity = 0
    layer.removeAnimation(forKey: "grow")
    layer.add(group, forKey: "leave")
    CATransaction.commit()
  }

  /// New content: the old fades out in 110 ms, the new fades in over 170 ms, the box reshapes on the spring.
  fileprivate func show(_ new: NSView) {
    let old = content
    content = new
    body.addSubview(new)
    new.setFrameOrigin(anchored(new.frame.size))
    // Back to a page that's still fading out: it stays.
    fade(old, to: 0, duration: 0.11, delay: 0) { [weak self] in if self?.content !== old { old.removeFromSuperview() } }
    new.wantsLayer = true
    new.layer?.opacity = 0
    fade(new, to: 1, duration: 0.17, delay: reduce ? 0 : 0.06)
    panels?.step("reshaped")
    resize(to: new.frame.size)
    panels?.changed()
  }

  fileprivate func contentChanged() {
    resize(to: content.frame.size)
    needsLayout = true
  }

  private func fade(_ view: NSView, to opacity: Float, duration: CFTimeInterval, delay: CFTimeInterval,
                    done: (() -> Void)? = nil) {
    view.wantsLayer = true
    guard let layer = view.layer else { done?(); return }
    let animation = CABasicAnimation(keyPath: "opacity")
    animation.fromValue = layer.presentation()?.opacity ?? layer.opacity
    animation.toValue = opacity
    animation.duration = duration
    animation.beginTime = CACurrentMediaTime() + delay
    animation.fillMode = .backwards
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
}

// MARK: Panel kit

/// The pieces panels are made of, laid out top down in a flipped column, so a new prompt is a few lines.
enum PanelKit {
  static let padding: CGFloat = 12

  /// A column of views (each its own height), `width` wide plus padding; returns a view sized to fit.
  static func stack(_ views: [NSView], width: CGFloat, spacing: CGFloat = 0, padding: CGFloat = PanelKit.padding) -> NSView {
    let column = PanelColumn()
    var y = padding
    for (index, view) in views.enumerated() {
      if index > 0 { y += spacing }
      view.frame = NSRect(x: padding, y: y, width: width, height: view.frame.height)
      column.addSubview(view)
      y += view.frame.height
    }
    column.frame = NSRect(x: 0, y: 0, width: width + padding * 2, height: y + padding)
    return column
  }

  /// A section's grey title.
  static func header(_ text: String) -> NSView {
    let label = NSTextField(labelWithString: text)
    label.font = .systemFont(ofSize: 12, weight: .semibold)
    label.textColor = .secondaryLabelColor
    let holder = PanelColumn(frame: NSRect(x: 0, y: 0, width: 10, height: 28))
    label.frame = NSRect(x: 4, y: 8, width: 300, height: ceil(label.intrinsicContentSize.height))
    label.autoresizingMask = [.width]
    holder.addSubview(label)
    return holder
  }

  /// A 44 pt row: an icon in a circle, a title and a grey value under it.
  static func row(symbol: String, title: String, value: String = "", enabled: Bool = true,
                  action: @escaping () -> Void) -> NSView {
    let row = SettingRow(symbol: symbol, title: title, subtitle: value, on: false)
    row.frame.size.height = 44
    row.isEnabled = enabled
    row.onClick = { _ in action() }
    return row
  }

  /// "‹ Title": back to the panel's first page.
  static func back(_ title: String, action: @escaping () -> Void) -> NSView {
    let button = PanelBackButton(title: title)
    button.onClick = action
    button.frame.size.height = 30
    return button
  }

  /// A choice in a list: its title, and a tick when it's the current one.
  static func choice(_ title: String, chosen: Bool, action: @escaping () -> Void) -> NSView {
    let row = SettingRow(symbol: chosen ? "checkmark" : "", title: title, subtitle: "", on: false, plain: true)
    row.frame.size.height = 36
    row.onClick = { _ in action() }
    return row
  }

  /// A hairline across the panel.
  static func separator() -> NSView {
    let holder = PanelColumn(frame: NSRect(x: 0, y: 0, width: 10, height: 17))
    let line = NSBox(frame: NSRect(x: 4, y: 8, width: 2, height: 1))
    line.boxType = .separator
    line.autoresizingMask = [.width]
    holder.addSubview(line)
    return holder
  }
}

/// A flipped plain container.
final class PanelColumn: NSView {
  override var isFlipped: Bool { true }
  override var mouseDownCanMoveWindow: Bool { false }
}

/// The back button of a panel's second page.
final class PanelBackButton: NSView {
  var onClick: (() -> Void)?
  private let icon = NSImageView()
  private let label: NSTextField
  private var hovered = false

  init(title: String) {
    label = NSTextField(labelWithString: title)
    super.init(frame: .zero)
    wantsLayer = true
    layer?.cornerRadius = 8
    layer?.cornerCurve = .continuous
    icon.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: nil)
    icon.symbolConfiguration = .init(pointSize: 11, weight: .semibold)
    icon.contentTintColor = .labelColor
    label.font = .systemFont(ofSize: 13, weight: .semibold)
    label.lineBreakMode = .byTruncatingTail
    addSubview(icon)
    addSubview(label)
    setAccessibilityElement(true)
    setAccessibilityRole(.button)
    setAccessibilityLabel("Back")
    addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }
  override var wantsUpdateLayer: Bool { true }
  override var mouseDownCanMoveWindow: Bool { false }

  override func updateLayer() { layer?.backgroundColor = (hovered ? PanelColors.tile : .clear).cgColor }

  override func layout() {
    super.layout()
    let mid = bounds.height / 2
    icon.frame = NSRect(x: 4, y: mid - 8, width: 16, height: 16)
    let height = ceil(label.intrinsicContentSize.height)
    label.frame = NSRect(x: 22, y: (mid - height / 2).rounded(), width: bounds.width - 26, height: height)
  }

  override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
  override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
  override func mouseDown(with event: NSEvent) { onClick?() }
  override func accessibilityPerformPress() -> Bool { onClick?(); return true }
}

/// A 28 pt button in a panel: a grey wash, or the profile's colour for the answer a question leads with (its text
/// white or black, whichever reads). Disabled, it's faded and takes no clicks.
final class PanelButton: NSView {
  var onClick: (() -> Void)?
  var isEnabled = true {
    didSet { needsDisplay = true }
  }
  private let primary: Bool
  private let destructive: Bool
  private let label: NSTextField
  private var hovered = false
  private var down = false

  /// `destructive`: filled red, for an answer that deletes (Clear).
  init(title: String, primary: Bool = false, destructive: Bool = false) {
    self.primary = primary || destructive
    self.destructive = destructive
    label = NSTextField(labelWithString: title)
    super.init(frame: .zero)
    wantsLayer = true
    layer?.cornerRadius = 8
    layer?.cornerCurve = .continuous
    label.font = .systemFont(ofSize: 12.5, weight: primary ? .semibold : .medium)
    label.alignment = .center
    addSubview(label)
    setAccessibilityElement(true)
    setAccessibilityRole(.button)
    setAccessibilityLabel(title)
    addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }
  override var wantsUpdateLayer: Bool { true }
  override var mouseDownCanMoveWindow: Bool { false }
  override var intrinsicContentSize: NSSize {
    NSSize(width: ceil(label.attributedStringValue.size().width) + 4 + 24, height: 28)
  }

  override func updateLayer() {
    if destructive {
      layer?.backgroundColor = NSColor.systemRed.cgColor
      label.textColor = .white
    } else if primary {
      layer?.backgroundColor = ProfileColor.accent.cgColor
      label.textColor = ProfileColor.foreground(on: ProfileColor.accent)
    } else {
      layer?.backgroundColor = (hovered && isEnabled || down ? PanelColors.tileHover : PanelColors.tile).cgColor
      label.textColor = .labelColor
    }
    alphaValue = isEnabled ? (down ? 0.85 : 1) : 0.45
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    needsDisplay = true
  }

  override func layout() {
    super.layout()
    let height = ceil(label.intrinsicContentSize.height)
    label.frame = NSRect(x: 0, y: ((bounds.height - height) / 2).rounded(), width: bounds.width, height: height)
  }

  override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
  override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
  override func mouseDown(with event: NSEvent) { guard isEnabled else { return }; down = true; needsDisplay = true }

  override func mouseUp(with event: NSEvent) {
    guard down else { return }
    down = false
    needsDisplay = true
    if isEnabled, bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
  }

  /// A click as the mouse would make it (tests, VoiceOver).
  func performClick(_ sender: Any?) { if isEnabled { onClick?() } }
  override func accessibilityPerformPress() -> Bool { performClick(nil); return isEnabled }
}

/// What a question can carry under its title and icon (a save prompt's well): it sizes itself to the width it's given.
protocol PanelQuestionAccessory: NSView {
  func height(forWidth width: CGFloat) -> CGFloat
}

/// A question in a panel: a title, an optional site (its full origin, grey, wrapping anywhere), a grey message (both
/// wrapping), an optional icon at the left (on a tile with `tile`), an optional accessory at full width under them and
/// an optional "Don't ask again" box, then its buttons at the bottom right. `PanelKit.question` builds one; `buttons`
/// are in order. With `wait`, the buttons take no clicks for that long each time it appears.
final class PanelQuestion: NSView {
  let buttons: [PanelButton]
  let check: NSButton?
  let accessory: PanelQuestionAccessory?
  private let icon: NSImageView?
  private let tile: Bool
  private let title: NSTextField
  private let site: NSTextField?
  private let message: NSTextField
  private let width: CGFloat
  private let wait: TimeInterval
  private var shownCount = 0
  /// Its buttons take clicks (the wait is over).
  private(set) var ready: Bool

  /// `answers`: (title, primary, destructive); `wait`: their buttons take no clicks for that long after it appears.
  init(title: String, site: String? = nil, message: String, icon: NSImage? = nil, tile: Bool = false,
       accessory: PanelQuestionAccessory? = nil, check: String? = nil, width: CGFloat = 320,
       answers: [(title: String, primary: Bool, destructive: Bool)], wait: TimeInterval = 0, onAnswer: @escaping (Int) -> Void) {
    self.width = width
    self.wait = wait
    self.tile = tile
    self.accessory = accessory
    self.title = NSTextField(wrappingLabelWithString: title)
    self.site = site.map { NSTextField(wrappingLabelWithString: $0) }
    self.message = NSTextField(wrappingLabelWithString: message)
    self.icon = icon.map { NSImageView(image: $0) }
    self.check = check.map { NSButton(checkboxWithTitle: $0, target: nil, action: nil) }
    buttons = answers.map { PanelButton(title: $0.title, primary: $0.primary, destructive: $0.destructive) }
    ready = wait <= 0
    super.init(frame: .zero)
    self.title.font = .systemFont(ofSize: 13.5, weight: .semibold)
    for label in [self.site, self.message].compactMap({ $0 }) {
      label.font = .systemFont(ofSize: 12)
      label.textColor = .secondaryLabelColor
    }
    self.site?.lineBreakMode = .byCharWrapping
    for label in [self.title, self.site, self.message].compactMap({ $0 }) {
      label.isSelectable = false
      addSubview(label)
    }
    self.message.isHidden = message.isEmpty
    if let icon = self.icon {
      if tile {
        icon.imageScaling = .scaleNone
        icon.symbolConfiguration = .init(pointSize: 14, weight: .semibold)
        icon.contentTintColor = .secondaryLabelColor
        icon.wantsLayer = true
        icon.layer?.cornerRadius = 8
        icon.layer?.cornerCurve = .continuous
      } else {
        icon.imageScaling = .scaleProportionallyUpOrDown
      }
      addSubview(icon)
    }
    if let accessory { addSubview(accessory) }
    if let check = self.check {
      check.font = .systemFont(ofSize: 12)
      check.refusesFirstResponder = true
      addSubview(check)
    }
    for (index, button) in buttons.enumerated() {
      button.onClick = { onAnswer(index) }
      button.isEnabled = ready
      addSubview(button)
    }
    let height = layoutContent(apply: false)
    frame = NSRect(x: 0, y: 0, width: width, height: height)
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }
  override var mouseDownCanMoveWindow: Bool { false }
  override var wantsUpdateLayer: Bool { true }

  override func updateLayer() {
    if tile { icon?.layer?.backgroundColor = PanelColors.tile.cgColor }
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    needsDisplay = true
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guard window != nil, wait > 0 else { return }
    // Each time it appears its buttons wait, so a click meant for the page can't land on one.
    shownCount += 1
    let shown = shownCount
    ready = false
    buttons.forEach { $0.isEnabled = false }
    DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
      guard let self, self.window != nil, self.shownCount == shown else { return }
      self.ready = true
      self.buttons.forEach { $0.isEnabled = true }
    }
  }

  override func layout() {
    super.layout()
    _ = layoutContent(apply: true)
  }

  var siteText: String { site?.stringValue ?? "" }

  private func layoutContent(apply: Bool) -> CGFloat {
    let pad: CGFloat = 16
    let left = pad + (icon == nil ? 0 : 44)
    let textWidth = width - left - pad
    func height(_ label: NSTextField) -> CGFloat {
      label.preferredMaxLayoutWidth = textWidth
      return ceil(label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: textWidth, height: 10_000)).height ?? 16)
    }
    var y = pad
    let titleHeight = height(title)
    if apply {
      icon?.frame = NSRect(x: pad, y: pad, width: 32, height: 32)
      title.frame = NSRect(x: left - 2, y: y, width: textWidth + 4, height: titleHeight)
    }
    y += titleHeight
    if let site {
      y += 2
      let siteHeight = height(site)
      if apply { site.frame = NSRect(x: left - 2, y: y, width: textWidth + 4, height: siteHeight) }
      y += siteHeight
    }
    if !message.isHidden {
      y += 4
      let messageHeight = height(message)
      if apply { message.frame = NSRect(x: left - 2, y: y, width: textWidth + 4, height: messageHeight) }
      y += messageHeight
    }
    if icon != nil { y = max(y, pad + 32) }
    if let accessory {
      y += 12
      let fullWidth = width - pad * 2
      let accessoryHeight = accessory.height(forWidth: fullWidth)
      if apply { accessory.frame = NSRect(x: pad, y: y, width: fullWidth, height: accessoryHeight) }
      y += accessoryHeight
    }
    if let check {
      y += 10
      if apply { check.frame = NSRect(x: left - 2, y: y, width: textWidth + 4, height: 18) }
      y += 18
    }
    y += 14
    var right = width - pad
    for button in buttons.reversed() {
      let width = button.intrinsicContentSize.width
      right -= width
      if apply { button.frame = NSRect(x: right, y: y, width: width, height: 28) }
      right -= 6
    }
    return y + 28 + pad
  }
}

/// A host for panels over a view that takes clicks itself (the Settings window): it passes every click it doesn't
/// cover with a panel through to what's below.
final class PanelPassThroughView: NSView {
  override func hitTest(_ point: NSPoint) -> NSView? {
    let hit = super.hitTest(point)
    return hit === self ? nil : hit
  }
}
