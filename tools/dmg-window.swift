// The Finder window of Ray's DMG: a background that says how to install and first open Ray, and the .DS_Store that
// gives the window its size, icon view, background and icon spots. Built-in APIs only (no dmgbuild/create-dmg, no
// Finder scripting, which would need Automation permission and open a window). scripts/make-dmg.sh runs it:
//   dmg-window background <dir>             writes <dir>/background.png and background@2x.png (tiffutil joins them)
//   dmg-window layout <volume> <volume name> <app name>
//                                           writes <volume>/.DS_Store, pointing at <volume>/.background/background.tiff
// The .DS_Store format (a "Bud1" buddy allocator holding one B-tree leaf) and the alias record (version 2) follow
// Wim Lewis's notes and Alastair Houghton's ds_store/mac_alias (MIT), which dmgbuild writes the same way.
import AppKit

// MARK: Layout

let windowSize = CGSize(width: 640, height: 420)
let iconSize: CGFloat = 128
/// Icon centres, from the window's top left (what Finder's Iloc holds).
let appSpot = CGPoint(x: 170, y: 150)
let applicationsSpot = CGPoint(x: 470, y: 150)
/// Where Finder mounts the image for the people who open it.
func mountPoint(_ volumeName: String) -> String { "/Volumes/" + volumeName }

// MARK: Background

