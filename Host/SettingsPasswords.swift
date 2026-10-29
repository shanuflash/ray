import AppKit
import UniformTypeIdentifiers

// Settings › Passwords: the engine's saved passwords (`ac_passwords_*`, engine/chromium/src/chrome/browser/ray/
// ac_passwords.cc), behind the engine's own OS re-auth (`ac_reauth.cc`: Touch ID or the login password).
//
// Locked until Unlock (`ac_passwords_unlock`, which asks only when there are passwords); locked again when the
// Settings window closes, after five minutes without a click or key in it, or on sleep (`SettingsDataGuard`). Unlocked:
// the sites and usernames, searchable; a row opens its details (show and copy the password, copy the username, edit,
// delete); Add…; sites set to "never save". Showing, copying, editing and exporting go through the engine, which asks
// again once its five-minute validity has passed (exporting always asks). A shown password lives only in its label and
// in `revealed` until the row closes or the pane locks; a copied one is marked concealed and cleared after two minutes.
// Passwords go to the engine through `EngineCalls.callWithSecret` (`SecretJSON`), never in a log, the state log
// (counts only) or a test command line (fixtures by index, `SettingsFixtures`).

extension SettingGroup {
  static let passwordsSaving = SettingGroup(id: "passwordsSaving", title: "Saving and filling")
}

extension AnySettingKey {
  /// Chrome's "Offer to save passwords". Not built: Ray has no save or fill prompt yet (docs/MISSING.md, Chrome #2).
  /// Its id says "logins": Settings.json never names passwords (the `settings-persist` check looks).
  static let offerToSavePasswords = SettingKey<Bool>(
    "offerToSaveLogins", default: true, built: false,
    ui: SettingUI(
      pane: .passwords, group: .passwordsSaving, title: "Offer to save passwords",
      detail: "", about: "Ray asks to save a password when you sign in to a site, and fills it in next time.",
      keywords: ["save passwords", "fill passwords", "autofill", "sign in", "password manager"], control: .toggle))
}

/// The Passwords pane's own content: the saved passwords (locked until Unlock), then other apps and files.
final class PasswordsPaneContent: SettingsPaneContent {
  static let shared = PasswordsPaneContent()

  let saved = SavedPasswordsView()
  let more = PasswordsMoreView()

  var hasContent: Bool { true }

  func sections() -> [SettingsSection] {
    [
      SettingsSection(
        id: "passwords.saved", place: .after(SettingGroup.passwordsSaving.id), view: saved,
        search: [
          SettingsSearchEntry(title: "Saved passwords", detail: "See, copy and change the passwords Ray keeps",
                              keywords: ["passwords", "logins", "usernames", "unlock", "touch id", "reveal", "show password"]),
          SettingsSearchEntry(title: "Add a password", detail: "Save a site's sign-in by hand", keywords: ["new password", "add login"]),
          SettingsSearchEntry(title: "Never saved", detail: "Sites Ray doesn't offer to save passwords for",
                              keywords: ["exceptions", "never save", "blocked sites"]),
        ]),
      SettingsSection(
        id: "passwords.more", title: "Other apps and files", place: .bottom, view: more,
        search: [
          SettingsSearchEntry(title: "Password manager apps", detail: "1Password, Bitwarden and others in Ray",
                              keywords: ["1password", "bitwarden", "keepassxc", "proton pass", "extension", "add browser"]),
          SettingsSearchEntry(title: "Import passwords", detail: "From a CSV file", keywords: ["csv", "import", "passwords file"]),
          SettingsSearchEntry(title: "Export passwords", detail: "To a CSV file", keywords: ["csv", "export", "backup", "download"]),
        ]),
      JumpCloudSetupRow.section(),
    ]
  }

  /// For the state log: counts and states only, never a site, username or password.
  var debug: [String: Any] { saved.debug.merging(more.debug) { a, _ in a } }

  // MARK: Tests

