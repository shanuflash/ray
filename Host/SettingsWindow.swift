import AppKit

/// Ray's own Settings window (⌘, from the Ray menu; `ray://settings/appearance` opens it too). One pane for now,
/// Appearance, as grouped rounded rows: a title and a grey description on the left, the control on the right. Every
/// control goes through `RaySettings.apply`, the same call the test command `setting` makes.
final class SettingsWindowController: NSObject, NSWindowDelegate {
  static let shared = SettingsWindowController()

  private static let size = NSSize(width: 640, height: 560)

  private var window: NSWindow?
  private var pane: AppearancePaneView?
  private var saveFrame: DispatchWorkItem?

  var isOpen: Bool { window?.isVisible ?? false }
  var isKey: Bool { window?.isKeyWindow ?? false }

  /// Brings the window forward, making it first. `pane` names the pane to show (only "appearance" exists).
  func show(pane name: String = "appearance") {
    let window = self.window ?? makeWindow()
    if launchedInBackground {
      // A test instance never takes focus: the window goes on screen behind everything.
      window.orderBack(nil)
    } else {
      NSApp.activate()
      window.makeKeyAndOrderFront(nil)
    }
    pane?.refresh()
    logAll("settingsWindow")
  }

  func close() { window?.performClose(nil) }

  private func makeWindow() -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered, defer: false)
    window.title = "Settings"
    window.titlebarAppearsTransparent = true
    window.isReleasedWhenClosed = false
    window.isRestorable = false
    window.animationBehavior = .none
    window.tabbingMode = .disallowed
    window.minSize = NSSize(width: 520, height: 400)
    window.backgroundColor = SettingsColors.background
    window.delegate = self
    let pane = AppearancePaneView()
    let scroll = NSScrollView(frame: NSRect(origin: .zero, size: Self.size))
    scroll.autoresizingMask = [.width, .height]
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.scrollerStyle = .overlay
    scroll.documentView = pane
    pane.frame = NSRect(origin: .zero, size: scroll.contentSize)
    window.contentView = scroll
    self.pane = pane
    if let text = RaySettings.shared.values.windowFrame {
      let frame = NSRectFromString(text)
      // Only where it still lands on a screen, and never smaller than the window's minimum.
      if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }), frame.width >= 520, frame.height >= 400 {
        window.setFrame(frame, display: false)
      } else {
        window.center()
      }
    } else {
      window.center()
    }
    self.window = window
    return window
  }

  // MARK: NSWindowDelegate

  func windowDidResize(_ notification: Notification) {
    guard let scroll = window?.contentView as? NSScrollView, let pane else { return }
    pane.frame.size.width = scroll.contentSize.width
    pane.needsLayout = true
    rememberFrameSoon()
  }

  func windowDidMove(_ notification: Notification) { rememberFrameSoon() }

  func windowWillClose(_ notification: Notification) {
    pane?.closeColorPanel()
    if let window { RaySettings.shared.rememberWindowFrame(window.frame) }
    logAll("settingsWindow")
  }

  private func rememberFrameSoon() {
    saveFrame?.cancel()
    let work = DispatchWorkItem { [weak self] in
      guard let window = self?.window else { return }
      RaySettings.shared.rememberWindowFrame(window.frame)
    }
    saveFrame = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
  }

  private func logAll(_ event: String) {
    // The window's state is part of every browser window's state log; a test reads whichever logged last.
    DispatchQueue.main.async { AppController.shared.current?.logState(event) }
  }

  // MARK: Tests

  var debug: [String: Any] {
    [
      "open": isOpen, "pane": "appearance",
      "windows": NSApp.windows.filter { $0.title == "Settings" && $0.isVisible }.count, "frame": window.map { NSStringFromRect($0.frame) } ?? "",
      "title": window?.title ?? "", "controls": pane?.debug ?? [:],
    ]
  }

  /// For tests: draws the window's content into PNGs (light and dark), to look at its design.
  func snapshot(to path: String) -> Bool {
    // The whole pane, not just what the window shows.
    guard let window, let content = (window.contentView as? NSScrollView)?.documentView ?? window.contentView else { return false }
    for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
      let old = window.appearance
      window.appearance = NSAppearance(named: appearance)
      defer { window.appearance = old }
      content.layoutSubtreeIfNeeded()
      content.displayIfNeeded()
      guard let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return false }
      content.cacheDisplay(in: content.bounds, to: rep)
      let image = NSImage(size: content.bounds.size)
      image.lockFocus()
      content.effectiveAppearance.performAsCurrentDrawingAppearance {
        SettingsColors.background.setFill()
        NSRect(origin: .zero, size: content.bounds.size).fill()
      }
      rep.draw(in: NSRect(origin: .zero, size: content.bounds.size))
      image.unlockFocus()
      guard let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
      else { return false }
      guard (try? png.write(to: URL(fileURLWithPath: path.replacingOccurrences(of: ".png", with: "-\(name).png")))) != nil
      else { return false }
    }
    return true
  }

  /// For tests: the "All Settings…" link.
  func pressAllSettings() -> Bool {
    guard let pane else { return false }
    pane.openAllSettings()
    return true
  }

  /// For tests: a control pressed as a click would (a switch by name, `swatch <n>`, `zoom <n>`).
  func press(_ words: [String]) -> Bool {
    pane?.press(words) ?? false
  }
}

