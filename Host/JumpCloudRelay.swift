import AppKit
import Security

// JumpCloud Go through Google Chrome (Settings › Passwords, `jumpCloudRelay`, off by default).
//
// JumpCloud Go's native helper hands its sign-in token only to browsers on its own list, checked by the code signature
// of the process that launched it (docs/MISSING.md, Known limitations #15), so Ray can never get one. Real Google
// Chrome can. With the setting on, a normal Ray tab that lands on JumpCloud's user login page starts Ray's own Chrome
// instance (its own profile next to Ray's data, never the user's Chrome profile), loads JumpCloud's login page there
// headless (no window, no Dock icon, never activated, so a full-screen Ray stays on its Space), waits for the user
// console, then copies only jumpcloud.com cookies into Ray and reloads the tab. If headless Chrome hasn't signed in
// within `headlessDeadline`, the relay starts again in a small visible Chrome window (a full-screen Ray only gets a
// note with a button that brings Chrome forward). Chrome is driven over `--remote-debugging-pipe` (file descriptors 3 and 4, NUL-separated JSON):
// never a port, so nothing else on the Mac can reach it. Nothing here reads the Keychain.

// MARK: Login pages

enum JumpCloudLogin {
  /// The hosts whose login page triggers a relay, and the user console Chrome signs in on for each. JumpCloud's
  /// SAML/OIDC endpoints (sso.…) send an unsigned-in user to the console's /login with the flow in its query.
  static let hosts: [String: String] = [
    "console.jumpcloud.com": "console.jumpcloud.com",
    "console.eu.jumpcloud.com": "console.eu.jumpcloud.com",
    "sso.jumpcloud.com": "console.jumpcloud.com",
    "sso.eu.jumpcloud.com": "console.eu.jumpcloud.com",
  ]

  /// The user login route of JumpCloud's login UI (`loginRoutes.user`); /login/admin, /login/stepup and the rest are
  /// left alone.
  static let paths: Set<String> = ["/login", "/login/"]

  struct Match: Equatable {
    /// The Ray tab's committed origin (`https://console.jumpcloud.com`).
    let origin: String
    /// Where Chrome signs in: the console's own login page, never the app's flow (Chrome must not use up its
    /// one-time SAML request).
    let relayURL: String
    let consoleHost: String
  }

  /// The login page a committed navigation landed on: the host from the engine's committed origin (https, no port),
  /// the path from the tab's address only when that address is on the same origin.
  static func match(committedOrigin: String?, url: String) -> Match? {
    guard let origin = committedOrigin, let parts = URLComponents(string: origin), parts.scheme == "https",
          parts.port == nil, let host = parts.host?.lowercased(), let console = hosts[host],
          RayCoreTab.origin(forURL: url) == origin, let address = URLComponents(string: url),
          paths.contains(address.path) else { return nil }
    return Match(origin: origin, relayURL: "https://\(console)/login", consoleHost: console)
  }

  /// The relay page reached the signed-in user console.
  static func isSignedIn(_ url: String, consoleHost: String) -> Bool {
    guard let parts = URLComponents(string: url), parts.scheme == "https", parts.host?.lowercased() == consoleHost
    else { return false }
    let path = parts.path.lowercased()
    return path.hasPrefix("/userconsole") && !path.contains("login") && !(parts.fragment ?? "").lowercased().contains("login")
  }

  /// jumpcloud.com or a subdomain, on a dot boundary (a cookie's domain may lead with a dot).
  static func isJumpCloudDomain(_ domain: String) -> Bool {
    var host = domain.lowercased()
    if host.hasPrefix(".") { host.removeFirst() }
    return host == "jumpcloud.com" || host.hasSuffix(".jumpcloud.com")
  }

  /// One cookie from Chrome's `Storage.getCookies`, as the engine's `ac_cookies_import` takes it; nil for any other
  /// domain. Session cookies (no expiry) stay session cookies.
  static func cookie(from json: [String: Any]) -> Cookie? {
    guard let name = json["name"] as? String, let value = json["value"] as? String,
          let domain = json["domain"] as? String, let path = json["path"] as? String,
          isJumpCloudDomain(domain) else { return nil }
    let session = json["session"] as? Bool ?? false
    let expires = (json["expires"] as? NSNumber)?.doubleValue ?? -1
    var partition: CookiePartition?
    if let key = json["partitionKey"] as? [String: Any], let site = key["topLevelSite"] as? String {
      partition = CookiePartition(topLevelSite: site, crossSite: key["hasCrossSiteAncestor"] as? Bool ?? false)
    }
    return Cookie(
      domain: domain, name: name, value: SecretBytes(Array(value.utf8)), path: path,
      expires: session || expires <= 0 ? nil : expires * 1000,
      secure: json["secure"] as? Bool ?? false, httpOnly: json["httpOnly"] as? Bool ?? false,
      sameSite: (json["sameSite"] as? String)?.lowercased() ?? "unspecified",
      priority: (json["priority"] as? String)?.lowercased() ?? "medium", partition: partition,
      sourceScheme: (json["sourceScheme"] as? String)?.lowercased() ?? "unset",
      sourcePort: (json["sourcePort"] as? NSNumber)?.intValue ?? -1)
  }
}

// MARK: Chrome

