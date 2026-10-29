import AppKit

// Settings › Autofill: the engine's addresses and cards (`ac_autofill_addresses`, `ac_autofill_cards`,
// `ac_autofill_save_address`, `ac_autofill_save_card`, `ac_autofill_remove`; engine/chromium/src/chrome/browser/ray/
// ac_autofill.cc, ac_autofill_edit.cc).
//
// Addresses: a list; a row opens its editor (Save, Delete…); Add…. Cards: a list with the network and last four
// digits; a row opens its details, where Show asks the engine for the full number (`ac_autofill_card_number`, which asks
// for Touch ID or the login password every time, as Chrome's mandatory re-auth does); Edit (name, expiry, a new number),
// Delete…, Add…. A card number goes to the engine through `EngineCalls.callWithSecret` (`SecretJSON`); a shown one lives
// only in its label until the card closes, the window closes, five minutes pass or the Mac sleeps (`SettingsDataGuard`).
// The state log carries counts and ids, never a name, an address or a number.

extension SettingGroup {
  static let autofillSaving = SettingGroup(id: "autofillSaving", title: "Saving and filling")
}

extension AnySettingKey {
  /// Chrome's "Save and fill addresses". Not built: Ray has no autofill prompt or dropdown yet (MISSING Chrome #3).
  static let autofillAddresses = SettingKey<Bool>(
    "autofillAddresses", default: true, built: false,
    ui: SettingUI(
      pane: .autofill, group: .autofillSaving, title: "Save and fill addresses",
      detail: "", about: "Ray offers to save the addresses you type into forms, and fills them in next time.",
      keywords: ["addresses", "autofill", "forms", "shipping", "phone", "email"], control: .toggle))

  /// Chrome's "Save and fill payment methods". Not built, as above.
  static let autofillCards = SettingKey<Bool>(
    "autofillCards", default: true, built: false,
    ui: SettingUI(
      pane: .autofill, group: .autofillSaving, title: "Save and fill cards",
      detail: "", about: "Ray offers to save the cards you pay with, and fills them in next time. It asks for Touch ID first.",
      keywords: ["credit card", "debit card", "payment methods", "autofill", "checkout"], control: .toggle))
}

/// The Autofill pane's own content: addresses, then cards.
final class AutofillPaneContent: SettingsPaneContent {
  static let shared = AutofillPaneContent()

  let addresses = AutofillAddressesView()
  let cards = AutofillCardsView()

  var hasContent: Bool { true }

  func sections() -> [SettingsSection] {
    [
      SettingsSection(
        id: "autofill.addresses", place: .bottom, view: addresses,
        search: [SettingsSearchEntry(title: "Addresses", detail: "The addresses Ray fills into forms",
                                     keywords: ["address", "shipping", "billing", "home", "phone", "email", "name"])]),
      SettingsSection(
        id: "autofill.cards", place: .bottom, view: cards,
        search: [SettingsSearchEntry(title: "Cards", detail: "The cards Ray fills in when you pay",
                                     keywords: ["credit card", "debit card", "payment", "card number", "expiry"])]),
    ]
  }

  /// For the state log: counts and ids, never what they hold.
  var debug: [String: Any] {
    [
      "addresses": addresses.ids.count, "addressIds": addresses.ids, "cards": cards.ids.count, "cardIds": cards.ids,
      "openAddress": addresses.openID ?? NSNull(), "openCard": cards.openID ?? NSNull(),
      "addingAddress": addresses.adding, "addingCard": cards.adding, "editingCard": cards.editing,
      "revealed": cards.revealed, "lastAddress": addresses.last, "lastCard": cards.last,
      "formError": addresses.formError || cards.formError, "confirming": SettingsRecordConfirm.pending ?? NSNull(),
    ]
  }

  // MARK: Tests

