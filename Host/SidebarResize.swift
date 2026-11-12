import AppKit
import QuartzCore

/// The sidebar's width: dragged at its edge (`SidebarResizeHandle`), one for every window and remembered in
/// Settings.json (`RaySettings.sidebarWidth`). Owner's pick of `docs/mocks/sidebar-resize.html` (2026-11-12): Arc's
/// look, nothing drawn and only the cursor changing, with Ardia's rubber band at the limits.
enum SidebarWidth {
  static let standard = SidebarView.width
  /// Under this the top row's buttons meet: the sidebar button ends at 120, back begins 110 from the right edge.
  static let minimum: CGFloat = 240
  static let maximum: CGFloat = 480
  /// What the page always keeps, so a narrow window lowers the maximum (never under the minimum).
  static let pageMinimum: CGFloat = 400
  /// Ardia's rubber band (`useResizeDrag.ts`): at most 36 pt past a limit, approached over about 90 pt of pulling.
  static let band: CGFloat = 36
  static let bandScale: CGFloat = 90

  static func limits(windowWidth: CGFloat) -> ClosedRange<CGFloat> {
    minimum...max(minimum, min(maximum, (windowWidth - pageMinimum).rounded(.down)))
  }

  static func clamp(_ width: CGFloat, windowWidth: CGFloat) -> CGFloat {
    let limits = limits(windowWidth: windowWidth)
    return min(max(width.isFinite ? width : standard, limits.lowerBound), limits.upperBound).rounded()
  }

  /// Where the edge shows for a drag that asks for `width`: past a limit it follows less and less.
  static func stretched(_ width: CGFloat, windowWidth: CGFloat) -> CGFloat {
    let limits = limits(windowWidth: windowWidth)
    func stretch(_ over: CGFloat) -> CGFloat { band * (1 - exp(-over / bandScale)) }
    if width > limits.upperBound { return limits.upperBound + stretch(width - limits.upperBound) }
    if width < limits.lowerBound { return limits.lowerBound - stretch(limits.lowerBound - width) }
    return width
  }

  /// The drag that shows `width` (a press on an edge still springing back goes on from where it is).
  static func unstretched(_ width: CGFloat, windowWidth: CGFloat) -> CGFloat {
    let limits = limits(windowWidth: windowWidth)
    func pull(_ stretch: CGFloat) -> CGFloat { -bandScale * log(1 - min(stretch, band - 0.01) / band) }
    if width > limits.upperBound { return limits.upperBound + pull(width - limits.upperBound) }
    if width < limits.lowerBound { return limits.lowerBound - pull(limits.lowerBound - width) }
    return width
  }

  /// A saved width: a number within the limits, else nothing (the standard width).
  static func saved(_ json: Any?) -> CGFloat? {
    guard let number = json as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
    let width = CGFloat(number.doubleValue)
    guard width.isFinite else { return nil }
    return min(max(width, minimum), maximum).rounded()
  }
}

/// The strip on the sidebar's edge that drags its width: nothing drawn, a resize cursor, 6 pt of the sidebar's empty
/// gutter and 2 pt of the page's edge. A double click goes back to the standard width.
final class SidebarResizeHandle: NSView {
  static let inside: CGFloat = 6
  static let outside: CGFloat = 2

  var onBegin: (() -> Void)?
  /// How far the pointer is from where it pressed.
  var onDrag: ((CGFloat) -> Void)?
  var onEnd: (() -> Void)?
  var onDoubleClick: (() -> Void)?
  /// Scrolling over the strip scrolls what's under it (the sidebar's list).
  var onScroll: ((NSEvent) -> Void)?
  /// For tests: how often the strip set its cursor.
  private(set) var cursorSets = 0
  private var pressX: CGFloat?
  private var area: NSTrackingArea?

  override var mouseDownCanMoveWindow: Bool { false }

  // The cursor: a cursor rect, and set again as the pointer moves, since the page under the strip's outer 2 pt
  // sets its own.
  override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let area { removeTrackingArea(area) }
    let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .activeInKeyWindow, .inVisibleRect],
                              owner: self)
    addTrackingArea(area)
    self.area = area
  }

  private func setCursor() {
    NSCursor.resizeLeftRight.set()
    cursorSets += 1
  }

  override func cursorUpdate(with event: NSEvent) { setCursor() }
  override func mouseEntered(with event: NSEvent) { setCursor() }
  override func mouseMoved(with event: NSEvent) { setCursor() }

  override func mouseDown(with event: NSEvent) {
    if event.clickCount == 2 {
      release()
      return doubleClick()
    }
    press(at: event.locationInWindow.x)
  }

  override func mouseDragged(with event: NSEvent) {
    setCursor()
    drag(to: event.locationInWindow.x)
  }

  override func mouseUp(with event: NSEvent) { release() }

  override func scrollWheel(with event: NSEvent) { onScroll?(event) }

  // What the mouse does, and tests do through `sidebarwidth`.

  func press(at x: CGFloat) {
    guard pressX == nil else { return }
    pressX = x
    onBegin?()
  }

  func drag(to x: CGFloat) {
    guard let pressX else { return }
    onDrag?(x - pressX)
  }

  func release() {
    guard pressX != nil else { return }
    pressX = nil
    onEnd?()
  }

  func doubleClick() { onDoubleClick?() }
}

#if RAY_TEST_HOOKS
/// For tests: the edge moved one step per display frame, as a drag does, timing each step's layout and the frames.
final class SidebarResizeSweep: NSObject {
  private var link: CADisplayLink?
  private var frame = 0
  private var last: CFTimeInterval = 0
  private var layouts: [Double] = []
  private var intervals: [Double] = []
  private let frames: Int
  private let step: (CGFloat) -> Void
  private let done: ([String: Any]) -> Void

  /// `step` gets 0…1 and back to 0 over `frames` frames; `done` gets the numbers.
  init(frames: Int, step: @escaping (CGFloat) -> Void, done: @escaping ([String: Any]) -> Void) {
    self.frames = max(2, frames)
    self.step = step
    self.done = done
  }

  func start(in view: NSView) {
    let link = view.displayLink(target: self, selector: #selector(tick(_:)))
    link.add(to: .main, forMode: .common)
    self.link = link
  }

  @objc private func tick(_ link: CADisplayLink) {
    if last > 0 { intervals.append((link.timestamp - last) * 1000) }
    last = link.timestamp
    let along = CGFloat(frame) / CGFloat(frames - 1)
    let began = CACurrentMediaTime()
    step(1 - abs(along * 2 - 1))
    layouts.append((CACurrentMediaTime() - began) * 1000)
    frame += 1
    guard frame >= frames else { return }
    link.invalidate()
    self.link = nil
    let sorted = intervals.sorted()
    let median = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
    done([
      "frames": frames,
      "layoutMsMax": (layouts.max() ?? 0), "layoutMsMean": layouts.reduce(0, +) / Double(max(1, layouts.count)),
      "frameMsMedian": median, "frameMsMax": sorted.last ?? 0,
      // A frame that took over one and a half of the usual interval: a dropped frame.
      "longFrames": intervals.filter { median > 0 && $0 > median * 1.5 }.count,
    ])
  }
}
#endif