/// Where Ray finds Google Chrome, and whether it's really Google's.
enum RelayChromeApp {
  /// Google's stable Chrome, signed by Google's team. Beta, Dev and Canary have other identifiers and fail too
  /// (JumpCloud's helper refuses them as well).
  static let requirement = #"identifier "com.google.Chrome" and anchor apple generic and certificate leaf[subject.OU] = "EQHXZ8M8AV""#

  enum Found {
    /// `version` is the bundle's CFBundleShortVersionString (`142.0.7444.60`), nil when it can't be read.
    case chrome(executable: String, version: String?)
    case missing
    case unsigned
  }

  /// Google Chrome's executable once its signature checks out. Test builds take only `RAY_JUMPCLOUD_RELAY_CHROME` (a
  /// stand-in, never checked; its version from `RAY_JUMPCLOUD_RELAY_CHROME_VERSION`) and never fall back to the real
  /// Chrome.
  static func locate() -> Found {
    if TestEnvironment.isTestBuild {
      guard let path = TestEnvironment["RAY_JUMPCLOUD_RELAY_CHROME"], !path.isEmpty else { return .missing }
      return .chrome(executable: path, version: TestEnvironment["RAY_JUMPCLOUD_RELAY_CHROME_VERSION"])
    }
    guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") else { return .missing }
    guard isGoogleChrome(app), let executable = Bundle(url: app)?.executableURL?.path else { return .unsigned }
    // Read fresh each time: Bundle caches its Info.plist, and Chrome updates itself in place.
    let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
    return .chrome(executable: executable, version: info?["CFBundleShortVersionString"] as? String)
  }

  /// The app's code signature is valid and meets `requirement`. Resources aren't hashed (Chrome's framework is
  /// hundreds of MB); Chrome's hardened runtime makes macOS refuse any library not signed by Google's team.
  static func isGoogleChrome(_ app: URL) -> Bool {
    var code: SecStaticCode?
    var requirement: SecRequirement?
    guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
          SecRequirementCreateWithString(Self.requirement as CFString, [], &requirement) == errSecSuccess,
          let requirement else { return false }
    return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSDoNotValidateResources), requirement) == errSecSuccess
  }
}

/// What headless Chrome tells sites it is: ordinary Chrome of the same version. Headless Chrome puts "HeadlessChrome"
/// in its user agent (components/embedder_support/user_agent_utils.cc); `--user-agent` replaces that string, and
/// `Emulation.setUserAgentOverride` sets the page's client hints as Chrome builds them for that version.
enum RelayUserAgent {
  /// Chrome's reduced user agent on a Mac (`Chrome/<major>.0.0.0`, macOS frozen at 10_15_7). Nil for a version that
  /// doesn't start with a number.
  static func string(version: String) -> String? {
    guard let major = major(version) else { return nil }
    return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/\(major).0.0.0 Safari/537.36"
  }

  static func major(_ version: String) -> Int? {
    guard let first = version.split(separator: ".").first, let major = Int(first), major > 0 else { return nil }
    return major
  }

  /// Chrome's brand list for `version` (GenerateBrandVersionList: a GREASE brand, Chromium and Google Chrome, in the
  /// order the major version seeds); `full` gives each its full version, as Sec-CH-UA-Full-Version-List does.
  static func brands(version: String, full: Bool) -> [[String: String]] {
    guard let major = major(version) else { return [] }
    let chars = [" ", "(", ":", "-", ".", "/", ")", ";", "=", "?", "_"]
    let grease = ["8", "99", "24"][major % 3]
    let own = full ? version : String(major)
    let list = [
      ["brand": "Not\(chars[major % chars.count])A\(chars[(major + 1) % chars.count])Brand",
       "version": full ? "\(grease).0.0.0" : grease],
      ["brand": "Chromium", "version": own], ["brand": "Google Chrome", "version": own],
    ]
    let orders = [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]]
    var shuffled = list
    for (index, place) in orders[major % orders.count].enumerated() { shuffled[place] = list[index] }
    return shuffled
  }

  /// `Emulation.setUserAgentOverride`'s parameters for `version` on this Mac.
  static func override(version: String) -> [String: Any]? {
    guard let agent = string(version: version) else { return nil }
    let os = ProcessInfo.processInfo.operatingSystemVersion
    let metadata: [String: Any] = [
      "brands": brands(version: version, full: false), "fullVersionList": brands(version: version, full: true),
      "platform": "macOS", "platformVersion": "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
      "architecture": "arm", "bitness": "64", "model": "", "mobile": false, "wow64": false,
    ]
    return ["userAgent": agent, "platform": "MacIntel", "userAgentMetadata": metadata]
  }
}

/// One Chrome process Ray started, and the DevTools pipe to it. Main thread only.
final class RelayChrome {
  let pid: pid_t
  /// Started with `--headless=new`: no windows, no Dock icon, nothing to bring forward.
  let headless: Bool
  /// Events (`Target.targetInfoChanged`, …) by method name.
  var onEvent: ((String, [String: Any]) -> Void)?
  /// The process is gone (quit, crashed or killed).
  var onGone: (() -> Void)?
  /// Page targets open in it, from `Target.setDiscoverTargets`.
  private(set) var pages: Set<String> = []
  /// The owner has been told it's gone (its pipe closed or it exited).
  private(set) var gone = false
  /// Asked to quit: no new work for it.
  private(set) var closing = false
  /// Reaped.
  private var exited = false