  /// `autofill load|addaddress <i>|addcard <i>|open address|card <n>|close|edit <i>|reveal|revealcheck <i>|copy|
  /// remove|confirm yes|no`: as clicks and typing would; `<i>` is a fixture (`RAY_TEST_SECRETS`), so no card number
  /// is in the line. `edit` and `remove` act on the open address or card.
  func test(_ line: String, _ argument: String) -> String? {
    let words = argument.split(separator: " ").map(String.init)
    let first = words.first ?? ""
    let second = words.count > 1 ? words[1] : ""
    switch first {
    case "load":
      addresses.load()
      cards.load()
    case "addaddress":
      guard let item = SettingsFixtures.item("addresses", second) else { return "no fixture" }
      addresses.addFixture(item)
    case "addcard":
      guard let item = SettingsFixtures.item("cards", second) else { return "no fixture" }
      cards.addFixture(item)
    case "open":
      guard words.count == 3, let index = Int(words[2]) else { return "usage: autofill open address|card <n>" }
      let opened = second == "address" ? addresses.openRow(index) : second == "card" ? cards.openRow(index) : false
      return opened ? "ok" : "no such row"
    case "close":
      addresses.closeRow()
      cards.closeRow()
    case "edit":
      if addresses.openID != nil {
        guard let item = SettingsFixtures.item("addresses", second) else { return "no fixture" }
        return addresses.editFixture(item) ? "ok" : "no address open"
      }
      guard let item = SettingsFixtures.item("cards", second) else { return "no fixture" }
      return cards.editFixture(item) ? "ok" : "no card open"
    case "reveal": return cards.pressReveal() ? "ok" : "no card open"
    case "revealcheck":
      guard let item = SettingsFixtures.item("cards", second) else { return "no fixture" }
      return cards.revealedMatches(AutofillCardsView.digits(SettingsFixtures.text(item, "number")))
    case "copy": return cards.pressCopy() ? "ok" : "nothing shown"
    case "pasteboard":
      guard let item = SettingsFixtures.item("cards", second) else { return "no fixture" }
      let text = SettingsPasteboard.board.string(forType: .string)
      return "{\"number\":\(text == AutofillCardsView.digits(SettingsFixtures.text(item, "number"))),\"empty\":\(text == nil),"
        + "\"concealed\":\(SettingsPasteboard.isConcealed),\"clearPending\":\(SettingsPasteboard.clearPending)}"
    case "remove":
      let pressed = addresses.openID != nil ? addresses.pressDelete() : cards.pressDelete()
      return pressed ? "ok" : "nothing open"
    case "confirm":
      guard second == "yes" || second == "no", SettingsRecordConfirm.answer(second == "yes") else { return "no sheet" }
    default:
      return "usage: autofill load|addaddress|addcard|open|close|edit|reveal|revealcheck|copy|pasteboard|remove|confirm"
    }
    return "ok"
  }
}

// MARK: Addresses

/// The saved addresses: a header with Add…, a row each (the name, then the street and town), the open one's editor.
final class AutofillAddressesView: NSView, SettingsSizing {
  /// The engine's address fields (`kAddressFields`, ac_autofill_internal.h) in the editor's order, with their labels.
  static let fields: [(key: String, label: String)] = [
    ("name", "Name"), ("organization", "Organization"), ("street", "Street"), ("city", "City"), ("state", "State or region"),
    ("postalCode", "Postal code"), ("country", "Country"), ("phone", "Phone"), ("email", "Email"),
  ]

  private let stack = SettingsStack()
  private let header = SettingsDataHeader(title: "Addresses")
  private lazy var addButton = SettingsPushButton("Add…") { [weak self] in self?.startEditing(nil) }
  private var list: [[String: String]] = []
  private(set) var openID: String?
  private var form: SettingsForm?
  private var formCard: SettingsCard?
  /// The editor is for a new address.
  private(set) var adding = false
  private var busy = false
  private(set) var last = ""

  var ids: [String] { list.compactMap { $0["id"] } }
  var formError: Bool { !(form?.errorText ?? "").isEmpty }

  override var isFlipped: Bool { true }

  override init(frame: NSRect) {
    super.init(frame: frame)
    addSubview(stack)
    header.setTrailing([addButton])
    SettingsDataGuard.shared.register { [weak self] in self?.forget() }
    render()
  }

  required init?(coder: NSCoder) { fatalError() }

  func height(forWidth width: CGFloat) -> CGFloat { stack.height(forWidth: width) }

  override func layout() {
    super.layout()
    stack.frame = bounds
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window != nil { load() }
  }

