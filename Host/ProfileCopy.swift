import AppKit

/// Copy to Another Profile… (owner's pick A, 2026-11-25): a profile's ⋯ in Settings › Spaces asks, over the Settings
/// window, which profile and what (passwords, history, addresses, extensions), then copies through the engine's own
/// calls: passwords by Chrome's export (one Touch ID or login password, `ac_passwords_export`, to a private file read
/// and deleted at once) and `ac_passwords_add` per login; history `ac_history_query` into `ac_history_import`;
/// addresses `ac_autofill_addresses` into `ac_autofill_save_address`; extensions open their Web Store pages in a Space
/// of the other profile (the engine can't install a store extension by itself). Cookies (sign-ins) and cards (their
/// numbers need a re-auth each) aren't copied; bookmarks are every profile's already.
enum ProfileCopy {
  enum Kind: String, CaseIterable {
    case passwords, history, addresses, extensions

    var title: String {
      switch self {
      case .passwords: "Passwords"
      case .history: "History"
      case .addresses: "Addresses"
      case .extensions: "Extensions"
      }
    }
  }

  /// What the last copy did, for the state log (counts only).
  private(set) static var last: [String: Any]?
  private(set) static var running = false

  /// Asks, then copies. `from` is the profile's directory (nil: Default).
  static func ask(from source: String?) {
    guard let window = SettingsDataProfile.window, !running else { return }
    let targets = window.state.profiles.filter { $0.directory != source }
    guard !targets.isEmpty, let sourceInfo = window.state.profileInfo(source) ?? (source == nil ? ProfileInfo(directory: nil, name: ProfileInfo.defaultName) : nil)
    else { return }
    let form = ProfileCopyForm(targets: targets)
    var handle: PanelHandle?
    let question = PanelQuestion(title: "Copy from \(sourceInfo.name)", message: "", accessory: form,
                                 answers: [("Cancel", false, false), ("Copy", true, false)]) { answer in
      handle?.close()
      guard answer == 1, let target = form.target else { return }
      copy(from: source, to: target, kinds: form.chosen)
    }
    form.onChange = { [weak question] in question?.buttons[1].isEnabled = !form.chosen.isEmpty }
    pending = form
    pendingQuestion = question
    handle = SettingsWindowController.shared.askQuestion("profileCopy", question, onReturn: nil, onClose: {
      pending = nil
      pendingQuestion = nil
    })
  }

  /// The open question's form, for tests.
  private(set) static var pending: ProfileCopyForm?
  private(set) static weak var pendingQuestion: PanelQuestion?

  static func copy(from source: String?, to target: String?, kinds: Set<Kind>, done: (() -> Void)? = nil) {
    guard let window = SettingsDataProfile.window, !running else { return }
    running = true
    var result: [String: Any] = ["kinds": kinds.map(\.rawValue).sorted()]
    window.loadProfile(source) { from in
      window.loadProfile(target) { to in
        guard let from, let to, from !== to else {
          running = false
          last = ["error": "profile"]
          return
        }
        var steps = Kind.allCases.filter(kinds.contains)
        func next() {
          guard !steps.isEmpty else {
            running = false
            last = result
            window.logState("profileCopy")
            summary(result)
            done?()
            return
          }
          let kind = steps.removeFirst()
          let finish = { (count: Any) in
            result[kind.rawValue] = count
            next()
          }
          switch kind {
          case .history: copyHistory(from, to, finish)
          case .addresses: copyAddresses(from, to, finish)
          case .passwords: copyPasswords(from, to, finish)
          case .extensions: openExtensions(from, to, target: target, in: window, finish)
          }
        }
        next()
      }
    }
  }

  private static func summary(_ result: [String: Any]) {
    let parts = Kind.allCases.compactMap { kind -> String? in
      guard let count = result[kind.rawValue] as? Int else {
        return (result[kind.rawValue] as? String).map { "\(kind.title): \($0)" }
      }
      return "\(count.formatted()) \(kind.title)"
    }
    guard !parts.isEmpty else { return }
    SettingsDataProfile.window?.notes.show(Note("Copied \(parts.joined(separator: ", "))", key: "profileCopy"))
  }