  /// `passwords unlock|lock|idle|search <text>|open <n>|close|reveal|revealcheck <i>|copy user|password|pasteboard <i>|
  /// clearnow|add <i>|edit <i>|remove|confirm yes|no|more|export <path>|importcsv <path>`: the pane driven as clicks and
  /// typing would. `<i>` is a fixture login (`RAY_TEST_SECRETS`), so no secret is in the line. Nil: answered later.
  func test(_ line: String, _ argument: String) -> String? {
    let words = argument.split(separator: " ", maxSplits: 1).map(String.init)
    let rest = words.count == 2 ? words[1] : ""
    switch words.first {
    case "unlock": return saved.pressUnlock() ? "ok" : "not locked"
    case "lock":
      SettingsDataGuard.shared.lock()
    case "idle":
      // What five minutes without a click would do, now.
      guard SettingsDataGuard.shared.armed else { return "not armed" }
      SettingsDataGuard.shared.lock()
    case "search": saved.setQuery(rest)
    case "open": return Int(rest).map { saved.openRow($0) ? "ok" : "no such row" } ?? "usage: passwords open <n>"
    case "close": saved.closeRow(cancelAdding: true)
    case "reveal": return saved.pressReveal() ? "ok" : "no row open"
    case "revealcheck":
      guard let login = SettingsFixtures.item("logins", rest) else { return "no fixture" }
      return saved.revealedMatches(SettingsFixtures.text(login, "password"))
    case "copy":
      guard rest == "user" || rest == "password", saved.pressCopy(password: rest == "password") else { return "no row open" }
    case "pasteboard":
      guard let login = SettingsFixtures.item("logins", rest) else { return "no fixture" }
      let text = SettingsPasteboard.board.string(forType: .string)
      return "{\"password\":\(text == SettingsFixtures.text(login, "password")),\"username\":\(text == SettingsFixtures.text(login, "username")),"
        + "\"empty\":\(text == nil),\"concealed\":\(SettingsPasteboard.isConcealed),\"clearPending\":\(SettingsPasteboard.clearPending)}"
    case "clearnow": return SettingsPasteboard.clearNow() ? "ok" : "nothing to clear"
    case "add":
      guard let login = SettingsFixtures.item("logins", rest) else { return "no fixture" }
      return saved.addFixture(login) ? "ok" : "locked"
    case "edit":
      guard let login = SettingsFixtures.item("logins", rest) else { return "no fixture" }
      return saved.editFixture(login) ? "ok" : "no row open"
    case "remove": return saved.pressDelete() ? "ok" : "no row open"
    case "confirm":
      guard rest == "yes" || rest == "no", SettingsRecordConfirm.answer(rest == "yes") else { return "no sheet" }
    case "more": more.toggleMore()
    case "export":
      guard rest.hasPrefix("/") else { return "usage: passwords export <absolute path>" }
      return more.pressExport(testPath: rest) ? "ok" : "no window"
    case "importcsv":
      guard rest.hasPrefix("/") else { return "usage: passwords importcsv <absolute path>" }
      more.importCSV(URL(fileURLWithPath: rest))
    default:
      return "usage: passwords unlock|lock|idle|search|open|close|reveal|revealcheck|copy|pasteboard|clearnow|add|edit|remove|confirm|more|export|importcsv"
    }
    return "ok"
  }
}

// MARK: Saved passwords

/// The saved passwords: a lock with Unlock, or the list (header with count, search and Add…; rows; the open row's
/// details or editor; sites never saved).
final class SavedPasswordsView: NSView, SettingsSizing, NSSearchFieldDelegate {
  struct Login: Equatable {
    let origin: String
    let username: String
  }

  private let stack = SettingsStack()
  private let header = SettingsDataHeader(title: "Saved passwords")
  private let search = NSSearchField()
  private lazy var addButton = SettingsPushButton("Add…") { [weak self] in self?.startAdding() }
  private lazy var lockedView = PasswordsLockedView { [weak self] in _ = self?.pressUnlock() }

  private(set) var locked = true
  private var logins: [Login] = []
  private var exceptions: [String] = []
  private var query = ""
  private var open: Login?
  /// The open row's password while it shows; nil the moment it hides, the row closes or the pane locks.
  private var revealed: String?
  private var addCard: SettingsCard?
  private var addForm: SettingsForm?
  private var editCard: SettingsCard?
  private var editForm: SettingsForm?
  private var busy = false
  /// What the last action came to, for tests: a fixed word, never data.
  private(set) var last = ""

  override var isFlipped: Bool { true }

  override init(frame: NSRect) {
    super.init(frame: frame)
    addSubview(stack)
    search.placeholderString = "Search"
    search.delegate = self
    search.sendsSearchStringImmediately = true
    search.controlSize = .regular
    search.setAccessibilityLabel("Search saved passwords")
    header.setTrailing([search, addButton])
    SettingsDataGuard.shared.register { [weak self] in self?.lock() }
    render()
  }

  required init?(coder: NSCoder) { fatalError() }

  func height(forWidth width: CGFloat) -> CGFloat { stack.height(forWidth: width) }

  override func layout() {
    super.layout()
    stack.frame = bounds
  }

  private var profile: RayCoreProfile? { settingsDataProfile }

  private var shown: [Login] {
    let words = query.lowercased().split(separator: " ").map(String.init)
    guard !words.isEmpty else { return logins }
    return logins.filter { login in
      let text = (login.origin + " " + login.username).lowercased()
      return words.allSatisfy { text.contains($0) }
    }
  }

  // MARK: Showing