func drawBackground(scale: CGFloat) -> NSBitmapImageRep {
  let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(windowSize.width * scale), pixelsHigh: Int(windowSize.height * scale),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .calibratedRGB,
    bytesPerRow: 0, bitsPerPixel: 0)!
  rep.size = windowSize
  NSGraphicsContext.saveGraphicsState()
  let context = NSGraphicsContext(bitmapImageRep: rep)!
  NSGraphicsContext.current = context
  // Top-left origin, as Finder's icon spots.
  context.cgContext.translateBy(x: 0, y: windowSize.height)
  context.cgContext.scaleBy(x: 1, y: -1)
  NSGraphicsContext.current = NSGraphicsContext(cgContext: context.cgContext, flipped: true)

  let cg = context.cgContext
  let space = CGColorSpace(name: CGColorSpace.sRGB)!
  func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
  }
  func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(colorsSpace: space, colors: stops.map(\.1) as CFArray, locations: stops.map(\.0))!
  }

  // Dia's lavender, top to bottom. Finder draws the icons' names in black (light mode) or white (dark mode) straight
  // on the picture, so the band under the icons stays at a luminance of about 0.18, where both read at 4.5:1.
  cg.drawLinearGradient(gradient([(0, rgb(0x9A6CF2)), (0.38, rgb(0x8160EE)), (0.6, rgb(0x7558E6)),
                                  (1, rgb(0x3E2A9E))]),
                        start: .zero, end: CGPoint(x: 0, y: windowSize.height), options: [])
  // Light from above: a warm glow behind Ray, a cool one behind Applications, faded out before the names.
  for (centre, color, radius) in [(CGPoint(x: appSpot.x - 20, y: 40), rgb(0xFF8FD8, 0.45), 230.0),
                                  (CGPoint(x: applicationsSpot.x + 40, y: 20), rgb(0x8FE3FF, 0.35), 240.0)] {
    cg.drawRadialGradient(gradient([(0, color), (1, color.copy(alpha: 0)!)]), startCenter: centre, startRadius: 0,
                          endCenter: centre, endRadius: radius, options: [])
  }

  // The move: a swoosh from Ray over to Applications that fades in from its start, with a glow and a few speed
  // marks behind it.
  let start = CGPoint(x: appSpot.x + iconSize / 2 + 26, y: appSpot.y + 8)
  let end = CGPoint(x: applicationsSpot.x - iconSize / 2 - 22, y: applicationsSpot.y + 8)
  let lift = CGPoint(x: (start.x + end.x) / 2, y: appSpot.y - 46)
  let swoosh = CGMutablePath()
  swoosh.move(to: start)
  swoosh.addQuadCurve(to: end, control: lift)
  // The curve's direction at its end, for the head.
  let angle = atan2(end.y - lift.y, end.x - lift.x)
  func head(_ length: CGFloat, spread: CGFloat) -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: end.x - length * cos(angle - spread), y: end.y - length * sin(angle - spread)))
    p.addLine(to: end)
    p.addLine(to: CGPoint(x: end.x - length * cos(angle + spread), y: end.y - length * sin(angle + spread)))
    return p
  }
  let stroke = CGMutablePath()
  stroke.addPath(swoosh.copy(strokingWithWidth: 5, lineCap: .round, lineJoin: .round, miterLimit: 10))
  stroke.addPath(head(17, spread: 0.6).copy(strokingWithWidth: 5, lineCap: .round, lineJoin: .round, miterLimit: 10))
  cg.saveGState()
  cg.setShadow(offset: .zero, blur: 18, color: rgb(0xFFFFFF, 0.9))
  cg.addPath(stroke)
  cg.setFillColor(rgb(0xFFFFFF, 0.35))
  cg.fillPath()
  cg.restoreGState()
  cg.saveGState()
  cg.addPath(stroke)
  cg.clip()
  cg.drawLinearGradient(gradient([(0, rgb(0xFFFFFF, 0)), (0.45, rgb(0xFFFFFF, 0.75)), (1, rgb(0xFFFFFF))]),
                        start: CGPoint(x: start.x - 4, y: 0), end: CGPoint(x: end.x, y: 0), options: [])
  cg.restoreGState()
  for (i, dy) in [-11.0, 0, 11].enumerated() {
    let y = start.y + dy, length: CGFloat = i == 1 ? 22 : 13
    let x = start.x - 9 - length
    cg.saveGState()
    cg.addPath(CGPath(roundedRect: CGRect(x: x, y: y - 1.5, width: length, height: 3), cornerWidth: 1.5,
                      cornerHeight: 1.5, transform: nil))
    cg.clip()
    cg.drawLinearGradient(gradient([(0, rgb(0xFFFFFF, 0)), (1, rgb(0xFFFFFF, 0.55))]),
                          start: CGPoint(x: x, y: 0), end: CGPoint(x: x + length, y: 0), options: [])
    cg.restoreGState()
  }

  let centred = NSMutableParagraphStyle()
  centred.alignment = .center
  let shadow = NSShadow()
  shadow.shadowColor = NSColor(white: 0, alpha: 0.25)
  shadow.shadowOffset = NSSize(width: 0, height: -1)
  shadow.shadowBlurRadius = 6
  func line(_ text: String, top: CGFloat, size: CGFloat, weight: NSFont.Weight, alpha: CGFloat, kern: CGFloat = 0) {
    NSAttributedString(string: text, attributes: [
      .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: NSColor(white: 1, alpha: alpha),
      .paragraphStyle: centred, .shadow: shadow, .kern: kern,
    ]).draw(in: CGRect(x: 24, y: top, width: windowSize.width - 48, height: size * 1.6))
  }
  line("Drag Ray to Applications", top: 254, size: 20, weight: .bold, alpha: 1, kern: -0.2)

  // The first open, on a frosted card.
  let card = CGRect(x: 28, y: 298, width: windowSize.width - 56, height: 92)
  let cardPath = CGPath(roundedRect: card, cornerWidth: 16, cornerHeight: 16, transform: nil)
  cg.addPath(cardPath)
  cg.setFillColor(rgb(0xFFFFFF, 0.12))
  cg.fillPath()
  cg.addPath(cardPath)
  cg.setStrokeColor(rgb(0xFFFFFF, 0.28))
  cg.setLineWidth(1)
  cg.strokePath()
  line("OPENING IT THE FIRST TIME", top: card.minY + 13, size: 10.5, weight: .bold, alpha: 0.7, kern: 1.2)
  line("macOS 14: right-click Ray in Applications, then Open", top: card.minY + 36, size: 13, weight: .medium,
       alpha: 0.95)
  line("macOS 15+: open Ray once, then System Settings › Privacy & Security › Open Anyway",
       top: card.minY + 58, size: 13, weight: .medium, alpha: 0.95)

  NSGraphicsContext.restoreGraphicsState()
  return rep
}