enum SettingsColors {
  private static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
    NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light }
  }

  static let background = SidebarColors.background
  /// The rounded group behind a set of rows: the sidebar's lifted white, and a step above the dark window.
  static let group = dynamic(light: NSColor(white: 1, alpha: 1), dark: NSColor(white: 0.15, alpha: 1))
  static let separator = PanelColors.border
  static let switchOff = dynamic(light: NSColor(white: 0, alpha: 0.2), dark: NSColor(white: 1, alpha: 0.25))
}

// MARK: Pane

/// Settings › Appearance.
private final class AppearancePaneView: NSView {
  private static let margin: CGFloat = 28
  private static let maxWidth: CGFloat = 640

  private let heading = NSTextField(labelWithString: "Appearance")
  private var sections: [(header: NSTextField?, group: SettingsGroupView)] = []
  private let allSettings = LinkButton(title: "All Settings…")
  private let allSettingsNote = NSTextField(wrappingLabelWithString: "Chrome's other pages: privacy, passwords, extensions and more.")

  private let minimalURL = RaySwitch()
  private let loadingProgress = RaySwitch()
  private let swatches = SwatchRow()
  private let zoom = NSPopUpButton(frame: .zero, pullsDown: false)
  private let newTabs = RaySwitch()
  private let recentTabs = RaySwitch()
  private let copyLink = RaySwitch()
  private let sidebarKey = RaySwitch()

  override var isFlipped: Bool { true }

