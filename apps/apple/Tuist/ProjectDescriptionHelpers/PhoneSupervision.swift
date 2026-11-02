import ProjectDescription

extension Omnigent {
  /// iOS Info.plist keys for phone supervision: the background attention poll
  /// (`PhoneSupervision.refreshTaskIdentifier`) and the camera for pairing codes.
  public static let phoneSupervisionInfoPlist: [String: Plist.Value] = [
    "BGTaskSchedulerPermittedIdentifiers": ["ai.omnigent.attention-refresh"],
    "UIBackgroundModes": ["fetch"],
    "NSCameraUsageDescription":
      "Omnigent uses the camera to scan a pairing code from your Mac, and web pages you open can use it when you allow it.",
  ]
}
