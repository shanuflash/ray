import AppKit
import QuartzCore

// The address of the link under the pointer, in a small pill at the page's bottom left (Chrome's status bubble,
// owner's pick 2026-11-05: Ardia's pill on the notes' surface, `docs/mocks/tab-details.html`). Chrome's timing
// (`status_bubble_views.cc`): it shows 80 ms after the engine reports a link (`tab:didChangeStatusText:`), fading in
// over 120 ms; once the pointer leaves the link it waits 250 ms and fades out over 200 ms; another link meanwhile
// swaps the text in place. A third of the page wide at most; still on one link after 1.6 s, a cut address grows to
// the page's width (and the next link shows grown, until it hides). The pointer near it sends it to the bottom right
// (Arc's), and it sits above a note in its corner (the downloads note) instead of under it.

final class LinkPreview {
  static let showDelay: TimeInterval = 0.08
  static let hideDelay: TimeInterval = 0.25
  static let fadeIn: TimeInterval = 0.12
  static let fadeOut: TimeInterval = 0.2
  static let expandDelay: TimeInterval = 1.6
  /// Ardia's pill: 6 pt in from the page's corner, 22 pt tall.
  static let inset: CGFloat = 6
  static let height: CGFloat = 22
  /// Chrome's: how near the pointer may come before the pill moves away.
  static let avoidance: CGFloat = 20
  /// Longer addresses are cut before they're measured (Crest drops ones over 8,192 bytes).
  static let longest = 2048

  private weak var host: NSView?
  /// The view the pill goes below (the floating sidebar): a peeking sidebar covers it.
  private let below: () -> NSView?
  /// A note in the corner the pill would take: it sits on top of it.
  private let obstacle: (_ trailing: Bool) -> NSRect?
  private let view = LinkPreviewView()
  private var page: NSRect = .zero
  private(set) var url = ""
  private var wanted = ""
  private(set) var shown = false
  private(set) var trailing = false
  private(set) var expanded = false
  private var showWork: DispatchWorkItem?
  private var hideWork: DispatchWorkItem?
  private var expandWork: DispatchWorkItem?
  private var monitor: Any?
  /// For the state log: how many times it appeared.
  private(set) var appearances = 0
  var onChange: (() -> Void)?

  init(host: NSView, below: @escaping () -> NSView?, obstacle: @escaping (_ trailing: Bool) -> NSRect?) {
    self.host = host
    self.below = below
    self.obstacle = obstacle
    view.alphaValue = 0
    view.isHidden = true
  }

  /// The engine's status text for the active tab: a link's address, or empty when the pointer left it.
  func status(_ text: String) {
    let text = String(text.prefix(Self.longest))
    wanted = text
    if text.isEmpty {
      showWork?.cancel()
      showWork = nil
      expandWork?.cancel()
      guard shown, hideWork == nil else { return }
      let work = DispatchWorkItem { [weak self] in self?.fadeOut() }
      hideWork = work
      DispatchQueue.main.asyncAfter(deadline: .now() + Self.hideDelay, execute: work)
      return
    }
    hideWork?.cancel()
    hideWork = nil
    if shown {
      show(text)
    } else if showWork == nil {
      let work = DispatchWorkItem { [weak self] in
        guard let self else { return }
        self.showWork = nil
        if !self.wanted.isEmpty { self.show(self.wanted) }
      }
      showWork = work
      DispatchQueue.main.asyncAfter(deadline: .now() + Self.showDelay, execute: work)
    }
  }

  /// Gone at once (a tab switch, the window closing).
  func hide() {
    wanted = ""
    [showWork, hideWork, expandWork].forEach { $0?.cancel() }
    showWork = nil
    hideWork = nil
    guard shown else { return }
    shown = false
    expanded = false
    stopWatching()
    view.layer?.removeAllAnimations()
    view.alphaValue = 0
    view.isHidden = true
    onChange?()
  }

  /// The page's frame in the host.
  func layout(in page: NSRect) {
    guard page != self.page else { return }
    self.page = page
    if shown { place(animated: false) }
  }

  /// A note came or went: keep clear of it.
  func notesChanged() { if shown { place(animated: true) } }