  private let toChrome: FileHandle
  private let fromChrome: FileHandle
  private let writes = DispatchQueue(label: "ray.jumpcloud.pipe")
  private var exitSource: DispatchSourceProcess?
  private var nextID = 1
  private var waiting: [Int: ([String: Any]?, String?) -> Void] = [:]
  private var received: [UInt8] = []

  /// Starts `executable` with `arguments`, Chrome reading fd 3 and writing fd 4. Nil if it can't start.
  static func launch(_ executable: String, arguments: [String], headless: Bool) -> RelayChrome? {
    var toChrome: [Int32] = [-1, -1]
    var fromChrome: [Int32] = [-1, -1]
    guard pipe(&toChrome) == 0 else { return nil }
    guard pipe(&fromChrome) == 0 else {
      Darwin.close(toChrome[0])
      Darwin.close(toChrome[1])
      return nil
    }
    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
    posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
    posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
    posix_spawn_file_actions_adddup2(&actions, toChrome[0], 3)
    posix_spawn_file_actions_adddup2(&actions, fromChrome[1], 4)
    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }
    // Only fds 0–4 reach Chrome; signals start as a fresh process has them.
    posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))
    var mask = sigset_t()
    sigemptyset(&mask)
    posix_spawnattr_setsigmask(&attributes, &mask)
    var defaults = sigset_t()
    sigemptyset(&defaults)
    for signal in Int32(1)..<32 where signal != SIGKILL && signal != SIGSTOP { sigaddset(&defaults, signal) }
    posix_spawnattr_setsigdefault(&attributes, &defaults)

    // Ray's environment without what names Ray (LaunchServices' bundle id, Ray's test switches) or loads code.
    let environment = ProcessInfo.processInfo.environment.filter { key, _ in
      !key.hasPrefix("__CF") && key != "CFProcessPath" && !key.hasPrefix("XPC_") && !key.hasPrefix("RAY_")
        && !key.hasPrefix("DYLD_")
    }.map { "\($0.key)=\($0.value)" }
    let argv = ([executable] + arguments).map { strdup($0) } + [nil]
    let envp = environment.map { strdup($0) } + [nil]
    defer {
      argv.forEach { free($0) }
      envp.forEach { free($0) }
    }
    var pid: pid_t = 0
    let status = posix_spawn(&pid, executable, &actions, &attributes, argv, envp)
    Darwin.close(toChrome[0])
    Darwin.close(fromChrome[1])
    guard status == 0 else {
      Darwin.close(toChrome[1])
      Darwin.close(fromChrome[0])
      return nil
    }
    // A write to a Chrome that has gone fails with EPIPE instead of signalling Ray.
    _ = fcntl(toChrome[1], F_SETNOSIGPIPE, 1)
    return RelayChrome(pid: pid, headless: headless, write: toChrome[1], read: fromChrome[0])
  }

  private init(pid: pid_t, headless: Bool, write: Int32, read: Int32) {
    self.pid = pid
    self.headless = headless
    toChrome = FileHandle(fileDescriptor: write, closeOnDealloc: true)
    fromChrome = FileHandle(fileDescriptor: read, closeOnDealloc: true)
    fromChrome.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      DispatchQueue.main.async { self?.receive(data) }
    }
    // Holds this object until the process has exited and been reaped (the handler is released on cancel).
    let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
    source.setEventHandler { self.reap() }
    source.resume()
    exitSource = source
  }

  /// Sends a command (to a target's flat session when `session` is set); `done` gets its result, or its error (also
  /// "Chrome is gone").
  func send(_ method: String, _ params: [String: Any] = [:], session: String? = nil,
            done: (([String: Any]?, String?) -> Void)? = nil) {
    guard !gone else {
      done?(nil, "Chrome is gone")
      return
    }
    let id = nextID
    nextID += 1
    if let done { waiting[id] = done }
    var message: [String: Any] = ["id": id, "method": method, "params": params]
    if let session { message["sessionId"] = session }
    guard var data = try? JSONSerialization.data(withJSONObject: message) else {
      waiting.removeValue(forKey: id)?(nil, "unserialisable")
      return
    }
    data.append(0)
    let handle = toChrome
    writes.async { try? handle.write(contentsOf: data) }
  }

  private func receive(_ data: Data) {
    guard !data.isEmpty else {
      fromChrome.readabilityHandler = nil
      reap()
      return
    }
    received.append(contentsOf: data)
    // Messages are NUL-terminated. Cookie values pass through here: the bytes are zeroed once parsed.
    while let end = received.firstIndex(of: 0) {
      let message = Data(received[..<end])
      received.withUnsafeMutableBufferPointer { buffer in
        for index in 0...end { buffer[index] = 0 }
      }
      received.removeSubrange(...end)
      handle(message)
    }
  }

  private func handle(_ message: Data) {
    var message = message
    defer { message.resetBytes(in: 0..<message.count) }
    guard let json = (try? JSONSerialization.jsonObject(with: message)) as? [String: Any] else { return }
    if let id = (json["id"] as? NSNumber)?.intValue {
      let error = (json["error"] as? [String: Any])?["message"] as? String
      waiting.removeValue(forKey: id)?(json["result"] as? [String: Any], error ?? (json["result"] == nil ? "no result" : nil))
      return
    }
    guard let method = json["method"] as? String else { return }
    let params = json["params"] as? [String: Any] ?? [:]
    switch method {
    case "Target.targetCreated", "Target.targetInfoChanged":
      if let info = params["targetInfo"] as? [String: Any], info["type"] as? String == "page",
         let id = info["targetId"] as? String { pages.insert(id) }
    case "Target.targetDestroyed":
      if let id = params["targetId"] as? String { pages.remove(id) }
    default: break
    }
    onEvent?(method, params)
  }

  /// Asks Chrome to quit; if it hasn't within `deadline`, SIGTERM, and SIGKILL 3 s after that.
  func close(deadline: TimeInterval = 5) {
    guard !gone, !closing else { return }
    closing = true
    send("Browser.close")
    DispatchQueue.main.asyncAfter(deadline: .now() + deadline) { [weak self] in self?.terminate() }
  }

  /// SIGTERM now, SIGKILL in 3 s unless it has quit (strong captures: it's reaped whoever lets go of it).
  func terminate() {
    guard !exited else { return }
    closing = true
    kill(pid, SIGTERM)
    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
      guard !self.exited else { return }
      kill(self.pid, SIGKILL)
      DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.reap() }
    }
  }

  /// The process exited (or its pipe closed): reaps it once it has, and tells the owner once.
  private func reap() {
    var status: Int32 = 0
    if !exited, waitpid(pid, &status, WNOHANG) == pid {
      exited = true
      exitSource?.cancel()
      exitSource = nil
    } else if !exited, !closing {
      // The pipe closed first: the process is on its way out; make sure it goes (its exit event reaps it).
      terminate()
    }
    finish()
  }

  private func finish() {
    guard !gone else { return }
    gone = true
    fromChrome.readabilityHandler = nil
    let pending = waiting
    waiting = [:]
    pending.values.forEach { $0(nil, "Chrome is gone") }
    received.withUnsafeMutableBufferPointer { buffer in
      for index in buffer.indices { buffer[index] = 0 }
    }
    received = []
    onGone?()
  }
}

