import CommonCrypto
import Foundation
import SQLite3

// Host/SafeStorage.swift: moving a data dir from the mock keychain's key to Ray's own, on throwaway files only (the
// keychain here is a FileKeychain; nothing touches the login keychain).

var failures = 0
func expect(_ condition: Bool, _ message: String) {
  if !condition {
    failures += 1
    print("FAIL safe storage: \(message)")
  }
}

let hex = { (d: Data) in d.map { String(format: "%02x", $0) }.joined() }
// os_crypt's key for "mock_password", as Ardia's keychain_key_provider_unittest has it.
expect(hex(SafeStorage.key(password: SafeStorage.mockPassword)) == "af0f762aaf6d7d11581b7aa8ce7218de", "mock key")
// Chromium's empty-password fallback key (encryptor.cc) is PBKDF2 with 1 round, so 1003 rounds must differ from it.
expect(hex(SafeStorage.key(password: Data())) != "d0d0ec9c7d77d43ac54187fa4818d17f", "rounds")

let mock = SafeStorage.key(password: SafeStorage.mockPassword)
func seal(_ text: String, key: Data) -> Data { SafeStorage.tag + SafeStorage.crypt(kCCEncrypt, key: key, Data(text.utf8))! }
func open(_ value: Data, key: Data) -> String? {
  guard value.starts(with: SafeStorage.tag), let plain = SafeStorage.crypt(kCCDecrypt, key: key, value.dropFirst(3)) else { return nil }
  return String(data: plain, encoding: .utf8)
}

