import AppKit

/// Site permission requests (camera, location, notifications, …). Following the security checklist: a request
/// shows only over its own tab, names the full origin, ignores clicks for its first half second every time it
/// appears, never allows by default (Escape only dismisses), and Block / Allow are remembered for the site.
final class PermissionPrompts {
  struct Request {
    let id: String
    let origin: String
    let kinds: [String]
    weak var tab: ArdiaCoreTab?
  }

  private var queue: [Request] = []
  private var view: PermissionPromptView?
  var onChange: (() -> Void)?
  /// Where the prompt goes (top left of the page card) and the tab shown there.
  var host: (() -> (parent: NSView, frame: NSRect, activeTab: ArdiaCoreTab?))?

  func add(_ request: [String: Any], tab: ArdiaCoreTab) {
    guard let id = request["id"] as? String, let origin = request["origin"] as? String else { return }
    queue.append(Request(id: id, origin: origin, kinds: request["permissions"] as? [String] ?? [], tab: tab))
    update()
  }

  func dismissed(_ id: String) {
    queue.removeAll { $0.id == id }
    update()
  }

  /// Shows the active tab's first request, or nothing; call when tabs switch or the layout moves.
  func update() {
    queue.removeAll { $0.tab == nil || $0.tab?.closed == true }
    guard let host = host?(), let request = queue.first(where: { $0.tab === host.activeTab && $0.tab != nil }) else {
      view?.removeFromSuperview()
      view = nil
      onChange?()
      return
    }
    if view?.request?.id != request.id || view?.superview !== host.parent {
      view?.removeFromSuperview()
      let prompt = PermissionPromptView(request: request)
      prompt.onAnswer = { [weak self] result, remember in self?.answer(request.id, result, remember: remember) }
      host.parent.addSubview(prompt)
      view = prompt
    }
    let size = view!.fittingSize
    view!.frame = NSRect(x: host.frame.minX + 12, y: host.frame.maxY - size.height - 12, width: size.width, height: size.height)
    onChange?()
  }

  private func answer(_ id: String, _ result: String, remember: Bool) {
    queue.removeAll { $0.id == id }
    ArdiaCoreEngine.resolvePermission(id, result: result, remember: remember)
    update()
  }

  /// For tests: the prompt on screen and answering it the way a click (or Escape) would.
  var shown: [String: Any]? {
    view.flatMap { view in view.request.map { ["origin": $0.origin, "kinds": $0.kinds, "ready": view.ready] } }
  }

  func press(_ choice: String) -> Bool { view?.press(choice) ?? false }
}

final class PermissionPromptView: NSView {
  private(set) var request: PermissionPrompts.Request?
  var onAnswer: ((_ result: String, _ remember: Bool) -> Void)?
  private let stack = NSStackView()
  private let block = NSButton(title: "Block", target: nil, action: nil)
  private let allow = NSButton(title: "Allow", target: nil, action: nil)
  private(set) var ready = false

