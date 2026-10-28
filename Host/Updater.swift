import AppKit
import Sparkle

/// Ray's self-update, Sparkle 2 with its standard dialogs. Starts in the real app only: a test build never creates
/// the updater, so a check run can't reach the feed. It also stays off while Info.plist's SUPublicEDKey isn't a real
/// EdDSA public key (the repo ships a placeholder until the release key exists), because Sparkle refuses to check
/// without one and would show an error on every launch. Updates are accepted only when the archive's EdDSA signature
/// matches that key (Sparkle's own check; the ad-hoc code signature is not what is trusted).
final class Updater: NSObject {
  static let shared = Updater()

  private var controller: SPUStandardUpdaterController?
  /// Why the updater isn't running, for the About-style menu state and the test log.
  private(set) var offReason: String? = "not started"

  func start() {
    guard controller == nil else { return }
    if TestEnvironment.isTestBuild {
      offReason = "test build"
      return
    }
    guard Self.hasRealPublicKey else {
      offReason = "no public key"
      return
    }
    controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    offReason = nil
  }

  /// SUPublicEDKey is a base64 Ed25519 public key, 32 bytes.
  static var hasRealPublicKey: Bool {
    guard let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String else { return false }
    return Data(base64Encoded: key.trimmingCharacters(in: .whitespacesAndNewlines))?.count == 32
  }

  var canCheck: Bool { controller?.updater.canCheckForUpdates ?? false }

  func checkForUpdates(_ sender: Any?) { controller?.checkForUpdates(sender) }

  /// What the test log reports.
  var debug: [String: Any] {
    [
      "started": controller != nil, "reason": offReason ?? NSNull(),
      "feed": Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String ?? NSNull(),
      "publicKeyValid": Self.hasRealPublicKey,
    ]
  }
}
