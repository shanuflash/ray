import AppKit

// Ray's first run, and File › Import from Browser…: an overlay over the whole browser window. A veil (the window's
// own content, blurred within the window and washed, as Ardia's onboarding does) and a centred card in Ray's panel
// colours, whose steps slide on a spring. The first run walks Welcome → where you're coming from → what to bring →
// moving in → your colour → three keys; the import runs the middle three only. The data comes from `ImportSession`
// (the importer's contract) and nothing else; the importer writes into this window's sidebar as items land.

/// The first launch's whole welcome, or File › Import from Browser…'s import steps alone.
enum OnboardingMode: String {
  case firstRun, importOnly

  var steps: [OnboardingStep] {
    self == .firstRun ? [.welcome, .source, .items, .importing, .theme, .keys] : [.source, .items, .importing]
  }
}

enum OnboardingStep: String {
  case welcome, source, items, importing, theme, keys
}

/// One chosen item while it moves in.
enum ImportRowState: Equatable {
  case waiting, running, done(Int), failed(String)

  var name: String {
    switch self {
    case .waiting: "waiting"
    case .running: "running"
    case .done: "done"
    case .failed: "failed"
    }
  }
}

// MARK: Data source

/// The importer's `ImportSession`, kept alive until each call has answered. Finding the browsers does real work
/// (each one's Local State, Arc's whole sidebar file, app icons), so it runs off the main thread.
private final class ImportBackend {
  private var live: [ObjectIdentifier: ImportSession] = [:]

  func sources(completion: @escaping ([ImportSource]) -> Void) {
    DispatchQueue.global(qos: .userInitiated).async {
      let found = ImportSession.sources()
      DispatchQueue.main.async { completion(found) }
    }
  }

  func preview(_ source: ImportSource, profile: ImportProfile, completion: @escaping (ImportPreview) -> Void) {
    let session = ImportSession()
    let key = ObjectIdentifier(session)
    live[key] = session
    session.preview(source, profile: profile) { [weak self] preview in
      self?.live[key] = nil
      completion(preview)
    }
  }

  func run(_ source: ImportSource, profile: ImportProfile, items: Set<ImportItem>, into controller: BrowserWindowController,
           event: @escaping (ImportEvent) -> Void, completion: @escaping (ImportSummary) -> Void) {
    let session = ImportSession()
    let key = ObjectIdentifier(session)
    live[key] = session
    session.run(source, profile: profile, items: items, into: controller, event: event) { [weak self] summary in
      self?.live[key] = nil
      completion(summary)
    }
  }
}

extension ImportItem {
  /// The row's title in these screens: extensions come across as a list only for now (none get installed).
  var onboardingTitle: String { self == .extensions ? "Extensions (list only, installing comes later)" : title }
  /// Ticked by default: everything that really comes across.
  var onByDefault: Bool { self != .extensions }
}

// MARK: Overlay

/// The overlay itself: owns the flow's state, the veil and the card. Added above everything in the window's host
/// view, so nothing the window opens later (a toast, the command bar) can cover it.
final class OnboardingView: NSView {
  /// Whether the first run shows at launch: once per new data dir (`RaySettings`' `onboarded`); test builds only
  /// when a check asks for it (RAY_ONBOARDING=1), so every other check starts on a plain window.
  static var showsAtLaunch: Bool {
    !RaySettings.shared.values.onboarded && (!TestEnvironment.isTestBuild || TestEnvironment["RAY_ONBOARDING"] == "1")
  }

  static let cardWidth: CGFloat = 460
  static let minCardHeight: CGFloat = 400
  static let footerHeight: CGFloat = 64

  let mode: OnboardingMode
  var onClose: (() -> Void)?
  /// Called on every change, for the state log.
  var onChange: (() -> Void)?
  private weak var browser: BrowserWindowController?
  private let backend = ImportBackend()

  private let veil = NSVisualEffectView()
  private let wash = VeilWash()
  fileprivate let card = OnboardingCard()
  private var stepView: OnboardingStepView?
  private(set) var step: OnboardingStep
  private var trail: [OnboardingStep] = []
  private var closing = false
  private lazy var heightSpring = Spring(value: Self.minCardHeight, response: 0.34, dampingRatio: 0.9) {
    [weak self] _ in self?.layoutCard()
  }

  // The import's state.
  private(set) var sources: [ImportSource] = []
  /// The browsers on this Mac have been looked for (it takes a moment).
  private(set) var sourcesLoaded = false
  private(set) var selectedID: String?
  private var profileChoice: [String: String] = [:]
  private var previews: [String: ImportPreview] = [:]
  private(set) var checked: Set<ImportItem> = []
  private var checkedSource: String?
  private(set) var rows: [(item: ImportItem, state: ImportRowState)] = []
  private(set) var running = false
  private(set) var imported = false
  /// The source the last import ran from (its name titles the done state).
  private var importedFrom: ImportSource?

  init(mode: OnboardingMode, browser: BrowserWindowController) {
    self.mode = mode
    self.browser = browser
    step = mode.steps[0]
    super.init(frame: .zero)
    wantsLayer = true
    veil.material = .fullScreenUI
    veil.blendingMode = .withinWindow
    veil.state = .active
    veil.autoresizingMask = [.width, .height]
    wash.autoresizingMask = [.width, .height]
    addSubview(veil)
    addSubview(wash)
    addSubview(card)
    card.primary.onClick = { [weak self] in self?.primaryPressed() }
    card.back.onClick = { [weak self] in self?.backPressed() }
    backend.sources { [weak self] found in self?.sourcesArrived(found) }
    let center = NotificationCenter.default
    center.addObserver(self, selector: #selector(accentChanged), name: ProfileColor.didChange, object: nil)
    center.addObserver(self, selector: #selector(settingsChanged), name: RaySettings.didChange, object: nil)
  }

  required init?(coder: NSCoder) { fatalError() }

  deinit { NotificationCenter.default.removeObserver(self) }

  override var acceptsFirstResponder: Bool { true }
  override var mouseDownCanMoveWindow: Bool { false }

  // MARK: Presenting

  /// Shows the first step: the veil fades in and the card rises into place on a spring.
  func present() {
    veil.frame = bounds
    wash.frame = bounds
    show(step, direction: 0)
    heightSpring.jump(to: targetHeight)
    layoutCard()
    window?.makeFirstResponder(self)
    guard let layer, let cardLayer = card.layer else { return }
    let fade = CABasicAnimation(keyPath: "opacity")
    fade.fromValue = 0
    fade.toValue = 1
    fade.duration = 0.26
    fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
    layer.add(fade, forKey: "fade")
    let rise = CASpringAnimation(keyPath: "transform")
    rise.fromValue = NSValue(caTransform3D: card.transform(scale: 0.97, lift: -24))
    rise.toValue = NSValue(caTransform3D: CATransform3DIdentity)
    rise.mass = 1
    rise.stiffness = 260
    rise.damping = 26
    rise.duration = rise.settlingDuration
    let appear = CABasicAnimation(keyPath: "opacity")
    appear.fromValue = 0
    appear.toValue = 1
    appear.duration = 0.22
    cardLayer.add(rise, forKey: "rise")
    cardLayer.add(appear, forKey: "appear")
  }

  /// Ends the flow: the veil fades out while the card lifts away; then the overlay goes.
  func close() {
    guard !closing else { return }
    closing = true
    closeColorPanel()
    guard let layer, let cardLayer = card.layer else { return finishClose() }
    CATransaction.begin()
    CATransaction.setCompletionBlock { [weak self] in self?.finishClose() }
    let fade = CABasicAnimation(keyPath: "opacity")
    fade.fromValue = 1
    fade.toValue = 0
    fade.duration = 0.42
    fade.timingFunction = CAMediaTimingFunction(name: .easeIn)
    layer.opacity = 0
    layer.add(fade, forKey: "fade")
    let lift = CABasicAnimation(keyPath: "transform")
    lift.fromValue = NSValue(caTransform3D: CATransform3DIdentity)
    lift.toValue = NSValue(caTransform3D: card.transform(scale: 1.03, lift: 18))
    lift.duration = 0.42
    lift.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.7, 0.2)
    lift.fillMode = .forwards
    lift.isRemovedOnCompletion = false
    cardLayer.add(lift, forKey: "lift")
    CATransaction.commit()
    // Should the completion never come (no frames while the display sleeps), the overlay still goes.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.finishClose() }
  }

  private func finishClose() {
    guard superview != nil else { return }
    removeFromSuperview()
    onClose?()
  }

  // MARK: Steps

  private var index: Int { mode.steps.firstIndex(of: step) ?? 0 }

  private var targetHeight: CGFloat {
    let content = stepView?.fittingHeight(width: Self.cardWidth) ?? 0
    return max(Self.minCardHeight, ceil(content + Self.footerHeight))
  }

  private func go(to next: OnboardingStep) {
    guard next != step else { return }
    trail.append(step)
    move(to: next, direction: 1)
  }

  private func goBack() {
    guard let previous = trail.popLast() else { return }
    move(to: previous, direction: -1)
  }

  private func move(to next: OnboardingStep, direction: CGFloat) {
    if step == .theme { closeColorPanel() }
    step = next
    show(next, direction: direction)
    heightSpring.animate(to: targetHeight, in: self)
    changed()
  }

  private func show(_ next: OnboardingStep, direction: CGFloat) {
    let view: OnboardingStepView
    switch next {
    case .welcome: view = WelcomeStepView(flow: self)
    case .source: view = SourceStepView(flow: self)
    case .items: view = ItemsStepView(flow: self)
    case .importing: view = ImportingStepView(flow: self)
    case .theme: view = ThemeStepView(flow: self)
    case .keys: view = KeysStepView(flow: self)
    }
    view.refresh()
    let old = stepView
    stepView = view
    card.clip.addSubview(view)
    view.frame = NSRect(x: 0, y: 0, width: Self.cardWidth, height: view.fittingHeight(width: Self.cardWidth))
    updateFooter()
    guard direction != 0 else {
      old?.removeFromSuperview()
      return
    }
    // The old step drifts out the way you're going and fades; the new one comes in from the other side on a spring.
    if let old, let oldLayer = old.layer {
      CATransaction.begin()
      CATransaction.setCompletionBlock { old.removeFromSuperview() }
      let slide = CABasicAnimation(keyPath: "transform.translation.x")
      slide.fromValue = 0
      slide.toValue = -30 * direction
      let fade = CABasicAnimation(keyPath: "opacity")
      fade.fromValue = 1
      fade.toValue = 0
      let group = CAAnimationGroup()
      group.animations = [slide, fade]
      group.duration = 0.2
      group.timingFunction = CAMediaTimingFunction(name: .easeIn)
      group.fillMode = .forwards
      group.isRemovedOnCompletion = false
      oldLayer.add(group, forKey: "leave")
      CATransaction.commit()
    } else {
      old?.removeFromSuperview()
    }
    guard let layer = view.layer else { return }
    let slide = CASpringAnimation(keyPath: "transform.translation.x")
    slide.fromValue = 40 * direction
    slide.toValue = 0
    slide.mass = 1
    slide.stiffness = 300
    slide.damping = 30
    slide.duration = slide.settlingDuration
    let fade = CABasicAnimation(keyPath: "opacity")
    fade.fromValue = 0
    fade.toValue = 1
    fade.duration = 0.22
    fade.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) + 0.06
    fade.fillMode = .backwards
    fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
    layer.add(slide, forKey: "enter")
    layer.add(fade, forKey: "enterFade")
  }

