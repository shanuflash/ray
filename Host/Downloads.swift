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
    let started: Double
    let offTheRecord: Bool

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
      started = info["startTime"] as? Double ?? 0
      offTheRecord = info["offTheRecord"] as? Bool ?? false
    }

    var active: Bool { state == "downloading" }
    var waiting: Bool { active && dangerous }
    var host: String { URLComponents(string: url)?.host ?? "" }
    var fraction: Double { total > 0 ? min(max(received / total, 0), 1) : 0 }
  }

  /// Newest first: the profile's download history, then this session's as they come.
  private(set) var items: [Item] = []
  var onChange: ((_ newlyWaiting: Bool) -> Void)?
  private let profile: ArdiaCoreProfile
  /// A private window lists only private downloads and a normal one only normal ones, never each other's.
  private let offTheRecord: Bool

  /// `profile` is the normal profile (the engine's download calls work on it and report private downloads with an
  /// offTheRecord flag).
  init(profile: ArdiaCoreProfile, offTheRecord: Bool) {
    self.profile = profile
    self.offTheRecord = offTheRecord
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
    // The engine starts watching downloads on its first downloads call. Chrome reads its download history in the
    // background at launch, so ask again a little later too.
    loadHistory()
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.loadHistory() }
    if let folder = TestEnvironment["RAY_DOWNLOADS_DIR"], !offTheRecord {
      EngineCalls.call("ac_downloads_set_settings", profile: profile,
                       args: ["folder": folder, "askWhereToSave": false]) { _ in }
    }
  }

  /// Merges the engine's full list (history included) into ours.
  func loadHistory() {
    EngineCalls.call("ac_downloads_list", profile: profile) { [weak self] reply in
      guard let self, let list = reply?["downloads"] as? [[String: Any]] else { return }
      let known = Set(self.items.map(\.id))
      let history = list.compactMap(Item.init).filter { !known.contains($0.id) && $0.offTheRecord == self.offTheRecord }
      guard !history.isEmpty else { return }
      self.items = (self.items + history).sorted { $0.started > $1.started }
      self.onChange?(false)
    }
  }

  private func isOurs(_ payload: [String: Any]) -> Bool {
    guard (payload["profile"] as? String).map({ $0 == profile.path }) ?? true else { return false }
    let fromPrivate = (payload["offTheRecord"] as? Bool ?? false)
      || ((payload["download"] as? [String: Any])?["offTheRecord"] as? Bool ?? false)
    return fromPrivate == offTheRecord
  }

  func keep(_ id: String) { call("ac_downloads_keep", id) }
  func discard(_ id: String) { call("ac_downloads_cancel", id) }
  func cancel(_ id: String) { call("ac_downloads_cancel", id) }
  func pause(_ id: String) { call("ac_downloads_pause", id) }
  func resume(_ id: String) { call("ac_downloads_resume", id) }

  /// Takes a finished, failed or cancelled download off the list (the file stays where it is).
  func remove(_ id: String) {
    items.removeAll { $0.id == id }
    call("ac_downloads_remove", id)
    onChange?(false)
  }

  func open(_ id: String) {
    guard let item = items.first(where: { $0.id == id }), item.state == "finished", !item.path.isEmpty,
          FileManager.default.fileExists(atPath: item.path) else { return }
    NSWorkspace.shared.open(URL(fileURLWithPath: item.path))
  }

  /// The folder downloads land in (from the newest finished file, else ~/Downloads).
  var folder: URL {
    if let path = items.first(where: { $0.state == "finished" && !$0.path.isEmpty })?.path {
      return URL(fileURLWithPath: path).deletingLastPathComponent()
    }
    return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
      ?? FileManager.default.homeDirectoryForCurrentUser
  }

  func reveal(_ id: String) {
    guard let item = items.first(where: { $0.id == id }), !item.path.isEmpty else { return }
    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
  }

  private func call(_ name: String, _ id: String) {
    EngineCalls.call(name, profile: profile, args: ["id": id]) { _ in }
  }
}

/// The downloads list in the sidebar's panel: a header, then one row per download, newest first (Arc's layout: file
/// icon, name, a quiet status line, a thin progress bar while it comes in, and small actions that show on hover).
final class DownloadsListView: NSView {
  private let stack = NSStackView()
  private let header = NSView()
  private let titleLabel = NSTextField(labelWithString: "Downloads")
  private let folderButton = DownloadsListView.iconButton("folder", "Open Downloads Folder")
  private let closeButton = DownloadsListView.iconButton("xmark", "Close")
  private var rows: [String: DownloadRowView] = [:]
  weak var controller: DownloadsController?
  var onClose: (() -> Void)?
  var width: CGFloat = 251

