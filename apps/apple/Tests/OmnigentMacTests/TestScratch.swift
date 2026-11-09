import Foundation
import OmnigentDesktop
import Testing

#if OMNIGENT_CHROMIUM
  @testable import OmnigentMac
#else
  @testable import OmnigentMacAppStore
#endif

/// One test's own preferences, files and services, so nothing reaches the user's. Tests in the
/// host share a bundle identifier with the user's copy of the app, so they must not build
/// `AppServices` or `DesktopController` over the defaults.
@MainActor
final class TestScratch {
  let isolation: TestHost.Isolation
  let suite: String
  let desktop: DesktopController
  let services: AppServices

  /// - Parameters:
  ///   - managedByOwnSuite: Reads organization servers from this scratch's preferences.
  ///   - launchArguments: The arguments its services behave as launched with.
  ///   - notificationPermission: What answers the permission question.
  ///   - flushDrafts: What quitting does for drafts.
  /// - Throws: `TestHost.IsolationError` when the private store can't be made.
  init(
    managedByOwnSuite: Bool = false, launchArguments: [String] = [],
    notificationPermission: (any NotificationAuthorizing)? = nil,
    flushDrafts: @escaping () -> Void = {}
  ) throws {
    suite = "ai.omnigent.tests.\(UUID().uuidString)"
    isolation = try TestHost.Isolation(
      suite: suite,
      root: FileManager.default.temporaryDirectory.appending(
        path: suite, directoryHint: .isDirectory))
    desktop = isolation.makeDesktop(managedDomains: managedByOwnSuite ? [suite] : [])
    services = isolation.makeServices(
      desktop: desktop, flushDrafts: flushDrafts,
      notificationPermission: notificationPermission ?? TestHost.DeniedNotifications(),
      launchArguments: launchArguments)
  }

  var defaults: UserDefaults { isolation.defaults }

  /// Removes the preferences and files; call in a `defer`.
  func remove() {
    defaults.removePersistentDomain(forName: suite)
    do {
      try FileManager.default.removeItem(at: isolation.root)
    } catch CocoaError.fileNoSuchFile {
      // Nothing was written.
    } catch {
      Issue.record("Could not remove \(isolation.root.path): \(error)")
    }
  }
}