  /// Something the current step shows changed (a preview arrived, a box was ticked, an item landed).
  private func refresh() {
    stepView?.refresh()
    stepView?.needsLayout = true
    if let stepView { stepView.frame.size.height = stepView.fittingHeight(width: Self.cardWidth) }
    updateFooter()
    heightSpring.animate(to: targetHeight, in: self)
    changed()
  }

  private func changed() { onChange?() }

  // MARK: Footer

  private var primaryTitle: String {
    switch step {
    case .welcome: "Get started"
    case .source, .theme: "Continue"
    case .items: "Import"
    case .importing: mode == .importOnly ? "Done" : "Continue"
    case .keys: "Start browsing"
    }
  }

  private var primaryEnabled: Bool {
    switch step {
    case .source: sourcesLoaded && selectedSource != nil
    case .items: !checked.isEmpty
    case .importing: imported
    default: true
    }
  }

  /// The secondary button: Back, or Cancel where the import alone begins; none where there's no going back.
  private var backTitle: String? {
    switch step {
    case .welcome, .importing: nil
    case .source: mode == .importOnly ? "Cancel" : "Back"
    default: "Back"
    }
  }

  private func updateFooter() {
    card.primary.title = primaryTitle
    card.primary.isEnabled = primaryEnabled
    card.back.title = backTitle ?? ""
    card.back.isHidden = backTitle == nil
    card.dots.count = mode.steps.count
    card.dots.index = index
    card.needsLayout = true
  }

  private func primaryPressed() {
    guard primaryEnabled, !closing else { return }
    switch step {
    case .welcome: go(to: .source)
    case .source:
      if let source = selectedSource, checkedSource != source.id {
        checked = source.items.filter(\.onByDefault)
        checkedSource = source.id
      }
      go(to: .items)
    case .items: startImport()
    case .importing:
      if mode == .importOnly { close() } else { go(to: .theme) }
    case .theme: go(to: .keys)
    case .keys: finish()
    }
  }

  private func backPressed() {
    guard !closing, backTitle != nil else { return }
    if step == .source && mode == .importOnly { return close() }
    goBack()
  }

  /// "Start fresh instead": nothing to import, straight to the colour.
  fileprivate func startFresh() {
    guard step == .source, mode == .firstRun else { return }
    go(to: .theme)
  }

  private func finish() {
    if mode == .firstRun { RaySettings.shared.markOnboarded() }
    close()
  }

  /// Escape: the import alone can be left (not while it runs); the first run only ends through its own buttons.
  private func cancel() {
    guard mode == .importOnly, !running, !closing else { return }
    close()
  }

  // MARK: Keys and mouse

  override func keyDown(with event: NSEvent) {
    switch event.keyCode {
    case 36, 76: primaryPressed()
    case 53: cancel()
    default: break
    }
  }

  override func cancelOperation(_ sender: Any?) { cancel() }

  /// Outside the card the veil is the window's drag area (as Ardia's is); nothing reaches the page or sidebar.
  override func hitTest(_ point: NSPoint) -> NSView? {
    guard !isHidden, !closing, frame.contains(point) else { return nil }
    let local = convert(point, from: superview)
    if card.frame.contains(local), let hit = card.hitTest(convert(local, to: card.superview)) { return hit }
    return self
  }

  override func mouseDown(with event: NSEvent) {
    window?.makeFirstResponder(self)
    if event.clickCount == 2 { window?.performZoom(nil) } else { window?.performDrag(with: event) }
  }

