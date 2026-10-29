import AppKit

/// Which of a tab's loads the address field draws, and how far along. One main-frame navigation, one sweep.
///
/// Chrome counts a tab as loading while any frame loads (an iframe, a same-document navigation), and puts its
/// progress back to 0.1 whenever one starts. Dia, like Chrome's own tab throbber (`ShouldShowLoadingUI`), shows only
/// a main-frame navigation to a new document, once: a reload of an app that loads frames afterwards sweeps once.
/// The engine reports `loading` and `progress` only, so Ray tells the loads apart itself. A load gets a sweep when
/// the user started a navigation from Ray (address, reload, back, forward: `userReload()` and the rest), when the
/// tab hasn't shown a page yet, or when a new document commits mid-load (a link the page followed). Within a sweep
/// progress never goes back, and a sweep that reaches the end is done even if frames are still loading.
final class LoadSweeps {
  struct Sweep: Equatable {
    var running = false
    /// 0.1...1, never lower than it was earlier in the same sweep.
    var progress = 0.0
    /// Sweeps this tab has started, for the state log.
    var count = 0
  }

  static let shared = LoadSweeps()
  /// Where a sweep starts: Chrome's own first step (Ardia's bar starts at 8%).
  static let minimum = 0.1

  private struct Entry {
    var sweep = Sweep()
    var loading = false
    /// A navigation the user started from Ray is on its way.
    var owed = false
    /// The tab has committed a document (until then any load is its first page).
    var committed = false
  }

  private var entries: [Int32: Entry] = [:]

  func sweep(for tab: RayCoreTab) -> Sweep { entries[tab.tabId]?.sweep ?? Sweep() }

  /// The user started a navigation in this tab: its load sweeps from the start, before the page commits. A sweep
  /// that's already running carries on (no restart from the left).
  func expect(_ tab: RayCoreTab) {
    edit(tab) { entry in
      guard !entry.sweep.running else { return }
      if entry.loading { start(&entry) } else { entry.owed = true }
    }
  }

  func loadingChanged(_ tab: RayCoreTab) {
    let now = tab.loading
    edit(tab) { entry in
      if now, !entry.loading, entry.owed || !entry.committed { start(&entry) }
      if !now {
        entry.sweep.running = false
        entry.owed = false
      }
      entry.loading = now
    }
  }

  func progressChanged(_ tab: RayCoreTab) {
    let reported = min(1, tab.progress)
    edit(tab) { entry in
      guard entry.sweep.running else { return }
      entry.sweep.progress = max(entry.sweep.progress, reported)
      // At the end: the field runs it out and fades while any frames left finish quietly.
      if entry.sweep.progress >= 0.999 { entry.sweep.running = false }
    }
  }

  /// A main-frame document committed. Mid-sweep it's the same navigation; otherwise it's one the page started.
  func documentCommitted(_ tab: RayCoreTab) {
    edit(tab) { entry in
      entry.committed = true
      if entry.loading, !entry.sweep.running { start(&entry) }
    }
  }

  func forget(_ tab: RayCoreTab) { entries[tab.tabId] = nil }

  private func start(_ entry: inout Entry) {
    entry.sweep = Sweep(running: true, progress: Self.minimum, count: entry.sweep.count + 1)
    entry.owed = false
  }

  private func edit(_ tab: RayCoreTab, _ body: (inout Entry) -> Void) {
    var entry = entries[tab.tabId] ?? Entry()
    body(&entry)
    entries[tab.tabId] = entry
  }
}

/// Navigations the user starts from Ray's own controls. They go through here so their load sweeps from the start.
extension RayCoreTab {
  func userReload() {
    LoadSweeps.shared.expect(self)
    reload()
  }

  func userReloadIgnoringCache() {
    LoadSweeps.shared.expect(self)
    reloadIgnoringCache()
  }

  func userGoBack() {
    LoadSweeps.shared.expect(self)
    goBack()
  }

  func userGoForward() {
    LoadSweeps.shared.expect(self)
    goForward()
  }

  func userLoad(_ url: String) {
    LoadSweeps.shared.expect(self)
    loadURL(url, userInitiated: true)
  }
}
