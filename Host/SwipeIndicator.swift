import AppKit
import ObjectiveC

// The back/forward swipe's indicator (two fingers on the trackpad, or one on a Magic Mouse): Dia's frosted chip with
// a chevron (owner's pick A of `docs/mocks/swipe-indicator.html`, 2026-11-10; sizes from Ardia's `SwipeOverlay.tsx`).
// Chrome still recognises the gesture and navigates (`HistorySwiper`: its threshold, vertical cancel and the System
// Settings switch); only what it draws is Ray's. Chrome's own overlay (`HistoryOverlayController`, a dark 140 pt
// half-circle) is a view it adds to the page's render view, so `ChromeSwipeHook` wraps three of its methods through
// the Objective-C runtime, hides Chrome's view and tells the window. No engine change; if a later engine renames the
// class, Chrome's overlay simply stays (`hook` false in the state log, and the check fails).

enum ChromeSwipeHook {
  private(set) static var installed = false
  /// Chrome's delegate call that navigates: a swipe let go past the threshold. Without it, "armed" stands in.
  private(set) static var navigateHooked = false
  /// Chrome's latest overlay view, for the state log (hidden while Ray draws its own).
  private(set) static weak var chromeView: NSView?

  static func install() {
    guard !installed else { return }
    guard let overlay = NSClassFromString("HistoryOverlayController"),
          let show = class_getInstanceMethod(overlay, NSSelectorFromString("showPanelForView:")),
          let progress = class_getInstanceMethod(overlay, NSSelectorFromString("setProgress:finished:")),
          let dismiss = class_getInstanceMethod(overlay, NSSelectorFromString("dismiss")) else {
      NSLog("[ray] swipe indicator: Chrome's history overlay not found, keeping Chrome's")
      return
    }
    installed = true

    typealias Show = @convention(c) (AnyObject, Selector, NSView) -> Void
    let showSelector = method_getName(show)
    let originalShow = unsafeBitCast(method_getImplementation(show), to: Show.self)
    let newShow: @convention(block) (AnyObject, NSView) -> Void = { controller, view in
      originalShow(controller, showSelector, view)
      guard let chrome = (controller as? NSViewController)?.view, let window = view.window else { return }
      chrome.isHidden = true
      chromeView = chrome
      // Chrome has just placed it for no progress: past the page's left edge going back, its right edge forward.
      let back = chrome.frame.midX < view.frame.midX
      indicator(in: window)?.began(ObjectIdentifier(controller), back: back)
    }
    method_setImplementation(show, imp_implementationWithBlock(newShow))

    typealias Progress = @convention(c) (AnyObject, Selector, CGFloat, ObjCBool) -> Void
    let progressSelector = method_getName(progress)
    let originalProgress = unsafeBitCast(method_getImplementation(progress), to: Progress.self)
    let newProgress: @convention(block) (AnyObject, CGFloat, ObjCBool) -> Void = { controller, amount, finished in
      originalProgress(controller, progressSelector, amount, finished)
      guard let chrome = (controller as? NSViewController)?.view, let window = chrome.window else { return }
      chrome.isHidden = true
      indicator(in: window)?.progress(ObjectIdentifier(controller), amount, armed: finished.boolValue)
    }
    method_setImplementation(progress, imp_implementationWithBlock(newProgress))

    typealias Dismiss = @convention(c) (AnyObject, Selector) -> Void
    let dismissSelector = method_getName(dismiss)
    let originalDismiss = unsafeBitCast(method_getImplementation(dismiss), to: Dismiss.self)
    let newDismiss: @convention(block) (AnyObject) -> Void = { controller in
      let window = (controller as? NSViewController)?.view.window
      originalDismiss(controller, dismissSelector)
      if let window { indicator(in: window)?.ended(ObjectIdentifier(controller)) }
    }
    method_setImplementation(dismiss, imp_implementationWithBlock(newDismiss))

    // Chrome navigates through its render view's delegate, before it dismisses the overlay (trackpad and mouse).
    if let delegate = NSClassFromString("ChromeRenderWidgetHostViewMacDelegate"),
       let navigate = class_getInstanceMethod(delegate, NSSelectorFromString("navigateInDirection:onWindow:")) {
      typealias Navigate = @convention(c) (AnyObject, Selector, Int32, NSWindow?) -> Void
      let navigateSelector = method_getName(navigate)
      let originalNavigate = unsafeBitCast(method_getImplementation(navigate), to: Navigate.self)
      let newNavigate: @convention(block) (AnyObject, Int32, NSWindow?) -> Void = { delegate, direction, window in
        if let window { indicator(in: window)?.navigated() }
        originalNavigate(delegate, navigateSelector, direction, window)
      }
      method_setImplementation(navigate, imp_implementationWithBlock(newNavigate))
      navigateHooked = true
    }
  }

