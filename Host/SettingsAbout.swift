import AppKit

/// Settings › About Ray: the version and the engine, in the window's own row style. The example of a pane with
/// content of its own: this file plus one line in `SettingsPanes.make(_:)`.
final class AboutPaneContent: SettingsPaneContent {
  var hasContent: Bool { true }

  func sections() -> [SettingsSection] {
    let info = Bundle.main.infoDictionary ?? [:]
    let version = info["CFBundleShortVersionString"] as? String ?? "?"
    let build = info["CFBundleVersion"] as? String ?? "?"
    let engine = RayCoreEngine.shared?.chromiumVersion ?? ""
    var rows = [SettingsRowView(title: "Version", detail: "", control: SettingsValueLabel("\(version) (\(build))"))]
    if !engine.isEmpty {
      rows.append(SettingsRowView(
        title: "Engine", detail: "Chromium without Google.", control: SettingsValueLabel(engine)))
    }
    return [
      SettingsSection(
        id: "about.version", title: "Ray", place: .top, view: SettingsRowList(rows: rows),
        search: [
          SettingsSearchEntry(title: "Version", detail: "Ray's version and build", keywords: ["about", "build", "release"]),
          SettingsSearchEntry(title: "Engine", detail: "The Chromium version under Ray", keywords: ["chromium", "chrome"]),
        ])
    ]
  }
}
