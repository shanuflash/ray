import AppKit

/// Ray's Dock tile plug-in (Contents/PlugIns/RayDockTile.docktileplugin, the app's `NSDockTilePlugIn` key). While Ray
/// isn't running the Dock asks this bundle what to draw, so the app icon the user chose in Settings › Appearance stays
/// in the Dock after quitting. The choice is the app's own preference (`appIcon`, written by Host/AppIcon.swift as
/// the icon's name); the artwork is the app's Resources/AppIcons/<name>.png. While Ray runs, `applicationIconImage`
/// does the same and this only follows its notice (named after the bundle id, so a test build never reaches the real
/// plug-in). The default icon is the bundle's own: no content view. Never writes anything.
@objc(RayDockTilePlugIn)
final class RayDockTilePlugIn: NSObject, NSDockTilePlugIn {
  private var dockTile: NSDockTile?
  private var observer: NSObjectProtocol?

  /// The app: this bundle is <app>/Contents/PlugIns/RayDockTile.docktileplugin.
  private lazy var app: Bundle? = {
    let url = Bundle(for: RayDockTilePlugIn.self).bundleURL
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return Bundle(url: url)
  }()

  func setDockTile(_ dockTile: NSDockTile?) {
    if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
    observer = nil
    self.dockTile = dockTile
    guard dockTile != nil, let bundleId = app?.bundleIdentifier else { return }
    observer = DistributedNotificationCenter.default().addObserver(
      forName: Notification.Name("\(bundleId).appIconChanged"), object: nil, queue: .main
    ) { [weak self] note in self?.show(note.userInfo?["icon"] as? String) }
    CFPreferencesAppSynchronize(bundleId as CFString)
    show(CFPreferencesCopyAppValue("appIcon" as CFString, bundleId as CFString) as? String)
  }

  private func show(_ name: String?) {
    guard let dockTile else { return }
    // Only a plain icon name: it becomes a file name in the app's Resources.
    if let name, name != "crt", !name.isEmpty, name.allSatisfy({ $0.isLetter || $0 == "-" }),
       let url = app?.url(forResource: name, withExtension: "png", subdirectory: "AppIcons"),
       let artwork = NSImage(contentsOf: url) {
      let view = NSImageView(frame: NSRect(origin: .zero, size: dockTile.size))
      view.image = AppIconCanvas.dockImage(artwork: artwork)
      view.imageScaling = .scaleProportionallyUpOrDown
      dockTile.contentView = view
    } else {
      dockTile.contentView = nil
    }
    dockTile.display()
  }

  deinit {
    if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
  }
}
