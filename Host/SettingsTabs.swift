import AppKit

/// Settings › Tabs and sidebar's own content: a live picture beside "Open new tabs next to the current one", the new
/// tab highlighted where it lands.
final class TabsPaneContent: SettingsPaneContent {
  func picture(for key: AnySettingKey) -> NSView? {
    guard key === AnySettingKey.newTabNextToActive else { return nil }
    return SettingsLivePicture(following: [.newTabNextToActive]) { mini in
      mini.showsAddressBar = false
      mini.rows = RaySettings.shared[.newTabNextToActive]
        ? [.plain, .active, .new, .plain] : [.new, .plain, .active, .plain]
    }
  }
}
