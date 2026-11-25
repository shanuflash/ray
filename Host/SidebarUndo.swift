import AppKit
import QuartzCore

// ⌘Z and ⇧⌘Z for the sidebar's organisation, as Arc's: pinning, favorites, moves, folders, names, icons and colours
// undo and redo, interleaved in time with closed tabs (Clear Today, ⌘W) when Settings › Reopen closed tabs with ⌘Z is
// on. The timeline of sidebar edits and closed tabs follows Circa's SidebarUndoRouter
// (github.com/okafrancois/circa, MIT License, Copyright (c) 2026 Okatech); the edits here are snapshots of the
// sidebar's shape, not Circa's command journal.

/// The sidebar's shape at one moment: each row's place and the fields an edit can change. Never the page, its history
/// or the tab itself.
struct SidebarSnapshot {
  struct Row: Equatable {
    let id: UUID
    let kind: SidebarEntry.Kind
    let parentID: UUID?
    let pinnedURL: String?
    let url: String
    let title: String
    let customTitle: String?
    let color: String?
    let icon: String?
    let isOpen: Bool?

    init(_ entry: SidebarEntry) {
      id = entry.id
      kind = entry.kind
      parentID = entry.parentID
      pinnedURL = entry.pinnedURL
      url = entry.isFolder ? entry.url : entry.currentURL
      // A tab's title is its page's: only a folder's is the user's.
      title = entry.title
      customTitle = entry.customTitle
      color = entry.color
      icon = entry.icon
      isOpen = entry.isOpen
    }

    /// What an edit changes, compared without the page's own (address, title): a tab that loads isn't an edit.
    func sameShape(_ other: Row) -> Bool {
      id == other.id && kind == other.kind && parentID == other.parentID && pinnedURL == other.pinnedURL
        && customTitle == other.customTitle && color == other.color && icon == other.icon
        && (kind != .folder || title == other.title)
    }
  }

  /// Every list a row can be in, by key: each profile's favorites (`fav:<profile>`), each Space's pinned
  /// (`pin:<space>`) and Today (`today:<space>`), in a fixed order.
  let lists: [(key: String, rows: [Row])]

  init(_ state: SidebarState) {
    lists = Self.lists(of: state).map { ($0.key, $0.entries.map(Row.init)) }
  }

  static func lists(of state: SidebarState) -> [(key: String, entries: [SidebarEntry])] {
    [("fav:", state.defaultFavorites)]
      + state.profileFavorites.keys.sorted().map { ("fav:" + $0, state.profileFavorites[$0] ?? []) }
      + state.spaces.flatMap { [("pin:" + $0.id.uuidString, $0.pinned), ("today:" + $0.id.uuidString, $0.today)] }
  }

  /// Puts `entries` in the list `key` names; false when that list is gone (its Space was deleted).
  @discardableResult
  static func set(_ key: String, _ entries: [SidebarEntry], in state: SidebarState) -> Bool {
    if key.hasPrefix("fav:") {
      let profile = String(key.dropFirst(4))
      state.setFavorites(entries, profile: profile.isEmpty ? nil : profile)
      return true
    }
    let pinned = key.hasPrefix("pin:")
    guard let id = UUID(uuidString: String(key.drop { $0 != ":" }.dropFirst())), let space = state.space(id: id) else {
      return false
    }
    if pinned { space.pinned = entries } else { space.today = entries }
    return true
  }

  var ids: Set<UUID> { Set(lists.flatMap { $0.rows.map(\.id) }) }

  func sameShape(_ other: SidebarSnapshot) -> Bool {
    func same(_ a: [Row], _ b: [Row]) -> Bool { a.count == b.count && zip(a, b).allSatisfy { $0.sameShape($1) } }
    return lists.count == other.lists.count
      && zip(lists, other.lists).allSatisfy { $0.key == $1.key && same($0.rows, $1.rows) }
  }

