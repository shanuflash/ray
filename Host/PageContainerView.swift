import AppKit

final class PageContainerView: NSView {
  private(set) var shown: RayCoreTab?
  private var devTools: NSView?
  private var hideGeneration: [Int32: Int] = [:]
  private let progressLayer = CALayer()

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.cornerRadius = Self.radius
    layer?.cornerCurve = .continuous
    layer?.masksToBounds = true
    layer?.backgroundColor = NSColor.clear.cgColor
    progressLayer.backgroundColor = ProfileColor.accent.cgColor
    progressLayer.opacity = 0
    progressLayer.zPosition = 10
    layer?.addSublayer(progressLayer)
  }

  required init?(coder: NSCoder) { fatalError() }

  static let radius: CGFloat = 10

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    updateBackground()
  }

  var cornerRadius: CGFloat {
    get { layer?.cornerRadius ?? 0 }
    set {
      guard layer?.cornerRadius != newValue else { return }
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      layer?.cornerRadius = newValue
      CATransaction.commit()
    }
  }

  override var isFlipped: Bool { true }

  var debugState: [String: Any] {
    let page = shown?.view
    var state: [String: Any] = ["pageFrame": page.map { NSStringFromRect($0.frame) } ?? "", "progressLine": progressShown,
                                 "progressColor": progressColor]
    if let page {
      state["pageSubviews"] = page.subviews.map {
        "\(type(of: $0)) \(NSStringFromRect($0.frame)) hidden=\($0.isHidden)"
      }
    }
    // Chrome's content layer is the first sublayer of the render view's layer; it must track the page size.
    if let render = page?.subviews.first, let content = render.layer?.sublayers?.first {
      state["contentLayerMatches"] = content.bounds.size == render.bounds.size
    }
    #if RAY_TEST_HOOKS
    state["switches"] = switches
    #endif
    if let devTools, devTools.superview === self {
      state["devToolsFrame"] = NSStringFromRect(devTools.frame)
      if let page, let pageIndex = subviews.firstIndex(of: page), let devIndex = subviews.firstIndex(of: devTools) {
        state["pageAboveDevTools"] = pageIndex > devIndex
      }
    }
    return state
  }

  func attach(_ tab: RayCoreTab) {
    let page = tab.view
    guard page.superview !== self else { return }
    page.removeFromSuperview()
    page.isHidden = tab !== shown
    page.frame = bounds
    addSubview(page, positioned: .below, relativeTo: nil)
  }

  func detach(_ tab: RayCoreTab) {
    // The page held for a switch is going: the new page shows now, drawn or not.
    if leaving === tab {
      leaving = nil
      release()
    }
    if shown === tab { release() }
    if tab.view.superview === self { tab.view.removeFromSuperview() }
    if shown === tab {
      shown = nil
      setDevTools(nil)
    }
  }

  // MARK: Switching

  /// The page a switch left: it stays on screen, under the page switched to, until that one has drawn. A hidden
  /// page has no compositor and shows only its background colour for a frame or more after it's shown, and the
  /// page left loses its content as soon as it's hidden, so hiding one and showing the other at once flashes blank.
  private var leaving: RayCoreTab?
  private var firstFrame: PageFrameWatch?
  private var releaseLink: CADisplayLink?
  private var switchGeneration = 0

  func show(_ tab: RayCoreTab) {
    attach(tab)
    let previous = shown
    guard previous !== tab else { return }
    // What the screen shows now: the page an unfinished switch is still holding (its new page hasn't drawn), else
    // the one shown.
    let held = firstFrame != nil ? leaving : nil
    let onScreen = held ?? previous.flatMap { $0.view.superview === self && !$0.view.isHidden ? $0 : nil }
    #if RAY_TEST_HOOKS
    sampleSwitch(from: onScreen, to: tab)
    #endif
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    // The page that isn't on screen goes at once: a switch's new page that never drew, or the page a switch that
    // just finished is about to hide.
    if held != nil, let previous, previous !== tab { hide(previous) }
    if held == nil, let leaving, leaving !== tab { hide(leaving) }
    stopSwitch()
    leaving = nil
    shown = tab
    updateBackground()
    // A page still visible (the one an unfinished switch was holding) has its compositor and its frame.
    let drawn = !tab.view.isHidden
    tab.view.alphaValue = 1
    tab.view.isHidden = false
    tab.noteShown(byHost: true)
    hideGeneration[tab.tabId, default: 0] += 1
    bringToFront(tab.view)
    if let onScreen, onScreen !== tab {
      hold(onScreen, until: tab, drawn: drawn)
    }
    setDevTools(tab.devToolsView)
    layoutPages()
    CATransaction.commit()
    updateProgress(for: tab)
  }

  func showNothing() {
    stopSwitch()
    if let leaving { hide(leaving) }
    leaving = nil
    if let shown, shown.view.superview === self {
      shown.view.alphaValue = 1
      hide(shown)
    }
    shown = nil
    setDevTools(nil)
    updateProgressHidden()
    updateBackground()
  }

  /// Keeps `old` on screen while `new` (on top, transparent) makes its first frame.
  private func hold(_ old: RayCoreTab, until new: RayCoreTab, drawn: Bool) {
    // Only a window on screen draws: elsewhere Chrome makes no frames, and nothing would show the switch anyway.
    guard window?.occlusionState.contains(.visible) == true else {
      hide(old)
      return
    }
    leaving = old
    if drawn {
      newPageDrew()
    } else if let watch = PageFrameWatch(page: new.view, onFrame: { [weak self] in self?.newPageDrew() }) {
      firstFrame = watch
      new.view.alphaValue = 0
    } else {
      leaving = nil
      hide(old)
      return
    }
    // A page that never draws (its renderer gone, a window moved off screen) mustn't keep the old one up.
    let generation = switchGeneration
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
      guard let self, self.switchGeneration == generation else { return }
      self.release()
    }
  }

  /// The new page has its frame: it shows in the same commit as the layer that carries the frame. The old page is
  /// hidden a display frame later, once that commit is on screen: hiding drops its content in the GPU process at
  /// once, which could otherwise reach the screen before the new page does.
  private func newPageDrew() {
    firstFrame = nil
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    shown?.view.alphaValue = 1
    CATransaction.commit()
    let link = displayLink(target: self, selector: #selector(releaseAfterFrame(_:)))
    link.add(to: .main, forMode: .common)
    releaseLink = link
  }

  @objc private func releaseAfterFrame(_ link: CADisplayLink) { release() }

  /// Ends the switch: the new page shows (if it hasn't yet) and the old one is hidden.
  private func release() {
    let old = leaving
    stopSwitch()
    leaving = nil
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    shown?.view.alphaValue = 1
    if let old, old !== shown { hide(old) }
    CATransaction.commit()
  }

  private func stopSwitch() {
    switchGeneration += 1
    firstFrame?.stop()
    firstFrame = nil
    releaseLink?.invalidate()
    releaseLink = nil
  }

  private func hide(_ tab: RayCoreTab) {
    guard tab.view.superview === self else { return }
    tab.view.alphaValue = 1
    tab.view.isHidden = true
    noteHiddenLater(tab)
  }

  /// The shown page goes above the others (without leaving the view tree, which Chrome would see as hide and show),
  /// so it covers the page left as soon as it draws, and takes the clicks.
  private func bringToFront(_ page: NSView) {
    guard subviews.last(where: { $0 !== devTools }) !== page else { return }
    let context = Unmanaged.passUnretained(page).toOpaque()
    sortSubviews({ a, b, context in
      let page = Unmanaged<NSView>.fromOpaque(context!).takeUnretainedValue()
      return a === page ? .orderedDescending : b === page ? .orderedAscending : .orderedSame
    }, context: context)
  }

  private func updateBackground() {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    let empty = dark ? NSColor(white: 0.165, alpha: 1) : NSColor(white: 0.96, alpha: 1)
    layer?.backgroundColor = (shown == nil ? empty : NSColor.white).cgColor
    CATransaction.commit()
  }

  private func updateProgressHidden() {
    progressLayer.opacity = 0
  }

  func setDevTools(_ view: NSView?) {
    if devTools !== view {
      devTools?.removeFromSuperview()
      devTools = view
      if let view {
        view.removeFromSuperview()
        if let page = shown?.view, page.superview === self {
          addSubview(view, positioned: .below, relativeTo: page)
        } else {
          addSubview(view, positioned: .below, relativeTo: nil)
        }
      }
    }
    layoutPages()
  }

  override func layout() {
    super.layout()
    layoutPages()
  }

  private func layoutPages() {
    var pageFrame = bounds
    if let tab = shown, let devTools, devTools.superview === self {
      var devToolsFrame = NSRect.zero
      tab.devToolsLayout(for: bounds.size, devTools: &devToolsFrame, page: &pageFrame)
      devTools.frame = devToolsFrame
    }
    for case let page in subviews where page !== devTools {
      page.frame = page === shown?.view ? pageFrame : bounds
    }
    let progressFrame = progressLayer.frame
    progressLayer.frame = NSRect(x: 0, y: 0, width: progressFrame.width, height: 2)
  }

  /// The page's own thin load line, for when the address bar above the page (which shows the load itself) is off.
  var showsProgress = true {
    didSet {
      guard !showsProgress, oldValue else { return }
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      progressLayer.opacity = 0
      CATransaction.commit()
    }
  }
  var progressShown: Bool { progressLayer.opacity > 0 }

  /// The profile's colour changed: the line takes it up.
  func refreshAccent() {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    effectiveAppearance.performAsCurrentDrawingAppearance { progressLayer.backgroundColor = ProfileColor.accent.cgColor }
    CATransaction.commit()
  }

  /// For tests: the line's colour as `#RRGGBB`.
  var progressColor: String {
    progressLayer.backgroundColor.flatMap { NSColor(cgColor: $0) }.map { ProfileColor.hex(of: $0) } ?? ""
  }

  func updateProgress(for tab: RayCoreTab) {
    guard tab === shown else { return }
    CATransaction.begin()
    CATransaction.setAnimationDuration(0.2)
    effectiveAppearance.performAsCurrentDrawingAppearance { progressLayer.backgroundColor = ProfileColor.accent.cgColor }
    if tab.loading && showsProgress {
      progressLayer.opacity = 1
      progressLayer.frame.size.width = bounds.width * CGFloat(max(0.1, tab.progress))
    } else {
      progressLayer.frame.size.width = bounds.width
      progressLayer.opacity = 0
    }
    CATransaction.commit()
  }

  #if RAY_TEST_HOOKS
  // MARK: Switch sampling (tests)

  private var sampler: SwitchSampler?
  /// The last switches' frames, newest last (`SwitchSampler`).
  private var switches: [[String: Any]] = []
  private var switchCount = 0

  private func sampleSwitch(from previous: RayCoreTab?, to tab: RayCoreTab) {
    sampler?.finish()
    guard let previous, previous.view.superview === self, !previous.view.isHidden else { return }
    switchCount += 1
    let number = switchCount
    sampler = SwitchSampler(container: self, from: previous, to: tab) { [weak self] record in
      guard let self else { return }
      var record = record
      record["n"] = number
      self.switches = Array((self.switches + [record]).suffix(20))
      self.sampler = nil
    }
  }
  #endif

  private func noteHiddenLater(_ tab: RayCoreTab) {
    let generation = hideGeneration[tab.tabId, default: 0]
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self, weak tab] in
      guard let self, let tab, !tab.closed, tab !== self.shown,
            self.hideGeneration[tab.tabId, default: 0] == generation else { return }
      tab.noteShown(byHost: false)
    }
  }
}