  private func render() {
    var items: [SettingsStack.Item] = []
    if locked {
      items.append(.init(view: lockedView))
    } else {
      header.count = logins.isEmpty ? "" : logins.count.formatted()
      items.append(.init(view: header))
      if let addCard { items.append(.init(view: addCard, gap: 4)) }
      let list = shown
      if list.isEmpty {
        items.append(.init(view: SettingsNote(query.isEmpty
          ? "No saved passwords yet."
          : "No saved passwords match.")))
      }
      for (index, login) in list.enumerated() {
        let row = SettingsRecordRow(symbol: "key.fill", title: Self.host(of: login.origin),
                                  detail: login.username.isEmpty ? "No username" : login.username, headFirst: true)
        row.expanded = login == open
        row.onClick = { [weak self] in self?.toggle(login) }
        items.append(.init(view: row, line: index > 0))
        if login == open { items.append(.init(view: editCard ?? detailCard(for: login))) }
      }
      if !exceptions.isEmpty {
        let never = SettingsDataHeader(title: "Never saved")
        items.append(.init(view: never, gap: 22))
        items.append(.init(view: SettingsNote("Ray won't offer to save passwords on these sites.", inset: 0)))
        for (index, origin) in exceptions.enumerated() {
          let allow = SettingsPushButton("Remove") { [weak self] in self?.allow(origin) }
          allow.setAccessibilityLabel("Remove \(Self.host(of: origin)) from never saved")
          items.append(.init(view: SettingsRecordRow(symbol: "nosign", title: Self.host(of: origin), detail: "", headFirst: true,
                                                   trailing: allow), line: index > 0))
        }
      }
    }
    stack.set(items)
    settingsContentDidResize(self)
  }

  private func detailCard(for login: Login) -> SettingsCard {
    let copyUser = SettingsIconButton(symbol: "doc.on.doc", label: "Copy Username") { [weak self] in _ = self?.pressCopy(password: false) }
    let eye = SettingsIconButton(symbol: revealed == nil ? "eye" : "eye.slash", label: revealed == nil ? "Show Password" : "Hide Password") { [weak self] in
      _ = self?.pressReveal()
    }
    let copyPassword = SettingsIconButton(symbol: "doc.on.doc", label: "Copy Password") { [weak self] in _ = self?.pressCopy(password: true) }
    let lines = SettingsStack()
    lines.set([
      .init(view: SettingsDetailLine(name: "Website", value: login.origin)),
      .init(view: SettingsDetailLine(name: "Username", value: login.username.isEmpty ? "None" : login.username,
                                     buttons: login.username.isEmpty ? [] : [copyUser])),
      .init(view: SettingsDetailLine(name: "Password", value: revealed ?? String(repeating: "•", count: 10),
                                     monospaced: revealed != nil, buttons: [eye, copyPassword])),
      .init(view: SettingsButtonBar(
        leading: [SettingsPushButton("Delete…", destructive: true) { [weak self] in _ = self?.pressDelete() }],
        trailing: [SettingsPushButton("Edit") { [weak self] in self?.startEditing() }])),
    ])
    return SettingsCard(lines)
  }

  /// "accounts.example.com" for "https://accounts.example.com" (its port too); anything else as it is.
  static func host(of origin: String) -> String {
    guard let components = URLComponents(string: origin), let host = components.host, !host.isEmpty else { return origin }
    return host + (components.port.map { ":\($0)" } ?? "")
  }

  // MARK: Unlocking

  /// Unlock: the engine asks for Touch ID or the login password (not when there are no passwords yet).
  func pressUnlock() -> Bool {
    guard locked, !busy, let profile else { return false }
    guard settingsReauthAllowed else {
      last = "noReauth"
      settingsDataChanged("passwords")
      return true
    }
    busy = true
    last = "unlocking"
    EngineCalls.call("ac_passwords_unlock", profile: profile) { [weak self] reply in
      guard let self else { return }
      self.busy = false
      guard reply?["unlocked"] as? Bool == true else {
        self.last = reply?["error"] != nil ? "error" : "denied"
        return settingsDataChanged("passwords")
      }
      self.locked = false
      self.last = "unlocked"
      SettingsDataGuard.shared.arm()
      self.load()
    }
    return true
  }

  /// Forgets everything shown: the list, any password, what the forms held.
  func lock() {
    guard !locked || addCard != nil || revealed != nil else { return }
    locked = true
    logins = []
    exceptions = []
    open = nil
    revealed = nil
    query = ""
    search.stringValue = ""
    endAdding()
    endEditing()
    last = "locked"
    render()
    settingsDataChanged("passwords")
  }