  override init(frame: NSRect) {
    super.init(frame: frame)
    titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
    titleLabel.textColor = .secondaryLabelColor
    folderButton.target = self
    folderButton.action = #selector(openFolder)
    closeButton.target = self
    closeButton.action = #selector(close)
    header.addSubview(titleLabel)
    header.addSubview(folderButton)
    header.addSubview(closeButton)
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 2
    stack.edgeInsets = NSEdgeInsets(top: 8, left: 6, bottom: 6, right: 6)
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
      stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }

  required init?(coder: NSCoder) { fatalError() }

  @objc private func close() { onClose?() }

  @objc private func openFolder() {
    guard let folder = controller?.folder else { return }
    NSWorkspace.shared.open(folder)
  }

  func show(_ items: [DownloadsController.Item]) {
    let shown = Array(items.prefix(8))
    for view in stack.arrangedSubviews {
      stack.removeArrangedSubview(view)
      view.removeFromSuperview()
    }
    header.frame = NSRect(x: 0, y: 0, width: width - 12, height: 28)
    titleLabel.frame = NSRect(x: 8, y: 6, width: 150, height: 17)
    closeButton.frame = NSRect(x: header.frame.width - 28, y: 2, width: 26, height: 24)
    folderButton.frame = closeButton.frame.offsetBy(dx: -28, dy: 0)
    stack.addArrangedSubview(header)
    header.widthAnchor.constraint(equalToConstant: width - 12).isActive = true
    header.heightAnchor.constraint(equalToConstant: 28).isActive = true
    var kept: [String: DownloadRowView] = [:]
    for item in shown {
      let row = rows[item.id] ?? DownloadRowView()
      row.controller = controller
      row.show(item)
      stack.addArrangedSubview(row)
      row.widthAnchor.constraint(equalToConstant: width - 12).isActive = true
      row.heightAnchor.constraint(equalToConstant: DownloadRowView.height).isActive = true
      kept[item.id] = row
    }
    rows = kept
    if shown.isEmpty { stack.addArrangedSubview(EmptyDownloadsView(width: width - 12)) }
  }

  func row(for id: String) -> DownloadRowView? { rows[id] }

  override var fittingSize: NSSize { NSSize(width: width, height: stack.fittingSize.height) }

  static func iconButton(_ symbol: String, _ label: String) -> NSButton {
    let button = HoverIconButton()
    button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
    button.symbolConfiguration = .init(pointSize: 12, weight: .medium)
    button.isBordered = false
    button.bezelStyle = .regularSquare
    button.imagePosition = .imageOnly
    button.contentTintColor = .secondaryLabelColor
    button.refusesFirstResponder = true
    button.toolTip = label
    return button
  }
}

private final class EmptyDownloadsView: NSView {
  init(width: CGFloat) {
    super.init(frame: .zero)
    let icon = NSImageView(image: NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: nil) ?? NSImage())
    icon.symbolConfiguration = .init(pointSize: 22, weight: .light)
    icon.contentTintColor = .tertiaryLabelColor
    let label = NSTextField(labelWithString: "No downloads yet")
    label.font = .systemFont(ofSize: 13)
    label.textColor = .secondaryLabelColor
    label.alignment = .center
    icon.frame = NSRect(x: (width - 28) / 2, y: 18, width: 28, height: 28)
    label.frame = NSRect(x: 0, y: 52, width: width, height: 18)
    addSubview(icon)
    addSubview(label)
    translatesAutoresizingMaskIntoConstraints = false
    widthAnchor.constraint(equalToConstant: width).isActive = true
    heightAnchor.constraint(equalToConstant: 86).isActive = true
  }

  required init?(coder: NSCoder) { fatalError() }
  override var isFlipped: Bool { true }
}