// MARK: Relay

final class JumpCloudRelay {
  static let shared = JumpCloudRelay()
  /// Posted when Chrome or the relay changes (Settings' status line follows it).
  static let didChange = Notification.Name("JumpCloudRelay.didChange")
  static let extensionID = "jdoahkhfkeipblhbhppmcbdgapeoaopa"
  static let storeURL = "https://chromewebstore.google.com/detail/\(extensionID)"
  static let windowSize = NSSize(width: 440, height: 620)
  /// After a relay, the same tab landing on the login page again this soon gets a note, not another relay.
  static let loopWindow: TimeInterval = 30

  /// Ray's own Chrome profile, next to Settings.json (never the user's Chrome profile).
  let directory = ((dataDirectory as NSString).deletingLastPathComponent as NSString).appendingPathComponent("JumpCloud Relay")

  /// How long the user has to sign in; how long Chrome has to answer at all (twice over when headless Chrome is
  /// silent and a windowed one gets its turn). Test builds can shorten both.
  private let signInDeadline: TimeInterval = TestEnvironment["RAY_JUMPCLOUD_RELAY_DEADLINE"].flatMap(Double.init) ?? 120
  private var answerDeadline: TimeInterval { min(15, signInDeadline / 3) }
  /// How long headless Chrome has to reach the user console before the relay starts again in a visible window
  /// (JumpCloud Go finishes on its own in a second or two when the device passes). Test builds can shorten it.
  static let headlessDeadline: TimeInterval = TestEnvironment["RAY_JUMPCLOUD_RELAY_HEADLESS_DEADLINE"].flatMap(Double.init) ?? 10

  private var chrome: RelayChrome?
  private var relay: Relay?
  private var recent: [Int32: Recent] = [:]
  private var setupOpen = false
  private var terminating: NSObjectProtocol?

  // For the state log.
  private(set) var launches = 0
  private(set) var lastResult = "none"
  private(set) var cookiesImported = 0
  private var lastArguments: [String] = []
  /// Times Ray asked macOS to bring Chrome forward (never for headless Chrome, never for a full-screen Ray by itself).
  private(set) var activations = 0
  /// Headless relays that started again in a visible window.
  private(set) var fallbacks = 0
  /// How the last relay reached Chrome: "headless" or "window".
  private(set) var lastMode = "none"
  /// Test builds: treat Ray's window as full screen (`jumpcloud fullscreen on`), as a hidden instance can't be.
  var simulatesFullScreen = false

  private final class Relay {
    let match: JumpCloudLogin.Match
    weak var tab: RayCoreTab?
    weak var controller: BrowserWindowController?
    var targetID: String?
    var deadline: DispatchWorkItem?
    var importing = false
    /// The relay runs in headless Chrome (until it falls back to a window).
    var headless = false
    /// Between closing headless Chrome and the visible one answering: its going isn't a failure.
    var switching = false
    var headlessDeadline: DispatchWorkItem?
    /// Chrome was brought forward for it, so Ray comes back to the front when it ends.
    var activated = false

    init(match: JumpCloudLogin.Match, tab: RayCoreTab, controller: BrowserWindowController) {
      self.match = match
      self.tab = tab
      self.controller = controller
    }
  }

  private struct Recent {
    let time: TimeInterval
    /// The relay reloaded the tab: that reload's own landing on the login page is expected.
    var reloadPending: Bool
  }

  private init() {
    terminating = NotificationCenter.default.addObserver(
      forName: NSApplication.willTerminateNotification, object: nil, queue: .main
    ) { [weak self] _ in self?.chrome?.terminate() }
  }