  private func load(then: (() -> Void)? = nil) {
    guard !locked, let profile else { return }
    EngineCalls.call("ac_passwords_list", profile: profile) { [weak self] reply in
      guard let self, !self.locked else { return }
      let list = reply?["passwords"] as? [[String: Any]] ?? []
      self.logins = list.compactMap { item -> Login? in
        guard let origin = item["origin"] as? String, !origin.isEmpty else { return nil }
        return Login(origin: origin, username: item["username"] as? String ?? "")
      }.sorted {
        let a = Self.host(of: $0.origin).lowercased(), b = Self.host(of: $1.origin).lowercased()
        return a == b ? $0.username.lowercased() < $1.username.lowercased() : a < b
      }
      if let open = self.open, !self.logins.contains(open) { self.closeRow() }
      EngineCalls.call("ac_passwords_exceptions", profile: profile) { [weak self] reply in
        guard let self, !self.locked else { return }
        self.exceptions = (reply?["origins"] as? [String] ?? []).sorted()
        self.render()
        then?()
        settingsDataChanged("passwords")
      }
    }
  }

  // MARK: Rows

  private func toggle(_ login: Login) {
    SettingsDataGuard.shared.touch()
    if open == login { return closeRow() }
    endEditing()
    revealed = nil
    open = login
    render()
    if let card = openCard { settingsScrollIntoView(card) }
    settingsDataChanged("passwords")
  }

  /// The open row's details or editor, as the list shows it.
  private var openCard: NSView? {
    guard open != nil else { return nil }
    let views = stack.items.map(\.view)
    guard let row = views.firstIndex(where: { ($0 as? SettingsRecordRow)?.expanded == true }), row + 1 < views.count else { return nil }
    return views[row + 1]
  }

  /// `cancelAdding`: an Add form open goes too (its Cancel).
  func closeRow(cancelAdding: Bool = false) {
    endEditing()
    if cancelAdding { endAdding() }
    revealed = nil
    open = nil
    render()
    settingsDataChanged("passwords")
  }

  /// For tests: opens the n-th row shown.
  func openRow(_ index: Int) -> Bool {
    let list = shown
    guard !locked, list.indices.contains(index) else { return false }
    if open != list[index] { toggle(list[index]) }
    return true
  }

  func setQuery(_ text: String) {
    search.stringValue = text
    query = text
    render()
    settingsDataChanged("passwords")
  }

  func controlTextDidChange(_ notification: Notification) {
    guard (notification.object as? NSSearchField) === search else { return }
    query = search.stringValue
    render()
  }

  /// Show or hide the open row's password. Showing asks the engine, which asks for Touch ID again once its validity
  /// has run out.
  func pressReveal() -> Bool {
    guard let login = open, !busy, let profile else { return false }
    SettingsDataGuard.shared.touch()
    if revealed != nil {
      revealed = nil
      last = "hidden"
      render()
      settingsDataChanged("passwords")
      return true
    }
    guard settingsReauthAllowed else {
      last = "noReauth"
      settingsDataChanged("passwords")
      return true
    }
    busy = true
    EngineCalls.call("ac_passwords_reveal", profile: profile, args: ["origin": login.origin, "username": login.username]) { [weak self] reply in
      guard let self else { return }
      self.busy = false
      guard !self.locked, self.open == login, let password = reply?["password"] as? String else {
        self.last = reply?["error"] != nil ? "error" : "denied"
        return settingsDataChanged("passwords")
      }
      self.revealed = password
      self.last = "revealed"
      self.render()
      settingsDataChanged("passwords")
    }
    return true
  }

  /// For tests: whether the shown password is the fixture's, never the password itself.
  func revealedMatches(_ expected: String) -> String {
    guard let revealed else { return "hidden" }
    return revealed == expected ? "match" : "no match"
  }

  /// Copy the username, or the password (asked of the engine, concealed, cleared after two minutes).
  func pressCopy(password: Bool) -> Bool {
    guard let login = open, let profile else { return false }
    SettingsDataGuard.shared.touch()
    guard password else {
      SettingsPasteboard.copy(login.username, secret: false)
      last = "copiedUsername"
      settingsDataChanged("passwords")
      return true
    }
    if let revealed {
      SettingsPasteboard.copy(revealed, secret: true)
      last = "copiedPassword"
      settingsDataChanged("passwords")
      return true
    }
    guard settingsReauthAllowed else {
      last = "noReauth"
      settingsDataChanged("passwords")
      return true
    }
    EngineCalls.call("ac_passwords_reveal", profile: profile, args: ["origin": login.origin, "username": login.username]) { [weak self] reply in
      guard let self, !self.locked, let password = reply?["password"] as? String else {
        self?.last = "denied"
        return settingsDataChanged("passwords")
      }
      SettingsPasteboard.copy(password, secret: true)
      self.last = "copiedPassword"
      settingsDataChanged("passwords")
    }
    return true
  }