func writeBackground(to dir: String) throws {
  for (scale, name) in [(1.0, "background.png"), (2.0, "background@2x.png")] {
    let png = drawBackground(scale: scale).representation(using: .png, properties: [:])!
    try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
  }
}

// MARK: Alias

/// Big-endian byte building.
struct Bytes {
  var data = Data()
  mutating func u8(_ v: UInt8) { data.append(v) }
  mutating func u16(_ v: UInt16) { withUnsafeBytes(of: v.bigEndian) { data.append(contentsOf: $0) } }
  mutating func u32(_ v: UInt32) { withUnsafeBytes(of: v.bigEndian) { data.append(contentsOf: $0) } }
  mutating func raw(_ d: Data) { data.append(d) }
  mutating func zeros(_ n: Int) { data.append(Data(count: n)) }
  /// A Pascal string in a fixed field of `size` bytes (length byte included), Mac Roman.
  mutating func pascal(_ s: String, size: Int) {
    let bytes = Array((s.data(using: .macOSRoman, allowLossyConversion: true) ?? Data()).prefix(size - 1))
    u8(UInt8(bytes.count))
    data.append(contentsOf: bytes)
    zeros(size - 1 - bytes.count)
  }
  mutating func utf16(_ s: String) { for unit in s.utf16 { u16(unit) } }
}

/// Seconds from 1904 (HFS) for a date.
func hfsSeconds(_ date: Date) -> UInt32 { UInt32(clamping: Int64(date.timeIntervalSince1970) + 2_082_844_800) }

/// A version 2 alias record for `file` on the volume mounted at `volume` (HFS+), as the Alias Manager made them: the
/// volume by name and creation date, the file by CNIDs and by path, so it resolves wherever the image is mounted.
func alias(of file: String, volume: String, volumeName: String) throws -> Data {
  let fm = FileManager.default
  let fileAttributes = try fm.attributesOfItem(atPath: file)
  let parent = (file as NSString).deletingLastPathComponent
  let parentAttributes = try fm.attributesOfItem(atPath: parent)
  let volumeAttributes = try fm.attributesOfItem(atPath: volume)
  let fileName = (file as NSString).lastPathComponent
  let parentName = (parent as NSString).lastPathComponent
  let relative = String(file.dropFirst(volume.count))  // "/.background/background.tiff"
  func cnid(_ a: [FileAttributeKey: Any]) -> UInt32 { UInt32(truncatingIfNeeded: (a[.systemFileNumber] as! NSNumber).uint64Value) }
  func created(_ a: [FileAttributeKey: Any]) -> UInt32 { hfsSeconds(a[.creationDate] as! Date) }

  var b = Bytes()
  b.raw(Data(count: 4))  // application-specific
  b.u16(0)  // length, set below
  b.u16(2)  // version
  b.u16(0)  // kind: file
  b.pascal(volumeName, size: 28)
  b.u32(created(volumeAttributes))
  b.raw("H+".data(using: .ascii)!)
  b.u16(5)  // ejectable disk
  b.u32(cnid(parentAttributes))
  b.pascal(fileName, size: 64)
  b.u32(cnid(fileAttributes))
  b.u32(created(fileAttributes))
  b.zeros(8)  // type and creator
  b.u16(0xFFFF); b.u16(0xFFFF)  // levels from and to
  b.zeros(4 + 2 + 10)  // volume attributes, filesystem id, reserved

  func tag(_ t: UInt16, _ value: Data) {
    b.u16(t); b.u16(UInt16(value.count)); b.raw(value)
    if value.count % 2 == 1 { b.u8(0) }
  }
  func unicode(_ s: String) -> Data { var u = Bytes(); u.u16(UInt16(s.utf16.count)); u.utf16(s); return u.data }
  tag(0, parentName.data(using: .macOSRoman, allowLossyConversion: true)!)  // parent folder's name
  var cnids = Bytes(); cnids.u32(cnid(parentAttributes))
  tag(1, cnids.data)  // CNIDs of the folders up to the volume
  tag(2, (volumeName + relative.replacingOccurrences(of: "/", with: ":")).data(using: .macOSRoman, allowLossyConversion: true)!)
  tag(14, unicode(fileName))
  tag(15, unicode(volumeName))
  tag(18, relative.data(using: .utf8)!)  // POSIX path within the volume
  tag(19, mountPoint(volumeName).data(using: .utf8)!)  // the volume's mount point
  b.u16(0xFFFF); b.u16(0)  // end

  var record = b.data
  let length = UInt16(record.count).bigEndian
  withUnsafeBytes(of: length) { record.replaceSubrange(4..<6, with: $0) }
  return record
}