  // MARK: History

  private static func copyHistory(_ from: RayCoreProfile, _ to: RayCoreProfile, _ done: @escaping (Any) -> Void) {
    EngineCalls.call("ac_history_query", profile: from, args: ["maxUrls": 50_000, "maxVisits": 1]) { reply in
      let rows: [[String: Any]] = (reply?["entries"] as? [[String: Any]] ?? []).compactMap { row in
        guard let url = row["u"] as? String, let last = (row["v"] as? [Double])?.max(), last > 0 else { return nil }
        return ["u": url, "t": String((row["t"] as? String ?? "").prefix(1024)), "n": max(1, row["n"] as? Int ?? 1), "l": last]
      }
      var batches = stride(from: 0, to: rows.count, by: 1000).map { Array(rows[$0..<min($0 + 1000, rows.count)]) }
      func send() {
        guard !batches.isEmpty else { return done(rows.count) }
        guard let json = try? JSONSerialization.data(withJSONObject: ["rows": batches.removeFirst()]) else { return done("failed") }
        EngineCalls.call("ac_history_import", profile: to, json: json) { reply in
          if reply?["error"] != nil { return done("failed") }
          send()
        }
      }
      send()
    }
  }

  // MARK: Addresses

  private static func copyAddresses(_ from: RayCoreProfile, _ to: RayCoreProfile, _ done: @escaping (Any) -> Void) {
    EngineCalls.call("ac_autofill_addresses", profile: from) { reply in
      var addresses = (reply?["addresses"] as? [[String: Any]] ?? []).map { entry -> [String: String] in
        var address = entry.compactMapValues { $0 as? String }
        address["id"] = nil
        return address
      }
      var saved = 0
      func send() {
        guard !addresses.isEmpty else { return done(saved) }
        EngineCalls.call("ac_autofill_save_address", profile: to, args: ["address": addresses.removeFirst()]) { reply in
          if reply != nil, reply?["error"] == nil { saved += 1 }
          send()
        }
      }
      send()
    }
  }

  // MARK: Passwords

  private static func copyPasswords(_ from: RayCoreProfile, _ to: RayCoreProfile, _ done: @escaping (Any) -> Void) {
    guard settingsReauthAllowed else { return done("needs Touch ID") }
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Ray Profile Copy \(UUID().uuidString)")
    do {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                              attributes: [.posixPermissions: 0o700])
    } catch { return done("failed") }
    let file = folder.appendingPathComponent("passwords.csv")
    let cleanUp = {
      // Overwrite before removing: the file held every password in plain text.
      if let handle = try? FileHandle(forWritingTo: file) {
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: 0)
        handle.write(Data(count: Int(size)))
        try? handle.close()
      }
      try? FileManager.default.removeItem(at: folder)
    }
    EngineCalls.call("ac_passwords_export", profile: from, args: ["path": file.path]) { reply in
      guard reply?["status"] as? String == "succeeded" else {
        cleanUp()
        return done(reply?["status"] as? String == "reauthFailed" ? "not confirmed" : "failed")
      }
      let credentials = (try? PasswordsCSV.load(file)) ?? []
      cleanUp()
      var queue = credentials
      var saved = 0
      func send() {
        guard !queue.isEmpty else { return done(saved) }
        let credential = queue.removeFirst()
        guard let origin = ImportShape.origin(of: credential), !credential.password.isEmpty else { return send() }
        let writer = SecretWriter(capacity: 256)
        writer.append("{\"origin\":")
        JSON.string(origin, to: writer)
        writer.append(",\"username\":")
        JSON.string(credential.username, to: writer)
        writer.append(",\"password\":")
        JSON.string(credential.password, to: writer)
        writer.append(UInt8(ascii: "}"))
        writer.append(0)
        let json = writer.finish()
        EngineCalls.callWithSecret("ac_passwords_add", profile: to, json: json) { reply in
          json.wipe()
          if reply?["error"] == nil || (reply?["error"] as? String)?.contains("already saved") == true { saved += 1 }
          send()
        }
      }
      send()
    }
  }

  // MARK: Extensions

  /// The source's extensions the target hasn't, as Web Store pages in a Space on the target profile.
  private static func openExtensions(_ from: RayCoreProfile, _ to: RayCoreProfile, target: String?,
                                     in window: BrowserWindowController, _ done: @escaping (Any) -> Void) {
    EngineCalls.call("ac_extensions_list", profile: from) { reply in
      let theirs = (reply?["extensions"] as? [[String: Any]] ?? []).filter { $0["location"] as? String != "UNPACKED" }
        .compactMap { $0["id"] as? String }
      EngineCalls.call("ac_extensions_list", profile: to) { reply in
        let have = Set((reply?["extensions"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String })
        let missing = theirs.filter { !have.contains($0) && $0.allSatisfy { $0.isLetter && $0.isLowercase } && $0.count == 32 }
        guard !missing.isEmpty else { return done(0) }
        guard let space = window.state.spaces.first(where: { $0.profile == target }) else { return done("no Space") }
        window.switchSpace(to: space)
        DispatchQueue.main.async {
          for id in missing.prefix(20) {
            _ = window.openToday("https://chromewebstore.google.com/detail/\(id)", after: nil, foreground: false)
          }
          done(min(missing.count, 20))
        }
      }
    }
  }
}