  // MARK: Adding

  private func startAdding() {
    guard !locked else { return }
    SettingsDataGuard.shared.touch()
    if addCard == nil {
      let form = SettingsForm()
      form.add("website", "Website", placeholder: "example.com")
      form.add("username", "Username", placeholder: "Optional")
      form.add("password", "Password", secure: true)
      let stack = SettingsStack()
      stack.set([
        .init(view: form),
        .init(view: SettingsButtonBar(trailing: [
          SettingsPushButton("Cancel") { [weak self] in self?.cancelAdding() },
          SettingsPushButton("Save") { [weak self] in self?.saveAdding() },
        ])),
      ])
      addForm = form
      addCard = SettingsCard(stack)
    }
    render()
    if let addCard { settingsScrollIntoView(addCard) }
    if let field = addForm?["website"] { window?.makeFirstResponder(field) }
    settingsDataChanged("passwords")
  }

  private func cancelAdding() {
    endAdding()
    render()
    settingsDataChanged("passwords")
  }

  private func endAdding() {
    addForm?.wipe()
    addForm = nil
    addCard = nil
  }

  /// The website as the engine keeps it: scheme, host and port ("example.com/login" is "https://example.com").
  static func origin(typed text: String) -> String? {
    var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, !text.contains(" ") else { return nil }
    if !text.contains("://") { text = "https://" + text }
    guard let components = URLComponents(string: text), let scheme = components.scheme?.lowercased(),
          scheme == "https" || scheme == "http", components.user == nil, components.password == nil,
          let host = components.host?.lowercased(), !host.isEmpty,
          host.contains(".") || host == "localhost" || host.contains(":") else { return nil }
    let shownHost = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
    return "\(scheme)://\(shownHost)" + (components.port.map { ":\($0)" } ?? "")
  }

  private func saveAdding() {
    guard let form = addForm, let profile, !busy else { return }
    SettingsDataGuard.shared.touch()
    guard let origin = Self.origin(typed: form["website"]?.stringValue ?? "") else {
      form.errorText = "Enter the site's address, like example.com."
      return
    }
    let username = form["username"]?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard let field = form["password"], !field.stringValue.isEmpty else {
      form.errorText = "Enter the password."
      return
    }
    if logins.contains(Login(origin: origin, username: username)) {
      form.errorText = "A password for this username on this site is already saved."
      return
    }
    let json = SecretJSON.object([("origin", .text(origin)), ("username", .text(username)), ("password", .text(field.stringValue))])
    busy = true
    EngineCalls.callWithSecret("ac_passwords_add", profile: profile, json: json) { [weak self] reply in
      guard let self else { return }
      self.busy = false
      if reply == nil || reply?["error"] != nil {
        self.last = "error"
        self.addForm?.errorText = "Ray couldn't save this password."
        return settingsDataChanged("passwords")
      }
      self.last = "added"
      self.endAdding()
      self.open = Login(origin: origin, username: username)
      self.revealed = nil
      self.load()
    }
  }

  /// For tests: Add…, the fixture typed into the form, Save.
  func addFixture(_ login: [String: Any]) -> Bool {
    guard !locked else { return false }
    startAdding()
    addForm?["website"]?.stringValue = SettingsFixtures.text(login, "origin")
    addForm?["username"]?.stringValue = SettingsFixtures.text(login, "username")
    addForm?["password"]?.stringValue = SettingsFixtures.text(login, "password")
    saveAdding()
    return true
  }

  // MARK: Editing

  private func startEditing() {
    guard let login = open else { return }
    SettingsDataGuard.shared.touch()
    revealed = nil
    let form = SettingsForm()
    form.add("username", "Username", value: login.username, placeholder: "None")
    form.add("password", "Password", placeholder: "Unchanged", secure: true)
    let stack = SettingsStack()
    stack.set([
      .init(view: form),
      .init(view: SettingsButtonBar(trailing: [
        SettingsPushButton("Cancel") { [weak self] in
          self?.endEditing()
          self?.render()
        },
        SettingsPushButton("Save") { [weak self] in self?.saveEditing() },
      ])),
    ])
    editForm = form
    editCard = SettingsCard(stack)
    render()
    if let editCard { settingsScrollIntoView(editCard) }
    if let field = form["password"] { window?.makeFirstResponder(field) }
    settingsDataChanged("passwords")
  }

  private func endEditing() {
    editForm?.wipe()
    editForm = nil
    editCard = nil
  }

