import Foundation

enum TestEnvironment {
  #if RAY_TEST_HOOKS
  static let isTestBuild = true
  static subscript(key: String) -> String? { ProcessInfo.processInfo.environment[key] }
  #else
  static let isTestBuild = false
  static subscript(key: String) -> String? { nil }
  #endif

  static func log(_ message: @autoclosure () -> String) {
    guard isTestBuild else { return }
    FileHandle.standardError.write("[ray] \(message())\n".data(using: .utf8)!)
  }
}