  override init(frame: NSRect) {
    super.init(frame: frame)
    heading.font = .systemFont(ofSize: 22, weight: .semibold)
    addSubview(heading)

    func toggle(_ control: RaySwitch, _ key: RaySetting, _ label: String) {
      control.setAccessibilityLabel(label)
      control.onChange = { on in RaySettings.shared.apply(key, on ? "on" : "off") }
    }
    toggle(minimalURL, .minimalURL, "Minimal URL in the address bar")
    toggle(loadingProgress, .loadingProgress, "Show loading progress in the address bar")
    toggle(newTabs, .newTabNextToActive, "Open new tabs next to the active tab")
    toggle(recentTabs, .recentTabCycling, "Cycle through tabs in most recently used order with Ctrl+Tab")
    toggle(copyLink, .copyLinkShortcut, "Enable quick page link copying with ⌘+Shift+C")
    toggle(sidebarKey, .sidebarShortcut, "Use ⌘+S to toggle vertical tabs in Vertical layout")

    swatches.onChoose = { hex in RaySettings.shared.apply(.theme, hex ?? "default") }
    swatches.onCustom = { [weak self] in self?.openColorPanel() }

    for level in RaySettings.zoomLevels {
      zoom.addItem(withTitle: "\(Int((level * 100).rounded()))%")
      zoom.lastItem?.representedObject = level
    }
    zoom.target = self
    zoom.action = #selector(zoomChosen)
    zoom.setAccessibilityLabel("Default page zoom")

    addSection(nil, [
      SettingRowView(title: "Minimal URL in the address bar",
                     detail: "Show only the site in the address bar. The rest of the address appears when you hover it.",
                     control: minimalURL),
      SettingRowView(title: "Show loading progress in the address bar",
                     detail: "A wash fills the address bar, and a thin line runs along the page, while a page loads.",
                     control: loadingProgress),
    ])
    addSection(nil, [
      SettingRowView(title: "Theme", detail: "The colour of Ray's highlights: loading, selection, drop targets and switches.",
                     accessory: swatches),
    ])
    addSection("Page", [
      SettingRowView(title: "Page zoom", detail: "For sites you haven't zoomed yourself. Zooming a site with ⌘+ or ⌘− keeps its own level.",
                     control: zoom),
    ])
    addSection("Tabs", [
      SettingRowView(title: "Open new tabs next to the active tab",
                     detail: "A new tab goes right after the tab you're on, when it's in Today. Off: at the top of Today.",
                     control: newTabs),
      SettingRowView(title: "Cycle through tabs in most recently used order with Ctrl+Tab",
                     detail: "Hold Control and press Tab again to go further back. Off: in the order of the sidebar.",
                     control: recentTabs),
    ])
    addSection("Shortcuts", [
      SettingRowView(title: "Enable quick page link copying with ⌘+Shift+C",
                     detail: "Copies the page's address. Off: the key goes to the page.", control: copyLink),
      SettingRowView(title: "Use ⌘+S to toggle vertical tabs in Vertical layout",
                     detail: "In Ray, ⌘S shows and hides the sidebar. Off: the key goes to the page (Save Page As).",
                     control: sidebarKey),
    ])

    allSettings.onClick = { [weak self] in self?.openAllSettings() }
    allSettingsNote.font = .systemFont(ofSize: 12)
    allSettingsNote.textColor = .secondaryLabelColor
    addSubview(allSettings)
    addSubview(allSettingsNote)

    NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged), name: RaySettings.didChange, object: nil)
    NotificationCenter.default.addObserver(self, selector: #selector(accentChanged), name: ProfileColor.didChange, object: nil)
    refresh()
  }

  required init?(coder: NSCoder) { fatalError() }

  deinit { NotificationCenter.default.removeObserver(self) }

  private func addSection(_ title: String?, _ rows: [SettingRowView]) {
    let header = title.map { text -> NSTextField in
      let label = NSTextField(labelWithString: text)
      label.font = .systemFont(ofSize: 12, weight: .semibold)
      label.textColor = .secondaryLabelColor
      addSubview(label)
      return label
    }
    let group = SettingsGroupView(rows: rows)
    addSubview(group)
    sections.append((header, group))
  }

  /// Shows the settings as they are now.
  func refresh() {
    let values = RaySettings.shared.values
    minimalURL.isOn = values.minimalURL
    loadingProgress.isOn = values.loadingProgress
    newTabs.isOn = values.newTabNextToActive
    recentTabs.isOn = values.recentTabCycling
    copyLink.isOn = values.copyLinkShortcut
    sidebarKey.isOn = values.sidebarShortcut
    swatches.selection = values.theme
    if let index = RaySettings.zoomLevels.firstIndex(of: values.defaultZoom) { zoom.selectItem(at: index) }
  }

  @objc private func settingsChanged() { refresh() }

  @objc private func accentChanged() { setNeedsDisplayRecursively() }

  @objc private func zoomChosen() {
    guard let level = zoom.selectedItem?.representedObject as? Double else { return }
    RaySettings.shared.apply(.defaultZoom, String(level))
  }

  func openAllSettings() { AppController.shared.openChromeSettings() }

  func press(_ words: [String]) -> Bool {
    let switches: [String: RaySwitch] = [
      "minimalURL": minimalURL, "loadingProgress": loadingProgress, "newTabNextToActive": newTabs,
      "recentTabCycling": recentTabs, "copyLinkShortcut": copyLink, "sidebarShortcut": sidebarKey,
    ]
    guard let name = words.first else { return false }
    if let control = switches[name] {
      control.press()
      return true
    }
    guard words.count == 2, let index = Int(words[1]) else { return false }
    switch name {
    case "swatch": return swatches.press(index: index)
    case "zoom":
      guard index >= 0, index < zoom.numberOfItems else { return false }
      zoom.selectItem(at: index)
      zoomChosen()
      return true
    default: return false
    }
  }

  // MARK: Colour panel

  /// The shared colour panel is also what a page's colour input uses: only close it if Settings opened it.
  private var ownsColorPanel = false

  private func openColorPanel() {
    let panel = NSColorPanel.shared
    ownsColorPanel = true
    panel.showsAlpha = false
    panel.setTarget(self)
    panel.setAction(#selector(colorPanelChanged(_:)))
    if let rgb = ProfileColor.parse(ProfileColor.hex(of: ProfileColor.accent)) {
      panel.color = NSColor(srgbRed: rgb.r, green: rgb.g, blue: rgb.b, alpha: 1)
    }
    panel.orderFront(nil)
  }

  @objc private func colorPanelChanged(_ panel: NSColorPanel) {
    guard let rgb = panel.color.usingColorSpace(.sRGB) else { return }
    func byte(_ v: CGFloat) -> Int { Int((min(1, max(0, v)) * 255).rounded()) }
    RaySettings.shared.apply(.theme, String(format: "#%02X%02X%02X", byte(rgb.redComponent), byte(rgb.greenComponent), byte(rgb.blueComponent)))
  }

  func closeColorPanel() {
    guard ownsColorPanel else { return }
    ownsColorPanel = false
    let panel = NSColorPanel.shared
    panel.setTarget(nil)
    panel.setAction(nil)
    panel.close()
  }

  // MARK: Layout

  override func layout() {
    super.layout()
    let margin = Self.margin
    let width = min(Self.maxWidth, bounds.width) - margin * 2
    let x = max(margin, (bounds.width - width) / 2)
    var y: CGFloat = 20
    let headingHeight = ceil(heading.intrinsicContentSize.height)
    heading.frame = NSRect(x: x, y: y, width: width, height: headingHeight)
    y += headingHeight + 16
    for (header, group) in sections {
      if let header {
        let height = ceil(header.intrinsicContentSize.height)
        header.frame = NSRect(x: x + 4, y: y, width: width - 8, height: height)
        y += height + 6
      }
      let height = group.fittingHeight(width: width)
      group.frame = NSRect(x: x, y: y, width: width, height: height)
      y += height + 22
    }
    let linkSize = allSettings.intrinsicContentSize
    allSettings.frame = NSRect(x: x + 4, y: y - 6, width: linkSize.width, height: linkSize.height)
    let noteHeight = textHeight(allSettingsNote, width: width - 8)
    allSettingsNote.frame = NSRect(x: x + 4, y: allSettings.frame.maxY + 2, width: width - 8, height: noteHeight)
    y = allSettingsNote.frame.maxY + 28
    if abs(frame.height - y) > 0.5, let scroll = enclosingScrollView {
      frame.size.height = max(y, scroll.contentSize.height)
    }
  }

  // MARK: State log

  var debug: [String: Any] {
    [
      "minimalURL": minimalURL.isOn, "loadingProgress": loadingProgress.isOn, "newTabNextToActive": newTabs.isOn,
      "recentTabCycling": recentTabs.isOn, "copyLinkShortcut": copyLink.isOn, "sidebarShortcut": sidebarKey.isOn,
      "swatch": swatches.selection ?? "default", "swatches": swatches.count, "swatchSelected": swatches.selectedIndex,
      "zoom": zoom.titleOfSelectedItem ?? "", "zoomLevels": zoom.itemTitles,
      "allSettingsLink": allSettings.title,
    ]
  }
}

