import AppKit

let environment = ProcessInfo.processInfo.environment
let launchedInBackground = TestEnvironment["LUMEN_BACKGROUND"] == "1"

let dataDirectory: String = {
  let base = TestEnvironment["LUMEN_DATA_DIR"].flatMap { $0.isEmpty ? nil : $0 }
    ?? (NSHomeDirectory() as NSString).appendingPathComponent("Library/Application Support/Lumen")
  return (base as NSString).appendingPathComponent("Chromium")
}()

do {
  try FileManager.default.createDirectory(atPath: dataDirectory, withIntermediateDirectories: true)
} catch {
  FileHandle.standardError.write("[lumen] can't use data dir \(dataDirectory): \(error.localizedDescription)\n".data(using: .utf8)!)
  exit(1)
}

var engineArguments = [
  CommandLine.arguments.first ?? "Lumen",
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
    + "ThrottleMainFrameTo60Hz,UrgentMainFrameForInput",
]
if TestEnvironment["LUMEN_ENGINE_FEATURES"] == "none" {
  engineArguments.removeAll { $0.hasPrefix("--enable-features=") }
}
if let port = TestEnvironment["LUMEN_REMOTE_DEBUGGING_PORT"] {
  engineArguments += ["--remote-debugging-port=\(port)", "--remote-allow-origins=*"]
}
if launchedInBackground {
  engineArguments += ["--mute-audio", "--disable-modal-animations", "--disable-backgrounding-occluded-windows"]
}

let argv = engineArguments.map { UnsafePointer<CChar>(strdup($0)!) }
let argvBuffer = UnsafeMutablePointer<UnsafePointer<CChar>>.allocate(capacity: argv.count)
argvBuffer.initialize(from: argv, count: argv.count)

exit(ArdiaCoreEngine.run(withArgc: Int32(argv.count), argv: argvBuffer, delegate: AppController.shared))