  func load() {
    guard let profile = settingsDataProfile else { return }
    EngineCalls.call("ac_autofill_addresses", profile: profile) { [weak self] reply in
      guard let self else { return }
      self.list = (reply?["addresses"] as? [[String: Any]] ?? []).map { entry in
        entry.compactMapValues { $0 as? String }
      }
      if let openID = self.openID, !self.ids.contains(openID) { self.endEditing() }
      self.render()
      settingsDataChanged("autofill")
    }
  }

  /// The window closed or the pane locked: an editor open goes, with what it held.
  private func forget() {
    guard formCard != nil else { return }
    endEditing()
    render()
  }

  private func render() {
    header.count = list.isEmpty ? "" : list.count.formatted()
    var items: [SettingsStack.Item] = [.init(view: header)]
    if adding, let formCard { items.append(.init(view: formCard, gap: 4)) }
    if list.isEmpty, !adding {
      items.append(.init(view: SettingsNote("No saved addresses.")))
    }
    for (index, address) in list.enumerated() {
      let id = address["id"] ?? ""
      let title = [address["name"], address["organization"]].compactMap { $0 }.first { !$0.isEmpty } ?? "Address"
      let row = SettingsRecordRow(symbol: "house.fill", title: title, detail: Self.summary(of: address))
      row.expanded = id == openID
      row.onClick = { [weak self] in self?.toggle(id) }
      items.append(.init(view: row, line: index > 0))
      if id == openID, let formCard { items.append(.init(view: formCard)) }
    }
    stack.set(items)
    settingsContentDidResize(self)
  }

  /// "1 Main St, Springfield, 12345, United States" on one line.
  static func summary(of address: [String: String]) -> String {
    let street = address["street"]?.components(separatedBy: .newlines).first
    let country = address["country"].map { Locale.current.localizedString(forRegionCode: $0) ?? $0 }
    return [street, address["city"], address["postalCode"], country].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
  }