  /// The engine asks for Touch ID again (once its validity has run out), then changes the username and, when one was
  /// typed, the password.
  private func saveEditing() {
    guard let login = open, let form = editForm, let profile, !busy else { return }
    SettingsDataGuard.shared.touch()
    let username = form["username"]?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? login.username
    var fields: [(String, SecretJSON.Value)] = [("origin", .text(login.origin)), ("username", .text(login.username))]
    if username != login.username {
      if logins.contains(Login(origin: login.origin, username: username)) {
        form.errorText = "This site already has a password saved for that username."
        return
      }
      fields.append(("newUsername", .text(username)))
    }
    if let password = form["password"]?.stringValue, !password.isEmpty { fields.append(("newPassword", .text(password))) }
    guard settingsReauthAllowed else {
      last = "noReauth"
      return settingsDataChanged("passwords")
    }
    busy = true
    EngineCalls.callWithSecret("ac_passwords_update", profile: profile, json: SecretJSON.object(fields)) { [weak self] reply in
      guard let self else { return }
      self.busy = false
      if reply == nil || reply?["error"] != nil {
        self.last = (reply?["error"] as? String) == "Not authenticated" ? "denied" : "error"
        self.editForm?.errorText = self.last == "denied" ? "Not changed: Ray couldn't confirm it's you." : "Ray couldn't change this password."
        return settingsDataChanged("passwords")
      }
      self.last = "edited"
      self.endEditing()
      self.open = Login(origin: login.origin, username: username)
      self.load()
    }
  }

  /// For tests: Edit, the fixture's username and password typed, Save.
  func editFixture(_ login: [String: Any]) -> Bool {
    guard open != nil else { return false }
    startEditing()
    editForm?["username"]?.stringValue = SettingsFixtures.text(login, "username")
    editForm?["password"]?.stringValue = SettingsFixtures.text(login, "password")
    saveEditing()
    return true
  }

  // MARK: Deleting

  func pressDelete() -> Bool {
    guard let login = open else { return false }
    SettingsDataGuard.shared.touch()
    SettingsRecordConfirm.ask(
      "removePassword", title: "Delete the password for \(Self.host(of: login.origin))?",
      message: "Ray won't be able to fill it in any more. This can't be undone.", confirm: "Delete", from: self
    ) { [weak self] yes in
      guard yes, let self, let profile = self.profile else { return }
      EngineCalls.call("ac_passwords_remove", profile: profile, args: ["origin": login.origin, "username": login.username]) { [weak self] reply in
        guard let self else { return }
        self.last = reply == nil || reply?["error"] != nil ? "error" : "removed"
        if self.open == login { self.closeRow() }
        self.load()
      }
    }
    settingsDataChanged("passwords")
    return true
  }

  /// A site out of "Never saved": Ray may offer to save its passwords again.
  private func allow(_ origin: String) {
    guard let profile else { return }
    SettingsDataGuard.shared.touch()
    EngineCalls.call("ac_passwords_allow", profile: profile, args: ["origin": origin]) { [weak self] _ in self?.load() }
  }

  /// Reloads the list if it shows (passwords imported from a file).
  func reloadIfUnlocked() {
    if !locked { load() }
  }

  // MARK: Tests

  var debug: [String: Any] {
    let list = shown
    return [
      "locked": locked, "count": logins.count, "shown": list.count, "exceptions": exceptions.count,
      "open": open.flatMap { list.firstIndex(of: $0) } ?? -1, "revealed": revealed != nil,
      "editing": editCard != nil, "adding": addCard != nil, "formError": !(addForm?.errorText ?? editForm?.errorText ?? "").isEmpty,
      "busy": busy, "last": last, "guardArmed": SettingsDataGuard.shared.armed, "confirming": SettingsRecordConfirm.pending ?? NSNull(),
      "clipboardPending": SettingsPasteboard.clearPending, "idleSeconds": SettingsDataGuard.idle,
      "clearSeconds": SettingsPasteboard.clearDelay,
    ]
  }
}

/// "Passwords are locked" with Unlock, where the list goes.
private final class PasswordsLockedView: NSView, SettingsSizing {
  private let icon = NSImageView()
  private let title = settingsLabel("Passwords are locked", size: 15, weight: .medium)
  private let detail = NSTextField(wrappingLabelWithString: "Touch ID or your login password.")
  private let button = AccentButton(title: "Unlock")