  private static func indicator(in window: NSWindow) -> SwipeIndicator? {
    AppController.shared.windows.first { $0.window === window }?.swipeIndicator
  }
}

/// One window's indicator over its page: slides in from the page's edge with the fingers and stops 14 pt in at the
/// threshold; armed (letting go navigates) it grows from 72 to 82 pt, the chevron goes solid and the trackpad ticks.
/// Let go: it shrinks away as the page changes, or slides back out. Reduce Motion: it fades in place.
final class SwipeIndicator {
  static let size: CGFloat = 72
  static let armedSize: CGFloat = 82
  static let inset: CGFloat = 14
  static let chevron: CGFloat = 28
  static let armedChevron: CGFloat = 34
  /// Every leave ends by then, even when the display link doesn't tick (a window off screen).
  static let leaveDeadline: TimeInterval = 1

  private weak var host: NSView?
  /// The view it goes below (the floating sidebar): a peeking sidebar covers it.
  private let below: () -> NSView?
  private let clip = SwipeClipView()
  private let chip = SwipeChipView()
  private var page: NSRect = .zero
  private var session: ObjectIdentifier?
  private(set) var shown = false
  private(set) var back = true
  private(set) var amount: CGFloat = 0
  private(set) var armed = false
  private var navigatedThisSwipe = false
  private enum Leaving: String { case none, commit, cancel }
  private var leaving = Leaving.none
  private var leaveFrom: CGFloat = 0
  private var leaveWork: DispatchWorkItem?
  private lazy var grow = Spring(value: 0, response: Spring.response, dampingRatio: Spring.dampingRatio) {
    [weak self] _ in self?.place()
  }
  private lazy var leave = Spring(value: 0, response: Spring.response, dampingRatio: Spring.dampingRatio) {
    [weak self] _ in self?.leaveStep()
  }
  /// For the state log.
  private(set) var steps: [String] = []
  private(set) var haptics = 0
  private(set) var swipes = 0
  #if RAY_TEST_HOOKS
  static var reduceMotionOverride: Bool?
  #endif
  var onChange: (() -> Void)?

  init(host: NSView, below: @escaping () -> NSView?) {
    self.host = host
    self.below = below
    ChromeSwipeHook.install()
    clip.isHidden = true
    clip.addSubview(chip)
  }

  static var reduceMotion: Bool {
    #if RAY_TEST_HOOKS
    if let reduceMotionOverride { return reduceMotionOverride }
    #endif
    return NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
  }

  /// The page's frame in the host and its corners.
  func layout(in page: NSRect, radius: CGFloat) {
    clip.layer?.cornerRadius = radius
    guard page != self.page else { return }
    self.page = page
    clip.frame = page
    if shown { place() }
  }

  // MARK: From Chrome's swiper

  func began(_ id: ObjectIdentifier, back: Bool) {
    finish(log: false)
    session = id
    self.back = back
    amount = 0
    armed = false
    navigatedThisSwipe = false
    grow.jump(to: 0)
    leave.jump(to: 0)
    swipes += 1
    steps = ["began \(back ? "back" : "forward")"]
    attach()
    shown = true
    clip.isHidden = false
    place()
    onChange?()
  }

  func progress(_ id: ObjectIdentifier, _ value: CGFloat, armed now: Bool) {
    guard id == session, leaving == .none else { return }
    amount = min(1, max(0, value))
    if now != armed {
      armed = now
      steps.append(now ? "armed" : "disarmed")
      if Self.reduceMotion { grow.jump(to: now ? 1 : 0) } else { grow.animate(to: now ? 1 : 0, in: chip) }
      if now {
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        haptics += 1
      }
      onChange?()
    }
    place()
  }

  func navigated() {
    guard session != nil else { return }
    navigatedThisSwipe = true
  }