  /// A country typed as a name ("France", "united kingdom") or a two-letter code, as the code the engine keeps.
  static func countryCode(_ text: String) -> String? {
    let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !typed.isEmpty else { return "" }
    let codes = Locale.Region.isoRegions.map(\.identifier).filter { $0.count == 2 && $0.allSatisfy(\.isLetter) }
    if typed.count == 2, codes.contains(typed.uppercased()) { return typed.uppercased() }
    let folded = typed.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    for locale in [Locale.current, Locale(identifier: "en_US")] {
      if let code = codes.first(where: {
        locale.localizedString(forRegionCode: $0)?.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) == folded
      }) { return code }
    }
    return nil
  }

  private func toggle(_ id: String) {
    SettingsDataGuard.shared.touch()
    if openID == id {
      endEditing()
    } else {
      startEditing(id)
      return
    }
    render()
    settingsDataChanged("autofill")
  }

  func closeRow() {
    guard formCard != nil else { return }
    endEditing()
    render()
  }

  /// For tests: opens the n-th address.
  func openRow(_ index: Int) -> Bool {
    guard list.indices.contains(index), let id = list[index]["id"] else { return false }
    if openID != id { startEditing(id) }
    return true
  }

  /// The editor for an address (nil: a new one), in place of its row's details or at the top for a new one.
  private func startEditing(_ id: String?) {
    endEditing()
    let address = id.flatMap { id in list.first { $0["id"] == id } } ?? [:]
    let form = SettingsForm()
    for (key, label) in Self.fields {
      var value = address[key] ?? ""
      if key == "country", !value.isEmpty { value = Locale.current.localizedString(forRegionCode: value) ?? value }
      form.add(key, label, value: value)
    }
    let stack = SettingsStack()
    let bar = SettingsButtonBar(
      leading: id == nil ? [] : [SettingsPushButton("Delete…", destructive: true) { [weak self] in _ = self?.pressDelete() }],
      trailing: [
        SettingsPushButton("Cancel") { [weak self] in
          self?.endEditing()
          self?.render()
          settingsDataChanged("autofill")
        },
        SettingsPushButton("Save") { [weak self] in self?.save() },
      ])
    stack.set([.init(view: form), .init(view: bar)])
    self.form = form
    formCard = SettingsCard(stack)
    openID = id
    adding = id == nil
    render()
    if let formCard { settingsScrollIntoView(formCard) }
    if let field = form["name"] { window?.makeFirstResponder(field) }
    settingsDataChanged("autofill")
  }

  private func endEditing() {
    form?.wipe()
    form = nil
    formCard = nil
    openID = nil
    adding = false
  }

  private func save() {
    guard let form, let profile = settingsDataProfile, !busy else { return }
    SettingsDataGuard.shared.touch()
    var address: [String: String] = [:]
    for (key, _) in Self.fields { address[key] = form[key]?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
    guard let country = Self.countryCode(address["country"] ?? "") else {
      form.errorText = "Ray doesn't know that country. Type its name or its two-letter code."
      return
    }
    address["country"] = country
    guard Self.fields.contains(where: { $0.key != "country" && !(address[$0.key] ?? "").isEmpty }) else {
      form.errorText = "Fill in at least a name or a street."
      return
    }
    if let openID { address["id"] = openID }
    busy = true
    EngineCalls.call("ac_autofill_save_address", profile: profile, args: ["address": address]) { [weak self] reply in
      guard let self else { return }
      self.busy = false
      guard let reply, reply["error"] == nil else {
        self.last = "error"
        self.form?.errorText = "Ray couldn't save this address."
        return settingsDataChanged("autofill")
      }
      self.last = self.adding ? "added" : "saved"
      self.endEditing()
      self.load()
    }
  }

  /// For tests: Add…, the fixture typed in, Save.
  func addFixture(_ item: [String: Any]) {
    startEditing(nil)
    fill(item)
    save()
  }

  /// For tests: the open address's fields from the fixture, Save.
  func editFixture(_ item: [String: Any]) -> Bool {
    guard openID != nil else { return false }
    fill(item)
    save()
    return true
  }

  private func fill(_ item: [String: Any]) {
    for (key, _) in Self.fields where item[key] != nil { form?[key]?.stringValue = SettingsFixtures.text(item, key) }
  }

  func pressDelete() -> Bool {
    guard let id = openID else { return false }
    SettingsRecordConfirm.ask(
      "removeAddress", title: "Delete this address?", message: "Ray won't fill it into forms any more. This can't be undone.",
      confirm: "Delete", from: self
    ) { [weak self] yes in
      guard yes, let profile = settingsDataProfile else { return }
      EngineCalls.call("ac_autofill_remove", profile: profile, args: ["id": id]) { [weak self] reply in
        guard let self else { return }
        self.last = reply == nil || reply?["error"] != nil ? "error" : "removed"
        if self.openID == id { self.endEditing() }
        self.load()
      }
    }
    settingsDataChanged("autofill")
    return true
  }
}

// MARK: Cards

/// The saved cards: a header with Add…, a row each ("Visa •••• 4242", the name and expiry), the open one's details
/// (Show asks for Touch ID) or editor.
final class AutofillCardsView: NSView, SettingsSizing {
  struct Card {
    let id: String
    let name: String
    let network: String
    let last4: String
    let month: Int
    let year: Int
  }

  private let stack = SettingsStack()
  private let header = SettingsDataHeader(title: "Cards")
  private lazy var addButton = SettingsPushButton("Add…") { [weak self] in self?.startEditing(nil) }
  private var list: [Card] = []
  private(set) var openID: String?
  /// The open card's full number while it shows; nil when it hides, the card closes or the pane locks.
  private var number: String?
  private var form: SettingsForm?
  private var formCard: SettingsCard?
  private(set) var adding = false
  private var busy = false
  private(set) var last = ""

  var ids: [String] { list.map(\.id) }
  var revealed: Bool { number != nil }
  var editing: Bool { formCard != nil && !adding }
  var formError: Bool { !(form?.errorText ?? "").isEmpty }

  override var isFlipped: Bool { true }

  override init(frame: NSRect) {
    super.init(frame: frame)
    addSubview(stack)
    header.setTrailing([addButton])
    SettingsDataGuard.shared.register { [weak self] in self?.forget() }
    render()
  }

  required init?(coder: NSCoder) { fatalError() }

  func height(forWidth width: CGFloat) -> CGFloat { stack.height(forWidth: width) }