  private func show(_ text: String) {
    guard let host else { return }
    url = text
    view.show(LinkPreview.parts(for: text))
    if view.superview !== host {
      if let below = below(), below.superview === host {
        host.addSubview(view, positioned: .below, relativeTo: below)
      } else {
        host.addSubview(view, positioned: .above, relativeTo: nil)
      }
    }
    let appearing = !shown
    if appearing {
      shown = true
      appearances += 1
      trailing = false
      watch()
    }
    avoidPointer()
    place(animated: false)
    if appearing {
      view.isHidden = false
      NSAnimationContext.runAnimationGroup { context in
        context.duration = Self.fadeIn
        context.timingFunction = CAMediaTimingFunction(name: .easeOut)
        view.animator().alphaValue = 1
      }
    }
    // Cut short: grow to the page's width if the pointer stays (Chrome's expand).
    expandWork?.cancel()
    if !expanded, view.naturalWidth > standardWidth {
      let work = DispatchWorkItem { [weak self] in
        guard let self, self.shown else { return }
        self.expanded = true
        self.place(animated: true)
        self.onChange?()
      }
      expandWork = work
      DispatchQueue.main.asyncAfter(deadline: .now() + Self.expandDelay, execute: work)
    }
    onChange?()
  }

  private func fadeOut() {
    hideWork = nil
    guard shown else { return }
    shown = false
    expanded = false
    expandWork?.cancel()
    stopWatching()
    NSAnimationContext.runAnimationGroup({ context in
      context.duration = Self.fadeOut
      context.timingFunction = CAMediaTimingFunction(name: .easeIn)
      view.animator().alphaValue = 0
    }, completionHandler: { [weak self] in
      guard let self, !self.shown else { return }
      self.view.isHidden = true
    })
    onChange?()
  }

  /// A third of the page (Chrome's standard width), never under 160 pt (Ardia's least).
  private var standardWidth: CGFloat { max(160, page.width / 3) }
  private var widest: CGFloat { max(0, page.width - Self.inset * 2) }

  private func frame(trailing: Bool) -> NSRect {
    let width = min(view.naturalWidth, expanded ? widest : min(widest, standardWidth)).rounded(.up)
    let x = trailing ? page.maxX - Self.inset - width : page.minX + Self.inset
    var y = page.minY + Self.inset
    // On top of a note in that corner (downloads), with the notes' gap.
    if let note = obstacle(trailing), note.width > 0, note.minX < x + width, note.maxX > x {
      y = max(y, note.maxY + Notes.gap)
    }
    return NSRect(x: x.rounded(), y: y.rounded(), width: width, height: Self.height)
  }

  private func place(animated: Bool) {
    let target = frame(trailing: trailing)
    guard target != view.frame else { return }
    if animated, view.alphaValue > 0, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
      NSAnimationContext.runAnimationGroup { context in
        // Chrome's expansion: 20–150 ms by how far it grows.
        context.duration = min(0.15, max(0.02, abs(target.width - view.frame.width) / 1000))
        context.timingFunction = CAMediaTimingFunction(name: .easeOut)
        view.animator().frame = target
      }
    } else {
      view.frame = target
    }
  }

  // MARK: Pointer

  /// The pointer near the pill (in the host): it takes the other corner, and comes back once the pointer leaves
  /// that corner's zone.
  func pointerMoved(to point: NSPoint) {
    guard shown else { return }
    let leading = frame(trailing: false).insetBy(dx: -Self.avoidance, dy: -Self.avoidance)
    let wantsTrailing = leading.contains(point)
    guard wantsTrailing != trailing else { return }
    trailing = wantsTrailing
    place(animated: false)
    onChange?()
  }

  private func avoidPointer() {
    guard let host, let window = host.window else { return }
    pointerMoved(to: host.convert(window.mouseLocationOutsideOfEventStream, from: nil))
  }

  /// Pointer moves only, in this app, only while the pill shows (never keys, never global).
  private func watch() {
    guard monitor == nil else { return }
    monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
      guard let self, let host = self.host, event.window === host.window else { return event }
      self.pointerMoved(to: host.convert(event.locationInWindow, from: nil))
      return event
    }
  }

  private func stopWatching() {
    if let monitor { NSEvent.removeMonitor(monitor) }
    monitor = nil
  }

  // MARK: Link preview text

  /// How a link reads: host (medium) then the rest (grey), as the address bar shows an address (`user:pass@`
  /// hidden, percent-encoded, punycode hosts). Mail and phone links show whole; `javascript:`, `data:` and the like
  /// only their scheme.
  static func parts(for url: String) -> AddressInput.AddressParts {
    let scheme = (URLComponents(string: url)?.scheme ?? "").lowercased()
    if ["mailto", "tel", "sms"].contains(scheme) {
      return AddressInput.AddressParts(host: url.prefix(scheme.count + 1).lowercased(), trail: String(url.dropFirst(scheme.count + 1)))
    }
    return AddressInput.addressParts(for: url)
  }

  var debug: [String: Any] {
    let f = view.frame
    return [
      "shown": shown, "text": shown ? view.text : "", "host": shown ? view.host : "", "side": trailing ? "trailing" : "leading",
      "expanded": expanded, "appearances": appearances, "alpha": Double(view.alphaValue),
      "frame": String(format: "%.0f,%.0f,%.0f,%.0f", f.minX, f.minY, f.width, f.height),
      "page": String(format: "%.0f,%.0f,%.0f,%.0f", page.minX, page.minY, page.width, page.height),
      "style": view.style,
    ]
  }
}

