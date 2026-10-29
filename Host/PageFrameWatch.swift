import AppKit
import QuartzCore

/// Tells when a page that was just shown has drawn. A hidden page has no compositor (Chrome's BrowserCompositorMac
/// drops it on hide and makes a new one on show), so its first frame after showing arrives as a new content layer
/// (`DisplayCALayerTree`: a CALayerHost, or an IOSurface layer in software) under the render view's flipped layer,
/// added on the main thread once the GPU has the frame. Until then the page shows only its background colour.
final class PageFrameWatch: NSObject {
  private var observed: [(layer: CALayer, key: String)] = []
  private var known: Set<ObjectIdentifier> = []
  private weak var root: CALayer?
  private var onFrame: (() -> Void)?
  private(set) var drew = false

  /// Nil when the page has no render view (a tab that hasn't made one yet): there is nothing to wait for.
  init?(page: NSView, onFrame: @escaping () -> Void) {
    guard let render = Self.renderView(in: page), let root = render.layer else { return nil }
    self.onFrame = onFrame
    self.root = root
    super.init()
    observe(root, "sublayers")
    for tree in root.sublayers ?? [] { watch(tree) }
  }

  deinit { stop() }

  static func renderView(in page: NSView) -> NSView? {
    page.subviews.first { String(describing: type(of: $0)) == "RenderWidgetHostViewCocoa" }
  }

  func stop() {
    for (layer, key) in observed { layer.removeObserver(self, forKeyPath: key) }
    observed = []
    onFrame = nil
  }

  private func observe(_ layer: CALayer, _ key: String) {
    layer.addObserver(self, forKeyPath: key, options: [], context: nil)
    observed.append((layer, key))
  }

  /// One of the render view's layer trees: its content layers so far are stale (a compositor that is gone).
  private func watch(_ tree: CALayer) {
    known.insert(ObjectIdentifier(tree))
    observe(tree, "sublayers")
    for content in tree.sublayers ?? [] {
      known.insert(ObjectIdentifier(content))
      // The software path keeps its layer and swaps the surface in it.
      if !content.className.contains("LayerHost") { observe(content, "contents") }
    }
  }

  override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?,
                             context: UnsafeMutableRawPointer?) {
    guard !drew, let layer = object as? CALayer else { return }
    if keyPath == "contents" {
      guard layer.contents != nil else { return }
    } else if layer === root {
      // The display came back with a new tree: watch it for its first frame.
      for tree in layer.sublayers ?? [] where !known.contains(ObjectIdentifier(tree)) { watch(tree) }
      return
    } else {
      guard (layer.sublayers ?? []).contains(where: { !known.contains(ObjectIdentifier($0)) }) else { return }
    }
    drew = true
    let done = onFrame
    stop()
    done?()
  }
}

#if RAY_TEST_HOOKS
/// For tests: what each display frame of a tab switch showed in the page area. `o` the page left, `n` the page
/// switched to (once it has drawn), `b` both, `-` neither (a blank frame: only a background colour). The
/// `switch-no-blank` check reads these from the state log.
final class SwitchSampler: NSObject {
  private weak var container: NSView?
  private weak var old: RayCoreTab?
  private weak var new: RayCoreTab?
  private var watch: PageFrameWatch?
  private var link: CADisplayLink?
  private var frames = ""
  private var drewAt: Int?
  private let done: ([String: Any]) -> Void

  init(container: NSView, from old: RayCoreTab, to new: RayCoreTab, done: @escaping ([String: Any]) -> Void) {
    self.container = container
    self.old = old
    self.new = new
    self.done = done
    super.init()
    watch = PageFrameWatch(page: new.view) { [weak self] in
      guard let self else { return }
      self.drewAt = self.frames.count
    }
    let link = container.displayLink(target: self, selector: #selector(tick(_:)))
    link.add(to: .main, forMode: .common)
    self.link = link
  }

  private func onScreen(_ tab: RayCoreTab?) -> Bool {
    guard let page = tab?.view, page.superview === container else { return false }
    return !page.isHidden && page.alphaValue > 0
  }

  @objc private func tick(_ link: CADisplayLink) {
    let oldShows = onScreen(old)
    let newShows = onScreen(new) && (watch == nil || watch?.drew == true)
    frames += oldShows && newShows ? "b" : oldShows ? "o" : newShows ? "n" : "-"
    // Settled: the new page alone for two frames, or long enough to give up.
    if frames.hasSuffix("nn") || frames.count >= 60 { finish() }
  }

  func finish() {
    guard let link else { return }
    link.invalidate()
    self.link = nil
    watch?.stop()
    done(["frames": frames, "blankFrames": frames.filter { $0 == "-" }.count, "drewAt": drewAt ?? NSNull(),
          "watched": watch != nil])
  }
}
#endif