  /// Whether JumpCloud Go is installed in Ray's Chrome profile.
  var isSetUp: Bool {
    let path = (directory as NSString).appendingPathComponent("Default/Extensions/\(Self.extensionID)")
    return !((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []).isEmpty
  }

  /// What Settings says under the setup row.
  var status: (text: String, canSetUp: Bool) {
    switch RelayChromeApp.locate() {
    case .missing: return ("Needs Google Chrome, which isn't installed.", false)
    case .unsigned: return ("The Google Chrome on this Mac isn't signed by Google, so Ray won't open it.", false)
    case .chrome:
      if isSetUp { return ("JumpCloud Go is installed in Ray's own Chrome profile.", true) }
      return ("Once: install JumpCloud Go in Ray's own Chrome profile (not your usual Chrome).", true)
    }
  }

  // MARK: Trigger

  /// A normal tab's main frame committed a new document (BrowserWindowController.tabDidCommitDocument).
  func documentCommitted(_ tab: RayCoreTab, in controller: BrowserWindowController) {
    guard RaySettings.shared[.jumpCloudRelay], !controller.isPrivate, tab.profile?.offTheRecord != true,
          let match = JumpCloudLogin.match(committedOrigin: tab.committedOrigin, url: tab.url) else { return }
    let now = ProcessInfo.processInfo.systemUptime
    if var last = recent[tab.tabId], now - last.time < Self.loopWindow {
      if last.reloadPending {
        last.reloadPending = false
        recent[tab.tabId] = last
        return
      }
      return finish("loopGuard", note: "Still not signed in to JumpCloud. Try again in a moment", in: controller)
    }
    if let relay {
      if relay.tab === tab { return }
      return finish("busy", note: "JumpCloud sign-in is already open in Chrome", in: controller)
    }
    start(match, tab: tab, controller: controller)
  }

  private func start(_ match: JumpCloudLogin.Match, tab: RayCoreTab, controller: BrowserWindowController) {
    guard isSetUp else {
      return finish("notSetUp", note: "Set up JumpCloud Go in Chrome first", symbol: "gearshape", in: controller) {
        [weak self] in self?.setUp()
      }
    }
    let relay = Relay(match: match, tab: tab, controller: controller)
    self.relay = relay
    let deadline = DispatchWorkItem { [weak self, weak relay] in
      guard let self, let relay, self.relay === relay, !relay.importing else { return }
      self.fail(relay, "timedOut", note: "JumpCloud sign-in didn't finish")
    }
    relay.deadline = deadline
    DispatchQueue.main.asyncAfter(deadline: .now() + signInDeadline, execute: deadline)
    changed()
    // Headless unless Ray's Chrome is already open with windows (Set Up…): then the relay's window joins it.
    open(relay, headless: !(chrome.map { !$0.gone && !$0.closing && !$0.headless } ?? false))
  }

  /// Opens the console's login page for `relay` in headless Chrome (falling back to a window if it doesn't sign in in
  /// time) or in a visible window.
  private func open(_ relay: Relay, headless: Bool) {
    relay.headless = headless
    withChrome(headless: headless, wanted: { [weak self, weak relay] in relay != nil && self?.relay === relay },
               failing: { [weak self, weak relay] result, note in
      guard let self, let relay, self.relay === relay else { return }
      // A headless Chrome that never answered may be one a policy keeps from running headless: try a window.
      if relay.headless, result == "noAnswer" { return self.fallBack(relay) }
      self.fail(relay, result, note: note)
    }) { [weak self, weak relay] chrome in
      guard let self, let relay, self.relay === relay else { return }
      relay.switching = false
      relay.headless = chrome.headless
      self.lastMode = chrome.headless ? "headless" : "window"
      self.changed()
      guard chrome.headless else { return self.openWindow(relay, in: chrome) }
      let fallback = DispatchWorkItem { [weak self, weak relay] in
        guard let self, let relay else { return }
        self.fallBack(relay)
      }
      relay.headlessDeadline = fallback
      DispatchQueue.main.asyncAfter(deadline: .now() + Self.headlessDeadline, execute: fallback)
      self.openHeadless(relay, in: chrome)
    }
  }

  /// A page with no window: blank first, so the user agent override is in place before JumpCloud's first request.
  private func openHeadless(_ relay: Relay, in chrome: RelayChrome) {
    chrome.send("Target.createTarget", ["url": "about:blank"]) { [weak self, weak relay] result, _ in
      guard let self, let relay, self.relay === relay, relay.headless else { return }
      guard let target = result?["targetId"] as? String else { return self.fallBack(relay) }
      relay.targetID = target
      self.changed()
      chrome.send("Target.attachToTarget", ["targetId": target, "flatten": true]) { [weak self, weak relay] result, _ in
        guard let self, let relay, self.relay === relay, relay.headless, relay.targetID == target else { return }
        guard let session = result?["sessionId"] as? String else { return self.fallBack(relay) }
        let url = relay.match.relayURL
        let navigate = { [weak self, weak relay] in
          chrome.send("Page.navigate", ["url": url], session: session) { _, error in
            guard let self, let relay, self.relay === relay, relay.headless, error != nil else { return }
            self.fallBack(relay)
          }
        }
        // Without the override the page still gets `--user-agent`; only its client hints would name headless Chrome.
        guard let version = self.chromeVersion, let override = RelayUserAgent.override(version: version) else {
          return navigate()
        }
        chrome.send("Emulation.setUserAgentOverride", override, session: session) { _, _ in navigate() }
      }
    }
  }

  /// Today's small window over Ray's. Brought forward unless Ray is in full screen, where macOS would leave Ray's
  /// Space for it: a note's button does that when the user wants it.
  private func openWindow(_ relay: Relay, in chrome: RelayChrome) {
    guard let controller = relay.controller else { return fail(relay, "cancelled", note: "JumpCloud sign-in didn't finish") }
    var params: [String: Any] = ["url": relay.match.relayURL, "newWindow": true]
    let bounds = bounds(over: controller.window)
    for (key, value) in bounds { params[key] = value }
    chrome.send("Target.createTarget", params) { [weak self, weak relay] result, _ in
      guard let self, let relay, self.relay === relay else { return }
      guard let target = result?["targetId"] as? String else {
        return self.fail(relay, "chromeQuit", note: "JumpCloud sign-in didn't finish")
      }
      relay.targetID = target
      self.place(target, bounds: bounds, in: chrome)
      if self.isFullScreen(relay.controller) {
        relay.controller?.showToast("Finish signing in to JumpCloud in Chrome", symbol: "arrow.up.forward.app",
                                    duration: 8) { [weak self] in self?.showChrome() }
      } else {
        relay.activated = true
        self.bringForward(chrome)
      }
      self.changed()
    }
  }

  /// Headless Chrome didn't sign in (in time, or at all): close it and start again in a visible window, on the same
  /// profile once the headless one has quit.
  private func fallBack(_ relay: Relay) {
    guard self.relay === relay, relay.headless, !relay.importing, !relay.switching else { return }
    relay.headlessDeadline?.cancel()
    relay.headless = false
    relay.switching = true
    relay.targetID = nil
    fallbacks += 1
    NSLog("[ray] JumpCloud relay: headless didn't finish, opening a window")
    if let chrome, !chrome.gone, chrome.headless { chrome.close() }
    changed()
    open(relay, headless: false)
  }

  /// The toast's button: Chrome's relay window in front (the user leaves a full-screen Ray for it).
  func showChrome() {
    guard let relay, !relay.headless, let chrome, !chrome.gone else { return }
    relay.activated = true
    bringForward(chrome)
  }

  private func isFullScreen(_ controller: BrowserWindowController?) -> Bool {
    guard let window = controller?.window else { return false }
    return window.styleMask.contains(.fullScreen) || (TestEnvironment.isTestBuild && simulatesFullScreen)
  }

  // MARK: Chrome session

  /// The version of the Chrome Ray last launched or located, for the user agent override.
  private var chromeVersion: String?

  /// The running Chrome, or a new one once it has answered; `failing` on no Chrome, a bad signature or no answer.
  /// `headless` asks for a new Chrome without windows; a running Chrome with windows serves either. Headless Chrome
  /// can't show the setup page: it's closed first unless a relay is using it.
  private func withChrome(headless: Bool, wanted: @escaping () -> Bool = { true }, tries: Int = 0,
                          failing: @escaping (String, String) -> Void, _ ready: @escaping (RelayChrome) -> Void) {
    // Whoever asked has gone (the relay ended while this waited for the last Chrome to quit).
    guard wanted() else { return }
    if let chrome, !chrome.gone {
      if !chrome.closing, chrome.headless, !headless {
        guard relay == nil else { return failing("busy", "JumpCloud sign-in is already open in Chrome") }
        chrome.close()
      }
      guard chrome.closing else { return ready(chrome) }
      // The last relay's Chrome is still quitting: a second Chrome on the same profile would hand over to it.
      guard tries < 40 else { return failing("busy", "JumpCloud sign-in is already open in Chrome") }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
        self?.withChrome(headless: headless, wanted: wanted, tries: tries + 1, failing: failing, ready)
      }
      return
    }
    let executable: String
    let version: String?
    switch RelayChromeApp.locate() {
    case .missing: return failing("noChrome", "JumpCloud Go needs Google Chrome")
    case .unsigned: return failing("badSignature", "Google Chrome's signature didn't check out")
    case .chrome(let path, let found):
      executable = path
      version = found
    }
    do {
      try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
      // Only this user: cookies of a signed-in JumpCloud session live here.
      try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory)
    } catch {
      return failing("noChrome", "Couldn't make Chrome's profile for JumpCloud Go")
    }
    var arguments = [
      "--user-data-dir=\(directory)", "--remote-debugging-pipe", "--no-first-run", "--no-default-browser-check",
      "--no-startup-window",
    ]
    // Headless only with a user agent to give it (it would otherwise call itself HeadlessChrome); without a version,
    // the relay uses a window. Chrome's new headless mode is the full browser on the profile, extensions included.
    let agent = version.flatMap(RelayUserAgent.string(version:))
    let startsHeadless = headless && agent != nil
    if startsHeadless, let agent { arguments += ["--headless=new", "--user-agent=\(agent)"] }
    guard let chrome = RelayChrome.launch(executable, arguments: arguments, headless: startsHeadless) else {
      return failing("noChrome", "Google Chrome didn't start")
    }
    chromeVersion = version
    launches += 1
    lastArguments = arguments
    self.chrome = chrome
    chrome.onEvent = { [weak self, weak chrome] method, params in
      guard let self, let chrome, self.chrome === chrome else { return }
      self.event(method, params, from: chrome)
    }
    chrome.onGone = { [weak self, weak chrome] in
      guard let self, let chrome, self.chrome === chrome else { return }
      self.chromeGone()
    }
    changed()
    // Chrome answers once its pipe handler runs; a policy that forbids remote debugging (RemoteDebuggingAllowed)
    // leaves it silent.
    var answered = false
    DispatchQueue.main.asyncAfter(deadline: .now() + answerDeadline) { [weak self, weak chrome] in
      guard let self, let chrome, !answered, self.chrome === chrome else { return }
      // Given up on: its pending setDiscoverTargets ends with "Chrome is gone" when it quits, which isn't news.
      answered = true
      // Kept as `chrome` while it quits, so the next one waits for it (one Chrome per profile).
      chrome.onGone = nil
      chrome.onEvent = nil
      chrome.terminate()
      self.setupOpen = false
      failing("noAnswer", "Chrome didn't answer Ray. A policy may block it")
      self.changed()
    }
    chrome.send("Target.setDiscoverTargets", ["discover": true]) { [weak chrome] _, error in
      guard let chrome, !answered else { return }
      answered = true
      if error == nil { ready(chrome) } else { failing("noAnswer", "Chrome didn't answer Ray. A policy may block it") }
    }
  }

  private func event(_ method: String, _ params: [String: Any], from chrome: RelayChrome) {
    switch method {
    case "Target.targetInfoChanged":
      guard let relay, !relay.importing, let info = params["targetInfo"] as? [String: Any],
            let target = info["targetId"] as? String, target == relay.targetID, let url = info["url"] as? String,
            JumpCloudLogin.isSignedIn(url, consoleHost: relay.match.consoleHost) else { return }
      signedIn(relay, in: chrome)
    case "Target.targetDestroyed":
      let target = params["targetId"] as? String
      if let relay, !relay.importing, target != nil, target == relay.targetID {
        // Headless, nobody could have closed it: Chrome lost the page. A window is worth a try.
        if relay.headless { return fallBack(relay) }
        relay.targetID = nil
        return fail(relay, "cancelled", note: "JumpCloud sign-in didn't finish")
      }
      // Nothing of Ray's left open in it (the setup window closed): Chrome quits.
      if relay == nil, chrome.pages.isEmpty { chrome.close() }
    default: break
    }
  }

  private func chromeGone() {
    chrome = nil
    setupOpen = false
    // Headless Chrome quitting by itself (a policy against headless mode, a crash) gets the window instead; the one
    // a fallback closed was meant to go.
    if let relay, !relay.importing, !relay.switching {
      if relay.headless { fallBack(relay) } else { fail(relay, "chromeQuit", note: "JumpCloud sign-in didn't finish") }
    }
    changed()
  }

  /// Closes the relay's window, and Chrome itself unless the user has another of Ray's Chrome windows open.
  private func retire(_ target: String?) {
    guard let chrome else { return }
    let others = chrome.pages.subtracting(target.map { [$0] } ?? [])
    if others.isEmpty || !setupOpen {
      chrome.close()
    } else if let target {
      chrome.send("Target.closeTarget", ["targetId": target])
    }
  }

  // MARK: Signed in

  private func signedIn(_ relay: Relay, in chrome: RelayChrome) {
    relay.importing = true
    relay.deadline?.cancel()
    relay.headlessDeadline?.cancel()
    changed()
    chrome.send("Storage.getCookies") { [weak self] result, error in
      guard let self else { return }
      let cookies = (result?["cookies"] as? [[String: Any]] ?? []).compactMap(JumpCloudLogin.cookie(from:))
      self.retire(relay.targetID)
      self.bringRayBack(relay)
      guard error == nil, !cookies.isEmpty else {
        return self.fail(relay, "noCookies", note: "Chrome had no JumpCloud sign-in to share")
      }
      self.copy(cookies, for: relay)
    }
  }

  /// Replaces Ray's JumpCloud cookies with Chrome's: `ac_cookies_import` keeps a cookie Ray already has, so a stale
  /// session would win; `ac_site_data_clear` first empties jumpcloud.com in Ray (its cookies and site storage).
  private func copy(_ cookies: [Cookie], for relay: Relay) {
    guard let profile = relay.controller?.profile ?? RayCoreEngine.shared?.defaultProfile, !profile.offTheRecord else {
      cookies.forEach { $0.value.wipe() }
      return fail(relay, "importFailed", note: "Couldn't bring the JumpCloud sign-in into Ray")
    }
    let batch = CookieWire.batches(Array(cookies.prefix(ImportRun.cookieBatch)), size: ImportRun.cookieBatch).batches
    cookies.forEach { $0.value.wipe() }
    EngineCalls.call("ac_site_data_clear", profile: profile, args: ["origin": relay.match.origin]) { [weak self] _ in
      guard let self else { return }
      guard let json = batch.first else { return self.fail(relay, "importFailed", note: "Couldn't bring the JumpCloud sign-in into Ray") }
      EngineCalls.callWithSecret("ac_cookies_import", profile: profile, json: json) { [weak self] reply in
        batch.forEach { $0.wipe() }
        guard let self else { return }
        let imported = (reply?["imported"] as? NSNumber)?.intValue ?? 0
        guard reply?["error"] == nil, imported > 0 else {
          return self.fail(relay, "importFailed", note: "Couldn't bring the JumpCloud sign-in into Ray")
        }
        self.cookiesImported = imported
        self.done(relay)
      }
    }
  }

  private func done(_ relay: Relay) {
    self.relay = nil
    var reloaded = false
    if let tab = relay.tab, !tab.closed, tab.committedOrigin == relay.match.origin,
       JumpCloudLogin.match(committedOrigin: tab.committedOrigin, url: tab.url) != nil {
      tab.userReload()
      reloaded = true
    }
    if let tab = relay.tab {
      recent[tab.tabId] = Recent(time: ProcessInfo.processInfo.systemUptime, reloadPending: reloaded)
    }
    finish("signedIn", note: "Signed in with JumpCloud Go", in: relay.controller)
  }

  private func fail(_ relay: Relay, _ result: String, note: String) {
    guard self.relay === relay else { return }
    self.relay = nil
    relay.deadline?.cancel()
    relay.headlessDeadline?.cancel()
    if !relay.importing { retire(relay.targetID) }
    bringRayBack(relay)
    finish(result, note: note, in: relay.controller)
  }

  private func finish(_ result: String, note: String, symbol: String? = nil, in controller: BrowserWindowController?,
                      action: (() -> Void)? = nil) {
    lastResult = result
    // Never logs addresses or cookies, in any build.
    NSLog("[ray] JumpCloud relay: %@", result)
    (controller ?? AppController.shared.current)?.showToast(note, symbol: symbol, action: action)
    changed()
  }

  // MARK: Set up

  /// Settings' Set Up…: Ray's Chrome on JumpCloud Go's Web Store page, at Chrome's own size, until the user closes it.
  func setUp() {
    withChrome(headless: false, failing: { [weak self] result, note in
      self?.finish(result, note: note, in: nil)
    }) { [weak self] chrome in
      guard let self else { return }
      self.setupOpen = true
      chrome.send("Target.createTarget", ["url": Self.storeURL, "newWindow": true]) { [weak self] _, _ in
        self?.bringForward(chrome)
        self?.lastResult = "setup"
        self?.changed()
      }
    }
  }

  // MARK: Windows

  /// The relay window's frame, centred over Ray's window, in Chrome's screen coordinates (points from the top left of
  /// the main screen).
  private func bounds(over window: NSWindow) -> [String: Int] {
    let size = Self.windowSize
    var origin = NSPoint(x: window.frame.midX - size.width / 2, y: window.frame.midY - size.height / 2)
    if let visible = window.screen?.visibleFrame {
      origin.x = min(max(origin.x, visible.minX), max(visible.minX, visible.maxX - size.width))
      origin.y = min(max(origin.y, visible.minY), max(visible.minY, visible.maxY - size.height))
    }
    let top = (NSScreen.screens.first?.frame.maxY ?? window.frame.maxY) - origin.y - size.height
    return ["left": Int(origin.x.rounded()), "top": Int(top.rounded()), "width": Int(size.width), "height": Int(size.height)]
  }

  /// `Target.createTarget` takes the bounds on recent Chrome; this sets them on any.
  private func place(_ target: String, bounds: [String: Int], in chrome: RelayChrome) {
    chrome.send("Browser.getWindowForTarget", ["targetId": target]) { result, _ in
      guard let window = result?["windowId"] else { return }
      chrome.send("Browser.setWindowBounds", ["windowId": window, "bounds": bounds])
    }
  }

  /// Chrome's window in front (never headless Chrome, which has none; never from a background test instance, though
  /// it's counted there).
  private func bringForward(_ chrome: RelayChrome) {
    guard !chrome.headless else { return }
    activations += 1
    guard !launchedInBackground, let app = NSRunningApplication(processIdentifier: chrome.pid) else { return }
    NSApp.yieldActivation(to: app)
    app.activate(from: .current, options: [])
  }

  /// Ray back in front after a relay that brought Chrome forward; one that never left Ray takes no focus.
  private func bringRayBack(_ relay: Relay) {
    guard relay.activated, !launchedInBackground, let controller = relay.controller else { return }
    NSApp.activate()
    controller.window.makeKeyAndOrderFront(nil)
  }

  private func changed() {
    NotificationCenter.default.post(name: Self.didChange, object: self)
  }

  // MARK: State log

  var debug: [String: Any] {
    let state: String
    if let relay { state = relay.importing ? "importing" : (relay.targetID == nil ? "launching" : "signingIn") } else {
      state = setupOpen ? "setup" : "idle"
    }
    let permissions = (try? FileManager.default.attributesOfItem(atPath: directory))?[.posixPermissions] as? NSNumber
    return [
      "state": state, "launches": launches, "lastResult": lastResult, "cookiesImported": cookiesImported,
      "chromeRunning": chrome.map { !$0.gone } ?? false, "pid": chrome.map { Int($0.pid) } ?? NSNull(),
      "arguments": lastArguments, "directory": directory,
      "directoryMode": permissions.map { String($0.intValue, radix: 8) } ?? NSNull(),
      "setUp": isSetUp, "status": status.text, "activations": activations, "fallbacks": fallbacks,
      "mode": relay.map { $0.headless ? "headless" : "window" } ?? "none", "lastMode": lastMode,
      "chromeHeadless": chrome.map { !$0.gone && $0.headless } ?? false,
    ]
  }
}
