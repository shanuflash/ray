import AppKit

/// An alternate app icon as the Dock draws it. The PNGs `scripts/build-app.sh` exports (Contents/Resources/AppIcons)
/// are the artwork alone, edge to edge; the Dock wants macOS's icon grid (the tile 824 of 1024, centred, with a soft
/// shadow under it), as an icns would have it. Compiled into the app (Host/AppIcon.swift) and into the Dock tile
/// plug-in (DockTile/), so both draw the same picture; nothing here but AppKit.
enum AppIconCanvas {
  /// The picture the Dock shows for `artwork`: `side` points square.
  static func dockImage(artwork: NSImage, side: CGFloat = 512) -> NSImage {
    NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
      let tile = side * 824 / 1024
      let rect = NSRect(x: (side - tile) / 2, y: (side - tile) / 2, width: tile, height: tile)
      NSGraphicsContext.saveGraphicsState()
      let shadow = NSShadow()
      shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
      shadow.shadowOffset = NSSize(width: 0, height: -side * 0.01)
      shadow.shadowBlurRadius = side * 0.02
      shadow.set()
      artwork.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
      NSGraphicsContext.restoreGraphicsState()
      return true
    }
  }
}
