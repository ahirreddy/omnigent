import OmnigentAppUI
import OmnigentPlatform
import UIKit

/// Installs phone supervision before launch finishes, so a notification action or a background
/// refresh that launches the app reaches it.
final class PhoneAppDelegate: NSObject, UIApplicationDelegate {
  /// The app's supervision coordinator, shared by every scene.
  static let supervision = PhoneSupervision()

  func application(
    _ application: UIApplication,
    // swiftlint:disable:next discouraged_optional_collection
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
  ) -> Bool {
    Self.supervision.lastServerURL = {
      UserDefaults.standard.string(forKey: IOSRootView.lastServerKey)
    }
    Self.supervision.install()
    #if DEBUG
      FrameMonitor.startIfRequested()
      PerfDriver.startIfRequested()
    #endif
    return true
  }
}