  func ended(_ id: ObjectIdentifier) {
    guard id == session else { return }
    session = nil
    let commit = navigatedThisSwipe || (!ChromeSwipeHook.navigateHooked && armed)
    steps.append(commit ? "committed" : "cancelled")
    leaving = commit ? .commit : .cancel
    leaveFrom = amount
    leave.jump(to: 0)
    leave.animate(to: 1, in: chip)
    let work = DispatchWorkItem { [weak self] in self?.finish(log: true) }
    leaveWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.leaveDeadline, execute: work)
    if !leave.isMoving { finish(log: true) }
    onChange?()
  }

  /// Gone at once (a tab switch); Chrome's later calls for this swipe are ignored.
  func hide() {
    session = nil
    finish(log: shown)
  }

  // MARK: Drawing

  private func attach() {
    guard let host, clip.superview !== host else { return }
    if let below = below(), below.superview === host {
      host.addSubview(clip, positioned: .below, relativeTo: below)
    } else {
      host.addSubview(clip, positioned: .above, relativeTo: nil)
    }
    clip.frame = page
  }

  private func leaveStep() {
    place()
    if leaving != .none, !leave.isMoving, leave.value >= 1 { finish(log: true) }
  }

  private func finish(log: Bool) {
    leaveWork?.cancel()
    leaveWork = nil
    let was = shown
    leaving = .none
    shown = false
    clip.isHidden = true
    grow.jump(to: 0)
    leave.jump(to: 0)
    if was && log {
      steps.append("gone")
      onChange?()
    }
  }

  /// The chip's size, where it sits (its near edge's distance in from the page's edge), its opacity and scale.
  private var geometry: (size: CGFloat, x: CGFloat, alpha: CGFloat, scale: CGFloat, grown: CGFloat) {
    let grown = min(1.2, max(0, grow.value))
    let size = Self.size + (Self.armedSize - Self.size) * grown
    let left = min(1, max(0, leave.value))
    if Self.reduceMotion {
      let alpha = leaving == .none ? amount : leaveFrom * (1 - left)
      return (size, Self.inset, alpha, 1, grown)
    }
    let travel = leaving == .cancel ? leaveFrom * (1 - left) : amount
    let x = travel * (size + Self.inset) - size
    return leaving == .commit ? (size, x, 1 - left, 1 - 0.99 * left, grown) : (size, x, 1, 1, grown)
  }

  private func place() {
    guard shown else { return }
    let g = geometry
    let drawn = g.size * g.scale
    let centerX = back ? g.x + g.size / 2 : page.width - g.x - g.size / 2
    chip.frame = NSRect(x: centerX - drawn / 2, y: page.height / 2 - drawn / 2, width: drawn, height: drawn)
    chip.alphaValue = max(0, min(1, g.alpha))
    chip.update(back: back, grown: g.grown, scale: g.scale)
  }

  /// Where the chip would sit once settled, in the host (the check's yardstick, since springs need frames).
  private var target: NSRect {
    let size = armed ? Self.armedSize : Self.size
    let x = Self.reduceMotion ? Self.inset : amount * (size + Self.inset) - size
    let minX = back ? page.minX + x : page.maxX - x - size
    return NSRect(x: minX, y: page.midY - size / 2, width: size, height: size)
  }

  private static func text(_ r: NSRect) -> String {
    String(format: "%.1f,%.1f,%.1f,%.1f", r.minX, r.minY, r.width, r.height)
  }

  var debug: [String: Any] {
    [
      "hook": ChromeSwipeHook.installed,
      "navigateHook": ChromeSwipeHook.navigateHooked,
      "chromeHidden": ChromeSwipeHook.chromeView.map { $0.isHidden && $0.superview != nil } ?? NSNull(),
      "shown": shown,
      "direction": back ? "back" : "forward",
      "progress": Double(amount),
      "armed": armed,
      "leaving": leaving.rawValue,
      "frame": Self.text(clip.convert(chip.frame, to: nil)),
      "target": Self.text(target),
      "page": Self.text(page),
      "alpha": Double(chip.alphaValue),
      "belowSidebar": host.map { host in
        guard let below = below(), let mine = host.subviews.firstIndex(of: clip),
              let theirs = host.subviews.firstIndex(of: below) else { return true }
        return mine < theirs
      } ?? true,
      "reduceMotion": Self.reduceMotion,
      "steps": steps,
      "haptics": haptics,
      "swipes": swipes,
    ]
  }
}

/// The page's rect, clipping the chip to the page card's corners; never takes a click.
final class SwipeClipView: NSView {
  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.masksToBounds = true
    layer?.cornerCurve = .continuous
  }

  required init?(coder: NSCoder) { fatalError() }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Dia's chip: the panels' frosted surface as a circle, a bold chevron (half strength until armed) and, in light mode,
