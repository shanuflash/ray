import AppKit
import Security

// JumpCloud Go through Google Chrome (Settings › Passwords, `jumpCloudRelay`, off by default).
//
// JumpCloud Go's native helper hands its sign-in token only to browsers on its own list, checked by the code signature
// of the process that launched it (docs/MISSING.md, Known limitations #15), so Ray can never get one. Real Google
// Chrome can. With the setting on, a normal Ray tab that lands on JumpCloud's user login page starts Ray's own Chrome
// instance (its own profile next to Ray's data, never the user's Chrome profile), shows JumpCloud's login page there
// in a small window for Touch ID, waits for the user console, then copies only jumpcloud.com cookies into Ray and
// reloads the tab. Chrome is driven over `--remote-debugging-pipe` (file descriptors 3 and 4, NUL-separated JSON):
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
    case chrome(executable: String)
    case missing
    case unsigned
  }

  /// Google Chrome's executable once its signature checks out. Test builds take only `RAY_JUMPCLOUD_RELAY_CHROME` (a
  /// stand-in, never checked) and never fall back to the real Chrome.
  static func locate() -> Found {
    if TestEnvironment.isTestBuild {
      guard let path = TestEnvironment["RAY_JUMPCLOUD_RELAY_CHROME"], !path.isEmpty else { return .missing }
      return .chrome(executable: path)
    }
    guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") else { return .missing }
    guard isGoogleChrome(app), let executable = Bundle(url: app)?.executableURL?.path else { return .unsigned }
    return .chrome(executable: executable)
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

/// One Chrome process Ray started, and the DevTools pipe to it. Main thread only.
final class RelayChrome {
  let pid: pid_t
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
  static func launch(_ executable: String, arguments: [String]) -> RelayChrome? {
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
    return RelayChrome(pid: pid, write: toChrome[1], read: fromChrome[0])
  }

  private init(pid: pid_t, write: Int32, read: Int32) {
    self.pid = pid
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

  /// Sends a command; `done` gets its result, or its error (also "Chrome is gone").
  func send(_ method: String, _ params: [String: Any] = [:], done: (([String: Any]?, String?) -> Void)? = nil) {
    guard !gone else {
      done?(nil, "Chrome is gone")
      return
    }
    let id = nextID
    nextID += 1
    if let done { waiting[id] = done }
    guard var data = try? JSONSerialization.data(withJSONObject: ["id": id, "method": method, "params": params]) else {
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

  /// How long the user has to sign in; how long Chrome has to answer at all. Test builds can shorten both.
  private let signInDeadline: TimeInterval = TestEnvironment["RAY_JUMPCLOUD_RELAY_DEADLINE"].flatMap(Double.init) ?? 120
  private var answerDeadline: TimeInterval { min(15, signInDeadline / 2) }

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

  private final class Relay {
    let match: JumpCloudLogin.Match
    weak var tab: RayCoreTab?
    weak var controller: BrowserWindowController?
    var targetID: String?
    var deadline: DispatchWorkItem?
    var importing = false

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
    withChrome(failing: { [weak self, weak relay] result, note in
      guard let self, let relay, self.relay === relay else { return }
      self.fail(relay, result, note: note)
    }) { [weak self, weak relay] chrome in
      guard let self, let relay, self.relay === relay else { return }
      var params: [String: Any] = ["url": match.relayURL, "newWindow": true]
      let bounds = self.bounds(over: controller.window)
      for (key, value) in bounds { params[key] = value }
      chrome.send("Target.createTarget", params) { [weak self, weak relay] result, _ in
        guard let self, let relay, self.relay === relay else { return }
        guard let target = result?["targetId"] as? String else {
          return self.fail(relay, "chromeQuit", note: "JumpCloud sign-in didn't finish")
        }
        relay.targetID = target
        self.place(target, bounds: bounds, in: chrome)
        self.bringForward(chrome)
        self.changed()
      }
    }
  }

  // MARK: Chrome session

  /// The running Chrome, or a new one once it has answered; `failing` on no Chrome, a bad signature or no answer.
  private func withChrome(tries: Int = 0, failing: @escaping (String, String) -> Void,
                          _ ready: @escaping (RelayChrome) -> Void) {
    if let chrome, !chrome.gone {
      guard chrome.closing else { return ready(chrome) }
      // The last relay's Chrome is still quitting: a second Chrome on the same profile would hand over to it.
      guard tries < 40 else { return failing("busy", "JumpCloud sign-in is already open in Chrome") }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
        self?.withChrome(tries: tries + 1, failing: failing, ready)
      }
      return
    }
    let executable: String
    switch RelayChromeApp.locate() {
    case .missing: return failing("noChrome", "JumpCloud Go needs Google Chrome")
    case .unsigned: return failing("badSignature", "Google Chrome's signature didn't check out")
    case .chrome(let path): executable = path
    }
    do {
      try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
      // Only this user: cookies of a signed-in JumpCloud session live here.
      try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory)
    } catch {
      return failing("noChrome", "Couldn't make Chrome's profile for JumpCloud Go")
    }
    let arguments = [
      "--user-data-dir=\(directory)", "--remote-debugging-pipe", "--no-first-run", "--no-default-browser-check",
      "--no-startup-window",
    ]
    guard let chrome = RelayChrome.launch(executable, arguments: arguments) else {
      return failing("noChrome", "Google Chrome didn't start")
    }
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
      chrome.onGone = nil
      chrome.terminate()
      self.chrome = nil
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
    if let relay, !relay.importing { fail(relay, "chromeQuit", note: "JumpCloud sign-in didn't finish") }
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
    changed()
    chrome.send("Storage.getCookies") { [weak self] result, error in
      guard let self else { return }
      let cookies = (result?["cookies"] as? [[String: Any]] ?? []).compactMap(JumpCloudLogin.cookie(from:))
      self.retire(relay.targetID)
      self.bringRayBack(relay.controller)
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
    if !relay.importing { retire(relay.targetID) }
    bringRayBack(relay.controller)
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
    withChrome(failing: { [weak self] result, note in
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

  /// Chrome in front for Touch ID (never from a background test instance).
  private func bringForward(_ chrome: RelayChrome) {
    guard !launchedInBackground, let app = NSRunningApplication(processIdentifier: chrome.pid) else { return }
    NSApp.yieldActivation(to: app)
    app.activate(from: .current, options: [])
  }

  private func bringRayBack(_ controller: BrowserWindowController?) {
    guard !launchedInBackground, let controller else { return }
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
      "setUp": isSetUp, "status": status.text,
    ]
  }
}