func textHeight(_ label: NSTextField, width: CGFloat) -> CGFloat {
  guard !label.stringValue.isEmpty, let cell = label.cell else { return 0 }
  return ceil(cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: max(10, width), height: 10_000)).height)
}

extension NSView {
  /// Every view in the tree redraws (accent colours that views read in `updateLayer` or `draw`).
  func setNeedsDisplayRecursively() {
    needsDisplay = true
    subviews.forEach { $0.setNeedsDisplayRecursively() }
  }
}

// MARK: Rows

/// A rounded group of rows with a hairline between them.
private final class SettingsGroupView: NSView {
  private let rows: [SettingRowView]
  private var lines: [NSView] = []

  init(rows: [SettingRowView]) {
    self.rows = rows
    super.init(frame: .zero)
    wantsLayer = true
    layer?.cornerRadius = 10
    layer?.cornerCurve = .continuous
    for (index, row) in rows.enumerated() {
      addSubview(row)
      if index > 0 {
        let line = NSView()
        line.wantsLayer = true
        lines.append(line)
        addSubview(line)
      }
    }
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }
  override var wantsUpdateLayer: Bool { true }

  override func updateLayer() {
    layer?.backgroundColor = SettingsColors.group.cgColor
    layer?.borderColor = SettingsColors.separator.cgColor
    layer?.borderWidth = 1
    for line in lines { line.layer?.backgroundColor = SettingsColors.separator.cgColor }
  }