  override func layout() {
    super.layout()
    stack.frame = bounds
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window != nil { load() }
  }

  func load() {
    guard let profile = settingsDataProfile else { return }
    EngineCalls.call("ac_autofill_cards", profile: profile) { [weak self] reply in
      guard let self else { return }
      self.list = (reply?["cards"] as? [[String: Any]] ?? []).compactMap { entry in
        guard let id = entry["id"] as? String else { return nil }
        return Card(id: id, name: entry["name"] as? String ?? "", network: entry["network"] as? String ?? "card",
                    last4: entry["last4"] as? String ?? "", month: (entry["expMonth"] as? NSNumber)?.intValue ?? 0,
                    year: (entry["expYear"] as? NSNumber)?.intValue ?? 0)
      }
      if let openID = self.openID, !self.ids.contains(openID) { self.closeRow() }
      self.render()
      settingsDataChanged("autofill")
    }
  }

  /// The window closed, five minutes passed or the Mac slept: the number goes, and any editor with what it held.
  private func forget() {
    guard number != nil || formCard != nil else { return }
    number = nil
    endEditing()
    render()
    settingsDataChanged("autofill")
  }

  static func networkName(_ network: String) -> String {
    switch network {
    case "visa": return "Visa"
    case "mastercard": return "Mastercard"
    case "amex": return "American Express"
    case "discover": return "Discover"
    case "diners": return "Diners Club"
    case "jcb": return "JCB"
    case "unionpay": return "UnionPay"
    default: return "Card"
    }
  }

  static func expiry(_ card: Card) -> String {
    guard card.month > 0, card.year > 0 else { return "" }
    return String(format: "%02d/%02d", card.month, card.year % 100)
  }

  static func digits(_ text: String) -> String { text.filter(\.isASCII).filter(\.isNumber) }

  /// Whether a number passes the Luhn check Chrome's card editor makes.
  static func luhn(_ digits: String) -> Bool {
    var sum = 0
    for (index, character) in digits.reversed().enumerated() {
      guard var value = character.wholeNumberValue else { return false }
      if index % 2 == 1 {
        value *= 2
        if value > 9 { value -= 9 }
      }
      sum += value
    }
    return sum % 10 == 0
  }

  /// "4242 4242 4242 4242": groups of four.
  static func grouped(_ digits: String) -> String {
    var out = ""
    for (index, character) in digits.enumerated() {
      if index > 0, index % 4 == 0 { out.append(" ") }
      out.append(character)
    }
    return out
  }

  private func render() {
    header.count = list.isEmpty ? "" : list.count.formatted()
    var items: [SettingsStack.Item] = [.init(view: header)]
    if adding, let formCard { items.append(.init(view: formCard, gap: 4)) }
    if list.isEmpty, !adding {
      items.append(.init(view: SettingsNote("No saved cards.")))
    }
    for (index, card) in list.enumerated() {
      let expiry = Self.expiry(card)
      let detail = [card.name, expiry.isEmpty ? "" : "Expires \(expiry)"].filter { !$0.isEmpty }.joined(separator: " · ")
      let row = SettingsRecordRow(symbol: "creditcard.fill", title: "\(Self.networkName(card.network)) •••• \(card.last4)", detail: detail)
      row.expanded = card.id == openID
      row.onClick = { [weak self] in self?.toggle(card.id) }
      items.append(.init(view: row, line: index > 0))
      if card.id == openID { items.append(.init(view: adding ? detailCard(card) : formCard ?? detailCard(card))) }
    }
    stack.set(items)
    settingsContentDidResize(self)
  }

