import AppKit

protocol FindBarDelegate: AnyObject {
  func findBar(_ bar: FindBarView, find text: String, forward: Bool)
  func findBarClose(_ bar: FindBarView)
}

/// Find in page (⌘F): a small bar floating at the top right of the page, as in Arc. Return / ⌘G go to the next
/// match, ⇧Return / ⇧⌘G to the previous one, Escape closes.
final class FindBarView: NSView, NSTextFieldDelegate {
  static let size = NSSize(width: 320, height: 40)

  weak var delegate: FindBarDelegate?
  private let field = NSTextField()
  private let count = NSTextField(labelWithString: "")
  private let icon = NSImageView()
  private let previous = FindBarView.button("chevron.up", "Previous Match")
  private let next = FindBarView.button("chevron.down", "Next Match")
  private let close = FindBarView.button("xmark", "Close")
  private(set) var matches = (count: 0, active: 0)

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.cornerRadius = 10
    layer?.cornerCurve = .continuous
    layer?.borderWidth = 1
    layer?.shadowOpacity = 0.18
    layer?.shadowRadius = 8
    layer?.shadowOffset = CGSize(width: 0, height: -2)
    icon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
    icon.symbolConfiguration = .init(pointSize: 12, weight: .semibold)
    icon.contentTintColor = .tertiaryLabelColor
    field.isBordered = false
    field.drawsBackground = false
    field.focusRingType = .none
    field.font = .systemFont(ofSize: 13)
    field.placeholderString = "Find on page"
    field.delegate = self
    field.cell?.isScrollable = true
    count.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    count.textColor = .secondaryLabelColor
    count.alignment = .right
    previous.target = self
    previous.action = #selector(findPrevious)
    next.target = self
    next.action = #selector(findNext)
    close.target = self
    close.action = #selector(closeBar)
    [icon, field, count, previous, next, close].forEach(addSubview)
  }

  required init?(coder: NSCoder) { fatalError() }

  override var wantsUpdateLayer: Bool { true }
  override var mouseDownCanMoveWindow: Bool { false }

  override func updateLayer() {
    layer?.backgroundColor = SidebarColors.background.cgColor
    layer?.borderColor = NSColor.separatorColor.cgColor
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    needsDisplay = true
  }

  var text: String { field.stringValue }

  func focus() {
    window?.makeFirstResponder(field)
    field.currentEditor()?.selectAll(nil)
  }

  func setMatches(_ total: Int, active: Int) {
    matches = (total, active)
    count.stringValue = field.stringValue.isEmpty ? "" : total == 0 ? "No matches" : "\(active) of \(total)"
    count.textColor = total == 0 && !field.stringValue.isEmpty ? .systemRed : .secondaryLabelColor
    previous.isEnabled = total > 0
    next.isEnabled = total > 0
  }

  func controlTextDidChange(_ notification: Notification) {
    setMatches(0, active: 0)
    if !field.stringValue.isEmpty { delegate?.findBar(self, find: field.stringValue, forward: true) }
  }

  func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
    switch selector {
    case #selector(NSResponder.insertNewline(_:)):
      NSApp.currentEvent?.modifierFlags.contains(.shift) == true ? findPrevious() : findNext()
    case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
      findPrevious()
    case #selector(NSResponder.cancelOperation(_:)):
      closeBar()
    default:
      return false
    }
    return true
  }

  @objc func findNext() {
    guard !field.stringValue.isEmpty else { return }
    delegate?.findBar(self, find: field.stringValue, forward: true)
  }

  @objc func findPrevious() {
    guard !field.stringValue.isEmpty else { return }
    delegate?.findBar(self, find: field.stringValue, forward: false)
  }

  @objc private func closeBar() { delegate?.findBarClose(self) }

  override func layout() {
    super.layout()
    let mid = bounds.height / 2
    icon.frame = NSRect(x: 12, y: mid - 8, width: 16, height: 16)
    close.frame = NSRect(x: bounds.width - 32, y: mid - 13, width: 26, height: 26)
    next.frame = close.frame.offsetBy(dx: -28, dy: 0)
    previous.frame = next.frame.offsetBy(dx: -28, dy: 0)
    count.frame = NSRect(x: previous.frame.minX - 80, y: mid - 8, width: 74, height: 16)
    field.frame = NSRect(x: 34, y: mid - 9, width: count.frame.minX - 38, height: 18)
  }

  private static func button(_ symbol: String, _ label: String) -> NSButton {
    let button = HoverIconButton()
    button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
    button.symbolConfiguration = .init(pointSize: 11, weight: .semibold)
    button.isBordered = false
    button.bezelStyle = .regularSquare
    button.imagePosition = .imageOnly
    button.contentTintColor = .secondaryLabelColor
    button.refusesFirstResponder = true
    return button
  }
}
