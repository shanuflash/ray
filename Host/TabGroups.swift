import AppKit

/// Today folders as Chrome tab groups, so `chrome.tabGroups` and extensions (Claude's, which groups the tabs it
/// drives) see and drive them. The engine's tab strip is the truth for what extensions do; Ray's sidebar state is the
/// truth for what the user does. Each `tabs.strip` event is merged three ways against the last one seen: only what
/// changed in Chrome since then is adopted (a group made, renamed, recoloured, collapsed, a tab joining or leaving),
/// then whatever still differs is pushed back with `ac_tabs_group`. A stale event so never undoes a change of Ray's.
///
/// Only Today tabs are ever in a group (Chrome never lets a pinned tab be in one): a pinned tab or favorite in a group
/// is taken out of it. Unloaded tabs aren't Chrome tabs, so a folder's group holds its open tabs and is made when the
/// first of them opens (after a relaunch, say). Group ids change every run, so they're never saved.
final class TabGroupSync {
  struct Look: Equatable {
    var title: String
    var color: String
    var collapsed: Bool
  }

  private let profile: RayCoreProfile
  private let windowID: () -> Int32
  private let state: () -> SidebarState
  /// Called after Chrome changed Ray's state (the controller saves, redraws and pushes).
  var onAdopt: ((String) -> Void)?

  /// The last strip seen: each grouped tab's group, and each group's look.
  private var seenTabs: [Int: String] = [:]
  private var seenGroups: [String: Look] = [:]
  /// Groups Ray took apart itself (a folder pinned or deleted): not adopted again if an event still shows them.
  private var released: Set<String> = []
  /// Groups Ray made in the last few seconds, with the look it gave them. Chrome's saved-tab-groups service settles a
  /// moment after launch and writes back the look it saved when the group was made (Chrome's default, before Ray's
  /// title and colour landed): that isn't the user's or an extension's change, so it's pushed over, not adopted.
  private var made: [String: (look: Look, at: Date)] = [:]
  private static let settleTime: TimeInterval = 5
  private var pending: [String: Any]?
  private static var watching = false

  init(profile: RayCoreProfile, windowID: @escaping () -> Int32, state: @escaping () -> SidebarState) {
    self.profile = profile
    self.windowID = windowID
    self.state = state
    EngineEvents.on("tabs.strip") { [weak self] payload in self?.received(payload) }
    if !Self.watching {
      Self.watching = true
      EngineCalls.call("ac_tabs_watch", profile: profile) { _ in }
    }
  }

  static func look(of folder: SidebarEntry) -> Look {
    Look(title: folder.title, color: FolderLook.chromeColor(folder.color), collapsed: !(folder.isOpen ?? true))
  }

  /// For tests: the groups as Chrome last showed them.
  var debug: [[String: Any]] {
    seenGroups.sorted { $0.key < $1.key }.map { token, look in
      ["id": token, "title": look.title, "color": look.color, "collapsed": look.collapsed,
       "tabs": seenTabs.filter { $0.value == token }.keys.sorted()]
    }
  }

  // MARK: From Chrome

  private func received(_ payload: [String: Any]) {
    guard (payload["window"] as? NSNumber)?.int32Value == windowID(), payload["closed"] == nil else { return }
    // `ac_tabs_group` reports its own change from inside the call: take events on the next turn, newest only.
    let first = pending == nil
    pending = payload
    guard first else { return }
    DispatchQueue.main.async { [weak self] in
      guard let self, let payload = self.pending else { return }
      self.pending = nil
      self.merge(payload)
    }
  }

