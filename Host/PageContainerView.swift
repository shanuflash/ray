import AppKit

final class PageContainerView: NSView {
  private(set) var shown: ArdiaCoreTab?
  private var devTools: NSView?
  private var hideGeneration: [Int32: Int] = [:]
  private let progressLayer = CALayer()

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.cornerRadius = 10
    layer?.cornerCurve = .continuous
    layer?.masksToBounds = true
    layer?.backgroundColor = NSColor.white.cgColor
    progressLayer.backgroundColor = NSColor.controlAccentColor.cgColor
    progressLayer.opacity = 0
    progressLayer.zPosition = 10
    layer?.addSublayer(progressLayer)
  }

  required init?(coder: NSCoder) { fatalError() }

  func attach(_ tab: ArdiaCoreTab) {
    let page = tab.view
    guard page.superview !== self else { return }
    page.removeFromSuperview()
    page.isHidden = tab !== shown
    page.frame = bounds
    addSubview(page, positioned: .below, relativeTo: nil)
  }

  func detach(_ tab: ArdiaCoreTab) {
    if tab.view.superview === self { tab.view.removeFromSuperview() }
    if shown === tab {
      shown = nil
      setDevTools(nil)
    }
  }

  func show(_ tab: ArdiaCoreTab) {
    attach(tab)
    let previous = shown
    guard previous !== tab else { return }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    shown = tab
    tab.view.isHidden = false
    tab.noteShown(byHost: true)
    hideGeneration[tab.tabId, default: 0] += 1
    if let previous, previous.view.superview === self {
      previous.view.isHidden = true
      noteHiddenLater(previous)
    }
    setDevTools(tab.devToolsView)
    layoutPages()
    CATransaction.commit()
    updateProgress(for: tab)
  }

  func setDevTools(_ view: NSView?) {
    if devTools !== view {
      devTools?.removeFromSuperview()
      devTools = view
      if let view {
        view.removeFromSuperview()
        addSubview(view)
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
    progressLayer.frame = NSRect(x: 0, y: bounds.height - 2, width: progressFrame.width, height: 2)
  }

  func updateProgress(for tab: ArdiaCoreTab) {
    guard tab === shown else { return }
    CATransaction.begin()
    CATransaction.setAnimationDuration(0.2)
    if tab.loading {
      progressLayer.opacity = 1
      progressLayer.frame.size.width = bounds.width * CGFloat(max(0.1, tab.progress))
    } else {
      progressLayer.frame.size.width = bounds.width
      progressLayer.opacity = 0
    }
    CATransaction.commit()
  }

  private func noteHiddenLater(_ tab: ArdiaCoreTab) {
    let generation = hideGeneration[tab.tabId, default: 0]
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self, weak tab] in
      guard let self, let tab, !tab.closed, tab !== self.shown,
            self.hideGeneration[tab.tabId, default: 0] == generation else { return }
      tab.noteShown(byHost: false)
    }
  }
}
