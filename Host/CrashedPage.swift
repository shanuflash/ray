import AppKit

// A tab whose page crashed (`rendererGone`): Ray's own view in the page's place, "This page crashed" with Reload
// (docs/mocks/page-prompts.html, look A); Return does nothing, as in Ray's other page prompts. Out of memory and a second crash within 10 s (Chrome's rule) get their own
// words. A tab that lost its page while it wasn't shown (macOS short of memory, say) reloads when it's next shown, as
// Crest does and as a sleeping tab would, with no view.

final class CrashedPages {
  struct Crash {
    /// The engine's word: crashed, killed, oom, launchFailed, evicted, …
    let status: String
    let code: Int
    let at: Date
    /// A second crash within 10 s of the last.
    let again: Bool
  }

  private weak var controller: BrowserWindowController?
  /// Tabs whose page is gone, shown with the view.
  private var crashed: [ObjectIdentifier: (tab: RayCoreTab?, crash: Crash)] = [:]
  /// When each tab's page last crashed, for "keeps crashing".
  private var lastCrash: [ObjectIdentifier: Date] = [:]
  /// Tabs that lost their page while hidden: they reload when shown.
  private var reloadOnShow: Set<ObjectIdentifier> = []
  private(set) var view: CrashedPageView?
  private(set) var last: [String: Any]?
  var onChange: (() -> Void)?

  init(controller: BrowserWindowController) {
    self.controller = controller
  }

  func rendererGone(_ tab: RayCoreTab, status: String, code: Int) {
    guard let controller, !AppController.shared.quitting else { return }
    let key = ObjectIdentifier(tab)
    let now = Date()
    let again = lastCrash[key].map { now.timeIntervalSince($0) < 10 } ?? false
    lastCrash[key] = now
    if tab === controller.activeTab {
      crashed[key] = (tab, Crash(status: status, code: code, at: now, again: again))
      last = ["status": status, "code": code, "shown": true]
    } else {
      reloadOnShow.insert(key)
      last = ["status": status, "code": code, "shown": false]
    }
    update()
  }

  /// A load started in the tab (Reload, a new address): its page is back.
  func loading(_ tab: RayCoreTab) {
    guard tab.loading else { return }
    let key = ObjectIdentifier(tab)
    reloadOnShow.remove(key)
    guard crashed.removeValue(forKey: key) != nil else { return }
    update()
  }

  /// Tabs switched: the view follows the active tab; one that lost its page in the background reloads now.
  func tabSwitched() {
    if let tab = controller?.activeTab, reloadOnShow.remove(ObjectIdentifier(tab)) != nil {
      tab.reload()
      last = (last ?? [:]).merging(["reloadedOnShow": true]) { $1 }
    }
    update()
  }

  func update() {
    crashed = crashed.filter { $0.value.tab != nil && $0.value.tab?.closed == false }
    guard let controller, let tab = controller.activeTab, let crash = crashed[ObjectIdentifier(tab)]?.crash else {
      view?.removeFromSuperview()
      view = nil
      onChange?()
      return
    }
    if view == nil {
      let made = CrashedPageView()
      made.onReload = { [weak self, weak tab] in self?.reload(tab) }
      view = made
    }
    view?.show(crash)
    controller.placeCrashedPage(view!)
    onChange?()
  }

  private func reload(_ tab: RayCoreTab?) {
    guard let tab else { return }
    crashed.removeValue(forKey: ObjectIdentifier(tab))
    tab.reload()
    last = (last ?? [:]).merging(["reloaded": true]) { $1 }
    update()
  }

  var state: [String: Any] {
    var shown: Any = NSNull()
    if let view, view.superview != nil { shown = ["title": view.title.stringValue, "message": view.message.stringValue] }
    return ["shown": shown, "waitingToReload": reloadOnShow.count, "last": last ?? NSNull()]
  }

  /// `crashed reload`: Reload, as a click.
  func test(_ argument: String) -> String {
    guard argument == "reload" else { return "usage: crashed reload" }
    guard let view, view.superview != nil else { return "no crashed page" }
    view.reloadButton.performClick(nil)
    return "ok"
  }
}

/// The crashed page's view: a page with nothing but a glyph, a title, a grey line and Reload, in the card colour.
final class CrashedPageView: NSView {
  let title = NSTextField(labelWithString: "")
  let message = NSTextField(labelWithString: "")
  let reloadButton = PanelButton(title: "Reload", primary: true)
  private let glyph = NSImageView()
  var onReload: (() -> Void)?

  init() {
    super.init(frame: .zero)
    wantsLayer = true
    layer?.cornerRadius = PageContainerView.radius
    layer?.cornerCurve = .continuous
    layer?.masksToBounds = true
    glyph.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)?
      .withSymbolConfiguration(.init(pointSize: 34, weight: .light))
    glyph.contentTintColor = .secondaryLabelColor
    // A page-sized heading (Settings' pane titles), then body text.
    title.font = .systemFont(ofSize: 22, weight: .medium)
    message.font = .systemFont(ofSize: 13)
    message.textColor = .secondaryLabelColor
    for label in [title, message] {
      label.alignment = .center
      label.isSelectable = false
    }
    reloadButton.onClick = { [weak self] in self?.onReload?() }
    [glyph, title, message, reloadButton].forEach(addSubview)
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }
  override var wantsUpdateLayer: Bool { true }
  override var mouseDownCanMoveWindow: Bool { false }

  override func updateLayer() {
    layer?.backgroundColor = SurfaceBackdrop.solidFill.cgColor
  }

  func show(_ crash: CrashedPages.Crash) {
    switch (crash.again, crash.status) {
    case (true, _):
      title.stringValue = "This page keeps crashing"
      message.stringValue = "Close other tabs or apps, then reload."
    case (false, "oom"):
      title.stringValue = "This page ran out of memory"
      message.stringValue = "Close some tabs, then reload."
    default:
      title.stringValue = "This page crashed"
      message.stringValue = "Reload to try again."
    }
    needsLayout = true
  }

  override func layout() {
    super.layout()
    let glyphSize: CGFloat = 44
    let titleHeight = ceil(title.intrinsicContentSize.height)
    let messageHeight = ceil(message.intrinsicContentSize.height)
    let buttonSize = reloadButton.intrinsicContentSize
    let total = glyphSize + 14 + titleHeight + 4 + messageHeight + 16 + buttonSize.height
    var y = ((bounds.height - total) / 2).rounded()
    glyph.frame = NSRect(x: ((bounds.width - glyphSize) / 2).rounded(), y: y, width: glyphSize, height: glyphSize)
    y += glyphSize + 14
    let width = min(bounds.width - 32, 360)
    let x = ((bounds.width - width) / 2).rounded()
    title.frame = NSRect(x: x, y: y, width: width, height: titleHeight)
    y += titleHeight + 4
    message.frame = NSRect(x: x, y: y, width: width, height: messageHeight)
    y += messageHeight + 16
    reloadButton.frame = NSRect(x: ((bounds.width - buttonSize.width) / 2).rounded(), y: y,
                                width: buttonSize.width, height: buttonSize.height)
  }
}
