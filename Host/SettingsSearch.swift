import AppKit

/// Something Settings can show: a pane, a setting's row or a pane's own section. The window's search lists these, and
/// the command bar offers them as "Settings: …" rows; choosing one opens the window at its pane, scrolls to it and
/// flashes it.
struct SettingsTarget {
  enum Kind: String {
    case pane, setting, section
  }

  let kind: Kind
  let pane: SettingPane
  /// The setting's id or the section's id (nil for a pane).
  let anchor: String?
  let title: String
  /// Where it is: the pane, then the group ("Appearance › Address bar").
  let caption: String
  let detail: String
  let keywords: [String]
  /// Its group's title, for search.
  let group: String

  var id: String { anchor ?? "pane:\(pane.rawValue)" }
}

/// Settings search, after Ardia's (`searchMatch.ts`): every typed word must match a word of the title, keywords,
/// group, pane name or description (whole, plural, a word start, or inside a word from three letters), each field
/// weighted; the title (and the whole phrase in it) counts most. Only what the window shows is searched: shown panes,
/// rows whose feature is built (all in test builds) and panes' own sections.
enum SettingsSearch {
  /// Everything searchable now, in sidebar order.
  static func targets() -> [SettingsTarget] {
    var out: [SettingsTarget] = []
    for pane in SettingPane.shown {
      out.append(SettingsTarget(
        kind: .pane, pane: pane, anchor: nil, title: pane.title, caption: pane.section.title ?? "Settings",
        detail: pane.subtitle, keywords: [], group: ""))
      for section in SettingsPanes.sections(for: pane) {
        for entry in section.search {
          out.append(SettingsTarget(
            kind: .section, pane: pane, anchor: section.id, title: entry.title,
            caption: [pane.title, section.title].compactMap { $0 }.joined(separator: " › "), detail: entry.detail,
            keywords: entry.keywords, group: section.title ?? ""))
        }
      }
      for key in pane.shownSettings {
        out.append(SettingsTarget(
          kind: .setting, pane: pane, anchor: key.id, title: key.ui.title,
          caption: [pane.title, key.ui.group.title].compactMap { $0 }.joined(separator: " › "), detail: key.ui.detail + " " + key.ui.about,
          keywords: key.ui.keywords, group: key.ui.group.title ?? ""))
      }
    }
    return out
  }

  /// Lowercased words without accents or apostrophes; ⌘ ⌥ ⇧ ⌃ count as letters.
  static func normalize(_ text: String) -> String {
    let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
      .replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "’", with: "")
    var out = ""
    var space = false
    for scalar in folded.unicodeScalars {
      if CharacterSet.alphanumerics.contains(scalar) || "⌘⌥⇧⌃".unicodeScalars.contains(scalar) {
        out.unicodeScalars.append(scalar)
        space = false
      } else if !space {
        out.append(" ")
        space = true
      }
    }
    return out.trimmingCharacters(in: .whitespaces)
  }

  private static func words(_ text: String) -> [String] { normalize(text).split(separator: " ").map(String.init) }

  /// How well one typed word matches one word: whole 1, plural 0.95, its start 0.85, inside it (3+ letters) 0.45.
  private static func quality(_ token: String, _ word: String) -> Double {
    if word == token { return 1 }
    if word == token + "s" || token == word + "s" || word == token + "es" || token == word + "es" { return 0.95 }
    if word.hasPrefix(token) { return 0.85 }
    if token.count >= 3, word.contains(token) { return 0.45 }
    return 0
  }

  private static func score(_ target: SettingsTarget, tokens: [String], phrase: String) -> Double {
    let fields: [(weight: Double, words: [String])] = [
      (10, words(target.title)), (8, target.keywords.flatMap(words)), (5, words(target.group)),
      (4, words(target.pane.title)), (2, words(target.detail)),
    ]
    var total = 0.0
    for token in tokens {
      var best = 0.0
      for field in fields {
        for word in field.words { best = max(best, field.weight * quality(token, word)) }
      }
      if best == 0 { return 0 }
      total += best
    }
    let title = normalize(target.title)
    let pane = normalize(target.pane.title)
    if pane == phrase || pane.hasPrefix(phrase) { total += 6 }
    if title == phrase { total += 12 }
    else if title.hasPrefix(phrase) { total += 8 }
    else if " \(title) ".contains(" \(phrase) ") { total += 5 }
    else if tokens.count > 1, title.contains(phrase) { total += 3 }
    else if " \(normalize(target.keywords.joined(separator: " "))) ".contains(" \(phrase) ") { total += 4 }
    return total / Double(tokens.count) + (tokens.count > 1 ? total / 40 : 0)
  }

  /// The targets `query` finds, best first within each pane, the panes in the order of their best hit.
  static func search(_ query: String) -> [SettingsTarget] {
    let phrase = normalize(query)
    let tokens = phrase.split(separator: " ").map(String.init)
    guard !tokens.isEmpty else { return [] }
    var hits: [(target: SettingsTarget, score: Double)] = []
    for target in targets() {
      let value = score(target, tokens: tokens, phrase: phrase)
      if value >= 1.8 { hits.append((target, value)) }
    }
    hits.sort { $0.score > $1.score }
    let top = hits.first?.score ?? 0
    hits = hits.filter { $0.score >= top * 0.3 }
    var panes: [SettingPane] = []
    for hit in hits where !panes.contains(hit.target.pane) { panes.append(hit.target.pane) }
    return panes.flatMap { pane in hits.filter { $0.target.pane == pane }.map(\.target) }.prefix(40).map { $0 }
  }

  // MARK: Command bar

  /// The command bar's "Settings: …" rows for `query`, matched as `BarActions` matches menu commands (two characters
  /// at least, every typed word the start of a word of a name, in order): a setting by its title or keywords, a pane
  /// by its name, either after "settings". `exact` only when the query names one in full after "settings"
  /// ("settings theme colour"), the one case where a row may lead (see `Suggestions.build`).
  static func barMatches(_ query: String) -> [(target: SettingsTarget, exact: Bool)] {
    let typed = BarActions.words(query)
    let joined = typed.joined(separator: " ")
    guard joined.count >= 2 else { return [] }
    var hits: [(target: SettingsTarget, exact: Bool, score: Int)] = []
    for target in targets() {
      let title = BarActions.words(target.title)
      var names = [["settings"] + title, title]
      if target.kind == .setting { names += target.keywords.map(BarActions.words) }
      var best: Int?
      var exact = false
      for (index, name) in names.enumerated() {
        guard var score = BarActions.score(typed, name) else { continue }
        if index == 0, name.joined(separator: " ") == joined { exact = true; score += 1000 }
        if index > 1 { score -= 5 }  // a keyword after the title
        if target.kind == .pane { score += 3 }  // a pane before its own rows
        best = max(best ?? score, score)
      }
      if let best { hits.append((target, exact, best)) }
    }
    let limit = joined.count < 4 ? 1 : 2
    return hits.sorted { $0.score > $1.score }.prefix(limit).map { ($0.target, $0.exact) }
  }
}
