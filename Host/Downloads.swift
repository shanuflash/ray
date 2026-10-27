import AppKit

/// A profile's downloads, kept current from the engine's `downloads.*` events. A download Chrome holds as dangerous
/// or insecure waits for Keep or Discard.
final class DownloadsController {
  struct Item {
    let id: String
    let url: String
    let filename: String
    let path: String
    let state: String
    let paused: Bool
    let received: Double
    let total: Double
    let speed: Double
    let dangerous: Bool
    let error: String?

    init?(_ info: [String: Any]) {
      guard let id = info["id"] as? String else { return nil }
      self.id = id
      url = info["url"] as? String ?? ""
      let reported = info["filename"] as? String ?? ""
      // A download blocked before it got a name (an insecure one, say) is named from its URL.
      filename = reported.isEmpty ? (URL(string: url)?.lastPathComponent ?? "") : reported
      path = info["path"] as? String ?? ""
      state = info["state"] as? String ?? "downloading"
      paused = info["paused"] as? Bool ?? false
      received = info["received"] as? Double ?? 0
      total = info["total"] as? Double ?? -1
      speed = info["speed"] as? Double ?? 0
      dangerous = info["dangerous"] as? Bool ?? false
      error = info["error"] as? String
    }

    var active: Bool { state == "downloading" }
    var waiting: Bool { active && dangerous }
    var host: String { URLComponents(string: url)?.host ?? "" }
    var fraction: Double { total > 0 ? min(max(received / total, 0), 1) : 0 }
  }

  /// Newest first; only this session's downloads (the list starts empty, as Arc's does).
  private(set) var items: [Item] = []
  var onChange: ((_ newlyWaiting: Bool) -> Void)?
  private let profile: ArdiaCoreProfile

  init(profile: ArdiaCoreProfile) {
    self.profile = profile
    EngineEvents.on("downloads.changed") { [weak self] payload in
      guard let self, self.isOurs(payload), let item = (payload["download"] as? [String: Any]).flatMap(Item.init) else {
        return
      }
      let wasWaiting = self.items.first { $0.id == item.id }?.waiting ?? false
      if let index = self.items.firstIndex(where: { $0.id == item.id }) {
        self.items[index] = item
      } else {
        self.items.insert(item, at: 0)
      }
      self.onChange?(item.waiting && !wasWaiting)
    }
    EngineEvents.on("downloads.removed") { [weak self] payload in
      guard let self, self.isOurs(payload), let id = payload["id"] as? String else { return }
      self.items.removeAll { $0.id == id }
      self.onChange?(false)
    }
    // The engine starts watching downloads on its first downloads call.
    EngineCalls.call("ac_downloads_list", profile: profile) { _ in }
    if let folder = TestEnvironment["RAY_DOWNLOADS_DIR"] {
      EngineCalls.call("ac_downloads_set_settings", profile: profile,
                       args: ["folder": folder, "askWhereToSave": false]) { _ in }
    }
  }

  private func isOurs(_ payload: [String: Any]) -> Bool {
    (payload["profile"] as? String).map { $0 == profile.path } ?? true
  }

  func keep(_ id: String) { call("ac_downloads_keep", id) }
  func discard(_ id: String) { call("ac_downloads_cancel", id) }
  func cancel(_ id: String) { call("ac_downloads_cancel", id) }
  func pause(_ id: String) { call("ac_downloads_pause", id) }
  func resume(_ id: String) { call("ac_downloads_resume", id) }

  func reveal(_ id: String) {
    guard let item = items.first(where: { $0.id == id }), !item.path.isEmpty else { return }
    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
  }

  private func call(_ name: String, _ id: String) {
    EngineCalls.call(name, profile: profile, args: ["id": id]) { _ in }
  }
}

/// The list in the downloads popover: one row per download, newest first.
final class DownloadsListView: NSView {
  private let stack = NSStackView()
  private var rows: [String: DownloadRowView] = [:]
  weak var controller: DownloadsController?

  override init(frame: NSRect) {
    super.init(frame: frame)
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 2
    stack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
      stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }

  required init?(coder: NSCoder) { fatalError() }

  func show(_ items: [DownloadsController.Item]) {
    let shown = Array(items.prefix(8))
    for row in stack.arrangedSubviews { stack.removeArrangedSubview(row); row.removeFromSuperview() }
    var kept: [String: DownloadRowView] = [:]
    for item in shown {
      let row = rows[item.id] ?? DownloadRowView()
      row.controller = controller
      row.show(item)
      stack.addArrangedSubview(row)
      row.widthAnchor.constraint(equalToConstant: 320).isActive = true
      kept[item.id] = row
    }
    rows = kept
    if shown.isEmpty {
      let empty = NSTextField(labelWithString: "No downloads yet")
      empty.textColor = .secondaryLabelColor
      stack.addArrangedSubview(empty)
    }
  }

  func row(for id: String) -> DownloadRowView? { rows[id] }

  override var fittingSize: NSSize { stack.fittingSize }
}

final class DownloadRowView: NSView {
  weak var controller: DownloadsController?
  private let icon = NSImageView()
  private let name = NSTextField(labelWithString: "")
  private let status = NSTextField(labelWithString: "")
  private let progress = NSProgressIndicator()
  private let primary = NSButton()
  private let secondary = NSButton()
  private var item: DownloadsController.Item?
  private var heldSince: Date?