/// Resolves an alias record the way Finder will (through a bookmark) and returns the path it finds.
func resolve(_ record: Data) -> String? {
  guard let bookmark = CFURLCreateBookmarkDataFromAliasRecord(nil, record as CFData)?.takeRetainedValue() else { return nil }
  var stale = false
  return (try? URL(resolvingBookmarkData: bookmark as Data, options: [.withoutUI, .withoutMounting],
                   bookmarkDataIsStale: &stale))?.path
}

// MARK: DS_Store

enum Value {
  case blob(Data), long(UInt32), type(String), bool(Bool)
}

struct Record {
  let name: String, code: String, value: Value
  func write(to b: inout Bytes) {
    b.u32(UInt32(name.utf16.count)); b.utf16(name)
    b.raw(code.data(using: .ascii)!)
    switch value {
    case .blob(let d): b.raw("blob".data(using: .ascii)!); b.u32(UInt32(d.count)); b.raw(d)
    case .long(let v): b.raw("long".data(using: .ascii)!); b.u32(v)
    case .type(let t): b.raw("type".data(using: .ascii)!); b.raw(t.data(using: .ascii)!)
    case .bool(let v): b.raw("bool".data(using: .ascii)!); b.u8(v ? 1 : 0)
    }
  }
}

func iconSpot(_ p: CGPoint) -> Value {
  var b = Bytes()
  b.u32(UInt32(p.x)); b.u32(UInt32(p.y))
  b.raw(Data([0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0, 0]))
  return .blob(b.data)
}

func plist(_ object: [String: Any]) throws -> Data {
  try PropertyListSerialization.data(fromPropertyList: object, format: .binary, options: 0)
}

/// One leaf of records in a buddy-allocated file: header (32 bytes at 0), the DSDB tree header (32 at 32), the
/// allocator's own block (2 KB at 2 KB) and the leaf (4 KB at 4 KB), every other buddy on the free lists. Offsets are
/// from byte 4 of the file.
func dsStore(_ unsorted: [Record]) -> Data {
  let records = unsorted.sorted {
    let a = $0.name.lowercased(), b = $1.name.lowercased()
    return a != b ? Array(a.utf16).lexicographicallyPrecedes(Array(b.utf16)) : $0.code < $1.code
  }
  let (dsdbOffset, rootOffset, leafOffset) = (32, 2048, 4096)
  let (rootSize, leafSize) = (2048, 4096)

  var leaf = Bytes()
  leaf.u32(0)  // no children: a leaf
  leaf.u32(UInt32(records.count))
  for r in records { r.write(to: &leaf) }
  precondition(leaf.data.count <= leafSize, "the .DS_Store records outgrew one node")

  var dsdb = Bytes()
  dsdb.u32(2)  // the leaf's block number
  dsdb.u32(0)  // levels above the leaf
  dsdb.u32(UInt32(records.count))
  dsdb.u32(1)  // nodes
  dsdb.u32(0x1000)  // page size

  var root = Bytes()
  root.u32(3); root.u32(0)  // block count, unknown
  root.u32(UInt32(rootOffset | 11)); root.u32(UInt32(dsdbOffset | 5)); root.u32(UInt32(leafOffset | 12))
  root.zeros(4 * (256 - 3))  // the address table is padded to 256 entries
  root.u32(1); root.u8(4); root.raw("DSDB".data(using: .ascii)!); root.u32(1)  // table of contents
  for width in 0..<32 {  // free lists by log2 of the size
    let free: [Int]
    switch width {
    case 6...10: free = [1 << width]  // 64 … 1024: what's left of the first 2 KB
    case 13...30: free = [1 << width]  // the upper buddies of everything above the used 8 KB
    default: free = []
    }
    root.u32(UInt32(free.count))
    for offset in free { root.u32(UInt32(offset)) }
  }
  precondition(root.data.count <= rootSize)

  var file = Data(count: 4 + 8192)
  var header = Bytes()
  header.u32(1); header.raw("Bud1".data(using: .ascii)!)
  header.u32(UInt32(rootOffset)); header.u32(UInt32(rootSize)); header.u32(UInt32(rootOffset))
  header.raw(Data([0x00, 0x00, 0x10, 0x0C, 0x00, 0x00, 0x00, 0x87, 0x00, 0x00, 0x20, 0x0B, 0x00, 0x00, 0x00, 0x00]))
  file.replaceSubrange(0..<header.data.count, with: header.data)
  file.replaceSubrange((4 + dsdbOffset)..<(4 + dsdbOffset + dsdb.data.count), with: dsdb.data)
  file.replaceSubrange((4 + rootOffset)..<(4 + rootOffset + root.data.count), with: root.data)
  file.replaceSubrange((4 + leafOffset)..<(4 + leafOffset + leaf.data.count), with: leaf.data)
  return file
}

