import CommonCrypto
import Darwin
import Foundation
import Security
import SQLite3

/// The engine encrypts cookies, saved passwords, card numbers and sign-in tokens (os_crypt: "v10" + AES-128-CBC with a
/// key derived from a password) with the password of "Ray Safe Storage" in the login keychain. Ray 0.1 ran on
/// Ardia's prebuilt engine with Chromium's mock keychain, whose password is the public "mock_password", so its data
/// is as good as plain text. `prepare` moves a data dir from the mock key to Ray's own key once, before the engine
/// starts, and says whether the engine may leave the mock keychain.
///
/// It makes the keychain item itself (the engine would only make one for a fresh data dir and otherwise asks the
/// user, engine/patches/chromium-safe-storage-no-silent-reset.patch), re-encrypts copies of the databases, then swaps
/// them in. Anything that fails before the swap leaves the data dir as it was and the engine on the mock keychain for
/// this launch; the next launch tries again. The originals stay in "Safe Storage Migration/backup" for a week.
enum SafeStorage {
  static let service = "Ray Safe Storage"
  static let account = "Ray"
  /// In the engine's data dir: written once its databases are under Ray's key. Holds the date of the move.
  static let markerName = "Ray Safe Storage"
  /// Next to the engine's data dir: the copies being re-encrypted, the plan for swapping them in, the originals.
  static let workName = "Safe Storage Migration"
  static let backupDays = 7.0
  /// The profile databases that hold os_crypt values (cookie stores, password stores, autofill and token tables).
  static let databases = ["Cookies", "Network/Cookies", "Extension Cookies", "Login Data", "Login Data For Account",
                          "Web Data", "Account Web Data"]

  enum Mode: String {
    /// Start the engine on the mock keychain (`--use-mock-keychain`).
    case mock
    /// Start it on Ray's keychain item.
    case keychain
    /// Don't start it: the swap stopped half way, and either key would lose data. Ask the user to try again.
    case blocked
  }

  struct Report {
    var mode: Mode
    /// Values re-encrypted by this launch.
    var moved = 0
    /// Why, in a few words, for the state log. No paths, values or secrets.
    var note: String
  }

  // MARK: Keys

  static let mockPassword = Data("mock_password".utf8)
  static let tag = Data("v10".utf8)

