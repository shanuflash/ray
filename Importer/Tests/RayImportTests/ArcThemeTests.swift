import Foundation
import XCTest
@testable import RayImport

final class ArcThemeTests: XCTestCase {
  private func firstBaseRed(_ theme: Any) -> Double? {
    var node: Any? = theme
    for key in ["background", "single", "_0", "style", "color", "_0", "blendedGradient", "_0", "baseColors"] {
      node = (node as? [String: Any])?[key]
    }
    return ((node as? [[String: Any]])?.first?["red"] as? NSNumber)?.doubleValue
  }

  func testEachSpaceCarriesItsWindowThemeVerbatim() throws {
    let sidebar = try ArcSidebar.parse(Data(contentsOf: Fixtures.support("Arc/StorableSidebar.json")))
    let byId = Dictionary(uniqueKeysWithValues: sidebar.spaces.map { ($0.id, $0) })

    for (space, fixture) in [("S-PERSONAL", "green-pink"), ("S-WORK", "blue-teal")] {
      let original = try JSONSerialization.jsonObject(with: Data(contentsOf: Fixtures.url("arc-themes/\(fixture).json")))
      let expected = try JSONSerialization.data(withJSONObject: original, options: [.sortedKeys])
      let carried = try XCTUnwrap(byId[space]?.theme)
      XCTAssertEqual(carried, String(data: expected, encoding: .utf8), space)
      let decoded = try JSONSerialization.jsonObject(with: Data(carried.utf8))
      XCTAssertEqual(firstBaseRed(decoded), firstBaseRed(original), space)
      XCTAssertNotNil(firstBaseRed(original), space)
    }
    XCTAssertNil(byId["S-UNTITLED"]?.theme)
    XCTAssertEqual(byId["S-WORK"]?.colors?.count, 2)
  }

  func testDiscoverySummariesListTheThemes() throws {
    let arc = try XCTUnwrap(Fixtures.discovery().list().first { $0.id == "arc" })
    let spaces = arc.profiles.flatMap { $0.spaces ?? [] }
    XCTAssertEqual(Set(spaces.filter { $0.theme != nil }.map(\.id)), ["S-PERSONAL", "S-WORK"])
  }

  func testAnOversizedThemeIsLeftOut() {
    let huge: [String: Any] = ["background": ["blob": String(repeating: "x", count: ArcSidebar.maxThemeBytes)]]
    XCTAssertNil(ArcSidebar.json(huge))
    XCTAssertNotNil(ArcSidebar.json(["background": [:]]))
  }

  func testThemesAreBoundedBeforeTheyAreWalked() throws {
    let color: [String: Any] = ["red": 0.1, "green": 0.2, "blue": 0.3, "alpha": 1, "colorSpace": "extendedSRGB"]
    let many = Array(repeating: color, count: 200_000)
    let theme: [String: Any] = ["background": ["single": ["_0": ["style": ["color": ["_0": ["blendedGradient": ["_0": [
      "baseColors": many, "overlayColors": many, "note": String(repeating: "y", count: 1_000_000),
    ]]]]]]]]]
    let bounded = try XCTUnwrap(ArcSidebar.bounded(theme))
    let json = try XCTUnwrap(ArcSidebar.json(bounded))
    XCTAssertLessThan(json.utf8.count, 4_096)
    XCTAssertEqual(ArcSidebar.gradient(bounded)?.count, ArcSidebar.maxThemeArray)
    func wide(_ level: Int) -> Any {
      level == 0 ? String(repeating: "z", count: 256)
        : Dictionary(uniqueKeysWithValues: (0..<32).map { ("k\($0)", wide(level - 1)) })
    }
    let tree = wide(3)
    let started = Date()
    XCTAssertNil(ArcSidebar.bounded(tree), "a theme over the shared budget is dropped whole")
    XCTAssertLessThan(Date().timeIntervalSince(started), 0.5)
    let crowded = Dictionary(uniqueKeysWithValues: (0..<100_000).map { ("k\($0)", 1) })
    XCTAssertNil(ArcSidebar.bounded(["background": crowded]).flatMap { ($0 as? [String: Any])?["background"] })
    var deep: Any = ["x": 1]
    for _ in 0..<5_000 { deep = ["d": deep] }
    XCTAssertNotNil(ArcSidebar.json(ArcSidebar.bounded(deep)))
  }
}
