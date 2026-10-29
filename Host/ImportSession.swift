import AppKit

// The contract between the importer (Importer/Sources/RayImport, Ardia's import core) and the screens that use it
// (onboarding, File › Import from Browser…). The screens only see these types; ImportSession does the reading, the
// one Keychain prompt and the writing into Ray (sidebar, engine history, passwords, cookies, autofill).
//
// Never imported: another browser's settings (Ray keeps its own).

/// What can be brought over, in the order the screens list it.
enum ImportItem: String, CaseIterable {
  case pinnedTabs, favorites, openTabs, history, bookmarks, passwords, cookies, autofill, extensions

  var title: String {
    switch self {
    case .pinnedTabs: "Pinned tabs and folders"
    case .favorites: "Favorites"
    case .openTabs: "Open tabs"
    case .history: "History"
    case .bookmarks: "Bookmarks"
    case .passwords: "Passwords"
    case .cookies: "Cookies, so you stay signed in"
    case .autofill: "Addresses and cards"
    case .extensions: "Extensions"
    }
  }

  /// SF Symbol for the row.
  var symbol: String {
    switch self {
    case .pinnedTabs: "pin"
    case .favorites: "star"
    case .openTabs: "sidebar.left"
    case .history: "clock.arrow.circlepath"
    case .bookmarks: "bookmark"
    case .passwords: "key"
    case .cookies: "person.crop.circle.badge.checkmark"
    case .autofill: "creditcard"
    case .extensions: "puzzlepiece.extension"
    }
  }

  /// Encrypted in the source browser: reading it needs that browser's "<Name> Safe Storage" key, which macOS asks
  /// the user about (once per browser, during `run`).
  var needsUnlock: Bool { self == .passwords || self == .cookies || self == .autofill }
}

struct ImportProfile: Equatable {
  let id: String
  let name: String
}

struct ImportSource: Equatable {
  /// The importer's browser id ("arc", "chrome", "dia", "safari", "firefox", …).
  let id: String
  let name: String
  /// The browser's app icon, when it's installed.
  let icon: NSImage?
  let profiles: [ImportProfile]
  /// Arc: listed first and marked Recommended.
  let recommended: Bool
  /// A short note under the name when something stands in the way ("Needs Full Disk Access"), else nil.
  let note: String?
  /// What this source can give at all (Safari has no pinned tabs, Firefox no autofill…).
  let items: Set<ImportItem>
}

/// Counts for the "what to bring" step, read without any Keychain prompt. A count that needs the key to know is nil
/// (the row shows no number).
struct ImportPreview {
  var counts: [ImportItem: Int] = [:]
  /// One line for the source row, e.g. "3 spaces, 42 pinned tabs, 2 profiles".
  var summary = ""
}

enum ImportEvent {
  case started(ImportItem)
  /// `count` came in; `existing` were already in Ray and were left as they were (the sidebar never takes a URL
  /// twice), so a 0 can say "already here" rather than look like nothing was found.
  case finished(ImportItem, count: Int, existing: Int = 0)
  /// The user denied the Keychain prompt, the data was unreadable, the engine refused it…: the other items go on.
  case failed(ImportItem, reason: String)
}

/// What an import added to the sidebar, per kind (folders not counted), and what was there already.
struct SidebarImportCounts {
  var favorites = 0, pinned = 0, today = 0
  var alreadyFavorites = 0, alreadyPinned = 0, alreadyToday = 0
}

struct ImportSummary {
  var imported: [ImportItem: Int] = [:]
  /// Per item, how many were already in Ray (only where some were).
  var existing: [ImportItem: Int] = [:]
  var failed: [ImportItem: String] = [:]
}

// MARK: Session

/// Runs an import. Owned by the importer side: screens call these and nothing else. Test builds read browsers from
/// RAY_IMPORT_SOURCE_DIR (a fake ~/Library/Application Support, e.g. Importer/fixtures/home/Library/Application
/// Support) and use RAY_IMPORT_SECRET as every browser's Safe Storage secret, so tests never touch a real profile or
/// the Keychain.
final class ImportSession {
  /// Holds the browsers' derived keys during a run (dropped when it ends). Nil in a test build without
  /// RAY_IMPORT_SOURCE_DIR.
  private lazy var importer: Importer? = ImportPlaces.discovery().map { Importer(discovery: $0) }
  private var running = false

  /// Browsers found on this Mac, Arc first, then by name.
  static func sources() -> [ImportSource] { ImportSources.list() }

  /// Counts for the "what to bring" step, read off the main thread without any Keychain prompt; completion on main.
  func preview(_ source: ImportSource, profile: ImportProfile, completion: @escaping (ImportPreview) -> Void) {
    DispatchQueue.global(qos: .userInitiated).async {
      let preview = ImportCounter.preview(source, profile: profile)
      DispatchQueue.main.async { completion(preview) }
    }
  }

  /// Reads the chosen items (one Keychain prompt when any needs the key) and writes them into Ray: the sidebar of
  /// `controller`'s window, and the engine's history, passwords, cookies and autofill. Events and completion on main.
  func run(
    _ source: ImportSource, profile: ImportProfile, items: Set<ImportItem>, into controller: BrowserWindowController,
    event: @escaping (ImportEvent) -> Void, completion: @escaping (ImportSummary) -> Void
  ) {
    guard !running, let importer else {
      let reason = running ? "Another import is running" : "\(source.name) wasn't found"
      var summary = ImportSummary()
      for item in ImportItem.allCases where items.contains(item) {
        event(.started(item))
        event(.failed(item, reason: reason))
        summary.failed[item] = reason
      }
      return completion(summary)
    }
    running = true
    let run = ImportRun(
      source: source, profileId: profile.id, items: items, importer: importer, controller: controller, event: event)
    run.start { [weak self] summary in
      self?.running = false
      completion(summary)
    }
  }
}