  /// Puts the sidebar back in this shape, in every Space. `other` is the shape being left (the edit's other side):
  /// rows it has that this one hasn't were made by the edit and go (unless live: a tab is never closed by an undo).
  /// Rows in neither (opened since) stay where they are. A pinned row, favorite or folder this shape has that's gone
  /// since comes back unloaded; a Today tab that's gone was closed, and ⇧⌘T (or ⌘Z) is what brings it back. A list
  /// whose Space was deleted since is left out. `leavingToday`: a Today folder that leaves Today, before it does (its
  /// Chrome group is taken apart).
  func restore(into state: SidebarState, leaving other: SidebarSnapshot, leavingToday: (SidebarEntry) -> Void) {
    var current: [UUID: SidebarEntry] = [:]
    for entry in state.allEntries { current[entry.id] = entry }
    let made = other.ids.subtracting(ids)
    var placed: Set<UUID> = []
    func entry(_ row: Row) -> SidebarEntry? {
      let entry: SidebarEntry
      if let existing = current[row.id] {
        entry = existing
      } else {
        if row.kind == .today { return nil }
        entry = SidebarEntry(kind: row.kind, url: row.url, title: row.title, id: row.id)
        entry.isOpen = row.isOpen
      }
      entry.kind = row.kind
      entry.parentID = row.parentID
      entry.pinnedURL = row.pinnedURL
      entry.customTitle = row.customTitle
      entry.color = row.color
      entry.icon = row.icon
      if entry.isFolder { entry.title = row.title }
      placed.insert(row.id)
      return entry
    }
    let todayFolders = state.todayFolders
    let now = Self.lists(of: state)
    var built: [String: [SidebarEntry]] = [:]
    var order: [String] = now.map(\.key)
    for (key, rows) in lists where now.contains(where: { $0.key == key }) || key.hasPrefix("fav:") {
      built[key] = rows.compactMap(entry)
      if !order.contains(key) { order.append(key) }
    }
    // Rows this shape doesn't know: made by the edit (gone unless live), or opened since (kept in place).
    for (key, entries) in now {
      var list = built[key] ?? []
      for (index, item) in entries.enumerated() where !placed.contains(item.id) {
        if made.contains(item.id) && !item.isLive { continue }
        list.insert(item, at: min(index, list.count))
        placed.insert(item.id)
      }
      built[key] = list
    }
    let stillToday = Set(built.filter { $0.key.hasPrefix("today:") }.values.flatMap { $0.map(\.id) })
    for folder in todayFolders where !stillToday.contains(folder.id) { leavingToday(folder) }
    for key in order {
      guard let list = built[key] else { continue }
      if key.hasPrefix("pin:") { for folder in list where folder.isFolder { folder.groupToken = nil } }
      Self.set(key, list, in: state)
    }
    state.normalizePinned()
    state.normalizeToday()
    for space in state.spaces {
      if let active = space.activeEntryID, !(space.pinned + space.today).contains(where: { $0.id == active })
        && !state.allFavorites.contains(where: { $0.id == active }) {
        space.activeEntryID = nil
      }
    }
  }
}

/// One undoable sidebar edit: its name for Edit › Undo ("Pin Tab"), the shape before and after, and when.
struct SidebarEdit {
  let name: String
  let before: SidebarSnapshot
  let after: SidebarSnapshot
  let at: CFTimeInterval
}

/// A window's sidebar edits, newest last, and the ones undone (for redo). In memory only, as Arc's.
final class SidebarUndo {
  static let limit = 100

  private(set) var undoStack: [SidebarEdit] = []
  private(set) var redoStack: [SidebarEdit] = []
  /// Undos and redos done, for the state log.
  private(set) var steps: [String] = []
  private var depth = 0
  private var pending: (name: String, before: SidebarSnapshot)?

  /// Runs `body` as one edit named `name`: whatever it changes undoes in one step. Nested edits (a menu item that
  /// moves several rows) fold into the outermost one. A body that changes nothing records nothing.
  func edit<T>(_ name: String, state: SidebarState, _ body: () -> T) -> T {
    if depth == 0 { pending = (name, SidebarSnapshot(state)) }
    depth += 1
    defer {
      depth -= 1
      if depth == 0, let pending {
        self.pending = nil
        let after = SidebarSnapshot(state)
        if !after.sameShape(pending.before) {
          undoStack.append(SidebarEdit(name: pending.name, before: pending.before, after: after, at: CACurrentMediaTime()))
          if undoStack.count > Self.limit { undoStack.removeFirst(undoStack.count - Self.limit) }
          redoStack = []
        }
      }
    }
    return body()
  }

  var nextUndo: SidebarEdit? { undoStack.last }
  var nextRedo: SidebarEdit? { redoStack.last }

  /// The newest edit, taken off to undo; it waits for redo.
  func takeUndo() -> SidebarEdit? {
    guard let edit = undoStack.popLast() else { return nil }
    redoStack.append(edit)
    steps.append("undo:" + edit.name)
    return edit
  }

  /// The newest undone edit, taken off to redo; it can be undone again.
  func takeRedo() -> SidebarEdit? {
    guard let edit = redoStack.popLast() else { return nil }
    undoStack.append(SidebarEdit(name: edit.name, before: edit.before, after: edit.after, at: CACurrentMediaTime()))
    steps.append("redo:" + edit.name)
    return edit
  }

  func clear() {
    undoStack = []
    redoStack = []
    steps = []
  }

  var debug: [String: Any] {
    ["undo": undoStack.map(\.name), "redo": redoStack.map(\.name), "steps": steps]
  }
}