  override func rightMouseDown(with event: NSEvent) {}
  override func scrollWheel(with event: NSEvent) {}

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    trackingAreas.forEach(removeTrackingArea)
    addTrackingArea(NSTrackingArea(rect: .zero, options: [.cursorUpdate, .activeAlways, .inVisibleRect], owner: self))
  }

  override func cursorUpdate(with event: NSEvent) { NSCursor.arrow.set() }

  // MARK: Layout

  override func layout() {
    super.layout()
    veil.frame = bounds
    wash.frame = bounds
    layoutCard()
  }

  private func layoutCard() {
    let width = Self.cardWidth, height = heightSpring.value.rounded()
    card.frame = NSRect(x: ((bounds.width - width) / 2).rounded(), y: ((bounds.height - height) / 2).rounded(),
                        width: width, height: height)
  }

  @objc private func accentChanged() {
    setNeedsDisplayRecursively()
    stepView?.refresh()
  }

  @objc private func settingsChanged() {
    stepView?.refresh()
    changed()
  }

  // MARK: Sources

  var selectedSource: ImportSource? { sources.first { $0.id == selectedID } }

  func profile(of source: ImportSource) -> ImportProfile? {
    let chosen = profileChoice[source.id]
    return source.profiles.first { $0.id == chosen } ?? source.profiles.first
  }

  func preview(of source: ImportSource) -> ImportPreview? {
    profile(of: source).flatMap { previews[Self.key(source, $0)] }
  }

  private static func key(_ source: ImportSource, _ profile: ImportProfile) -> String { source.id + "\u{1}" + profile.id }

  private func requestPreview(_ source: ImportSource) {
    guard let profile = profile(of: source), previews[Self.key(source, profile)] == nil else { return }
    backend.preview(source, profile: profile) { [weak self] preview in
      guard let self else { return }
      self.previews[Self.key(source, profile)] = preview
      if self.step == .source || self.step == .items { self.refresh() } else { self.changed() }
    }
  }

  private func sourcesArrived(_ found: [ImportSource]) {
    // Recommended (Arc) first, then as the importer listed them.
    sources = found.enumerated().sorted {
      $0.element.recommended != $1.element.recommended ? $0.element.recommended : $0.offset < $1.offset
    }.map(\.element)
    sourcesLoaded = true
    if selectedID == nil || !sources.contains(where: { $0.id == selectedID }) { selectedID = sources.first?.id }
    for source in sources { requestPreview(source) }
    refresh()
  }

  fileprivate func choose(_ id: String) {
    guard sources.contains(where: { $0.id == id }), selectedID != id else { return }
    selectedID = id
    refresh()
  }

  fileprivate func chooseProfile(_ id: String) {
    guard let source = selectedSource, source.profiles.contains(where: { $0.id == id }) else { return }
    profileChoice[source.id] = id
    requestPreview(source)
    refresh()
  }

  fileprivate func toggle(_ item: ImportItem) {
    guard selectedSource?.items.contains(item) == true, step == .items else { return }
    if checked.contains(item) { checked.remove(item) } else { checked.insert(item) }
    refresh()
  }

  /// Ticked items that need the source's Keychain key: macOS asks for it once.
  var needsUnlock: Bool { checked.contains { $0.needsUnlock } }

  // MARK: Import

  private func startImport() {
    guard let source = selectedSource, let profile = profile(of: source), let browser, !running else { return }
    let items = checked
    rows = ImportItem.allCases.filter(items.contains).map { ($0, .waiting) }
    running = true
    imported = false
    importedFrom = source
    go(to: .importing)
    backend.run(source, profile: profile, items: items, into: browser, event: { [weak self] event in
      self?.importEvent(event)
    }, completion: { [weak self] summary in
      self?.importFinished(summary)
    })
  }

  private func setRow(_ item: ImportItem, _ state: ImportRowState) {
    guard let at = rows.firstIndex(where: { $0.item == item }) else { return }
    rows[at].state = state
  }

  private func importEvent(_ event: ImportEvent) {
    guard running else { return }
    switch event {
    case .started(let item): setRow(item, .running)
    case .finished(let item, let count): setRow(item, .done(count))
    case .failed(let item, let reason): setRow(item, .failed(reason))
    }
    refresh()
  }

  private func importFinished(_ summary: ImportSummary) {
    for (at, row) in rows.enumerated() where row.state == .waiting || row.state == .running {
      if let count = summary.imported[row.item] {
        rows[at].state = .done(count)
      } else {
        rows[at].state = .failed(summary.failed[row.item] ?? "Nothing came across")
      }
    }
    running = false
    imported = true
    refresh()
  }

  var importProgress: Double {
    guard !rows.isEmpty else { return imported ? 1 : 0 }
    let landed = rows.filter { if case .done = $0.state { true } else if case .failed = $0.state { true } else { false } }
    return Double(landed.count) / Double(rows.count)
  }

  var importSourceName: String { importedFrom?.name ?? selectedSource?.name ?? "" }

  // MARK: Colour panel

  private var ownsColorPanel = false

  fileprivate func openColorPanel() {
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

  private func closeColorPanel() {
    guard ownsColorPanel else { return }
    ownsColorPanel = false
    let panel = NSColorPanel.shared
    panel.setTarget(nil)
    panel.setAction(nil)
    panel.close()
  }

  // MARK: Tests

  /// For the state log.
  var debug: [String: Any] {
    let frame = card.convert(card.bounds, to: nil)
    let height = window?.contentView?.bounds.height ?? 0
    let content = window?.contentView?.bounds ?? .zero
    let source = selectedSource
    return [
      "mode": mode.rawValue, "step": step.rawValue, "steps": mode.steps.map(\.rawValue), "dot": card.dots.index,
      "dots": card.dots.count, "closing": closing,
      "title": stepView?.titleLabel.stringValue ?? "",
      "sources": sources.map { source -> [String: Any] in
        ["id": source.id, "name": source.name, "recommended": source.recommended, "note": source.note ?? NSNull(),
         "summary": preview(of: source)?.summary ?? NSNull(), "profiles": source.profiles.map(\.id)]
      },
      "sourcesLoaded": sourcesLoaded, "source": selectedID ?? NSNull(),
      "profile": source.flatMap { profile(of: $0)?.id } ?? NSNull(),
      "profilePicker": (stepView as? SourceStepView)?.profilePickerShown ?? false,
      "freshLink": (stepView as? SourceStepView)?.freshLinkShown ?? false,
      "items": ImportItem.allCases.filter { source?.items.contains($0) == true }.map(\.rawValue),
      "checked": ImportItem.allCases.filter(checked.contains).map(\.rawValue),
      "counts": Dictionary(uniqueKeysWithValues: (source.flatMap { preview(of: $0)?.counts } ?? [:]).map { ($0.key.rawValue, $0.value) }),
      "unlockNote": (stepView as? ItemsStepView)?.unlockNoteShown ?? false,
      "rows": rows.map { row -> [String: Any] in
        var out: [String: Any] = ["item": row.item.rawValue, "state": row.state.name]
        if case .done(let count) = row.state { out["count"] = count }
        if case .failed(let reason) = row.state { out["reason"] = reason }
        return out
      },
      "progress": importProgress, "running": running, "imported": imported,
      "keys": (stepView as? KeysStepView)?.keys ?? [],
      "swatch": (stepView as? ThemeStepView)?.swatchSelection ?? NSNull(),
      "primary": card.primary.title, "primaryEnabled": card.primary.isEnabled,
      "back": card.back.isHidden ? NSNull() : card.back.title,
      "cardFrame": String(format: "%.0f,%.0f,%.0f,%.0f", frame.minX, height - frame.maxY, frame.width, frame.height),
      "cardInWindow": content.contains(frame),
      "focused": window?.firstResponder === self,
    ]
  }

  /// For tests: what a click or key would do. Returns "ok" or why not.
  func command(_ words: [String]) -> String {
    switch words.first {
    case "next", "import", "finish":
      if words.first == "import" && step != .items { return "not on the items step" }
      if words.first == "finish" && !(step == .keys || (mode == .importOnly && step == .importing)) { return "not at the end" }
      guard card.primary.isEnabled else { return "disabled" }
      card.primary.press()
    case "back":
      guard !card.back.isHidden else { return "no back" }
      card.back.press()
    case "fresh":
      guard (stepView as? SourceStepView)?.pressFresh() == true else { return "no link" }
    case "choose":
      guard words.count == 2, step == .source, let row = (stepView as? SourceStepView)?.row(words[1]) else { return "no such source" }
      row.press()
    case "profile":
      // Profile ids can hold spaces ("Profile 1").
      let id = words.dropFirst().joined(separator: " ")
      guard !id.isEmpty, (stepView as? SourceStepView)?.pickProfile(id) == true else { return "no such profile" }
    case "toggle":
      guard words.count == 2, let item = ImportItem(rawValue: words[1]), let row = (stepView as? ItemsStepView)?.row(item) else {
        return "no such item"
      }
      row.press()
    case "swatch":
      guard words.count == 2, let n = Int(words[1]), (stepView as? ThemeStepView)?.pressSwatch(n) == true else { return "no swatch" }
    case "escape":
      keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                     context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                     isARepeat: false, keyCode: 53)!)
    default:
      return "usage: onboarding show|next|back|fresh|choose <id>|profile <id>|toggle <item>|import|swatch <n>|escape|finish|snap <path>"
    }
    return "ok"
  }
}

/// The veil's wash over the blur: Ardia's (white in light, black in dark), lighter, so the sidebar and page still
/// read behind it.
private final class VeilWash: NSView {
  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
  }

  required init?(coder: NSCoder) { fatalError() }

  override var wantsUpdateLayer: Bool { true }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func updateLayer() {
    let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    layer?.backgroundColor = (dark ? NSColor(white: 0, alpha: 0.42) : NSColor(white: 1, alpha: 0.38)).cgColor
  }
}

// MARK: Card

private enum OnboardingColors {
  private static func dynamic(dark: NSColor, light: NSColor) -> NSColor {
    NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light }
  }

  static let card = dynamic(dark: NSColor(white: 0.16, alpha: 1), light: NSColor(white: 0.985, alpha: 1))
  static let idleDot = dynamic(dark: NSColor(white: 1, alpha: 0.2), light: NSColor(white: 0, alpha: 0.16))
  static let boxOff = dynamic(dark: NSColor(white: 1, alpha: 0.3), light: NSColor(white: 0, alpha: 0.25))

  static func accent(_ light: CGFloat, dark: CGFloat) -> NSColor {
    NSColor(name: nil) { appearance in
      let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
      var resolved = ProfileColor.accent
      appearance.performAsCurrentDrawingAppearance { resolved = ProfileColor.accent.usingColorSpace(.sRGB) ?? ProfileColor.accent }
      return resolved.withAlphaComponent(isDark ? dark : light)
    }
  }
}