  private func detailCard(_ card: Card) -> SettingsCard {
    let eye = SettingsIconButton(symbol: number == nil ? "eye" : "eye.slash", label: number == nil ? "Show Number" : "Hide Number") { [weak self] in
      _ = self?.pressReveal()
    }
    let copy = SettingsIconButton(symbol: "doc.on.doc", label: "Copy Number") { [weak self] in _ = self?.pressCopy() }
    let shown = number.map(Self.grouped) ?? "•••• •••• •••• \(card.last4)"
    let lines = SettingsStack()
    var items: [SettingsStack.Item] = [
      .init(view: SettingsDetailLine(name: "Number", value: shown, monospaced: true, buttons: number == nil ? [eye] : [eye, copy])),
    ]
    if !card.name.isEmpty { items.append(.init(view: SettingsDetailLine(name: "Name on card", value: card.name))) }
    let expiry = Self.expiry(card)
    if !expiry.isEmpty { items.append(.init(view: SettingsDetailLine(name: "Expires", value: expiry))) }
    items.append(.init(view: SettingsButtonBar(
      leading: [SettingsPushButton("Delete…", destructive: true) { [weak self] in _ = self?.pressDelete() }],
      trailing: [SettingsPushButton("Edit") { [weak self] in self?.startEditing(card.id) }])))
    lines.set(items)
    return SettingsCard(lines)
  }

  private func toggle(_ id: String) {
    SettingsDataGuard.shared.touch()
    if openID == id { return closeRow() }
    endEditing()
    number = nil
    openID = id
    render()
    let views = stack.items.map(\.view)
    if let row = views.firstIndex(where: { ($0 as? SettingsRecordRow)?.expanded == true }), row + 1 < views.count {
      settingsScrollIntoView(views[row + 1])
    }
    settingsDataChanged("autofill")
  }

  func closeRow() {
    endEditing()
    number = nil
    openID = nil
    render()
    settingsDataChanged("autofill")
  }

  /// For tests: opens the n-th card.
  func openRow(_ index: Int) -> Bool {
    guard list.indices.contains(index) else { return false }
    if openID != list[index].id { toggle(list[index].id) }
    return true
  }

  /// Show or hide the open card's full number. Showing asks the engine, which asks for Touch ID every time.
  func pressReveal() -> Bool {
    guard let id = openID, !adding, !busy, let profile = settingsDataProfile else { return false }
    SettingsDataGuard.shared.touch()
    if number != nil {
      number = nil
      last = "hidden"
      render()
      settingsDataChanged("autofill")
      return true
    }
    guard settingsReauthAllowed else {
      last = "noReauth"
      settingsDataChanged("autofill")
      return true
    }
    busy = true
    EngineCalls.call("ac_autofill_card_number", profile: profile, args: ["id": id]) { [weak self] reply in
      guard let self else { return }
      self.busy = false
      guard self.openID == id, let number = reply?["number"] as? String, !number.isEmpty else {
        self.last = reply?["authenticated"] as? Bool == false ? "denied" : "error"
        return settingsDataChanged("autofill")
      }
      self.number = number
      self.last = "revealed"
      SettingsDataGuard.shared.arm()
      self.render()
      settingsDataChanged("autofill")
    }
    return true
  }

  /// For tests: whether the shown number is the fixture's, never the number itself.
  func revealedMatches(_ expected: String) -> String {
    guard let number else { return "hidden" }
    return number == expected ? "match" : "no match"
  }

  /// Copies the shown number, concealed and cleared after two minutes.
  func pressCopy() -> Bool {
    guard let number else { return false }
    SettingsDataGuard.shared.touch()
    SettingsPasteboard.copy(number, secret: true)
    last = "copied"
    settingsDataChanged("autofill")
    return true
  }

  /// The editor: name, number (for a card already saved, only to change it) and expiry.
  private func startEditing(_ id: String?) {
    let card = id.flatMap { id in list.first { $0.id == id } }
    form?.wipe()
    number = nil
    let form = SettingsForm()
    form.add("name", "Name on card", value: card?.name ?? "")
    form.add("number", "Card number", placeholder: card == nil ? "" : "Unchanged •••• \(card?.last4 ?? "")")
    form.add("month", "Expiry month", value: card.map { $0.month > 0 ? String(format: "%02d", $0.month) : "" } ?? "",
             placeholder: "MM", width: 64)
    form.add("year", "Expiry year", value: card.map { $0.year > 0 ? String($0.year) : "" } ?? "", placeholder: "YYYY", width: 80)
    let stack = SettingsStack()
    stack.set([
      .init(view: form),
      .init(view: SettingsButtonBar(trailing: [
        SettingsPushButton("Cancel") { [weak self] in
          guard let self else { return }
          let wasAdding = self.adding
          self.endEditing()
          if wasAdding { self.openID = nil }
          self.render()
          settingsDataChanged("autofill")
        },
        SettingsPushButton("Save") { [weak self] in self?.save() },
      ])),
    ])
    self.form = form
    formCard = SettingsCard(stack)
    adding = card == nil
    openID = card?.id ?? openID
    if adding { openID = nil }
    render()
    if let formCard { settingsScrollIntoView(formCard) }
    if let field = form[card == nil ? "name" : "month"] { window?.makeFirstResponder(field) }
    settingsDataChanged("autofill")
  }