final class DownloadRowView: NSView {
  static let height: CGFloat = 52
  weak var controller: DownloadsController?
  private let icon = NSImageView()
  private let name = NSTextField(labelWithString: "")
  private let status = NSTextField(labelWithString: "")
  private let track = CALayer()
  private let bar = CALayer()
  private let primary = DownloadsListView.iconButton("pause.fill", "Pause")
  private let secondary = DownloadsListView.iconButton("xmark", "Cancel")
  private let keep = NSButton(title: "Keep", target: nil, action: nil)
  private let discard = NSButton(title: "Discard", target: nil, action: nil)
  private let fill = CALayer()
  private var item: DownloadsController.Item?
  private var heldSince: Date?
  private var hovered = false

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    fill.cornerRadius = 8
    fill.cornerCurve = .continuous
    layer?.addSublayer(fill)
    icon.imageScaling = .scaleProportionallyUpOrDown
    name.font = .systemFont(ofSize: 13, weight: .medium)
    name.lineBreakMode = .byTruncatingMiddle
    status.font = .systemFont(ofSize: 11)
    status.textColor = .secondaryLabelColor
    status.lineBreakMode = .byTruncatingTail
    track.cornerRadius = 1.5
    bar.cornerRadius = 1.5
    layer?.addSublayer(track)
    layer?.addSublayer(bar)
    for button in [keep, discard] {
      button.bezelStyle = .rounded
      button.controlSize = .small
      button.target = self
    }
    keep.action = #selector(keepClicked)
    discard.action = #selector(discardClicked)
    primary.target = self
    primary.action = #selector(primaryClicked)
    secondary.target = self
    secondary.action = #selector(secondaryClicked)
    [icon, name, status, primary, secondary, keep, discard].forEach(addSubview)
    addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    translatesAutoresizingMaskIntoConstraints = false
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }
  override var wantsUpdateLayer: Bool { true }

  override func updateLayer() {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    fill.backgroundColor = (hovered ? SidebarColors.hover : .clear).cgColor
    track.backgroundColor = NSColor.labelColor.withAlphaComponent(0.1).cgColor
    bar.backgroundColor = ProfileColor.accent.cgColor
    CATransaction.commit()
  }

  override func mouseEntered(with event: NSEvent) {
    hovered = true
    updateButtons()
    needsDisplay = true
  }

  override func mouseExited(with event: NSEvent) {
    hovered = false
    updateButtons()
    needsDisplay = true
  }

  /// A click on a finished download opens it, as in Arc.
  override func mouseUp(with event: NSEvent) {
    guard let item, item.state == "finished", bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
    controller?.open(item.id)
  }

  /// Waiting for Keep or Discard: Discard is the default (Return), Keep ignores clicks for its first half second.
  var keepReady: Bool { item?.waiting == true && keep.isEnabled }

  func show(_ item: DownloadsController.Item) {
    self.item = item
    let ext = (item.filename as NSString).pathExtension
    if item.state == "finished", !item.path.isEmpty, FileManager.default.fileExists(atPath: item.path) {
      icon.image = NSWorkspace.shared.icon(forFile: item.path)
    } else {
      icon.image = NSWorkspace.shared.icon(for: .init(filenameExtension: ext) ?? .data)
    }
    icon.alphaValue = item.state == "failed" || item.state == "cancelled" ? 0.5 : 1
    name.stringValue = item.filename.isEmpty ? "Download" : item.filename
    let from = item.host.isEmpty ? "" : " · \(item.host)"
    status.textColor = .secondaryLabelColor
    if item.waiting {
      status.stringValue = "May be harmful or sent insecurely\(from)"
      status.textColor = .systemOrange
      if heldSince == nil {
        heldSince = Date()
        keep.isEnabled = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.keep.isEnabled = true }
      }
      discard.keyEquivalent = "\r"
    } else {
      heldSince = nil
      discard.keyEquivalent = ""
      switch item.state {
      case "finished": status.stringValue = Self.bytes(item.received) + from
      case "failed":
        status.stringValue = "Failed" + (item.error.map { " · " + $0.lowercased().replacingOccurrences(of: "_", with: " ") } ?? "")
        status.textColor = .systemRed
      case "cancelled": status.stringValue = "Cancelled" + from
      default:
        let size = item.total > 0 ? "\(Self.bytes(item.received)) of \(Self.bytes(item.total))" : Self.bytes(item.received)
        status.stringValue = item.paused ? "Paused · \(size)" : "\(size) · \(Self.bytes(item.speed))/s"
      }
    }
    toolTip = item.state == "finished" ? "Click to open" : nil
    updateButtons()
    needsLayout = true
    needsDisplay = true
  }

  private func updateButtons() {
    guard let item else { return }
    let waiting = item.waiting
    keep.isHidden = !waiting
    discard.isHidden = !waiting
    let downloading = item.active && !waiting
    primary.isHidden = waiting || !(downloading || (item.state == "finished" && hovered))
    secondary.isHidden = waiting || !(downloading || hovered)
    if downloading {
      primary.image = NSImage(systemSymbolName: item.paused ? "play.fill" : "pause.fill", accessibilityDescription: nil)
      primary.toolTip = item.paused ? "Resume" : "Pause"
      secondary.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Cancel")
      secondary.toolTip = "Cancel"
    } else {
      primary.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Show in Finder")
      primary.toolTip = "Show in Finder"
      secondary.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Remove from List")
      secondary.toolTip = "Remove from List"
    }
    needsLayout = true
  }

  @objc private func primaryClicked() {
    guard let item, let controller else { return }
    if item.state == "finished" { controller.reveal(item.id) }
    else if item.paused { controller.resume(item.id) }
    else { controller.pause(item.id) }
  }

  @objc private func secondaryClicked() {
    guard let item, let controller else { return }
    if item.active { controller.cancel(item.id) } else { controller.remove(item.id) }
  }

  @objc private func keepClicked() {
    guard let item else { return }
    controller?.keep(item.id)
  }

  @objc private func discardClicked() {
    guard let item else { return }
    controller?.discard(item.id)
  }

  /// For tests: press Keep or Discard the way a click would.
  func press(keep pressKeep: Bool) -> Bool {
    let button = pressKeep ? keep : discard
    guard !button.isHidden, button.isEnabled else { return false }
    button.performClick(nil)
    return true
  }

  override func layout() {
    super.layout()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    fill.frame = bounds
    CATransaction.commit()
    icon.frame = NSRect(x: 8, y: (bounds.height - 32) / 2, width: 32, height: 32)
    var right = bounds.width - 6
    for button in [discard, keep] where !button.isHidden {
      button.sizeToFit()
      right -= button.frame.width
      button.frame.origin = NSPoint(x: right, y: (bounds.height - button.frame.height) / 2)
      right -= 4
    }
    for button in [secondary, primary] where !button.isHidden {
      right -= 26
      button.frame = NSRect(x: right, y: (bounds.height - 24) / 2, width: 26, height: 24)
      right -= 2
    }
    let textX: CGFloat = 50
    let width = max(0, right - textX - 4)
    let showsBar = item.map { $0.active && !$0.waiting } ?? false
    name.frame = NSRect(x: textX, y: showsBar ? 7 : 9, width: width, height: 17)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    track.isHidden = !showsBar
    bar.isHidden = !showsBar
    track.frame = NSRect(x: textX, y: 27, width: width, height: 3)
    let fraction = item.map { $0.total > 0 ? $0.fraction : 0.08 } ?? 0
    bar.frame = NSRect(x: textX, y: 27, width: max(3, width * CGFloat(fraction)), height: 3)
    CATransaction.commit()
    status.frame = NSRect(x: textX, y: showsBar ? 32 : 27, width: width, height: 15)
  }

  private static func bytes(_ value: Double) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(max(value, 0)), countStyle: .file)
  }
}