/// The card: Ray's panel colours, a hairline and a soft shadow; steps slide inside its rounded clip, the step dots and
/// buttons stay put along the bottom.
fileprivate final class OnboardingCard: NSView {
  static let radius: CGFloat = 16
  let clip = FlippedClipView()
  let dots = StepDots()
  let back = OnboardingButton(style: .secondary)
  let primary = OnboardingButton(style: .primary)

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.cornerRadius = Self.radius
    layer?.cornerCurve = .continuous
    layer?.masksToBounds = false
    layer?.borderWidth = 1
    layer?.shadowColor = NSColor.black.cgColor
    layer?.shadowRadius = 30
    layer?.shadowOffset = CGSize(width: 0, height: -14)
    clip.wantsLayer = true
    clip.layer?.cornerRadius = Self.radius
    clip.layer?.cornerCurve = .continuous
    clip.layer?.masksToBounds = true
    addSubview(clip)
    addSubview(dots)
    addSubview(back)
    addSubview(primary)
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }
  override var wantsUpdateLayer: Bool { true }
  override var mouseDownCanMoveWindow: Bool { false }

  override func updateLayer() {
    let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    layer?.backgroundColor = OnboardingColors.card.cgColor
    layer?.borderColor = PanelColors.border.cgColor
    layer?.shadowOpacity = dark ? 0.4 : 0.2
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    needsDisplay = true
  }

  override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(superview) }

  /// A scale about the card's middle and a lift (points up), whatever the layer's anchor point.
  func transform(scale: CGFloat, lift: CGFloat) -> CATransform3D {
    guard let layer else { return CATransform3DIdentity }
    let dx = (0.5 - layer.anchorPoint.x) * layer.bounds.width
    let dy = (0.5 - layer.anchorPoint.y) * layer.bounds.height
    var t = CATransform3DMakeScale(scale, scale, 1)
    t.m41 = dx * (1 - scale)
    t.m42 = dy * (1 - scale) + lift
    return t
  }

  override func layout() {
    super.layout()
    layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: Self.radius, cornerHeight: Self.radius, transform: nil)
    clip.frame = bounds
    let mid = bounds.height - OnboardingView.footerHeight / 2
    let primarySize = primary.intrinsicContentSize
    primary.frame = NSRect(x: bounds.width - 20 - primarySize.width, y: (mid - primarySize.height / 2).rounded(),
                           width: primarySize.width, height: primarySize.height)
    let backSize = back.intrinsicContentSize
    back.frame = NSRect(x: primary.frame.minX - 8 - backSize.width, y: primary.frame.minY,
                        width: backSize.width, height: backSize.height)
    let dotsSize = dots.intrinsicContentSize
    dots.frame = NSRect(x: 28, y: (mid - dotsSize.height / 2).rounded(), width: dotsSize.width, height: dotsSize.height)
  }
}

fileprivate final class FlippedClipView: NSView {
  override var isFlipped: Bool { true }
}

/// Where you are: a dot per step, the current one a short pill in the profile's colour.
fileprivate final class StepDots: NSView {
  var count = 0 { didSet { if count != oldValue { rebuild() } } }
  var index = 0 { didSet { if index != oldValue { needsDisplay = true; needsLayout = true } } }
  private var dots: [CALayer] = []
  private static let size: CGFloat = 6
  private static let current: CGFloat = 18
  private static let gap: CGFloat = 6

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }
  override var wantsUpdateLayer: Bool { true }
  override var intrinsicContentSize: NSSize {
    NSSize(width: CGFloat(max(0, count - 1)) * (Self.size + Self.gap) + Self.current, height: Self.size)
  }

  private func rebuild() {
    dots.forEach { $0.removeFromSuperlayer() }
    dots = (0..<count).map { _ in
      let dot = CALayer()
      dot.cornerRadius = Self.size / 2
      layer?.addSublayer(dot)
      return dot
    }
    invalidateIntrinsicContentSize()
    needsLayout = true
    needsDisplay = true
  }

  override func updateLayer() {
    for (at, dot) in dots.enumerated() {
      dot.backgroundColor = (at == index ? ProfileColor.accent : OnboardingColors.idleDot).cgColor
    }
  }

  override func layout() {
    super.layout()
    CATransaction.begin()
    CATransaction.setAnimationDuration(0.28)
    CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1))
    var x: CGFloat = 0
    for (at, dot) in dots.enumerated() {
      let width = at == index ? Self.current : Self.size
      dot.frame = CGRect(x: x, y: 0, width: width, height: Self.size)
      x += width + Self.gap
    }
    CATransaction.commit()
  }
}

/// The card's buttons: the primary one filled in the profile's colour with the text that reads best on it, the
/// secondary one a quiet fill, both 30 pt tall with an 8 pt radius.
fileprivate final class OnboardingButton: NSControl {
  enum Style { case primary, secondary }
  let style: Style
  var onClick: (() -> Void)?
  private let label = NSTextField(labelWithString: "")
  private var hovered = false
  private var pressed = false

  var title: String {
    get { label.stringValue }
    set {
      guard newValue != label.stringValue else { return }
      label.stringValue = newValue
      setAccessibilityLabel(newValue)
      invalidateIntrinsicContentSize()
      superview?.needsLayout = true
      needsLayout = true
    }
  }

  override var isEnabled: Bool {
    didSet { alphaValue = isEnabled ? 1 : 0.4; needsDisplay = true }
  }

  init(style: Style) {
    self.style = style
    super.init(frame: .zero)
    wantsLayer = true
    layer?.cornerRadius = 8
    layer?.cornerCurve = .continuous
    label.font = .systemFont(ofSize: 13, weight: .medium)
    label.alignment = .center
    addSubview(label)
    setAccessibilityRole(.button)
    addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }
  override var wantsUpdateLayer: Bool { true }
  override var mouseDownCanMoveWindow: Bool { false }
  override var intrinsicContentSize: NSSize {
    NSSize(width: max(style == .primary ? 96 : 72, widthOf(label) + 28), height: 30)
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    !isHidden && frame.contains(point) ? self : nil
  }

  override func updateLayer() {
    let lit = isEnabled && (hovered || pressed)
    switch style {
    case .primary:
      let accent = ProfileColor.accent
      let fill = lit ? (accent.usingColorSpace(.sRGB)?.blended(withFraction: pressed ? 0.16 : 0.08, of: .black) ?? accent) : accent
      layer?.backgroundColor = fill.cgColor
      label.textColor = ProfileColor.foreground(on: accent)
    case .secondary:
      layer?.backgroundColor = (lit ? PanelColors.tileHover : PanelColors.tile).cgColor
      label.textColor = .labelColor
    }
  }

  override func layout() {
    super.layout()
    let line = ceil(label.intrinsicContentSize.height)
    label.frame = NSRect(x: 4, y: ((bounds.height - line) / 2).rounded(), width: bounds.width - 8, height: line)
  }

  override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
  override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }

  override func mouseDown(with event: NSEvent) {
    guard isEnabled else { return }
    pressed = true
    needsDisplay = true
  }

  override func mouseUp(with event: NSEvent) {
    let inside = bounds.contains(convert(event.locationInWindow, from: nil))
    pressed = false
    needsDisplay = true
    if inside { press() }
  }

  func press() {
    guard isEnabled, !isHidden else { return }
    onClick?()
  }

  override func accessibilityPerformPress() -> Bool {
    press()
    return true
  }
}

// MARK: Step views

private func oneLine(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
  let label = NSTextField(labelWithString: text)
  label.font = .systemFont(ofSize: size, weight: weight)
  label.textColor = color
  label.lineBreakMode = .byTruncatingTail
  return label
}

private func wrapping(_ text: String, size: CGFloat, color: NSColor = .secondaryLabelColor) -> NSTextField {
  let label = NSTextField(wrappingLabelWithString: text)
  label.font = .systemFont(ofSize: size)
  label.textColor = color
  label.isSelectable = false
  label.cell?.wraps = true
  label.cell?.truncatesLastVisibleLine = false
  return label
}

private func lineHeight(_ label: NSTextField) -> CGFloat { ceil(label.intrinsicContentSize.height) }

/// The width a one-line label's text needs (a truncating label reports no intrinsic width of its own).
private func widthOf(_ label: NSTextField) -> CGFloat { ceil(label.attributedStringValue.size().width) + 4 }

/// A label laid one line tall, centred on `mid` (labels draw from the top of their frame).
private func placeLine(_ label: NSTextField, x: CGFloat, mid: CGFloat, width: CGFloat) {
  let line = lineHeight(label)
  label.frame = NSRect(x: x, y: (mid - line / 2).rounded(), width: max(0, width), height: line)
}