  func fittingHeight(width: CGFloat) -> CGFloat {
    rows.reduce(0) { $0 + $1.fittingHeight(width: width) }
  }

  override func layout() {
    super.layout()
    var y: CGFloat = 0
    for (index, row) in rows.enumerated() {
      let height = row.fittingHeight(width: bounds.width)
      row.frame = NSRect(x: 0, y: y, width: bounds.width, height: height)
      if index > 0 { lines[index - 1].frame = NSRect(x: 16, y: y, width: bounds.width - 32, height: 1) }
      y += height
    }
  }
}

/// One setting: title and grey description on the left, a control on the right, or a wider accessory underneath.
private final class SettingRowView: NSView {
  private static let padding = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)

  private let titleLabel: NSTextField
  private let detailLabel: NSTextField
  private let control: NSView?
  private let accessory: NSView?

  init(title: String, detail: String, control: NSView? = nil, accessory: NSView? = nil) {
    titleLabel = NSTextField(wrappingLabelWithString: title)
    detailLabel = NSTextField(wrappingLabelWithString: detail)
    self.control = control
    self.accessory = accessory
    super.init(frame: .zero)
    titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
    detailLabel.font = .systemFont(ofSize: 12)
    detailLabel.textColor = .secondaryLabelColor
    for label in [titleLabel, detailLabel] {
      label.isSelectable = false
      label.cell?.wraps = true
      label.cell?.truncatesLastVisibleLine = false
    }
    addSubview(titleLabel)
    addSubview(detailLabel)
    if let control { addSubview(control) }
    if let accessory { addSubview(accessory) }
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }

  private var controlSize: NSSize { control.map { $0.fittingSize } ?? .zero }

  private func textWidth(_ width: CGFloat) -> CGFloat {
    let inset = Self.padding.left + Self.padding.right
    return width - inset - (control == nil ? 0 : controlSize.width + 16)
  }

  func fittingHeight(width: CGFloat) -> CGFloat {
    let text = textWidth(width)
    let title = textHeight(titleLabel, width: text), detail = textHeight(detailLabel, width: text)
    let block = title + (detail > 0 ? 2 + detail : 0)
    var height = Self.padding.top + max(block, controlSize.height) + Self.padding.bottom
    if let accessory { height += 10 + accessory.fittingSize.height }
    return max(height, 52)
  }

  override func layout() {
    super.layout()
    let pad = Self.padding
    let text = textWidth(bounds.width)
    let title = textHeight(titleLabel, width: text), detail = textHeight(detailLabel, width: text)
    let block = title + (detail > 0 ? 2 + detail : 0)
    let top = accessory == nil ? (bounds.height - block) / 2 : pad.top
    titleLabel.frame = NSRect(x: pad.left, y: top.rounded(), width: text, height: title)
    detailLabel.frame = NSRect(x: pad.left, y: (top + title + 2).rounded(), width: text, height: detail)
    if let control {
      let size = controlSize
      // Centred on the row, or on the text above an accessory.
      let middle = accessory == nil ? bounds.height / 2 : pad.top + max(block, size.height) / 2
      control.frame = NSRect(x: bounds.width - pad.right - size.width, y: (middle - size.height / 2).rounded(),
                             width: size.width, height: size.height)
    }
    if let accessory {
      let size = accessory.fittingSize
      accessory.frame = NSRect(x: pad.left, y: (top + block + 10).rounded(), width: bounds.width - pad.left - pad.right, height: size.height)
    }
  }
}

// MARK: Controls

/// A switch in the profile's colour (NSSwitch follows the system accent instead).
final class RaySwitch: NSControl {
  var onChange: ((Bool) -> Void)?
  var isOn = false {
    didSet {
      guard oldValue != isOn else { return }
      placeKnob(animated: window != nil)
      needsDisplay = true
      NSAccessibility.post(element: self, notification: .valueChanged)
    }
  }
  private let knob = CALayer()

  override init(frame: NSRect) {
    super.init(frame: NSRect(x: 0, y: 0, width: 38, height: 22))
    wantsLayer = true
    layer?.cornerRadius = 11
    knob.backgroundColor = NSColor.white.cgColor
    knob.cornerRadius = 9
    knob.shadowColor = NSColor.black.cgColor
    knob.shadowOpacity = 0.25
    knob.shadowRadius = 1.5
    knob.shadowOffset = CGSize(width: 0, height: -0.5)
    layer?.addSublayer(knob)
    setAccessibilityRole(.checkBox)
    focusRingType = .exterior
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }
  override var intrinsicContentSize: NSSize { NSSize(width: 38, height: 22) }
  override var fittingSize: NSSize { intrinsicContentSize }
  override var wantsUpdateLayer: Bool { true }
  override var acceptsFirstResponder: Bool { true }
  override var mouseDownCanMoveWindow: Bool { false }