  init(unlock: @escaping () -> Void) {
    super.init(frame: .zero)
    icon.image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: nil)
    icon.symbolConfiguration = .init(pointSize: 24, weight: .medium)
    icon.contentTintColor = .tertiaryLabelColor
    detail.font = .systemFont(ofSize: 12)
    detail.textColor = .secondaryLabelColor
    detail.alignment = .center
    detail.isSelectable = false
    title.alignment = .center
    button.onClick = unlock
    [icon, title, detail, button].forEach { addSubview($0) }
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }

  func height(forWidth width: CGFloat) -> CGFloat { 176 }

  override func layout() {
    super.layout()
    icon.frame = NSRect(x: ((bounds.width - 36) / 2).rounded(), y: 24, width: 36, height: 36)
    let titleHeight = ceil(title.intrinsicContentSize.height)
    title.frame = NSRect(x: 0, y: 70, width: bounds.width, height: titleHeight)
    let detailWidth = min(bounds.width, 380)
    let detailHeight = textHeight(detail, width: detailWidth)
    detail.frame = NSRect(x: ((bounds.width - detailWidth) / 2).rounded(), y: title.frame.maxY + 4, width: detailWidth, height: detailHeight)
    // AccentButton sizes its title to the point; a little more keeps "Unlock" whole.
    let size = NSSize(width: button.intrinsicContentSize.width + 8, height: button.intrinsicContentSize.height)
    button.frame = NSRect(x: ((bounds.width - size.width) / 2).rounded(), y: detail.frame.maxY + 12, width: size.width, height: size.height)
  }
}

// MARK: Other apps and files

/// Password manager apps (a note), then under "More": import from a CSV file and export to one.
final class PasswordsMoreView: NSView, SettingsSizing {
  private let stack = SettingsStack()
  private let more = SettingsMoreToggle()
  private var importStatus: String?
  private var exportStatus: String?
  /// For tests: what the last export and import came to (`succeeded`, `reauthFailed`…; counts).
  private var exportResult = ""
  private var importResult: [String: Int] = [:]
  private var importing = false

  override var isFlipped: Bool { true }

  override init(frame: NSRect) {
    super.init(frame: frame)
    addSubview(stack)
    more.onToggle = { [weak self] _ in self?.render() }
    render()
  }

  required init?(coder: NSCoder) { fatalError() }

  func height(forWidth width: CGFloat) -> CGFloat { stack.height(forWidth: width) }

  override func layout() {
    super.layout()
    stack.frame = bounds
  }

  /// 1Password's helper checks the browser's code signature and only trusts one added in its Settings › Browser,
  /// from Applications (its sandbox reads apps only there): Ardia's finding, docs/dia-feature-parity.md.
  static var managerNote: String {
    let apps = "Extensions from 1Password, Bitwarden, KeePassXC and Proton Pass connect to their Mac apps."
    let folder = Bundle.main.bundleURL.deletingLastPathComponent().path
    let inApplications = folder == "/Applications" || folder == (NSHomeDirectory() as NSString).appendingPathComponent("Applications")
    return inApplications
      ? "\(apps) For 1Password, add Ray once: in the 1Password app, open Settings › Browser › Add Browser and choose Ray."
      : "\(apps) For 1Password, move Ray to your Applications folder and open it again (1Password only connects to browsers there), then in the 1Password app open Settings › Browser › Add Browser and choose Ray."
  }

  private func render() {
    var items: [SettingsStack.Item] = [.init(view: SettingsRowView(title: "Password manager apps", detail: Self.managerNote))]
    if more.expanded {
      let importRow = SettingsRowView(
        title: "Import passwords",
        detail: importStatus ?? "From a CSV file.",
        control: SettingsPushButton("Import…") { [weak self] in self?.chooseImport() })
      let exportRow = SettingsRowView(
        title: "Export passwords",
        detail: exportStatus ?? "To a CSV file, readable by anyone.",
        control: SettingsPushButton("Export…") { [weak self] in _ = self?.pressExport(testPath: nil) })
      items += [.init(view: importRow, line: true), .init(view: exportRow, line: true)]
    }
    items.append(.init(view: more, line: true))
    stack.set(items)
    settingsContentDidResize(self)
  }

  func toggleMore() { more.toggle() }

  // MARK: Export

  /// Export…: a warning first, then where to save it, then the engine asks for Touch ID (every time) and writes it.
  /// `testPath` (tests) stands for the save panel's answer.
  func pressExport(testPath: String?) -> Bool {
    guard window != nil else { return false }
    if !more.expanded { more.toggle() }
    SettingsRecordConfirm.ask(
      "exportPasswords", title: "Export your passwords?",
      message: "The file holds every saved password as plain text. Anyone who can open it can read them, so delete it once you're done with it.",
      confirm: "Export…", destructive: false, from: self
    ) { [weak self] yes in
      guard yes, let self else { return }
      if let testPath { return self.export(to: testPath) }
      self.chooseExportPath()
    }
    settingsDataChanged("passwords")
    return true
  }

  private func chooseExportPath() {
    guard let window else { return }
    let panel = NSSavePanel()
    panel.nameFieldStringValue = "Ray Passwords.csv"
    panel.allowedContentTypes = [.commaSeparatedText]
    panel.canCreateDirectories = true
    panel.beginSheetModal(for: window) { [weak self] response in
      guard response == .OK, let url = panel.url else { return }
      self?.export(to: url.path)
    }
  }