/// One step's content: a title and a grey line under it, then its own rows. Laid out top-down in the card's width;
/// `place(width:apply:)` both measures and lays out, so the card's height always matches what's drawn.
fileprivate class OnboardingStepView: NSView {
  static let inset: CGFloat = 28
  unowned let flow: OnboardingView
  let titleLabel = oneLine("", size: 22, weight: .semibold)
  let subtitleLabel = wrapping("", size: 13)

  init(flow: OnboardingView) {
    self.flow = flow
    super.init(frame: .zero)
    wantsLayer = true
    addSubview(titleLabel)
    addSubview(subtitleLabel)
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }

  func refresh() {}

  func fittingHeight(width: CGFloat) -> CGFloat { place(width: width, apply: false) }

  override func layout() {
    super.layout()
    _ = place(width: bounds.width, apply: true)
  }

  /// Lays the title and line from the top; returns where the step's own content starts.
  func placeHeader(width: CGFloat, apply: Bool) -> CGFloat {
    let inset = Self.inset
    var y: CGFloat = 30
    let title = lineHeight(titleLabel)
    if apply { titleLabel.frame = NSRect(x: inset, y: y, width: width - inset * 2, height: title) }
    y += title + 4
    let sub = textHeight(subtitleLabel, width: width - inset * 2)
    if apply { subtitleLabel.frame = NSRect(x: inset, y: y, width: width - inset * 2, height: sub) }
    return y + sub + 18
  }

  func place(width: CGFloat, apply: Bool) -> CGFloat { placeHeader(width: width, apply: apply) }
}

// MARK: Welcome

fileprivate final class WelcomeStepView: OnboardingStepView {
  private let icon = NSImageView()

  override init(flow: OnboardingView) {
    super.init(flow: flow)
    icon.image = NSApp.applicationIconImage
    icon.imageScaling = .scaleProportionallyUpOrDown
    addSubview(icon)
    titleLabel.stringValue = "Welcome to Ray"
    titleLabel.font = .systemFont(ofSize: 26, weight: .semibold)
    titleLabel.alignment = .center
    subtitleLabel.stringValue = "Arc's sidebar on real Chromium. Bring your tabs, logins and history over in a minute."
    subtitleLabel.font = .systemFont(ofSize: 14)
    subtitleLabel.alignment = .center
  }

  required init?(coder: NSCoder) { fatalError() }

  override func place(width: CGFloat, apply: Bool) -> CGFloat {
    let size: CGFloat = 112
    // Centred in the card above the footer.
    let textWidth: CGFloat = 340
    let block = size + 16 + lineHeight(titleLabel) + 8 + textHeight(subtitleLabel, width: textWidth)
    var y = max(40, ((OnboardingView.minCardHeight - OnboardingView.footerHeight - block) / 2).rounded() + 8)
    if apply { icon.frame = NSRect(x: ((width - size) / 2).rounded(), y: y, width: size, height: size) }
    y += size + 16
    let title = lineHeight(titleLabel)
    if apply { titleLabel.frame = NSRect(x: 28, y: y, width: width - 56, height: title) }
    y += title + 8
    let sub = textHeight(subtitleLabel, width: textWidth)
    if apply { subtitleLabel.frame = NSRect(x: ((width - textWidth) / 2).rounded(), y: y, width: textWidth, height: sub) }
    return y + sub + 20
  }
}

// MARK: Where from

fileprivate final class SourceStepView: OnboardingStepView {
  private var rows: [SourceRowView] = []
  private let empty = wrapping("", size: 13)
  private let profileLabel = oneLine("Profile", size: 12, weight: .medium, color: .secondaryLabelColor)
  private let profiles = NSPopUpButton(frame: .zero, pullsDown: false)
  private let fresh = OnboardingLink(title: "Start fresh instead")

  override init(flow: OnboardingView) {
    super.init(flow: flow)
    titleLabel.stringValue = "Where are you coming from?"
    subtitleLabel.stringValue = "Browsers found on this Mac."
    addSubview(empty)
    profiles.controlSize = .small
    profiles.font = .systemFont(ofSize: 12)
    profiles.target = self
    profiles.action = #selector(profileChosen)
    profiles.setAccessibilityLabel("Profile")
    addSubview(profileLabel)
    addSubview(profiles)
    fresh.onClick = { [weak flow] in flow?.startFresh() }
    addSubview(fresh)
  }

  required init?(coder: NSCoder) { fatalError() }

  var profilePickerShown: Bool { !profiles.isHidden }
  var freshLinkShown: Bool { !fresh.isHidden }

  func row(_ id: String) -> SourceRowView? { rows.first { $0.sourceID == id } }

  func pressFresh() -> Bool {
    guard !fresh.isHidden else { return false }
    fresh.onClick?()
    return true
  }

  func pickProfile(_ id: String) -> Bool {
    guard !profiles.isHidden, let at = profiles.itemArray.firstIndex(where: { $0.representedObject as? String == id }) else {
      return false
    }
    profiles.selectItem(at: at)
    profileChosen()
    return true
  }

  @objc private func profileChosen() {
    guard let id = profiles.selectedItem?.representedObject as? String else { return }
    flow.chooseProfile(id)
  }

  /// One row per browser found, in the flow's order (they arrive a moment after the step shows).
  private func syncRows() {
    guard rows.map(\.sourceID) != flow.sources.map(\.id) else { return }
    rows.forEach { $0.removeFromSuperview() }
    rows = flow.sources.map { source in
      let row = SourceRowView(source: source)
      row.onClick = { [weak flow] in flow?.choose(source.id) }
      addSubview(row)
      return row
    }
  }

  override func refresh() {
    syncRows()
    let selected = flow.selectedSource
    for row in rows {
      guard let source = flow.sources.first(where: { $0.id == row.sourceID }) else { continue }
      row.selected = source.id == selected?.id
      row.detail = source.note ?? flow.preview(of: source)?.summary ?? ""
      row.dimmed = source.note != nil
    }
    empty.stringValue = flow.sourcesLoaded
      ? "No other browsers were found on this Mac. You can import later from File › Import from Browser…"
      : "Looking for browsers on this Mac…"
    empty.isHidden = !rows.isEmpty
    let many = (selected?.profiles.count ?? 0) > 1
    profiles.isHidden = !many
    profileLabel.isHidden = !many
    if many, let selected {
      let current = flow.profile(of: selected)?.id
      if profiles.itemArray.map({ $0.representedObject as? String }) != selected.profiles.map(\.id) {
        profiles.removeAllItems()
        for profile in selected.profiles {
          profiles.addItem(withTitle: profile.name)
          profiles.lastItem?.representedObject = profile.id
        }
      }
      if let at = selected.profiles.firstIndex(where: { $0.id == current }) { profiles.selectItem(at: at) }
    }
    fresh.isHidden = flow.mode != .firstRun
    needsLayout = true
  }

  override func place(width: CGFloat, apply: Bool) -> CGFloat {
    var y = placeHeader(width: width, apply: apply)
    let x: CGFloat = 20
    if rows.isEmpty {
      let height = textHeight(empty, width: width - Self.inset * 2)
      if apply { empty.frame = NSRect(x: Self.inset, y: y, width: width - Self.inset * 2, height: height) }
      y += height + 8
    }
    for row in rows {
      if apply { row.frame = NSRect(x: x, y: y, width: width - x * 2, height: SourceRowView.height) }
      y += SourceRowView.height + 2
    }
    if !profiles.isHidden {
      y += 10
      let size = profiles.fittingSize
      let label = lineHeight(profileLabel)
      let labelWidth = widthOf(profileLabel) + 4
      if apply {
        placeLine(profileLabel, x: Self.inset, mid: y + size.height / 2, width: labelWidth)
        profiles.frame = NSRect(x: Self.inset + labelWidth + 6, y: y, width: max(140, size.width), height: size.height)
      }
      y += max(size.height, label)
    }
    if !fresh.isHidden {
      y += 14
      let size = fresh.intrinsicContentSize
      if apply { fresh.frame = NSRect(x: Self.inset, y: y, width: size.width, height: size.height) }
      y += size.height
    }
    return y + 20
  }
}

