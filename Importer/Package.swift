// swift-tools-version:5.9
// Reads other browsers' data for File › Import and onboarding. Adapted from Ardia's packages/import
// (Apache-2.0, see NOTICE). Sources/RayImport is plain Swift: the app compiles it in with Host/, and
// `swift test --package-path Importer` runs its tests against fixtures/ (never a real profile).
import PackageDescription

let package = Package(
  name: "RayImport",
  platforms: [.macOS(.v14)],
  products: [.library(name: "RayImport", targets: ["RayImport"])],
  targets: [
    .target(name: "RayImport", path: "Sources/RayImport", linkerSettings: [.linkedLibrary("sqlite3")]),
    .testTarget(name: "RayImportTests", dependencies: ["RayImport"], path: "Tests/RayImportTests"),
  ]
)