  private func export(to path: String) {
    guard let profile = settingsDataProfile else { return }
    guard settingsReauthAllowed else {
      exportResult = "noReauth"
      return settingsDataChanged("passwords")
    }
    exportStatus = "Exporting…"
    exportResult = "exporting"
    render()
    EngineCalls.call("ac_passwords_export", profile: profile, args: ["path": path]) { [weak self] reply in
      guard let self else { return }
      let status = reply?["status"] as? String ?? (reply?["error"] != nil ? "error" : "unknown")
      self.exportResult = status
      let folder = (path as NSString).deletingLastPathComponent
      switch status {
      case "succeeded": self.exportStatus = "Saved to “\(FileManager.default.displayName(atPath: folder))”. Delete the file once you're done with it."
      case "reauthFailed": self.exportStatus = "Not exported: Ray couldn't confirm it's you."
      case "writeFailed": self.exportStatus = "Couldn't write the file. Try another folder."
      case "inProgress": self.exportStatus = "An export is already running."
      case "cancelled": self.exportStatus = nil
      default: self.exportStatus = "Couldn't export your passwords."
      }
      self.render()
      settingsDataChanged("passwords")
    }
  }

  // MARK: Import

  private func chooseImport() {
    guard let window else { return }
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.commaSeparatedText]
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.beginSheetModal(for: window) { [weak self] response in
      guard response == .OK, let url = panel.url else { return }
      self?.importCSV(url)
    }
  }

  /// Chrome's limit for one file (`kMaxPasswordsPerCSVFile`).
  static let importLimit = 3000

  /// Reads the file off the main thread (the importer's `PasswordsCSV`: Chrome's, Safari's, Firefox's, 1Password's and
  /// Bitwarden's columns), then saves each login through `ac_passwords_add`, one at a time, as File › Import does.
  /// A login already saved counts as there.
  func importCSV(_ url: URL) {
    guard !importing else { return }
    importing = true
    importStatus = "Importing…"
    importResult = [:]
    if !more.expanded { more.toggle() }
    render()
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let read = Result { try PasswordsCSV.load(url) }
      DispatchQueue.main.async {
        guard let self else { return }
        switch read {
        case .failure:
          self.finishImport(status: "Couldn't read that file. It needs url, username and password columns.", saved: 0, existing: 0, skipped: 0)
        case .success(let credentials) where credentials.count > Self.importLimit:
          self.finishImport(status: "That file has more than \(Self.importLimit.formatted()) passwords, more than Ray imports at once.",
                            saved: 0, existing: 0, skipped: credentials.count)
        case .success(let credentials):
          self.save(credentials, from: 0, saved: 0, existing: 0, skipped: 0)
        }
      }
    }
  }

  private func save(_ credentials: [Credential], from index: Int, saved: Int, existing: Int, skipped: Int) {
    guard index < credentials.count else {
      let words = [saved > 0 || existing == 0 ? "Imported \(ImportShape.plural(saved, "password"))." : nil,
                   existing > 0 ? "\(ImportShape.plural(existing, "was", "were")) already saved." : nil,
                   skipped > 0 ? "\(ImportShape.plural(skipped, "row")) had no website Ray can save for." : nil].compactMap { $0 }
      return finishImport(status: words.joined(separator: " "), saved: saved, existing: existing, skipped: skipped)
    }
    let credential = credentials[index]
    guard let origin = ImportShape.origin(of: credential), !credential.password.isEmpty, let profile = settingsDataProfile else {
      return save(credentials, from: index + 1, saved: saved, existing: existing, skipped: skipped + 1)
    }
    let json = SecretJSON.object([("origin", .text(origin)), ("username", .text(credential.username)),
                                  ("password", .text(credential.password))])
    EngineCalls.callWithSecret("ac_passwords_add", profile: profile, json: json) { [weak self] reply in
      let error = reply == nil ? "no reply" : reply?["error"] as? String
      let there = error?.contains("already saved") == true
      self?.save(credentials, from: index + 1, saved: saved + (error == nil ? 1 : 0), existing: existing + (there ? 1 : 0),
                 skipped: skipped + (error != nil && !there ? 1 : 0))
    }
  }

  private func finishImport(status: String, saved: Int, existing: Int, skipped: Int) {
    importing = false
    importStatus = status
    importResult = ["saved": saved, "existing": existing, "skipped": skipped]
    render()
    PasswordsPaneContent.shared.saved.reloadIfUnlocked()
    settingsDataChanged("passwords")
  }

  var debug: [String: Any] {
    ["moreOpen": more.expanded, "export": exportResult, "importing": importing, "imported": importResult]
  }
}