/// A browser to bring things from, styled like the sidebar's rows: 32 pt, 8 pt radius, the profile's colour faint
/// on hover and stronger once chosen.
fileprivate final class SourceRowView: NSView {
  static let height: CGFloat = 32
  let sourceID: String
  var onClick: (() -> Void)?
  private let icon = NSImageView()
  private let name: NSTextField
  private let detailLabel = oneLine("", size: 12, color: .secondaryLabelColor)
  private let badge: Badge?
  private var hovered = false
  var selected = false { didSet { if selected != oldValue { needsDisplay = true } } }
  var dimmed = false { didSet { icon.alphaValue = dimmed ? 0.55 : 1 } }
  var detail: String {
    get { detailLabel.stringValue }
    set { if detailLabel.stringValue != newValue { detailLabel.stringValue = newValue; needsLayout = true } }
  }

  init(source: ImportSource) {
    sourceID = source.id
    name = oneLine(source.name, size: 13, weight: .medium)
    badge = source.recommended ? Badge(text: "Recommended") : nil
    super.init(frame: .zero)
    wantsLayer = true
    layer?.cornerRadius = 8
    layer?.cornerCurve = .continuous
    icon.image = source.icon ?? NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
    icon.imageScaling = .scaleProportionallyUpOrDown
    if source.icon == nil {
      icon.symbolConfiguration = .init(pointSize: 14, weight: .regular)
      icon.contentTintColor = .secondaryLabelColor
    }
    addSubview(icon)
    addSubview(name)
    addSubview(detailLabel)
    if let badge { addSubview(badge) }
    setAccessibilityRole(.radioButton)
    setAccessibilityLabel(source.name)
    addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }
  override var wantsUpdateLayer: Bool { true }
  override var mouseDownCanMoveWindow: Bool { false }
  override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }

  override func updateLayer() {
    let fill: NSColor = selected ? OnboardingColors.accent(0.16, dark: 0.26) : hovered ? OnboardingColors.accent(0.07, dark: 0.12) : .clear
    layer?.backgroundColor = fill.cgColor
  }

  override func layout() {
    super.layout()
    let mid = bounds.height / 2
    icon.frame = NSRect(x: 8, y: (mid - 9).rounded(), width: 18, height: 18)
    var right = bounds.width - 8
    if let badge {
      let size = badge.intrinsicContentSize
      badge.frame = NSRect(x: right - size.width, y: (mid - size.height / 2).rounded(), width: size.width, height: size.height)
      right = badge.frame.minX - 8
    }
    let nameWidth = min(widthOf(name) + 2, right - 34)
    placeLine(name, x: 34, mid: mid, width: nameWidth)
    placeLine(detailLabel, x: name.frame.maxX + 6, mid: mid, width: right - name.frame.maxX - 6)
  }

  override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
  override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
  override func mouseDown(with event: NSEvent) { press() }
  func press() { onClick?() }
  override func accessibilityPerformPress() -> Bool { press(); return true }
  override func accessibilityValue() -> Any? { NSNumber(value: selected ? 1 : 0) }
}

/// "Recommended": a small pill in the profile's colour.
fileprivate final class Badge: NSView {
  private let label: NSTextField

  init(text: String) {
    label = oneLine(text, size: 11, weight: .semibold)
    super.init(frame: .zero)
    wantsLayer = true
    layer?.cornerRadius = 9
    layer?.cornerCurve = .continuous
    addSubview(label)
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }
  override var wantsUpdateLayer: Bool { true }
  override var intrinsicContentSize: NSSize { NSSize(width: widthOf(label) + 14, height: 18) }

  override func updateLayer() {
    layer?.backgroundColor = OnboardingColors.accent(0.14, dark: 0.24).cgColor
    let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    // The colour itself reads on its own pale fill in light; in dark a lighter mix of it does.
    label.textColor = dark ? ProfileColor.accent.blended(withFraction: 0.35, of: .white) : ProfileColor.accent
  }

  override func layout() {
    super.layout()
    placeLine(label, x: 7, mid: bounds.height / 2, width: bounds.width - 14)
  }
}

/// A text link in the profile's colour.
fileprivate final class OnboardingLink: NSView {
  var onClick: (() -> Void)?
  private let label: NSTextField

  init(title: String) {
    label = oneLine(title, size: 13, weight: .medium)
    super.init(frame: .zero)
    addSubview(label)
    setAccessibilityRole(.link)
    setAccessibilityLabel(title)
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }
  override var intrinsicContentSize: NSSize { NSSize(width: widthOf(label) + 4, height: lineHeight(label)) }
  override func hitTest(_ point: NSPoint) -> NSView? { !isHidden && frame.contains(point) ? self : nil }
  override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

  override func layout() {
    super.layout()
    label.frame = bounds
    label.textColor = ProfileColor.accent
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    label.textColor = ProfileColor.accent
  }

  override func mouseDown(with event: NSEvent) { onClick?() }
  override func accessibilityPerformPress() -> Bool { onClick?(); return true }
}

// MARK: What to bring

fileprivate final class ItemsStepView: OnboardingStepView {
  private var rows: [CheckRowView] = []
  private let lock = NSImageView()
  private let note = wrapping("", size: 12)
  private static let counts: NumberFormatter = {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    return formatter
  }()

  override init(flow: OnboardingView) {
    super.init(flow: flow)
    let source = flow.selectedSource
    titleLabel.stringValue = "Bring from \(source?.name ?? "your browser")"
    subtitleLabel.stringValue = "Settings stay Ray's own."
    for item in ImportItem.allCases where source?.items.contains(item) == true {
      let row = CheckRowView(item: item)
      row.onToggle = { [weak flow] in flow?.toggle(item) }
      rows.append(row)
      addSubview(row)
    }
    lock.image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: nil)
    lock.symbolConfiguration = .init(pointSize: 11, weight: .medium)
    lock.contentTintColor = .secondaryLabelColor
    note.stringValue = "macOS asks once for your password to open \(source?.name ?? "its")'s saved logins."
    addSubview(lock)
    addSubview(note)
  }

  required init?(coder: NSCoder) { fatalError() }

  var unlockNoteShown: Bool { !note.isHidden }

  func row(_ item: ImportItem) -> CheckRowView? { rows.first { $0.item == item } }

  override func refresh() {
    let counts = flow.selectedSource.flatMap { flow.preview(of: $0)?.counts } ?? [:]
    for row in rows {
      row.isOn = flow.checked.contains(row.item)
      row.count = counts[row.item].flatMap { Self.counts.string(from: NSNumber(value: $0)) } ?? ""
    }
    note.isHidden = !flow.needsUnlock
    lock.isHidden = note.isHidden
    needsLayout = true
  }

  override func place(width: CGFloat, apply: Bool) -> CGFloat {
    var y = placeHeader(width: width, apply: apply) - 6
    for row in rows {
      if apply { row.frame = NSRect(x: 20, y: y, width: width - 40, height: CheckRowView.height) }
      y += CheckRowView.height
    }
    if !note.isHidden {
      y += 12
      let textX = Self.inset + 18
      let height = textHeight(note, width: width - textX - Self.inset)
      if apply {
        lock.frame = NSRect(x: Self.inset, y: y, width: 13, height: 15)
        note.frame = NSRect(x: textX, y: y, width: width - textX - Self.inset, height: height)
      }
      y += height
    }
    return y + 20
  }
}

/// A check box in the profile's colour, with the tick in the colour that reads best on it.
fileprivate final class CheckBox: NSView {
  var isOn = true { didSet { if isOn != oldValue { needsDisplay = true } } }
  private let tick = NSImageView()

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.cornerRadius = 4.5
    layer?.cornerCurve = .continuous
    tick.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)
    tick.symbolConfiguration = .init(pointSize: 9, weight: .heavy)
    tick.imageScaling = .scaleNone
    addSubview(tick)
  }

  required init?(coder: NSCoder) { fatalError() }

  override var wantsUpdateLayer: Bool { true }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func updateLayer() {
    layer?.backgroundColor = (isOn ? ProfileColor.accent : .clear).cgColor
    layer?.borderWidth = isOn ? 0 : 1.5
    layer?.borderColor = OnboardingColors.boxOff.cgColor
    tick.isHidden = !isOn
    tick.contentTintColor = ProfileColor.foreground(on: ProfileColor.accent)
  }

  override func layout() {
    super.layout()
    tick.frame = bounds
  }
}

/// One thing to bring: box, symbol, title, and the count on the right when the preview knows it.
fileprivate final class CheckRowView: NSView {
  static let height: CGFloat = 30
  let item: ImportItem
  var onToggle: (() -> Void)?
  private let box = CheckBox()
  private let icon = NSImageView()
  private let title: NSTextField
  private let countLabel = oneLine("", size: 12, color: .secondaryLabelColor)
  private var hovered = false
  var isOn: Bool {
    get { box.isOn }
    set { box.isOn = newValue }
  }
  var count: String {
    get { countLabel.stringValue }
    set { if countLabel.stringValue != newValue { countLabel.stringValue = newValue; needsLayout = true } }
  }

  init(item: ImportItem) {
    self.item = item
    title = oneLine(item.onboardingTitle, size: 13)
    super.init(frame: .zero)
    wantsLayer = true
    layer?.cornerRadius = 8
    layer?.cornerCurve = .continuous
    icon.image = NSImage(systemSymbolName: item.symbol, accessibilityDescription: nil)
    icon.symbolConfiguration = .init(pointSize: 13, weight: .regular)
    icon.contentTintColor = .secondaryLabelColor
    countLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    countLabel.alignment = .right
    for view in [box, icon, title, countLabel] as [NSView] { addSubview(view) }
    setAccessibilityRole(.checkBox)
    setAccessibilityLabel(item.onboardingTitle)
    addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }
  override var wantsUpdateLayer: Bool { true }
  override var mouseDownCanMoveWindow: Bool { false }
  override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }

  override func updateLayer() {
    layer?.backgroundColor = (hovered ? PanelColors.tile : .clear).cgColor
  }

  override func layout() {
    super.layout()
    let mid = bounds.height / 2
    box.frame = NSRect(x: 8, y: (mid - 8).rounded(), width: 16, height: 16)
    icon.frame = NSRect(x: 34, y: (mid - 9).rounded(), width: 18, height: 18)
    let countWidth = count.isEmpty ? 0 : widthOf(countLabel) + 2
    placeLine(countLabel, x: bounds.width - 10 - countWidth, mid: mid, width: countWidth)
    placeLine(title, x: 60, mid: mid, width: bounds.width - 60 - countWidth - 18)
  }

  override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
  override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
  override func mouseDown(with event: NSEvent) { press() }
  func press() { onToggle?() }
  override func accessibilityPerformPress() -> Bool { press(); return true }
  override func accessibilityValue() -> Any? { NSNumber(value: isOn ? 1 : 0) }
}