func sql(_ path: String, _ statements: String) {
  var db: OpaquePointer?
  precondition(sqlite3_open(path, &db) == SQLITE_OK)
  precondition(sqlite3_exec(db, statements, nil, nil, nil) == SQLITE_OK, String(cString: sqlite3_errmsg(db)))
  sqlite3_close(db)
}
func insert(_ path: String, _ table: String, _ values: [Data?]) {
  var db: OpaquePointer?
  var statement: OpaquePointer?
  precondition(sqlite3_open(path, &db) == SQLITE_OK)
  let marks = values.indices.map { "?\($0 + 1)" }.joined(separator: ",")
  precondition(sqlite3_prepare_v2(db, "INSERT INTO \(table) VALUES (\(marks))", -1, &statement, nil) == SQLITE_OK)
  for (i, value) in values.enumerated() {
    if let value {
      _ = value.withUnsafeBytes { sqlite3_bind_blob(statement, Int32(i + 1), $0.baseAddress, Int32(value.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
    } else {
      sqlite3_bind_null(statement, Int32(i + 1))
    }
  }
  precondition(sqlite3_step(statement) == SQLITE_DONE)
  sqlite3_finalize(statement)
  sqlite3_close(db)
}
func column(_ path: String, _ query: String) -> [Data] {
  var db: OpaquePointer?
  var statement: OpaquePointer?
  precondition(sqlite3_open(path, &db) == SQLITE_OK)
  precondition(sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK)
  var out: [Data] = []
  while sqlite3_step(statement) == SQLITE_ROW {
    let bytes = sqlite3_column_blob(statement, 0)
    out.append(bytes.map { Data(bytes: $0, count: Int(sqlite3_column_bytes(statement, 0))) } ?? Data())
  }
  sqlite3_finalize(statement)
  sqlite3_close(db)
  return out
}

let files = FileManager.default
let root = NSTemporaryDirectory() + "ray-safe-storage-\(getpid())"
try? files.removeItem(atPath: root)
let data = root + "/Chromium"
try! files.createDirectory(atPath: data + "/Default/Network", withIntermediateDirectories: true)
try! files.createDirectory(atPath: data + "/Profile 1", withIntermediateDirectories: true)
files.createFile(atPath: data + "/Local State", contents: Data("{}".utf8))

let cookies = data + "/Default/Cookies"
sql(cookies, "CREATE TABLE cookies (host_key TEXT, name TEXT, value BLOB, encrypted_value BLOB);")
insert(cookies, "cookies", [Data("a.test".utf8), Data("sid".utf8), Data(), seal("cookie-one", key: mock)])
insert(cookies, "cookies", [Data("b.test".utf8), Data("sid".utf8), Data(), seal("cookie-one", key: mock)])
// Values the mock key doesn't open (the empty-key fallback, plain bytes that look like a tag) stay as they are.
let emptyKeyValue = seal("legacy", key: Data([0xd0, 0xd0, 0xec, 0x9c, 0x7d, 0x77, 0xd4, 0x3a, 0xc5, 0x41, 0x87, 0xfa, 0x48, 0x18, 0xd1, 0x7f]))
insert(cookies, "cookies", [Data("c.test".utf8), Data("old".utf8), Data(), emptyKeyValue])
let lookalike = Data("v10 plain text, not a secret".utf8)
insert(cookies, "cookies", [Data("d.test".utf8), Data("odd".utf8), Data(), lookalike])
insert(cookies, "cookies", [Data("e.test".utf8), Data("null".utf8), Data(), nil])

let logins = data + "/Profile 1/Login Data"
sql(logins, "CREATE TABLE logins (origin_url TEXT, password_value BLOB); CREATE TABLE notes (k TEXT PRIMARY KEY, value BLOB) WITHOUT ROWID;")
insert(logins, "logins", [Data("https://a.test".utf8), seal("hunter2", key: mock)])
insert(logins, "notes", [Data("n".utf8), seal("a note", key: mock)])
// A database left mid-write: its -journal must not survive next to the re-encrypted copy.
let webData = data + "/Default/Web Data"
sql(webData, "PRAGMA journal_mode=WAL; CREATE TABLE token_service (service TEXT, encrypted_token BLOB);")
insert(webData, "token_service", [Data("t".utf8), seal("token", key: mock)])
// Not a profile database: never opened.
sql(data + "/Default/History", "CREATE TABLE urls (u BLOB);")
insert(data + "/Default/History", "urls", [seal("history", key: mock)])

let keychain = FileKeychain(path: data + "/Test Safe Storage Key")
let now = Date(timeIntervalSince1970: 2_000_000_000)

// In use: a live SingletonLock (this process) keeps everything as it is.
try! files.createSymbolicLink(atPath: data + "/SingletonLock", withDestinationPath: "host-\(getpid())")
var report = SafeStorage.prepare(dataDirectory: data, keychain: keychain, now: now)
expect(report.mode == .mock && report.note == "in use", "in use: \(report)")
expect(!files.fileExists(atPath: keychain.path), "in use: made a key")
try! files.removeItem(atPath: data + "/SingletonLock")
// A stale lock (no such process) doesn't count.
try! files.createSymbolicLink(atPath: data + "/SingletonLock", withDestinationPath: "host-99999")

// A run that stopped while staging left only scratch files: they are thrown away.
try! files.createDirectory(atPath: root + "/Safe Storage Migration/staged", withIntermediateDirectories: true)
files.createFile(atPath: root + "/Safe Storage Migration/staged/0", contents: Data("junk".utf8))

report = SafeStorage.prepare(dataDirectory: data, keychain: keychain, now: now)
expect(report.mode == .keychain && report.note == "migrated", "first run: \(report)")
expect(report.moved == 5, "moved \(report.moved), expected 5")
// (Before reading anything: opening a WAL database makes its -wal again.)
expect(!files.fileExists(atPath: webData + "-wal"), "a -wal file is next to the swapped database")
let password = files.contents(atPath: keychain.path) ?? Data()
expect(password.count == 24 && Data(base64Encoded: password) != nil, "made key: \(password.count) bytes")
let real = SafeStorage.key(password: password)

let after = column(cookies, "SELECT encrypted_value FROM cookies ORDER BY host_key")
expect(open(after[0], key: real) == "cookie-one" && open(after[1], key: real) == "cookie-one", "cookies under the new key")
expect(open(after[0], key: mock) == nil, "cookie still opens with the mock key")
expect(after[2] == emptyKeyValue && after[3] == lookalike && after[4].isEmpty, "untouched values changed")
expect(open(column(logins, "SELECT password_value FROM logins")[0], key: real) == "hunter2", "password")
expect(open(column(logins, "SELECT value FROM notes")[0], key: real) == "a note", "WITHOUT ROWID table")
expect(open(column(webData, "SELECT encrypted_token FROM token_service")[0], key: real) == "token", "WAL database")
expect(open(column(data + "/Default/History", "SELECT u FROM urls")[0], key: mock) == "history", "History was touched")
expect(files.fileExists(atPath: data + "/" + SafeStorage.markerName), "no marker")
let backup = root + "/Safe Storage Migration/backup"
expect(open(column(backup + "/Default/Cookies", "SELECT encrypted_value FROM cookies ORDER BY host_key")[0], key: mock) == "cookie-one",
       "backup isn't the original")
expect(!files.fileExists(atPath: root + "/Safe Storage Migration/staged"), "staged copies left")

// Second run: nothing to do, the backup stays for a week, then goes.
report = SafeStorage.prepare(dataDirectory: data, keychain: keychain, now: now.addingTimeInterval(86400))
expect(report.mode == .keychain && report.note == "ready" && report.moved == 0, "second run: \(report)")
expect(files.fileExists(atPath: backup), "backup dropped early")
expect(column(cookies, "SELECT encrypted_value FROM cookies ORDER BY host_key") == after, "second run changed values")
report = SafeStorage.prepare(dataDirectory: data, keychain: keychain, now: now.addingTimeInterval(8 * 86400))
expect(!files.fileExists(atPath: root + "/Safe Storage Migration"), "backup kept past a week")

// A swap that stopped half way is finished without the keychain (it may be unreadable now), and nothing is lost.
let second = root + "/second/Chromium"
try! files.createDirectory(atPath: second + "/Default", withIntermediateDirectories: true)
sql(second + "/Default/Cookies", "CREATE TABLE cookies (encrypted_value BLOB);")
insert(second + "/Default/Cookies", "cookies", [seal("one", key: mock)])
sql(second + "/Default/Login Data", "CREATE TABLE logins (password_value BLOB);")
insert(second + "/Default/Login Data", "logins", [seal("two", key: mock)])
let secondKeychain = FileKeychain(path: second + "/Test Safe Storage Key")
let secondWork = root + "/second/Safe Storage Migration"
let plan = secondWork + "/plan.json"
let secondPassword = (try! SafeStorage.password(from: secondKeychain).get())
_ = try! SafeStorage.stage(dataDirectory: second, work: secondWork, plan: plan, password: secondPassword)
// Swap only the first entry by hand, as if the app stopped there.
try! files.moveItem(atPath: second + "/Default/Cookies", toPath: secondWork + "/moved-original")
try! files.moveItem(atPath: secondWork + "/staged/0", toPath: second + "/Default/Cookies")
struct BrokenKeychain: SafeStorageKeychain {
  func find() -> Result<Data, SafeStorage.KeychainStatus> { .failure(.init(status: errSecAuthFailed)) }
  func addIfAbsent(_ password: Data) -> OSStatus { errSecAuthFailed }
}
report = SafeStorage.prepare(dataDirectory: second, keychain: BrokenKeychain(), now: now)
expect(report.mode == .keychain, "resumed swap: \(report)")
let secondKey = SafeStorage.key(password: secondPassword)
expect(open(column(second + "/Default/Cookies", "SELECT encrypted_value FROM cookies")[0], key: secondKey) == "one", "resumed: cookies")
expect(open(column(second + "/Default/Login Data", "SELECT password_value FROM logins")[0], key: secondKey) == "two", "resumed: logins")

// A keychain that refuses before anything was staged: the engine stays on the mock key, nothing changes.
let third = root + "/third/Chromium"
try! files.createDirectory(atPath: third + "/Default", withIntermediateDirectories: true)
sql(third + "/Default/Cookies", "CREATE TABLE cookies (encrypted_value BLOB);")
insert(third + "/Default/Cookies", "cookies", [seal("three", key: mock)])
report = SafeStorage.prepare(dataDirectory: third, keychain: BrokenKeychain(), now: now)
expect(report.mode == .mock && report.note == "keychain \(errSecAuthFailed)", "refused keychain: \(report)")
expect(open(column(third + "/Default/Cookies", "SELECT encrypted_value FROM cookies")[0], key: mock) == "three", "refused keychain changed data")
expect(!files.fileExists(atPath: third + "/" + SafeStorage.markerName), "refused keychain wrote the marker")

// A fresh data dir (a new install): a key and the marker, nothing else.
let fresh = root + "/fresh/Chromium"
try! files.createDirectory(atPath: fresh, withIntermediateDirectories: true)  // main.swift makes it first
let freshKeychain = FileKeychain(path: root + "/fresh/key")
report = SafeStorage.prepare(dataDirectory: fresh, keychain: freshKeychain, now: now)
expect(report.mode == .keychain && report.moved == 0, "fresh: \(report)")
expect(files.fileExists(atPath: freshKeychain.path), "fresh: no key")

try? files.removeItem(atPath: root)
if failures > 0 {
  print("\(failures) safe storage checks failed")
  exit(1)
}
print("safe storage: all passed")