  /// os_crypt's key: PBKDF2-HMAC-SHA1 of the password, salt "saltysalt", 1003 rounds, 16 bytes
  /// (components/os_crypt/async/browser/keychain_key_provider.mm).
  static func key(password: Data) -> Data {
    let salt = Array("saltysalt".utf8)
    var key = [UInt8](repeating: 0, count: kCCKeySizeAES128)
    _ = password.withUnsafeBytes { raw in
      CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), raw.bindMemory(to: CChar.self).baseAddress, password.count,
                           salt, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003, &key, key.count)
    }
    return Data(key)
  }

  /// AES-128-CBC with os_crypt's fixed IV of 16 spaces and PKCS#7 padding (components/os_crypt/async/common/
  /// encryptor.cc). nil when the padding doesn't check out, which is what a wrong key almost always gives. The padding
  /// is checked here: CommonCrypto's own PKCS#7 option lets bad padding through on decrypt.
  static func crypt(_ operation: Int, key: Data, _ input: Data) -> Data? {
    let block = kCCBlockSizeAES128
    var input = input
    if operation == kCCEncrypt {
      let pad = block - input.count % block
      input.append(contentsOf: [UInt8](repeating: UInt8(pad), count: pad))
    } else if input.isEmpty || input.count % block != 0 {
      return nil
    }
    let iv = [UInt8](repeating: 0x20, count: block)
    var output = [UInt8](repeating: 0, count: input.count)
    var moved = 0
    let status = key.withUnsafeBytes { keyBytes in
      input.withUnsafeBytes { inputBytes in
        CCCrypt(CCOperation(operation), CCAlgorithm(kCCAlgorithmAES), CCOptions(0), keyBytes.baseAddress, key.count,
                iv, inputBytes.baseAddress, input.count, &output, output.count, &moved)
      }
    }
    guard status == kCCSuccess, moved == input.count else { return nil }
    if operation == kCCEncrypt { return Data(output) }
    guard let pad = output.last, (1...block).contains(Int(pad)),
          output.suffix(Int(pad)).allSatisfy({ $0 == pad }) else { return nil }
    return Data(output.dropLast(Int(pad)))
  }

  /// A "v10" value under `from`, under `to` instead; nil when `from` isn't its key.
  static func reencrypt(_ value: Data, from: Data, to: Data) -> Data? {
    guard value.starts(with: tag), let plain = crypt(kCCDecrypt, key: from, value.dropFirst(tag.count)),
          let sealed = crypt(kCCEncrypt, key: to, plain) else { return nil }
    return tag + sealed
  }

  // MARK: Keychain

  struct KeychainStatus: Error { var status: OSStatus }

  /// The keychain item's password; makes one (16 random bytes, base64, as the engine does) when there is none.
  static func password(from keychain: SafeStorageStore) -> Result<Data, KeychainStatus> {
    switch keychain.find() {
    case .success(let password):
      return password.isEmpty ? .failure(KeychainStatus(status: errSecDecode)) : .success(password)
    case .failure(let error) where error.status != errSecItemNotFound:
      return .failure(error)
    case .failure:
      break
    }
    var bytes = [UInt8](repeating: 0, count: 16)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
      return .failure(KeychainStatus(status: errSecIO))
    }
    let fresh = Data(Data(bytes).base64EncodedString().utf8)
    switch keychain.addIfAbsent(fresh) {
    case errSecSuccess: return .success(fresh)
    case errSecDuplicateItem: return keychain.find()
    case let status: return .failure(KeychainStatus(status: status))
    }
  }

  // MARK: Migration

  static func prepare(dataDirectory: String, keychain: SafeStorageStore, now: Date = Date()) -> Report {
    let files = FileManager.default
    let marker = (dataDirectory as NSString).appendingPathComponent(markerName)
    let work = ((dataDirectory as NSString).deletingLastPathComponent as NSString).appendingPathComponent(workName)
    let plan = (work as NSString).appendingPathComponent("plan.json")
    if files.fileExists(atPath: marker) {
      if !files.fileExists(atPath: plan) { dropOldBackup(work: work, marker: marker, now: now) }
      return Report(mode: .keychain, note: "ready")
    }
    if dataDirectoryInUse(dataDirectory) {
      // Another Ray has it open (the engine hands this launch to it): nothing may change under it.
      return Report(mode: .mock, note: "in use")
    }
    var moved = 0
    if !files.fileExists(atPath: plan) {
      // A run that stopped before writing its plan changed nothing outside `work`: start again. (With a plan, the
      // swap may have begun, and only finishing it keeps every value readable.)
      try? files.removeItem(atPath: work)
      let password: Data
      switch self.password(from: keychain) {
      case .success(let found): password = found
      case .failure(let error): return Report(mode: .mock, note: "keychain \(error.status)")
      }
      do {
        moved = try stage(dataDirectory: dataDirectory, work: work, plan: plan, password: password)
      } catch {
        try? files.removeItem(atPath: work)
        return Report(mode: .mock, note: "staging failed: \(describe(error))")
      }
    }
    do {
      try swap(dataDirectory: dataDirectory, work: work, plan: plan)
    } catch {
      return Report(mode: .blocked, moved: moved, note: "swap failed: \(describe(error))")
    }
    let stamp = (try? JSONSerialization.data(withJSONObject: ["migrated": now.timeIntervalSince1970])) ?? Data()
    guard files.createFile(atPath: marker, contents: stamp) else {
      return Report(mode: .blocked, moved: moved, note: "marker not written")
    }
    try? files.removeItem(atPath: plan)
    try? files.removeItem(atPath: (work as NSString).appendingPathComponent("staged"))
    return Report(mode: .keychain, moved: moved, note: "migrated")
  }

  struct Failure: Error, CustomStringConvertible { var description: String }

  /// Without paths (they hold the user's name).
  static func describe(_ error: Error) -> String {
    if let failure = error as? Failure { return failure.description }
    let ns = error as NSError
    return "\(ns.domain) \(ns.code)"
  }

  /// Copies every database that holds os_crypt values into `work/staged`, re-encrypts the copies, then writes the
  /// plan (the step that commits to swapping them in). Returns how many values it re-encrypted.
  static func stage(dataDirectory: String, work: String, plan: String, password: Data) throws -> Int {
    let files = FileManager.default
    let staged = (work as NSString).appendingPathComponent("staged")
    try files.createDirectory(atPath: staged, withIntermediateDirectories: true)
    let mock = key(password: mockPassword)
    let real = key(password: password)
    var entries: [[String: String]] = []
    var moved = 0
    let profiles = ((try? files.contentsOfDirectory(atPath: dataDirectory)) ?? []).sorted()
    for profile in profiles {
      for database in databases {
        let relative = (profile as NSString).appendingPathComponent(database)
        let original = (dataDirectory as NSString).appendingPathComponent(relative)
        var isDirectory: ObjCBool = false
        guard files.fileExists(atPath: original, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
        let copy = (staged as NSString).appendingPathComponent(String(entries.count))
        try copyDatabase(from: original, to: copy)
        moved += try reencryptDatabase(at: copy, from: mock, to: real)
        entries.append(["path": relative, "staged": String(entries.count)])
      }
    }
    let data = try JSONSerialization.data(withJSONObject: entries)
    try data.write(to: URL(fileURLWithPath: plan), options: .atomic)
    return moved
  }

  /// Puts each staged copy in its original's place; the original and its journal go to `work/backup`. Safe to run
  /// again after it stopped part way: a copy that is no longer staged is already in place.
  static func swap(dataDirectory: String, work: String, plan: String) throws {
    let files = FileManager.default
    guard let data = files.contents(atPath: plan),
          let entries = try JSONSerialization.jsonObject(with: data) as? [[String: String]] else {
      throw Failure(description: "unreadable plan")
    }
    for entry in entries {
      guard let relative = entry["path"], let index = entry["staged"], !relative.contains(".."),
            !index.contains("/") else { throw Failure(description: "bad plan entry") }
      let staged = ((work as NSString).appendingPathComponent("staged") as NSString).appendingPathComponent(index)
      guard files.fileExists(atPath: staged) else { continue }
      let original = (dataDirectory as NSString).appendingPathComponent(relative)
      let backup = ((work as NSString).appendingPathComponent("backup") as NSString).appendingPathComponent(relative)
      try files.createDirectory(atPath: (backup as NSString).deletingLastPathComponent,
                                withIntermediateDirectories: true)
      // Journals first: a stale -wal or -journal next to the new file would be replayed into it.
      for suffix in ["-journal", "-wal", "-shm", ""] where files.fileExists(atPath: original + suffix) {
        try files.moveItem(atPath: original + suffix, toPath: unused(backup + suffix))
      }
      try files.moveItem(atPath: staged, toPath: original)
    }
  }

  static func unused(_ path: String) -> String {
    var candidate = path
    var n = 1
    while FileManager.default.fileExists(atPath: candidate) {
      candidate = "\(path).\(n)"
      n += 1
    }
    return candidate
  }

  static func dropOldBackup(work: String, marker: String, now: Date) {
    guard FileManager.default.fileExists(atPath: work), let data = FileManager.default.contents(atPath: marker),
          let stamp = (try? JSONSerialization.jsonObject(with: data) as? [String: Double])?["migrated"],
          now.timeIntervalSince1970 - stamp > backupDays * 86400 else { return }
    try? FileManager.default.removeItem(atPath: work)
  }

  /// The engine's SingletonLock is a symlink to "<host>-<pid>" while a browser has the data dir open.
  static func dataDirectoryInUse(_ dataDirectory: String) -> Bool {
    let lock = (dataDirectory as NSString).appendingPathComponent("SingletonLock")
    guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: lock),
          let dash = target.lastIndex(of: "-"), let pid = pid_t(target[target.index(after: dash)...]), pid > 0
    else { return false }
    return kill(pid, 0) == 0 || errno == EPERM
  }

  // MARK: SQLite

  /// A consistent copy through SQLite's backup API, so a pending -wal or -journal is applied to it.
  static func copyDatabase(from source: String, to destination: String) throws {
    var from: OpaquePointer?
    var to: OpaquePointer?
    defer {
      sqlite3_close(from)
      sqlite3_close(to)
    }
    guard sqlite3_open_v2(source, &from, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
          sqlite3_open_v2(destination, &to, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
          let backup = sqlite3_backup_init(to, "main", from, "main") else {
      throw Failure(description: "can't open \((source as NSString).lastPathComponent)")
    }
    let stepped = sqlite3_backup_step(backup, -1)
    let finished = sqlite3_backup_finish(backup)
    guard stepped == SQLITE_DONE, finished == SQLITE_OK else {
      throw Failure(description: "can't copy \((source as NSString).lastPathComponent) (\(stepped))")
    }
  }

  /// Re-encrypts every "v10" BLOB in every column of every table that `from` decrypts, in one transaction. Values
  /// it doesn't decrypt (the engine's empty-key fallback, anything else) stay as they are.
  static func reencryptDatabase(at path: String, from: Data, to: Data) throws -> Int {
    var db: OpaquePointer?
    defer { sqlite3_close(db) }
    guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
      throw Failure(description: "can't open a staged copy")
    }
    func quoted(_ name: String) -> String { "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
    func rows(_ sql: String, bind: [Data] = [], _ read: (OpaquePointer) -> Void) throws {
      var statement: OpaquePointer?
      guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
        sqlite3_finalize(statement)
        throw Failure(description: String(cString: sqlite3_errmsg(db)))
      }
      defer { sqlite3_finalize(statement) }
      for (i, value) in bind.enumerated() {
        _ = value.withUnsafeBytes { sqlite3_bind_blob(statement, Int32(i + 1), $0.baseAddress, Int32(value.count), SQLITE_TRANSIENT) }
      }
      while true {
        switch sqlite3_step(statement) {
        case SQLITE_ROW: read(statement)
        case SQLITE_DONE: return
        default: throw Failure(description: String(cString: sqlite3_errmsg(db)))
        }
      }
    }
    func blob(_ statement: OpaquePointer, _ column: Int32) -> Data {
      guard let bytes = sqlite3_column_blob(statement, column) else { return Data() }
      return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
    }

    try rows("BEGIN IMMEDIATE") { _ in }
    var moved = 0
    do {
      var tables: [String] = []
      try rows("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'") {
        tables.append(String(cString: sqlite3_column_text($0, 0)))
      }
      for table in tables {
        var columns: [String] = []
        try rows("PRAGMA table_info(\(quoted(table)))") { columns.append(String(cString: sqlite3_column_text($0, 1))) }
        for column in columns {
          let c = quoted(column)
          let filter = "WHERE typeof(\(c)) = 'blob' AND substr(\(c), 1, 3) = X'763130' AND length(\(c)) >= 19 "
            + "AND (length(\(c)) - 3) % 16 = 0"
          // Distinct values, each updated wherever it appears: also works for a WITHOUT ROWID table, and the
          // fixed IV makes equal values equal under either key.
          var values: [Data] = []
          try rows("SELECT DISTINCT \(c) FROM \(quoted(table)) \(filter)") { values.append(blob($0, 0)) }
          for value in values {
            guard let sealed = reencrypt(value, from: from, to: to) else { continue }
            try rows("UPDATE \(quoted(table)) SET \(c) = ?1 WHERE \(c) = ?2", bind: [sealed, value]) { _ in }
            moved += Int(sqlite3_changes(db))
          }
        }
      }
      try rows("COMMIT") { _ in }
    } catch {
      try? rows("ROLLBACK") { _ in }
      throw error
    }
    return moved
  }

  private static let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}