// MARK: Moving in

fileprivate final class ImportingStepView: OnboardingStepView {
  private let bar = ProgressBar()
  private var rows: [ProgressRowView] = []

  override init(flow: OnboardingView) {
    super.init(flow: flow)
    addSubview(bar)
    for row in flow.rows {
      let view = ProgressRowView(item: row.item)
      rows.append(view)
      addSubview(view)
    }
  }

  required init?(coder: NSCoder) { fatalError() }

  override func refresh() {
    let failures = flow.rows.filter { if case .failed = $0.state { true } else { false } }.count
    if !flow.imported {
      titleLabel.stringValue = "Moving in…"
      subtitleLabel.stringValue = "Your sidebar fills in as it goes."
    } else if failures == 0 {
      titleLabel.stringValue = "You're moved in"
      subtitleLabel.stringValue = "Everything you chose from \(flow.importSourceName) is in Ray now."
    } else {
      titleLabel.stringValue = "You're moved in"
      subtitleLabel.stringValue = failures == flow.rows.count
        ? "Nothing came across this time. You can try again from File › Import from Browser…"
        : "Most of it came across. What didn't stays in \(flow.importSourceName); try again from File › Import from Browser…"
    }
    for (view, row) in zip(rows, flow.rows) { view.show(row.state) }
    bar.fraction = flow.importProgress
    needsLayout = true
  }

  override func place(width: CGFloat, apply: Bool) -> CGFloat {
    var y = placeHeader(width: width, apply: apply) - 6
    if apply { bar.frame = NSRect(x: Self.inset, y: y, width: width - Self.inset * 2, height: 3) }
    y += 3 + 10
    for row in rows {
      if apply { row.frame = NSRect(x: 20, y: y, width: width - 40, height: ProgressRowView.height) }
      y += ProgressRowView.height
    }
    return y + 20
  }
}

/// A thin bar in the profile's colour, on a quiet track; the fill eases to each new width.
fileprivate final class ProgressBar: NSView {
  private let fill = CALayer()
  var fraction: Double = 0 {
    didSet { if fraction != oldValue { placeFill(animated: true) } }
  }

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.cornerRadius = 1.5
    layer?.masksToBounds = true
    fill.cornerRadius = 1.5
    layer?.addSublayer(fill)
  }

  required init?(coder: NSCoder) { fatalError() }

  override var wantsUpdateLayer: Bool { true }

  override func updateLayer() {
    layer?.backgroundColor = PanelColors.tile.cgColor
    fill.backgroundColor = ProfileColor.accent.cgColor
  }

  override func layout() {
    super.layout()
    placeFill(animated: false)
  }

  private func placeFill(animated: Bool) {
    CATransaction.begin()
    CATransaction.setDisableActions(!animated)
    CATransaction.setAnimationDuration(0.3)
    CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
    fill.frame = CGRect(x: 0, y: 0, width: bounds.width * CGFloat(min(1, max(0, fraction))), height: bounds.height)
    CATransaction.commit()
  }
}

/// A small turning arc in the profile's colour (a layer animation; nothing ticks on the main thread).
fileprivate final class Spinner: NSView {
  private let arc = CAShapeLayer()

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    arc.fillColor = nil
    arc.lineWidth = 2
    arc.lineCap = .round
    arc.strokeEnd = 0.72
    layer?.addSublayer(arc)
  }

  required init?(coder: NSCoder) { fatalError() }

  override var wantsUpdateLayer: Bool { true }

  override func updateLayer() { arc.strokeColor = ProfileColor.accent.cgColor }

  override func layout() {
    super.layout()
    arc.frame = bounds
    arc.path = CGPath(ellipseIn: bounds.insetBy(dx: 1.5, dy: 1.5), transform: nil)
    spin()
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    spin()
  }

  private func spin() {
    guard window != nil, arc.animation(forKey: "spin") == nil else { return }
    let turn = CABasicAnimation(keyPath: "transform.rotation.z")
    turn.fromValue = 0
    turn.toValue = -2 * Double.pi
    turn.duration = 0.8
    turn.repeatCount = .infinity
    arc.add(turn, forKey: "spin")
  }
}

/// One chosen item while it moves in: a spinner, then a tick in the profile's colour and its count, or a quiet line
/// saying why it didn't come.
fileprivate final class ProgressRowView: NSView {
  static let height: CGFloat = 30
  private let icon = NSImageView()
  private let title: NSTextField
  private let spinner = Spinner()
  private let tick = NSImageView()
  private let detail = oneLine("", size: 12, color: .secondaryLabelColor)
  private var state = ImportRowState.waiting

  init(item: ImportItem) {
    title = oneLine(item.onboardingTitle, size: 13)
    super.init(frame: .zero)
    icon.image = NSImage(systemSymbolName: item.symbol, accessibilityDescription: nil)
    icon.symbolConfiguration = .init(pointSize: 13, weight: .regular)
    icon.contentTintColor = .secondaryLabelColor
    tick.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "Done")
    tick.symbolConfiguration = .init(pointSize: 14, weight: .medium)
    detail.alignment = .right
    for view in [icon, title, spinner, tick, detail] as [NSView] { addSubview(view) }
    show(.waiting)
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }

  func show(_ state: ImportRowState) {
    self.state = state
    spinner.isHidden = state != .running
    tick.isHidden = true
    title.alphaValue = 1
    icon.alphaValue = 1
    switch state {
    case .waiting:
      title.alphaValue = 0.5
      icon.alphaValue = 0.5
      detail.stringValue = ""
    case .running:
      detail.stringValue = ""
    case .done(let count):
      tick.isHidden = false
      detail.textColor = .secondaryLabelColor
      detail.stringValue = NumberFormatter.localizedString(from: NSNumber(value: count), number: .decimal)
    case .failed(let reason):
      title.alphaValue = 0.6
      icon.alphaValue = 0.6
      detail.textColor = .tertiaryLabelColor
      detail.stringValue = reason
    }
    needsDisplay = true
    needsLayout = true
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    tick.contentTintColor = ProfileColor.accent
  }

  override func layout() {
    super.layout()
    tick.contentTintColor = ProfileColor.accent
    let mid = bounds.height / 2
    icon.frame = NSRect(x: 8, y: (mid - 9).rounded(), width: 18, height: 18)
    let right = bounds.width - 8
    spinner.frame = NSRect(x: right - 14, y: (mid - 7).rounded(), width: 14, height: 14)
    tick.frame = NSRect(x: right - 16, y: (mid - 8).rounded(), width: 16, height: 16)
    let detailRight = tick.isHidden && spinner.isHidden ? right : right - 22
    let titleWidth = min(widthOf(title) + 2, detailRight - 34 - 60)
    placeLine(title, x: 34, mid: mid, width: titleWidth)
    let detailX = title.frame.maxX + 12
    placeLine(detail, x: detailX, mid: mid, width: detailRight - detailX)
  }
}

// MARK: Your colour

fileprivate final class ThemeStepView: OnboardingStepView {
  private let swatches = SwatchRow()
  private let preview = ThemePreview()

  override init(flow: OnboardingView) {
    super.init(flow: flow)
    titleLabel.stringValue = "Make it yours"
    subtitleLabel.stringValue = "Ray's colour, for loading, selection and highlights. Settings › Appearance has it too."
    swatches.onChoose = { hex in RaySettings.shared.apply(.theme, hex ?? "default") }
    swatches.onCustom = { [weak flow] in flow?.openColorPanel() }
    addSubview(swatches)
    addSubview(preview)
  }

  required init?(coder: NSCoder) { fatalError() }

  var swatchSelection: String { swatches.selection ?? "default" }

  func pressSwatch(_ index: Int) -> Bool { swatches.press(index: index) }

  override func refresh() {
    swatches.selection = RaySettings.shared.values.theme
    preview.setNeedsDisplayRecursively()
  }

  override func place(width: CGFloat, apply: Bool) -> CGFloat {
    var y = placeHeader(width: width, apply: apply)
    let size = swatches.fittingSize
    if apply { swatches.frame = NSRect(x: Self.inset, y: y, width: size.width, height: size.height) }
    y += size.height + 18
    if apply { preview.frame = NSRect(x: Self.inset, y: y, width: width - Self.inset * 2, height: ThemePreview.height) }
    return y + ThemePreview.height + 20
  }
}