  override func updateLayer() {
    layer?.backgroundColor = (isOn ? ProfileColor.accent : SettingsColors.switchOff).cgColor
    placeKnob(animated: false)
  }

  override func layout() {
    super.layout()
    placeKnob(animated: false)
  }

  private func placeKnob(animated: Bool) {
    CATransaction.begin()
    CATransaction.setDisableActions(!animated)
    CATransaction.setAnimationDuration(0.16)
    knob.frame = CGRect(x: isOn ? bounds.width - 20 : 2, y: 2, width: 18, height: 18)
    CATransaction.commit()
  }

  override func drawFocusRingMask() {
    NSBezierPath(roundedRect: bounds, xRadius: 11, yRadius: 11).fill()
  }

  override var focusRingMaskBounds: NSRect { bounds }

  override func mouseDown(with event: NSEvent) { press() }

  override func keyDown(with event: NSEvent) {
    if event.characters == " " { press() } else { super.keyDown(with: event) }
  }

  /// A click or the space bar.
  func press() {
    isOn.toggle()
    onChange?(isOn)
  }

  override func accessibilityValue() -> Any? { NSNumber(value: isOn ? 1 : 0) }
  override func accessibilityPerformPress() -> Bool {
    press()
    return true
  }
}

/// The row of colour choices: the default, the presets, and a custom colour that opens the colour panel.
private final class SwatchRow: NSView {
  var onChoose: ((String?) -> Void)?
  var onCustom: (() -> Void)?
  private var buttons: [SwatchButton] = []
  private let custom = SwatchButton(hex: nil, isCustom: true, name: "Custom Colour…")

  var count: Int { buttons.count + 1 }

  /// The chosen colour as `#RRGGBB`, nil for the default.
  var selection: String? {
    didSet { updateSelection() }
  }

  func press(index: Int) -> Bool {
    guard index >= 0, index < buttons.count else { return false }
    buttons[index].onClick?()
    return true
  }

  var selectedIndex: Int {
    if let index = buttons.firstIndex(where: { $0.isSelected }) { return index }
    return custom.isSelected ? buttons.count : -1
  }

  override var isFlipped: Bool { true }
  override var fittingSize: NSSize { NSSize(width: 340, height: 28) }

  override init(frame: NSRect) {
    super.init(frame: frame)
    let entries: [(String?, String)] = [(nil, "Lavender")] + ProfileColor.presets.map { ($0.hex as String?, $0.name) }
    for (hex, name) in entries {
      let button = SwatchButton(hex: hex, isCustom: false, name: name)
      button.onClick = { [weak self] in self?.onChoose?(hex) }
      buttons.append(button)
      addSubview(button)
    }
    custom.onClick = { [weak self] in self?.onCustom?() }
    addSubview(custom)
    updateSelection()
  }

  required init?(coder: NSCoder) { fatalError() }

  private func updateSelection() {
    var matched = false
    for button in buttons {
      button.isSelected = button.hex == selection
      matched = matched || button.isSelected
    }
    // A colour that isn't one of the swatches is the custom one.
    custom.hex = matched ? nil : selection
    custom.isSelected = !matched && selection != nil
  }

  override func layout() {
    super.layout()
    let size: CGFloat = 28, gap: CGFloat = 10
    for (index, button) in (buttons + [custom]).enumerated() {
      button.frame = NSRect(x: CGFloat(index) * (size + gap), y: 0, width: size, height: size)
    }
  }
}

/// One round colour choice; selected, it has a ring and a check mark in the colour that reads best on it.
private final class SwatchButton: NSControl {
  /// `#RRGGBB`; nil is the lavender, or for the custom button, no colour of its own yet.
  var hex: String? {
    didSet { if oldValue != hex { needsDisplay = true } }
  }
  let isCustom: Bool
  var onClick: (() -> Void)?
  var isSelected = false {
    didSet { if oldValue != isSelected { needsDisplay = true } }
  }
  private let fill = CALayer()
  private let rainbow = CAGradientLayer()
  private let ring = CAShapeLayer()
  private let check = NSImageView()