  init(request: PermissionPrompts.Request) {
    self.request = request
    super.init(frame: .zero)
    wantsLayer = true
    layer?.cornerRadius = 12
    layer?.cornerCurve = .continuous
    layer?.borderWidth = 1
    layer?.shadowOpacity = 0.2
    layer?.shadowRadius = 10
    layer?.shadowOffset = CGSize(width: 0, height: -3)

    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 8
    stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
      stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
      widthAnchor.constraint(equalToConstant: 300),
    ])

    let origin = NSTextField(wrappingLabelWithString: "\(Self.display(request.origin)) wants to:")
    origin.font = .systemFont(ofSize: 13, weight: .semibold)
    origin.preferredMaxLayoutWidth = 268
    origin.lineBreakMode = .byCharWrapping
    stack.addArrangedSubview(origin)
    for kind in request.kinds.isEmpty ? ["unknown"] : request.kinds {
      let row = NSStackView()
      row.spacing = 8
      let icon = NSImageView(image: NSImage(systemSymbolName: Self.symbol(kind), accessibilityDescription: nil) ?? NSImage())
      icon.symbolConfiguration = .init(pointSize: 12, weight: .medium)
      icon.contentTintColor = .secondaryLabelColor
      let label = NSTextField(labelWithString: Self.describe(kind))
      label.font = .systemFont(ofSize: 13)
      row.addArrangedSubview(icon)
      row.addArrangedSubview(label)
      stack.addArrangedSubview(row)
    }
    let buttons = NSStackView(views: [block, allow])
    buttons.spacing = 8
    for button in [block, allow] {
      button.bezelStyle = .rounded
      button.target = self
      button.isEnabled = false
      // Neither is the default button: Return does nothing, Escape dismisses.
      button.keyEquivalent = ""
    }
    block.action = #selector(blockClicked)
    allow.action = #selector(allowClicked)
    stack.addArrangedSubview(buttons)
    stack.setCustomSpacing(12, after: stack.arrangedSubviews[stack.arrangedSubviews.count - 2])
  }

  required init?(coder: NSCoder) { fatalError() }

  override var wantsUpdateLayer: Bool { true }
  override var mouseDownCanMoveWindow: Bool { false }

  override func updateLayer() {
    layer?.backgroundColor = SidebarColors.background.cgColor
    layer?.borderColor = NSColor.separatorColor.cgColor
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guard window != nil else { return }
    // Every time the prompt appears its buttons wait half a second, so a click meant for the page can't land on it.
    ready = false
    block.isEnabled = false
    allow.isEnabled = false
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
      guard let self, self.window != nil else { return }
      self.ready = true
      self.block.isEnabled = true
      self.allow.isEnabled = true
    }
  }

  override func cancelOperation(_ sender: Any?) { onAnswer?("dismiss", false) }

  @objc private func blockClicked() { onAnswer?("deny", true) }
  @objc private func allowClicked() { onAnswer?("accept", true) }

  func press(_ choice: String) -> Bool {
    switch choice {
    case "dismiss":
      onAnswer?("dismiss", false)
      return true
    case "allow", "block":
      let button = choice == "allow" ? allow : block
      guard button.isEnabled else { return false }
      button.performClick(nil)
      return true
    default:
      return false
    }
  }

  /// The origin in full (scheme, host and any port), never the page's own words.
  static func display(_ origin: String) -> String {
    guard let components = URLComponents(string: origin), let scheme = components.scheme, let host = components.host else {
      return origin
    }
    return "\(scheme)://\(host)" + (components.port.map { ":\($0)" } ?? "")
  }

  private static func describe(_ kind: String) -> String {
    switch kind {
    case "camera": return "Use your camera"
    case "microphone": return "Use your microphone"
    case "cameraPanTiltZoom": return "Move your camera"
    case "location": return "Know your location"
    case "notifications": return "Show notifications"
    case "clipboard": return "See text and images you copy"
    case "midi": return "Use your MIDI devices"
    case "multipleDownloads": return "Download multiple files"
    case "localFonts": return "Use the fonts on your Mac"
    case "idleDetection": return "Know when you're using your Mac"
    case "storageAccess": return "Use info it saved about you"
    case "windowManagement": return "Manage windows on your displays"
    case "fileSystem": return "Edit files on your Mac"
    case "keyboardLock": return "Take over your keyboard"
    case "pointerLock": return "Take over your pointer"
    case "protocolHandler": return "Open a type of link"
    case "sensors": return "Use your device's motion sensors"
    case "localNetwork": return "Find devices on your local network"
    case "vr", "ar", "handTracking": return "Use virtual reality devices"
    case "identityProvider": return "Sign you in with another site"
    case "webAppInstallation": return "Install a web app"
    case "capturedSurfaceControl": return "Scroll and zoom a tab you share"
    case "diskQuota": return "Store data on your Mac"
    default: return "Use a feature of your Mac"
    }
  }

  private static func symbol(_ kind: String) -> String {
    switch kind {
    case "camera", "cameraPanTiltZoom": return "video.fill"
    case "microphone": return "mic.fill"
    case "location": return "location.fill"
    case "notifications": return "bell.fill"
    case "clipboard": return "doc.on.clipboard"
    case "multipleDownloads": return "arrow.down.circle"
    case "windowManagement": return "macwindow.on.rectangle"
    case "fileSystem": return "folder"
    case "keyboardLock": return "keyboard"
    case "pointerLock": return "cursorarrow"
    case "localNetwork": return "network"
    default: return "hand.raised.fill"
    }
  }
}