/// A small piece of Ray in the chosen colour: the address field with its loading wash and line, over a page.
fileprivate final class ThemePreview: NSView {
  static let height: CGFloat = 112
  private let pill = CALayer()
  private let washMask = CAGradientLayer()
  private let wash = CAGradientLayer()
  private let line = CAGradientLayer()
  private let page = CALayer()
  private let pageLines = (0..<3).map { _ in CALayer() }
  private let address = oneLine("ray.app/welcome", size: 13, color: .secondaryLabelColor)
  private let lock = NSImageView()
  private let toggle = RaySwitch()

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.cornerRadius = 12
    layer?.cornerCurve = .continuous
    layer?.borderWidth = 1
    pill.cornerRadius = 10
    pill.cornerCurve = .continuous
    pill.masksToBounds = true
    wash.startPoint = CGPoint(x: 0, y: 0.5)
    wash.endPoint = CGPoint(x: 1, y: 0.5)
    washMask.startPoint = CGPoint(x: 0.5, y: 0)
    washMask.endPoint = CGPoint(x: 0.5, y: 1)
    wash.mask = washMask
    line.startPoint = CGPoint(x: 0, y: 0.5)
    line.endPoint = CGPoint(x: 1, y: 0.5)
    pill.addSublayer(wash)
    pill.addSublayer(line)
    page.cornerRadius = 8
    page.cornerCurve = .continuous
    layer?.addSublayer(page)
    pageLines.forEach { page.addSublayer($0); $0.cornerRadius = 3 }
    layer?.addSublayer(pill)
    lock.image = NSImage(systemSymbolName: "lock", accessibilityDescription: nil)
    lock.symbolConfiguration = .init(pointSize: 12, weight: .medium)
    lock.contentTintColor = .secondaryLabelColor
    addSubview(lock)
    addSubview(address)
    toggle.isOn = true
    toggle.setAccessibilityElement(false)
    addSubview(toggle)
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }
  override var wantsUpdateLayer: Bool { true }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func updateLayer() {
    let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    layer?.backgroundColor = SidebarColors.background.cgColor
    layer?.borderColor = PanelColors.border.cgColor
    pill.backgroundColor = SidebarColors.fill.cgColor
    page.backgroundColor = (dark ? NSColor(white: 0.16, alpha: 1) : NSColor.white).cgColor
    for (at, bar) in pageLines.enumerated() {
      bar.backgroundColor = (dark ? NSColor(white: 1, alpha: at == 0 ? 0.16 : 0.08) : NSColor(white: 0, alpha: at == 0 ? 0.1 : 0.05)).cgColor
    }
    let tint = LoadingTint.current
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    wash.colors = tint.wash.map(\.cgColor)
    line.colors = tint.line.map(\.cgColor)
    washMask.colors = [CGColor(gray: 0, alpha: CGFloat(tint.topFade)), CGColor.black]
    CATransaction.commit()
    toggle.needsDisplay = true
  }

  override func layout() {
    super.layout()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    let inset: CGFloat = 12
    let pillFrame = CGRect(x: inset, y: inset, width: bounds.width - inset * 2, height: 30)
    pill.frame = pillFrame
    // As if the page were part way through loading.
    let travel = pillFrame.width * 0.62
    wash.frame = CGRect(x: 0, y: 0, width: travel, height: pillFrame.height)
    washMask.frame = wash.bounds
    line.frame = CGRect(x: 0, y: pillFrame.height - 2, width: travel, height: 2)
    page.frame = CGRect(x: inset, y: pillFrame.maxY + 8, width: bounds.width - inset * 2, height: bounds.height - pillFrame.maxY - 8 - inset)
    for (at, bar) in pageLines.enumerated() {
      let widths: [CGFloat] = [0.42, 0.7, 0.55]
      bar.frame = CGRect(x: 12, y: 12 + CGFloat(at) * 13, width: (page.bounds.width - 80) * widths[at], height: 6)
    }
    CATransaction.commit()
    lock.frame = NSRect(x: pillFrame.minX + 11, y: pillFrame.midY - 8, width: 16, height: 16)
    placeLine(address, x: pillFrame.minX + 33, mid: pillFrame.midY, width: pillFrame.width - 45)
    let size = toggle.intrinsicContentSize
    toggle.frame = NSRect(x: page.frame.maxX - 12 - size.width, y: (page.frame.midY - size.height / 2).rounded(),
                          width: size.width, height: size.height)
  }
}

// MARK: Three keys

fileprivate final class KeysStepView: OnboardingStepView {
  private var rows: [KeyRowView] = []
  private(set) var keys: [String] = []

  override init(flow: OnboardingView) {
    super.init(flow: flow)
    titleLabel.stringValue = "You're all set"
    subtitleLabel.stringValue = "A few keys to start with."
    rebuild()
  }

  required init?(coder: NSCoder) { fatalError() }

  /// The keys as they work now: one whose shortcut Settings turned off isn't offered.
  private func rebuild() {
    let values = RaySettings.shared.values
    var list: [(caps: [String], title: String, detail: String)] = [
      (["⌘", "T"], "Command bar", "Open a site, search, or jump to a tab you have open."),
    ]
    if values.sidebarShortcut {
      list.append((["⌘", "S"], "Show or hide the sidebar", "Hidden, it peeks out at the window's left edge."))
    }
    if values.copyLinkShortcut {
      list.append((["⇧", "⌘", "C"], "Copy this page's link", "The address, ready to paste anywhere."))
    }
    let now = list.map { $0.caps.joined() }
    guard now != keys else { return }
    keys = now
    rows.forEach { $0.removeFromSuperview() }
    rows = list.map { KeyRowView(caps: $0.caps, title: $0.title, detail: $0.detail) }
    rows.forEach(addSubview)
    needsLayout = true
  }

  override func refresh() { rebuild() }

  override func place(width: CGFloat, apply: Bool) -> CGFloat {
    var y = placeHeader(width: width, apply: apply) - 2
    for row in rows {
      if apply { row.frame = NSRect(x: Self.inset, y: y, width: width - Self.inset * 2, height: KeyRowView.height) }
      y += KeyRowView.height + 6
    }
    return y + 14
  }
}

fileprivate final class KeyRowView: NSView {
  static let height: CGFloat = 44
  private var caps: [KeyCap] = []
  private let title: NSTextField
  private let detail: NSTextField

  init(caps: [String], title: String, detail: String) {
    self.title = oneLine(title, size: 13, weight: .medium)
    self.detail = oneLine(detail, size: 12, color: .secondaryLabelColor)
    super.init(frame: .zero)
    self.caps = caps.map { KeyCap(text: $0) }
    self.caps.forEach(addSubview)
    addSubview(self.title)
    addSubview(self.detail)
    setAccessibilityElement(true)
    setAccessibilityLabel("\(caps.joined()) \(title)")
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }

  override func layout() {
    super.layout()
    let mid = bounds.height / 2
    var x: CGFloat = 0
    for cap in caps {
      cap.frame = NSRect(x: x, y: (mid - 13).rounded(), width: 26, height: 26)
      x += 26 + 4
    }
    let textX: CGFloat = 104
    let titleHeight = lineHeight(title), detailHeight = lineHeight(detail)
    let top = (mid - (titleHeight + 1 + detailHeight) / 2).rounded()
    title.frame = NSRect(x: textX, y: top, width: bounds.width - textX, height: titleHeight)
    detail.frame = NSRect(x: textX, y: top + titleHeight + 1, width: bounds.width - textX, height: detailHeight)
  }
}

/// One key, drawn as a small rounded cap.
fileprivate final class KeyCap: NSView {
  private let label: NSTextField

  init(text: String) {
    label = oneLine(text, size: 13, weight: .medium)
    label.alignment = .center
    super.init(frame: .zero)
    wantsLayer = true
    layer?.cornerRadius = 6
    layer?.cornerCurve = .continuous
    layer?.borderWidth = 1
    addSubview(label)
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }
  override var wantsUpdateLayer: Bool { true }

  override func updateLayer() {
    layer?.backgroundColor = PanelColors.tile.cgColor
    layer?.borderColor = PanelColors.border.cgColor
  }

  override func layout() {
    super.layout()
    placeLine(label, x: 0, mid: bounds.height / 2, width: bounds.width)
  }
}
