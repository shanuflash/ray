import AppKit

let environment = ProcessInfo.processInfo.environment
let launchedInBackground = TestEnvironment["RAY_BACKGROUND"] == "1"

let dataDirectory: String = {
  // The test app never falls back to the default data dir: an unset or empty RAY_DATA_DIR would put a test
  // instance on the user's real profile.
  if TestEnvironment.isTestBuild, (TestEnvironment["RAY_DATA_DIR"] ?? "").isEmpty {
    FileHandle.standardError.write("[ray] test build needs RAY_DATA_DIR (a throwaway folder); refusing to start\n".data(using: .utf8)!)
    exit(2)
  }
  let base = TestEnvironment["RAY_DATA_DIR"].flatMap { $0.isEmpty ? nil : $0 }
    ?? (NSHomeDirectory() as NSString).appendingPathComponent("Library/Application Support/Ray")
  return (base as NSString).appendingPathComponent("Chromium")
}()

do {
  try FileManager.default.createDirectory(atPath: dataDirectory, withIntermediateDirectories: true)
} catch {
  FileHandle.standardError.write("[ray] can't use data dir \(dataDirectory): \(error.localizedDescription)\n".data(using: .utf8)!)
  exit(1)
}

var engineArguments = [
  CommandLine.arguments.first ?? "Ray",
  "--user-data-dir=\(dataDirectory)",
  "--profile-directory=Default",
  "--use-mock-keychain",
  "--disable-stack-profiler",
  "--disable-features=MacAppCodeSignClone,DevToolsAcceptDebuggingConnections,AutofillAiWalletPrivatePasses"
    + (launchedInBackground ? ",MacWebContentsOcclusion" : ""),
  "--enable-features=WebContentsDiscard,"
    + "ImprovedStartupBestEffortDelay:StartupDelayStopOnLoadingTimedOut/true,"
    + "CPUMeasurementInFreezingPolicy:freezing_visible_protection_time/0s,"
    + "InfiniteTabsFreezing:ardia_unconnected_unfreeze_interval/600s,"
    // No ThrottleMainFrameTo60Hz (Ardia's battery choice): pages keep the display's full 120 Hz, as in Chrome.
    + "UrgentMainFrameForInput",
]
if TestEnvironment["RAY_ENGINE_FEATURES"] == "none" {
  engineArguments.removeAll { $0.hasPrefix("--enable-features=") }
}
if TestEnvironment["RAY_IGNORE_CERT_ERRORS"] == "1" {
  // Test-only: the fixture's HTTPS server uses a throwaway self-signed certificate.
  engineArguments.append("--ignore-certificate-errors")
}
if let rules = TestEnvironment["RAY_HOST_RULES"] {
  // Test-only: names like ray.test resolve to the local fixture server (insecure-origin checks need a real host).
  engineArguments.append("--host-resolver-rules=\(rules)")
}
if let port = TestEnvironment["RAY_REMOTE_DEBUGGING_PORT"] {
  engineArguments += ["--remote-debugging-port=\(port)", "--remote-allow-origins=*"]
}
if launchedInBackground {
  engineArguments += ["--mute-audio", "--disable-modal-animations", "--disable-backgrounding-occluded-windows"]
}

let argv = engineArguments.map { UnsafePointer<CChar>(strdup($0)!) }
let argvBuffer = UnsafeMutablePointer<UnsafePointer<CChar>>.allocate(capacity: argv.count)
argvBuffer.initialize(from: argv, count: argv.count)

exit(ArdiaCoreEngine.run(withArgc: Int32(argv.count), argv: argvBuffer, delegate: AppController.shared))