  private func merge(_ payload: [String: Any]) {
    var tabs: [Int: String] = [:]
    for tab in payload["tabs"] as? [[String: Any]] ?? [] {
      if let id = (tab["tab"] as? NSNumber)?.intValue, let group = tab["group"] as? String, !group.isEmpty { tabs[id] = group }
    }
    var groups: [String: Look] = [:]
    for group in payload["groups"] as? [[String: Any]] ?? [] {
      guard let id = group["id"] as? String else { continue }
      groups[id] = Look(title: group["title"] as? String ?? "", color: group["color"] as? String ?? "grey",
                        collapsed: group["collapsed"] as? Bool ?? false)
    }
    let state = state()
    var adopted = false
    func folder(_ token: String) -> SidebarEntry? { state.todayFolders.first { $0.groupToken == token } }

    // Groups that went away (the last tab left or closed): their folders are plain folders until a tab opens.
    for folder in state.todayFolders {
      if let token = folder.groupToken, groups[token] == nil, seenGroups[token] != nil { folder.groupToken = nil }
    }
    // A look changed in Chrome (an extension's `tabGroups.update`): the folder takes it.
    made = made.filter { Date().timeIntervalSince($0.value.at) < Self.settleTime }
    for (token, look) in groups where seenGroups[token] != look {
      guard let folder = folder(token), Self.look(of: folder) != look else { continue }
      if let mine = made[token], mine.look != look { continue }
      folder.title = look.title
      if FolderLook.chromeColor(folder.color) != look.color { folder.color = FolderLook.rayColor(chrome: look.color) }
      folder.isOpen = !look.collapsed
      adopted = true
    }
    // Tabs that joined or left a group in Chrome.
    for entry in state.today where !entry.isFolder && entry.isLive {
      let id = Int(entry.tab!.tabId)
      let now = tabs[id], before = seenTabs[id]
      guard now != before else { continue }
      if let now, !released.contains(now) {
        let target = folder(now) ?? makeFolder(now, look: groups[now], at: entry, in: state)
        if entry.parentID != target.id {
          entry.parentID = target.id
          adopted = true
        }
      } else if now == nil, let parent = entry.parentID, state.entry(id: parent)?.groupToken == before {
        entry.parentID = nil
        adopted = true
      }
    }
    seenTabs = tabs
    seenGroups = groups
    released.formIntersection(groups.keys)
    if adopted {
      state.normalizeToday()
      onAdopt?("tabGroups")
    } else {
      push()
    }
  }

  private func makeFolder(_ token: String, look: Look?, at entry: SidebarEntry, in state: SidebarState) -> SidebarEntry {
    let folder = SidebarEntry.folder(look?.title ?? "", in: nil)
    folder.color = FolderLook.rayColor(chrome: look?.color ?? "grey")
    folder.isOpen = !(look?.collapsed ?? false)
    folder.groupToken = token
    state.today.insert(folder, at: state.today.firstIndex { $0 === entry } ?? 0)
    return folder
  }

  // MARK: To Chrome

  /// Makes Chrome's groups match the Today folders: a group for each folder with open tabs, its open tabs in it and
  /// no others, its look. Cheap when nothing differs; called after every change of the sidebar.
  func push() {
    let window = windowID()
    guard window >= 0 else { return }
    let state = state()
    var claimed = Set<Int>()
    for folder in state.todayFolders {
      let members = state.today.filter { $0.parentID == folder.id && $0.isLive }.map { Int($0.tab!.tabId) }
      claimed.formUnion(members)
      let look = Self.look(of: folder)
      if let token = folder.groupToken {
        // Made, and Chrome's event not merged yet: wait for it.
        guard let now = seenGroups[token] else { continue }
        let missing = members.filter { seenTabs[$0] != token }
        if !missing.isEmpty || now != look {
          group(window, tabs: missing, token: token, look: now != look ? look : nil)
        }
      } else if !members.isEmpty {
        group(window, tabs: members, token: "new", look: look) { [weak self] token in
          folder.groupToken = token
          self?.made[token] = (look, Date())
        }
      }
    }
    let strays = seenTabs.keys.filter { id in
      !claimed.contains(id) && state.allEntries.contains { $0.isLive && Int($0.tab!.tabId) == id }
    }
    if !strays.isEmpty { group(window, tabs: strays.sorted(), token: "", look: nil) }
  }

  /// A Today folder leaving Today (pinned, deleted): its group is taken apart now, so the event that follows isn't
  /// read as a new group to adopt.
  func release(_ folder: SidebarEntry) {
    guard let token = folder.groupToken else { return }
    folder.groupToken = nil
    released.insert(token)
    let tabs = seenTabs.filter { $0.value == token }.keys.sorted()
    let window = windowID()
    if window >= 0, !tabs.isEmpty { group(window, tabs: tabs, token: "", look: nil) }
  }

  private func group(_ window: Int32, tabs: [Int], token: String, look: Look?, made: ((String) -> Void)? = nil) {
    var args: [String: Any] = ["window": Int(window), "tabs": tabs, "group": token]
    if let look {
      args["title"] = look.title
      args["color"] = look.color
      args["collapsed"] = look.collapsed
    }
    EngineCalls.call("ac_tabs_group", profile: profile, args: args) { reply in
      if let token = reply?["group"] as? String, !token.isEmpty { made?(token) }
    }
  }
}