  init(hex: String?, isCustom: Bool, name: String) {
    self.hex = hex
    self.isCustom = isCustom
    super.init(frame: .zero)
    wantsLayer = true
    toolTip = name
    setAccessibilityRole(.radioButton)
    setAccessibilityLabel(name)
    fill.cornerCurve = .continuous
    layer?.addSublayer(fill)
    if isCustom {
      rainbow.type = .conic
      rainbow.startPoint = CGPoint(x: 0.5, y: 0.5)
      rainbow.endPoint = CGPoint(x: 0.5, y: 0)
      rainbow.colors = [0xFF5E5B, 0xFFD25E, 0x6BD968, 0x5ED2FF, 0x7B6BFF, 0xE56BFF, 0xFF5E5B].map {
        NSColor(srgbRed: CGFloat(($0 >> 16) & 0xFF) / 255, green: CGFloat(($0 >> 8) & 0xFF) / 255, blue: CGFloat($0 & 0xFF) / 255, alpha: 1).cgColor
      }
      layer?.addSublayer(rainbow)
    }
    ring.fillColor = nil
    ring.lineWidth = 2
    layer?.addSublayer(ring)
    check.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)
    check.symbolConfiguration = .init(pointSize: 11, weight: .bold)
    check.imageScaling = .scaleNone
    addSubview(check)
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }
  override var wantsUpdateLayer: Bool { true }
  override var mouseDownCanMoveWindow: Bool { false }
  override var acceptsFirstResponder: Bool { true }
  override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(convert(point, from: superview)) ? self : nil }

  /// What shows inside the ring: the colour itself (the lavender follows the appearance).
  private var color: NSColor? {
    if let hex, let rgb = ProfileColor.parse(hex) {
      return NSColor(srgbRed: rgb.r, green: rgb.g, blue: rgb.b, alpha: 1)
    }
    return isCustom ? nil : ProfileColor.lavender
  }

  override func updateLayer() {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    let inset: CGFloat = 4
    let inner = bounds.insetBy(dx: inset, dy: inset)
    fill.frame = inner
    fill.cornerRadius = inner.width / 2
    fill.backgroundColor = color?.cgColor
    rainbow.frame = inner
    rainbow.cornerRadius = inner.width / 2
    rainbow.isHidden = color != nil
    ring.frame = bounds
    ring.path = CGPath(ellipseIn: bounds.insetBy(dx: 1, dy: 1), transform: nil)
    ring.strokeColor = (isSelected ? NSColor.labelColor.withAlphaComponent(0.55) : NSColor.clear).cgColor
    CATransaction.commit()
    check.isHidden = !isSelected
    if let color { check.contentTintColor = ProfileColor.foreground(on: color) }
    check.frame = bounds
  }

  override func mouseDown(with event: NSEvent) { onClick?() }
  override func keyDown(with event: NSEvent) {
    if event.characters == " " { onClick?() } else { super.keyDown(with: event) }
  }
  override func accessibilityPerformPress() -> Bool {
    onClick?()
    return true
  }
  override func accessibilityValue() -> Any? { NSNumber(value: isSelected ? 1 : 0) }
}

/// A text link in the profile's colour.
private final class LinkButton: NSButton {
  var onClick: (() -> Void)?

  init(title: String) {
    super.init(frame: .zero)
    self.title = title
    isBordered = false
    bezelStyle = .regularSquare
    font = .systemFont(ofSize: 13, weight: .medium)
    target = self
    action = #selector(clicked)
    setButtonType(.momentaryChange)
    focusRingType = .exterior
    setAccessibilityRole(.link)
  }

  required init?(coder: NSCoder) { fatalError() }

  override var wantsUpdateLayer: Bool { false }

  override func draw(_ dirtyRect: NSRect) {
    let attributes: [NSAttributedString.Key: Any] = [.font: font ?? .systemFont(ofSize: 13), .foregroundColor: ProfileColor.accent]
    NSAttributedString(string: title, attributes: attributes).draw(at: NSPoint(x: 0, y: 1))
  }

  override var intrinsicContentSize: NSSize {
    let size = NSAttributedString(string: title, attributes: [.font: font ?? .systemFont(ofSize: 13)]).size()
    return NSSize(width: ceil(size.width), height: ceil(size.height) + 2)
  }

  override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

  @objc private func clicked() { onClick?() }
}