/// The sidebar's downloads panel: the list on a raised, rounded card that slides up from the footer.
final class DownloadsPanelView: NSView {
  let list: DownloadsListView

  init(list: DownloadsListView) {
    self.list = list
    super.init(frame: .zero)
    wantsLayer = true
    layer?.cornerRadius = 12
    layer?.cornerCurve = .continuous
    layer?.borderWidth = 1
    layer?.shadowOpacity = 0.18
    layer?.shadowRadius = 10
    layer?.shadowOffset = CGSize(width: 0, height: 3)
    addSubview(list)
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }
  override var wantsUpdateLayer: Bool { true }
  override var mouseDownCanMoveWindow: Bool { false }

  override func updateLayer() {
    let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    layer?.backgroundColor = (dark ? NSColor(white: 0.14, alpha: 1) : NSColor(white: 0.99, alpha: 1)).cgColor
    layer?.borderColor = (dark ? NSColor(white: 1, alpha: 0.1) : NSColor(white: 0, alpha: 0.08)).cgColor
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    needsDisplay = true
  }

  /// Presses on the card's empty space stay with it (otherwise they'd fall through to the window and drag it).
  override func mouseDown(with event: NSEvent) {}

  var wantedHeight: CGFloat { list.fittingSize.height }

  override func layout() {
    super.layout()
    list.frame = bounds
  }
}