  private func endEditing() {
    form?.wipe()
    form = nil
    formCard = nil
    adding = false
  }

  private func save() {
    guard let form, let profile = settingsDataProfile, !busy else { return }
    SettingsDataGuard.shared.touch()
    let typed = Self.digits(form["number"]?.stringValue ?? "")
    if adding || !typed.isEmpty {
      guard (12...19).contains(typed.count), Self.luhn(typed) else {
        form.errorText = "That card number isn't valid."
        return
      }
    }
    let monthText = form["month"]?.stringValue.trimmingCharacters(in: .whitespaces) ?? ""
    let yearText = form["year"]?.stringValue.trimmingCharacters(in: .whitespaces) ?? ""
    let month = Int(monthText) ?? 0
    var year = Int(yearText) ?? 0
    if (1...99).contains(year) { year += 2000 }
    guard monthText.isEmpty || (1...12).contains(month), yearText.isEmpty || (2000...2199).contains(year) else {
      form.errorText = "Enter the expiry as a month (1–12) and a year."
      return
    }
    var card: [(String, SecretJSON.Value)] = [("name", .text(form["name"]?.stringValue.trimmingCharacters(in: .whitespaces) ?? ""))]
    if month > 0 { card.append(("expMonth", .number(month))) }
    if year > 0 { card.append(("expYear", .number(year))) }
    if !adding, let id = openID { card.append(("id", .text(id))) }
    var fields: [(String, SecretJSON.Value)] = [("card", .object(card))]
    if !typed.isEmpty { fields.append(("number", .text(typed))) }
    busy = true
    let wasAdding = adding
    EngineCalls.callWithSecret("ac_autofill_save_card", profile: profile, json: SecretJSON.object(fields)) { [weak self] reply in
      guard let self else { return }
      self.busy = false
      guard let reply, reply["error"] == nil else {
        self.last = "error"
        self.form?.errorText = "Ray couldn't save this card."
        return settingsDataChanged("autofill")
      }
      self.last = wasAdding ? "added" : "saved"
      self.endEditing()
      if wasAdding { self.openID = nil }
      self.load()
    }
  }

  /// For tests: Add…, the fixture typed in, Save.
  func addFixture(_ item: [String: Any]) {
    startEditing(nil)
    fill(item)
    save()
  }

  /// For tests: Edit on the open card, the fixture's name (and nothing else) typed, Save.
  func editFixture(_ item: [String: Any]) -> Bool {
    guard let id = openID else { return false }
    startEditing(id)
    form?["name"]?.stringValue = SettingsFixtures.text(item, "name")
    save()
    return true
  }

  private func fill(_ item: [String: Any]) {
    for key in ["name", "number", "month", "year"] where item[key] != nil { form?[key]?.stringValue = SettingsFixtures.text(item, key) }
  }

  func pressDelete() -> Bool {
    guard let id = openID, !adding, let card = list.first(where: { $0.id == id }) else { return false }
    SettingsRecordConfirm.ask(
      "removeCard", title: "Delete \(Self.networkName(card.network)) •••• \(card.last4)?",
      message: "Ray won't fill it in when you pay any more. This can't be undone.", confirm: "Delete", from: self
    ) { [weak self] yes in
      guard yes, let profile = settingsDataProfile else { return }
      EngineCalls.call("ac_autofill_remove", profile: profile, args: ["id": id]) { [weak self] reply in
        guard let self else { return }
        self.last = reply == nil || reply?["error"] != nil ? "error" : "removed"
        if self.openID == id { self.closeRow() }
        self.load()
      }
    }
    settingsDataChanged("autofill")
    return true
  }
}
