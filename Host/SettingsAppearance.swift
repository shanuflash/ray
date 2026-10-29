import AppKit

/// Settings › Appearance's own content: live pictures beside "Show only the site in the address bar" and "Show the
/// address bar above the page".
final class AppearancePaneContent: SettingsPaneContent {
  func picture(for key: AnySettingKey) -> NSView? {
    if key === AnySettingKey.minimalURL {
      return SettingsLivePicture(following: [.minimalURL]) { mini in
        mini.showsAddressBar = true
        mini.minimalAddress = RaySettings.shared[.minimalURL]
      }
    }
    if key === AnySettingKey.pageAddressBar {
      return SettingsLivePicture(following: [.pageAddressBar, .minimalURL]) { mini in
        mini.showsAddressBar = RaySettings.shared[.pageAddressBar]
        mini.minimalAddress = RaySettings.shared[.minimalURL]
      }
    }
    return nil
  }
}