protocol SafeStorageStore {
  /// The item's password; errSecItemNotFound when there is no item.
  func find() -> Result<Data, SafeStorage.KeychainStatus>
  /// Adds the item unless one is there (errSecDuplicateItem).
  func addIfAbsent(_ password: Data) -> OSStatus
}

/// "Ray Safe Storage" in the login keychain, made the way the engine's KeychainV2 makes it (crypto/apple/
/// keychain_v2.mm), so the engine finds it and the item's access list trusts this app.
struct LoginKeychain: SafeStorageStore {
  func find() -> Result<Data, SafeStorage.KeychainStatus> {
    let query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword, kSecAttrService: SafeStorage.service, kSecAttrAccount: SafeStorage.account,
      kSecMatchLimit: kSecMatchLimitOne, kSecReturnData: true,
    ]
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    guard status == errSecSuccess else { return .failure(SafeStorage.KeychainStatus(status: status)) }
    guard let data = result as? Data else { return .failure(SafeStorage.KeychainStatus(status: errSecDecode)) }
    return .success(data)
  }

  func addIfAbsent(_ password: Data) -> OSStatus {
    let attributes: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword, kSecAttrAccessible: kSecAttrAccessibleWhenUnlocked,
      kSecAttrService: SafeStorage.service, kSecAttrAccount: SafeStorage.account, kSecValueData: password,
    ]
    return SecItemAdd(attributes as CFDictionary, nil)
  }
}

/// Test builds: the engine's file keychain (`--ray-test=keychain=file`, engine/raycore/src/ray/core/
/// ac_safe_storage.mm), a file in the data dir, so checks never touch the user's keychain.
struct FileKeychain: SafeStorageStore {
  let path: String

  func find() -> Result<Data, SafeStorage.KeychainStatus> {
    guard let data = FileManager.default.contents(atPath: path) else {
      return .failure(SafeStorage.KeychainStatus(status: errSecItemNotFound))
    }
    return .success(data)
  }

  func addIfAbsent(_ password: Data) -> OSStatus {
    let fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
    guard fd >= 0 else { return errno == EEXIST ? errSecDuplicateItem : errSecIO }
    defer { close(fd) }
    let written = password.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    return written == password.count ? errSecSuccess : errSecIO
  }
}