  override init(frame: NSRect) {
    super.init(frame: frame)
    icon.imageScaling = .scaleProportionallyUpOrDown
    name.font = .systemFont(ofSize: 13, weight: .medium)
    name.lineBreakMode = .byTruncatingMiddle
    status.font = .systemFont(ofSize: 11)
    status.textColor = .secondaryLabelColor
    status.lineBreakMode = .byTruncatingTail
    progress.style = .bar
    progress.controlSize = .small
    progress.minValue = 0
    progress.maxValue = 1
    for button in [primary, secondary] {
      button.bezelStyle = .rounded
      button.controlSize = .small
      button.target = self
    }
    primary.action = #selector(primaryClicked)
    secondary.action = #selector(secondaryClicked)
    [icon, name, status, progress, primary, secondary].forEach(addSubview)
  }

  required init?(coder: NSCoder) { fatalError() }

  override var intrinsicContentSize: NSSize { NSSize(width: 320, height: 54) }
  override var isFlipped: Bool { true }

  /// Waiting for Keep or Discard: Discard is the default (Return), Keep ignores clicks for its first half second.
  var keepReady: Bool { item?.waiting == true && primary.isEnabled }

  func show(_ item: DownloadsController.Item) {
    self.item = item
    let ext = (item.filename as NSString).pathExtension
    icon.image = NSWorkspace.shared.icon(for: .init(filenameExtension: ext) ?? .data)
    name.stringValue = item.filename.isEmpty ? "Download" : item.filename
    progress.isHidden = !item.active || item.waiting
    progress.isIndeterminate = item.total <= 0
    progress.doubleValue = item.fraction
    if item.isIndeterminateRunning { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
    primary.isHidden = false
    secondary.isHidden = false
    primary.keyEquivalent = ""
    secondary.keyEquivalent = ""
    let from = item.host.isEmpty ? "" : " from \(item.host)"
    if item.waiting {
      status.stringValue = "This file may be harmful or was sent insecurely\(from). Keep it?"
      status.textColor = .systemOrange
      secondary.title = "Discard"
      secondary.keyEquivalent = "\r"
      primary.title = "Keep"
      if heldSince == nil {
        heldSince = Date()
        primary.isEnabled = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.primary.isEnabled = true }
      }
    } else {
      heldSince = nil
      primary.isEnabled = true
      status.textColor = .secondaryLabelColor
      switch item.state {
      case "finished":
        status.stringValue = "\(Self.bytes(item.received))\(from)"
        primary.title = "Show in Finder"
        secondary.isHidden = true
      case "failed":
        status.stringValue = "Failed" + (item.error.map { " · \($0.lowercased().replacingOccurrences(of: "_", with: " "))" } ?? "")
        primary.isHidden = true
        secondary.isHidden = true
      case "cancelled":
        status.stringValue = "Cancelled"
        primary.isHidden = true
        secondary.isHidden = true
      default:
        let size = item.total > 0 ? "\(Self.bytes(item.received)) of \(Self.bytes(item.total))" : Self.bytes(item.received)
        status.stringValue = item.paused ? "Paused · \(size)" : "\(size) · \(Self.bytes(item.speed))/s"
        primary.title = item.paused ? "Resume" : "Pause"
        secondary.title = "Cancel"
      }
    }
    needsLayout = true
  }

  @objc private func primaryClicked() {
    guard let item, let controller else { return }
    if item.waiting { controller.keep(item.id) }
    else if item.state == "finished" { controller.reveal(item.id) }
    else if item.paused { controller.resume(item.id) }
    else { controller.pause(item.id) }
  }

  @objc private func secondaryClicked() {
    guard let item, let controller else { return }
    if item.waiting { controller.discard(item.id) } else { controller.cancel(item.id) }
  }

  /// For tests: press Keep or Discard the way a click would.
  func press(keep: Bool) -> Bool {
    let button = keep ? primary : secondary
    guard !button.isHidden, button.isEnabled else { return false }
    button.performClick(nil)
    return true
  }

  override func layout() {
    super.layout()
    icon.frame = NSRect(x: 4, y: 11, width: 32, height: 32)
    var buttonX = bounds.width - 4
    for button in [secondary, primary] where !button.isHidden {
      button.sizeToFit()
      buttonX -= button.frame.width
      button.frame.origin = NSPoint(x: buttonX, y: (bounds.height - button.frame.height) / 2)
      buttonX -= 4
    }
    let textWidth = buttonX - 44
    name.frame = NSRect(x: 44, y: 8, width: textWidth, height: 17)
    progress.frame = NSRect(x: 44, y: 27, width: textWidth, height: 8)
    status.frame = NSRect(x: 44, y: progress.isHidden ? 28 : 36, width: textWidth, height: 15)
    if !status.stringValue.isEmpty, item?.waiting == true {
      status.maximumNumberOfLines = 2
      status.frame = NSRect(x: 44, y: 26, width: textWidth, height: 28)
    }
  }

  private static func bytes(_ value: Double) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(max(value, 0)), countStyle: .file)
  }
}

private extension DownloadsController.Item {
  var isIndeterminateRunning: Bool { active && !waiting && total <= 0 }
}