func writeLayout(volume: String, volumeName: String, appName: String) throws {
  let background = volume + "/.background/background.tiff"
  let record = try alias(of: background, volume: volume, volumeName: volumeName)
  // The alias must find the background on this volume; Finder resolves it the same way when the image is opened.
  guard let found = resolve(record), (found as NSString).resolvingSymlinksInPath
    == (background as NSString).resolvingSymlinksInPath
  else {
    throw NSError(domain: "dmg-window", code: 1, userInfo: [NSLocalizedDescriptionKey:
      "the background's alias doesn't resolve to \(background) (got \(resolve(record) ?? "nothing"))"])
  }
  let window: [String: Any] = [
    "ContainerShowSidebar": false, "ShowPathbar": false, "ShowSidebar": false, "ShowStatusBar": false,
    "ShowTabView": false, "ShowToolbar": false, "SidebarWidth": 0,
    "WindowBounds": "{{200, 160}, {\(Int(windowSize.width)), \(Int(windowSize.height))}}",
  ]
  let iconView: [String: Any] = [
    "arrangeBy": "none", "backgroundColorBlue": 1.0, "backgroundColorGreen": 1.0, "backgroundColorRed": 1.0,
    "backgroundImageAlias": record, "backgroundType": 2, "gridOffsetX": 0.0, "gridOffsetY": 0.0,
    "gridSpacing": 100.0, "iconSize": Double(iconSize), "labelOnBottom": true, "showIconPreview": true,
    "showItemInfo": false, "textSize": 13.0, "viewOptionsVersion": 1,
  ]
  let store = dsStore([
    Record(name: ".", code: "bwsp", value: .blob(try plist(window))),
    Record(name: ".", code: "icvp", value: .blob(try plist(iconView))),
    Record(name: ".", code: "vSrn", value: .long(1)),
    Record(name: ".", code: "vstl", value: .type("icnv")),
    Record(name: appName, code: "Iloc", value: iconSpot(appSpot)),
    Record(name: "Applications", code: "Iloc", value: iconSpot(applicationsSpot)),
  ])
  try store.write(to: URL(fileURLWithPath: volume + "/.DS_Store"))
}

// MARK: Main

let args = CommandLine.arguments
do {
  switch (args.count, args.count > 1 ? args[1] : "") {
  case (3, "background"): try writeBackground(to: args[2])
  case (5, "layout"): try writeLayout(volume: args[2], volumeName: args[3], appName: args[4])
  default:
    FileHandle.standardError.write("usage: dmg-window background <dir> | layout <volume> <volume name> <app name>\n".data(using: .utf8)!)
    exit(2)
  }
} catch {
  FileHandle.standardError.write("dmg-window: \(error.localizedDescription)\n".data(using: .utf8)!)
  exit(1)
}