/// The question's form: To (a pop-up of the other profiles) and a box per kind.
final class ProfileCopyForm: NSView, PanelQuestionAccessory {
  private let targets: [ProfileInfo]
  private let label = settingsLabel("To", size: 13, color: .secondaryLabelColor)
  let popUp = NSPopUpButton(frame: .zero, pullsDown: false)
  private var boxes: [(ProfileCopy.Kind, NSButton)] = []
  private let note = settingsLabel("Sign-ins and cards stay. Bookmarks are shared already.", size: 11.5, color: .tertiaryLabelColor)
  var onChange: (() -> Void)?

  init(targets: [ProfileInfo]) {
    self.targets = targets
    super.init(frame: .zero)
    for info in targets {
      popUp.addItem(withTitle: info.name)
      popUp.lastItem?.image = ProfileInfo.avatar(info, size: 14)
    }
    addSubview(label)
    addSubview(popUp)
    for kind in ProfileCopy.Kind.allCases {
      let box = NSButton(checkboxWithTitle: kind == .extensions ? "Extensions (opens their store pages)" : kind.title,
                         target: self, action: #selector(toggled))
      box.state = kind == .extensions ? .off : .on
      boxes.append((kind, box))
      addSubview(box)
    }
    addSubview(note)
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }

  var target: String?? {
    let index = popUp.indexOfSelectedItem
    return targets.indices.contains(index) ? .some(targets[index].directory) : nil
  }

  var chosen: Set<ProfileCopy.Kind> { Set(boxes.filter { $0.1.state == .on }.map(\.0)) }

  @objc private func toggled() { onChange?() }

  func height(forWidth width: CGFloat) -> CGFloat { 34 + CGFloat(boxes.count) * 24 + 24 }

  override func layout() {
    super.layout()
    let size = popUp.intrinsicContentSize
    label.frame = NSRect(x: 0, y: (28 - label.intrinsicContentSize.height) / 2, width: 30, height: label.intrinsicContentSize.height)
    popUp.frame = NSRect(x: 34, y: (28 - size.height) / 2, width: max(size.width, 160), height: size.height)
    var y: CGFloat = 34
    for (_, box) in boxes {
      box.frame = NSRect(x: 0, y: y, width: bounds.width, height: 20)
      y += 24
    }
    note.frame = NSRect(x: 0, y: y + 2, width: bounds.width, height: note.intrinsicContentSize.height)
  }

  // Tests.
  func set(_ kinds: Set<ProfileCopy.Kind>, target index: Int) {
    for (kind, box) in boxes { box.state = kinds.contains(kind) ? .on : .off }
    if targets.indices.contains(index) { popUp.selectItem(at: index) }
    onChange?()
  }
}
