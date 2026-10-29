import AppKit

/// Links and files other apps hand Ray: a link clicked in Mail or Slack once Ray is the default browser, an HTML or
/// PDF file opened with Ray in Finder, `open -a Ray <url>`. Each opens as a new Today tab in the normal window, never
/// a private one (Chrome, Arc and Ardia agree), and the last one is active. Arc opens them in Little Arc, which Ray
/// doesn't have yet (docs/MISSING.md).
///
/// What's taken goes through AddressInput: links only as http(s) (`link(fromOtherApp:)`), files only from a document
/// open (Finder's, never a `file:` link) and only real local files of the declared types (`document(fromOtherApp:)`).
enum LinksFromApps {
  /// Opens that came in before the first window: on a launch by a link or file, AppKit delivers its open event
  /// after the engine has started (the engine's start runs on the main loop first) and before it finishes launching.
  private static var pending: [String] = []
  /// The first window is open: opens go straight to a window.
  private static var started = false
  private static var appKitFinished = false
  /// The engine's start, waiting for AppKit's launch to finish (`whenLaunched`).
  private static var waiting: (([String]) -> Void)?
  private static var engineStartedAt: TimeInterval = 0

  /// Before the engine runs (main.swift). AppKit hands the launch's open event to the handlers in place once it has
  /// posted willFinishLaunching (Apple's documented point for installing them). AppKit's own handlers never reached
  /// `application(_:open:)` in Ray, not even with the delegate set here (NSApp's delegate is otherwise only Ray's
  /// once the engine has started), so Ray takes GetURL and Open Documents itself, from here on. Chrome's own
  /// AppController, which would otherwise take them, never exists in Ray.
  static func install() {
    NotificationCenter.default.addObserver(
      forName: NSApplication.willFinishLaunchingNotification, object: nil, queue: nil
    ) { _ in
      if NSApp.delegate == nil { NSApp.delegate = AppController.shared }
      installHandlers()
    }
    NotificationCenter.default.addObserver(
      forName: NSApplication.didFinishLaunchingNotification, object: nil, queue: nil
    ) { _ in
      appKitFinished = true
      openFirstWindow(after: "AppKit's launch")
    }
  }

  /// The engine has started: `open` makes the first window, with the links and files that launched Ray, once AppKit
  /// has delivered the launch's open event (it has once its launch finishes). A deadline keeps a launch whose finish
  /// never comes from waiting for good.
  static func whenLaunched(_ open: @escaping ([String]) -> Void) {
    engineStartedAt = ProcessInfo.processInfo.systemUptime
    waiting = open
    // The delegate is set again by now (engineDidStart), which may have put AppKit's handlers back.
    installHandlers()
    if appKitFinished { return openFirstWindow(after: "the engine") }
    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { openFirstWindow(after: "the deadline") }
  }

  private static func openFirstWindow(after: String) {
    guard let open = waiting else { return }
    waiting = nil
    started = true
    let links = pending
    pending = []
    TestEnvironment.log(String(
      format: "launch: first window after %@, %.0f ms after the engine, %d links", after,
      (ProcessInfo.processInfo.systemUptime - engineStartedAt) * 1000, links.count))
    open(links)
  }

  private static func installHandlers() {
    let events = NSAppleEventManager.shared()
    events.setEventHandler(
      OpenEvents.shared, andSelector: #selector(OpenEvents.getURL(_:reply:)),
      forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    events.setEventHandler(
      OpenEvents.shared, andSelector: #selector(OpenEvents.openDocuments(_:reply:)),
      forEventClass: AEEventClass(kCoreEventClass), andEventID: AEEventID(kAEOpenDocuments))
  }

  /// `documents`: the open is a document open (Finder, the Dock icon, `open -a Ray <file>`), the one way a file
  /// gets in. A `file:` URL sent as a link is refused, as Ray doesn't claim the `file` scheme. `sent`: how many the
  /// event carried, counting any that weren't URLs at all.
  static func receive(_ urls: [URL], documents: Bool, sent: Int? = nil) {
    let accepted = urls.compactMap { url in
      url.isFileURL ? (documents ? AddressInput.document(fromOtherApp: url) : nil) : AddressInput.link(fromOtherApp: url)
    }
    // Counts only: never the URLs (CLAUDE.md, Logs).
    TestEnvironment.log("from other apps: \(sent ?? urls.count) received, \(accepted.count) accepted, "
      + (documents ? "documents" : "links") + (started ? "" : ", queued"))
    guard !accepted.isEmpty else { return }
    if started { AppController.shared.openLinks(accepted) } else { pending += accepted }
  }
}

/// The Apple Events macOS sends for "open this link" (GetURL, one URL as text) and "open these files" (Open
/// Documents, a list of files: Finder, the Dock icon, `open -a Ray <file>`).
private final class OpenEvents: NSObject {
  static let shared = OpenEvents()

  @objc func getURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
    let text = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue ?? ""
    LinksFromApps.receive([URL(string: text)].compactMap { $0 }, documents: false, sent: 1)
  }

  @objc func openDocuments(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
    guard let files = event.paramDescriptor(forKeyword: keyDirectObject) else { return }
    let items = files.numberOfItems > 0 ? (1...files.numberOfItems).compactMap { files.atIndex($0) } : [files]
    let urls = items.compactMap { $0.coerce(toDescriptorType: DescType(typeFileURL))?.fileURLValue }
    LinksFromApps.receive(urls, documents: true, sent: items.count)
  }
}

extension AppController {
  /// Opens AppKit hands the delegate itself rather than through Ray's handlers above; the event behind them, if any,
  /// says whether they are documents.
  func application(_ application: NSApplication, open urls: [URL]) {
    let event = NSAppleEventManager.shared().currentAppleEvent
    let documents = event?.eventClass == AEEventClass(kCoreEventClass) && event?.eventID == AEEventID(kAEOpenDocuments)
    LinksFromApps.receive(urls, documents: documents)
  }

  /// Ray has no untitled documents: the document types it declares are for viewing, so AppKit never asks the
  /// document controller for a new one at launch or on a Dock click.
  func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }

  /// Opens `urls` (already through AddressInput) in the normal window, brought to the front: opened again from
  /// Sidebar.json if it was closed, never a private window even when one is in front.
  func openLinks(_ urls: [String], in window: BrowserWindowController? = nil) {
    guard let controller = window ?? openMainWindow(forLinks: true) else { return }
    controller.openFromOtherApps(urls)
    noteFocused(controller)
    if !launchedInBackground {
      controller.window.makeKeyAndOrderFront(nil)
      NSApp.activate()
    }
  }
}
