import AppKit

/// Settings › Appearance's app-wide looks, applied once the engine has started and again on every change.
/// - Light or dark: `NSApp.appearance` (nil follows macOS). Every window, view and layer of Ray's own takes it the way
///   it takes a macOS switch (`viewDidChangeEffectiveAppearance`); private windows stay dark (their own appearance).
///   Chromium reads `NSApp.effectiveAppearance` for the browser's colour mode, so pages' `prefers-color-scheme`
///   follows too, as Chrome's pages follow its Light/Dark mode (and Ardia's follow its Appearance Theme); how a page
///   looks in it is the page's own choice.
/// - Scroll bars: `NSScroller.preferredScrollerStyle`, answered as overlay (When scrolling) or legacy (Always), and
///   macOS's own answer for Automatic. Chromium's OS settings provider reads it for every page and listens for the
///   change notice, so open pages switch at once with no engine change (Ardia's Thin scroll bars do the same).
enum AppLook {
  private static var observation: SettingsObservation?

  static func start() {
    apply()
    observation = RaySettings.shared.observe([.appearanceMode, .scrollBars]) { apply() }
  }

  private static func apply() {
    let settings = RaySettings.shared
    let wanted: NSAppearance.Name? = switch settings[.appearanceMode] {
    case "light": .aqua
    case "dark": .darkAqua
    default: nil
    }
    if NSApp.appearance?.name != wanted { NSApp.appearance = wanted.flatMap { NSAppearance(named: $0) } }
    let scrollers: NSScroller.Style? = switch settings[.scrollBars] {
    case "scrolling": .overlay
    case "always": .legacy
    default: nil
    }
    ScrollerStyle.set(scrollers)
  }

  /// For the state log: the app's appearance as set (`auto` when it follows macOS) and as it is, and the scroller
  /// style pages are told.
  static var debug: [String: Any] {
    let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    return [
      "appearance": NSApp.appearance.map { $0.name == .darkAqua ? "dark" : "light" } ?? "auto",
      "effective": dark ? "dark" : "light",
      "scrollers": NSScroller.preferredScrollerStyle == .overlay ? "overlay" : "legacy",
    ]
  }
}

/// The scroller style Ray answers for itself (and so for Chromium's pages): forced, or macOS's own while nil.
private enum ScrollerStyle {
  private static var forced: NSScroller.Style?
  private static var installed = false

  static func set(_ style: NSScroller.Style?) {
    guard style != forced else { return }
    if style != nil { install() }
    guard installed else { return }
    forced = style
    NotificationCenter.default.post(name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil)
  }

  /// Swaps `+[NSScroller preferredScrollerStyle]` for one that answers `forced` when set and calls macOS's own
  /// otherwise. Done once, the first time a style is forced, so a Ray that never changes the setting never swaps it.
  private static func install() {
    let selector = #selector(getter: NSScroller.preferredScrollerStyle)
    guard !installed, let method = class_getClassMethod(NSScroller.self, selector) else { return }
    typealias Getter = @convention(c) (AnyClass, Selector) -> Int
    let system = unsafeBitCast(method_getImplementation(method), to: Getter.self)
    let answer: @convention(block) (AnyClass) -> Int = { scroller in
      forced?.rawValue ?? system(scroller, selector)
    }
    method_setImplementation(method, imp_implementationWithBlock(answer))
    installed = true
  }
}
