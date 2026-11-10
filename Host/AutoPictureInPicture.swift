import AppKit

/// Settings › Tabs › Automatic Picture in Picture (Arc's, on by default): a video or call you're watching pops out
/// when you switch tabs or leave the window, and goes back when you return. Chrome's own automatic picture in
/// picture does it (`AutoPictureInPictureTabHelper`): Ray tells the engine which pages the user sees
/// (`PageContainerView`'s `noteShown(byHost:)` and window sight), and this turns it on or off for every profile
/// (Chrome's content setting, and the engine's switch over it). With `BrowserInitiatedAutomaticPictureInPicture`
/// (main.swift, as Ardia passes it) any page's one playing video qualifies, not only pages that ask for it. Chrome's
/// rules stand: https (or a file), playing with sound, or a call using the camera or microphone.
enum AutoPictureInPicture {
  private static var observation: SettingsObservation?

  /// From the first window on (the engine has started); once for the app.
  static func start() {
    guard observation == nil else { return }
    RayCoreEngine.setAutoPictureInPicture(RaySettings.shared[.autoPictureInPicture])
    observation = RaySettings.shared.observe(.autoPictureInPicture) { on in
      RayCoreEngine.setAutoPictureInPicture(on)
    }
  }
}
