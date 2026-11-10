import AppKit

/// Settings › Appearance's own content: one live picture on top of the Address bar card, showing both "Show only the
/// site in the address bar" and "Show the address bar above the page" as they are now.
final class AppearancePaneContent: SettingsPaneContent {
  func picture(for key: AnySettingKey) -> NSView? {
    guard key === AnySettingKey.minimalURL else { return nil }
    return SettingsLivePicture(size: NSSize(width: 232, height: 144), following: [.minimalURL, .pageAddressBar]) { mini in
      mini.showsAddressBar = RaySettings.shared[.pageAddressBar]
      mini.minimalAddress = RaySettings.shared[.minimalURL]
    }
  }
}
