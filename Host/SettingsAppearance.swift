import AppKit

/// Settings › Appearance's own content: a live picture beside "Show only the site in the address bar".
final class AppearancePaneContent: SettingsPaneContent {
  func picture(for key: AnySettingKey) -> NSView? {
    guard key === AnySettingKey.minimalURL else { return nil }
    return SettingsLivePicture(following: [.minimalURL]) { mini in
      mini.showsAddressBar = true
      mini.minimalAddress = RaySettings.shared[.minimalURL]
    }
  }
}