/// The pill: the notes' surface (glass or solid), the address in one line, cut from its end. Never takes a click.
private final class LinkPreviewView: NSView {
  private let body = NSView()
  private let backdrop = SurfaceBackdrop(radius: LinkPreviewView.radius)
  private let label = NSTextField(labelWithString: "")
  private(set) var text = ""
  private(set) var host = ""
  private var parts = AddressInput.AddressParts()
  var style: String { backdrop.style }
  /// Ardia's 7 pt corners.
  static let radius: CGFloat = 7
  static let padding: CGFloat = 8
  static let font = NSFont.systemFont(ofSize: 12)
  static let hostFont = NSFont.systemFont(ofSize: 12, weight: .medium)

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    body.wantsLayer = true
    body.layer?.cornerRadius = Self.radius
    body.layer?.cornerCurve = .continuous
    body.layer?.masksToBounds = true
    addSubview(body)
    body.addSubview(backdrop)
    label.lineBreakMode = .byTruncatingTail
    label.maximumNumberOfLines = 1
    label.cell?.truncatesLastVisibleLine = true
    body.addSubview(label)
    setAccessibilityElement(false)
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  func show(_ parts: AddressInput.AddressParts) {
    self.parts = parts
    text = parts.text
    host = parts.host
    refreshText()
  }

  private func refreshText() {
    let rest: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: NSColor.secondaryLabelColor]
    let shown = NSMutableAttributedString(string: parts.lead, attributes: rest)
    shown.append(NSAttributedString(string: parts.host, attributes: [.font: Self.hostFont, .foregroundColor: NSColor.labelColor]))
    shown.append(NSAttributedString(string: parts.trail, attributes: rest))
    label.attributedStringValue = shown
    needsLayout = true
  }

  /// The whole address's width, padding included.
  var naturalWidth: CGFloat { ceil(label.attributedStringValue.size().width) + 2 + Self.padding * 2 }

  override func layout() {
    super.layout()
    body.frame = bounds
    backdrop.frame = body.bounds
    let height = ceil(label.intrinsicContentSize.height)
    label.frame = NSRect(x: Self.padding, y: ((bounds.height - height) / 2).rounded(), width: max(0, bounds.width - Self.padding * 2), height: height)
    shadow()
  }

  /// Ardia's small shadow (radius 6, 2 pt down), not the notes' deep one: the pill is a fifth of their size.
  private func shadow() {
    guard let layer else { return }
    let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    layer.shadowColor = NSColor.black.cgColor
    layer.shadowOpacity = dark ? 0.3 : 0.1
    layer.shadowRadius = 6
    layer.shadowOffset = CGSize(width: 0, height: -2)
    layer.shadowPath = CGPath(roundedRect: bounds, cornerWidth: Self.radius, cornerHeight: Self.radius, transform: nil)
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    refreshText()
  }
}