/// a white wash when armed.
final class SwipeChipView: NSView {
  private let backdrop = SurfaceBackdrop(radius: SwipeIndicator.size / 2)
  private let wash = NSView()
  private let chevron = NSImageView()
  private var back = true
  private var grown: CGFloat = 0
  private var scale: CGFloat = 1

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    addSubview(backdrop)
    backdrop.layer?.cornerCurve = .circular
    wash.wantsLayer = true
    backdrop.addSubview(wash)
    chevron.imageScaling = .scaleProportionallyUpOrDown
    chevron.contentTintColor = .labelColor
    addSubview(chevron)
    setSymbol()
  }

  required init?(coder: NSCoder) { fatalError() }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  func update(back: Bool, grown: CGFloat, scale: CGFloat) {
    if back != self.back {
      self.back = back
      setSymbol()
    }
    self.grown = grown
    self.scale = scale
    needsLayout = true
  }

  private func setSymbol() {
    let config = NSImage.SymbolConfiguration(pointSize: 24, weight: .bold)
    chevron.image = NSImage(systemSymbolName: back ? "chevron.left" : "chevron.right", accessibilityDescription: nil)?
      .withSymbolConfiguration(config)
  }

  override func layout() {
    super.layout()
    backdrop.frame = bounds
    backdrop.radius = bounds.width / 2
    wash.frame = backdrop.bounds
    let side = (SwipeIndicator.chevron + (SwipeIndicator.armedChevron - SwipeIndicator.chevron) * min(1, grown)) * scale
    chevron.frame = NSRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side)
    chevron.alphaValue = 0.5 + 0.5 * min(1, grown)
    let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    wash.layer?.backgroundColor = NSColor(white: 1, alpha: dark ? 0 : 0.4 * min(1, grown)).cgColor
    SurfaceBackdrop.shadow(on: self, radius: bounds.width / 2)
  }
}

#if RAY_TEST_HOOKS
// MARK: Test driving

/// Drives Chrome's real overlay on the active tab's render view, as its swiper would, so the hook runs end to end:
/// `start back|forward`, `progress <0…1> [finished]`, `navigate` (Chrome's delegate: the page really goes),
/// `dismiss`.
extension ChromeSwipeHook {
  private static var testOverlay: NSViewController?
  private static var testBack = true

  static func drive(_ parts: [String], page: NSView?) -> String {
    switch parts.first {
    case "start" where parts.count == 2 && ["back", "forward"].contains(parts[1]):
      guard let cls = NSClassFromString("HistoryOverlayController"), let view = renderView(in: page) else {
        return "no overlay class or render view"
      }
      let initForMode = NSSelectorFromString("initForMode:")
      typealias Init = @convention(c) (AnyObject, Selector, Int32) -> NSViewController?
      guard let allocated = (cls as AnyObject).perform(NSSelectorFromString("alloc"))?.takeRetainedValue(),
            let overlay = unsafeBitCast(class_getMethodImplementation(cls, initForMode), to: Init.self)(
              allocated, initForMode, parts[1] == "back" ? 0 : 1) else { return "no overlay" }
      testOverlay = overlay
      testBack = parts[1] == "back"
      overlay.perform(NSSelectorFromString("showPanelForView:"), with: view)
    case "progress" where parts.count >= 2:
      guard let overlay = testOverlay, let value = Double(parts[1]) else { return "no swipe" }
      let selector = NSSelectorFromString("setProgress:finished:")
      typealias Progress = @convention(c) (AnyObject, Selector, CGFloat, ObjCBool) -> Void
      unsafeBitCast(class_getMethodImplementation(type(of: overlay), selector), to: Progress.self)(
        overlay, selector, CGFloat(value), ObjCBool(parts.count == 3 && parts[2] == "finished"))
    case "navigate":
      guard let view = renderView(in: page), let ivar = class_getInstanceVariable(type(of: view), "_responderDelegate"),
            let delegate = object_getIvar(view, ivar) as AnyObject? else { return "no delegate" }
      let selector = NSSelectorFromString("navigateInDirection:onWindow:")
      typealias Navigate = @convention(c) (AnyObject, Selector, Int32, NSWindow?) -> Void
      unsafeBitCast(class_getMethodImplementation(type(of: delegate), selector), to: Navigate.self)(
        delegate, selector, testBack ? 0 : 1, view.window)
    case "dismiss":
      guard let overlay = testOverlay else { return "no swipe" }
      overlay.perform(NSSelectorFromString("dismiss"))
      testOverlay = nil
    default:
      return "usage: swipe start back|forward | progress <0…1> [finished] | navigate | dismiss"
    }
    return "ok"
  }

  private static func renderView(in view: NSView?) -> NSView? {
    guard let view else { return nil }
    if NSStringFromClass(type(of: view)) == "RenderWidgetHostViewCocoa" { return view }
    for subview in view.subviews { if let found = renderView(in: subview) { return found } }
    return nil
  }
}
#endif
