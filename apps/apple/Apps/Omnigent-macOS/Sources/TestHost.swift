import Foundation
import ObjectiveC
import OmnigentAppUI
import OmnigentDesktop

/// Telling whether this process hosts the unit tests, and keeping what they touch away from the
/// user. The Debug app shares its bundle identifier with the user's own copy, so without this a
/// test run would read and change the user's preferences, server records and running host.
enum TestHost {
  /// Whether the process hosts tests: `xcodebuild` set its environment and XCTest is loaded.
  /// - Parameters:
  ///   - environment: The process's environment.
  ///   - hasXCTest: Whether XCTest's classes are loaded.
  /// - Returns: `true` only with both, so an inherited variable can't change a real launch.
  static func isHosting(environment: [String: String], hasXCTest: Bool) -> Bool {
    let keys = ["XCTestConfigurationFilePath", "XCTestBundlePath", "XCTestSessionIdentifier"]
    return keys.contains { environment[$0] != nil } && hasXCTest
  }

  /// The private place a test host keeps its state could not be set up.
  enum IsolationError: Error, Equatable, CustomStringConvertible {
    /// `UserDefaults` refused the suite, or it is the app's own domain.
    case defaultsUnavailable(suite: String)
    /// `UserDefaults.standard` could not be pointed at the private preferences.
    case standardDefaultsNotReplaced
    /// A notification center method could not be replaced.
    case notificationsNotReplaced(method: String)
    /// The directory could not be created.
    case directoryUnavailable(path: String, reason: String)

    var description: String {
      switch self {
      case .defaultsUnavailable(let suite):
        "The test host has no private preferences: \(suite) is not usable."
      case .standardDefaultsNotReplaced:
        "The test host could not replace UserDefaults.standard."
      case .notificationsNotReplaced(let method):
        "The test host could not silence UNUserNotificationCenter's \(method)."
      case .directoryUnavailable(let path, let reason):
        "The test host has no private directory at \(path): \(reason)"
      }
    }
  }

  /// Preferences and files of a test host, or of one test, apart from the user's.
  struct Isolation {
    /// The private preferences, empty when created.
    let defaults: UserDefaults
    /// The private directory.
    let root: URL

    /// Where the browser keeps profiles and history.
    var browserDirectory: URL { root.appending(path: "Browser", directoryHint: .isDirectory) }

    /// Creates the private store, or fails: it never falls back to the user's.
    /// - Parameters:
    ///   - suite: The preferences suite.
    ///   - root: The directory to create.
    ///   - bundleIdentifier: The app's own preferences domain, which the suite must not be.
    /// - Throws: `IsolationError` when either can't be set up.
    init(
      suite: String, root: URL, bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) throws(IsolationError) {
      guard suite != bundleIdentifier, let defaults = UserDefaults(suiteName: suite) else {
        throw .defaultsUnavailable(suite: suite)
      }
      defaults.removePersistentDomain(forName: suite)
      do {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      } catch {
        throw .directoryUnavailable(path: root.path, reason: error.localizedDescription)
      }
      self.defaults = defaults
      self.root = root
      defaults.set(root.appending(path: "Tabs").path, forKey: AppServices.tabsDirectoryKey)
    }

    /// The isolation of the process hosting the tests.
    /// - Returns: The isolation.
    /// - Throws: `IsolationError` when it can't be set up.
    static func forHostProcess() throws(IsolationError) -> Self {
      try Self(
        suite: "ai.omnigent.test-host",
        root: FileManager.default.temporaryDirectory.appending(
          path: "omnigent-test-host-\(ProcessInfo.processInfo.processIdentifier)",
          directoryHint: .isDirectory))
    }

    /// Makes `UserDefaults.standard` these preferences for the rest of the process, so no code
    /// and no framework, reaching for it directly, writes to the user's.
    /// - Parameter selector: The method that answers `UserDefaults.standard`.
    /// - Throws: `IsolationError.standardDefaultsNotReplaced` when the method can't be replaced.
    func replaceStandardDefaults(
      selector: Selector = #selector(getter: UserDefaults.standard)
    ) throws(IsolationError) {
      guard let method = unsafe class_getClassMethod(UserDefaults.self, selector) else {
        throw .standardDefaultsNotReplaced
      }
      nonisolated(unsafe) let defaults = defaults
      let standard: @convention(block) (AnyObject) -> UserDefaults = { _ in unsafe defaults }
      unsafe method_setImplementation(method, imp_implementationWithBlock(standard))
    }

    /// Shell services that can't reach the user's server, host, records or preferences: local
    /// processes are off, and the home and records they would use are private anyway.
    /// - Parameters:
    ///   - managedDomains: The domains organization servers come from.
    ///   - localServerCapability: Whether local processes are on; a test turning them on must
    ///     start none.
    /// - Returns: The services, with the menu bar extra off.
    func makeDesktop(
      managedDomains: [String] = [],
      localServerCapability: LocalServerCapability = .unavailable(
        .disabled("This process hosts unit tests."))
    ) -> DesktopController {
      var dependencies = LocalServerManager.Dependencies.live(
        records: LocalServerRecordStore(
          directory: root.appending(path: "LocalServer", directoryHint: .isDirectory)))
      dependencies.environment = [:]
      dependencies.homeDirectory = root
      let desktop = DesktopController(
        defaults: defaults, managedDomains: managedDomains,
        localServerCapability: localServerCapability,
        localServerDependencies: dependencies)
      desktop.localServerPreferences.showsMenuBarExtra = false
      desktop.notifications.preferencesProvider = {
        NotificationPreferences(turnEnded: false, elicitations: false, runnerOffline: false)
      }
      return desktop
    }

    /// App services over this isolation.
    /// - Parameters:
    ///   - desktop: The shell services.
    ///   - flushDrafts: Saves composer drafts at quit; by default nothing touches the user's.
    ///   - notificationPermission: Answers the permission question; by default it stays denied,
    ///     so no system prompt can appear.
    ///   - launchArguments: The arguments to behave as launched with; none by default, as the
    ///     test host's own hold nothing the tests chose.
    ///   - makeDemoSession: Makes the sessions of a launch with `-OmnigentDemo`.
    /// - Returns: The services, with nothing kept in the user's Application Support.
    func makeServices(
      desktop: DesktopController, flushDrafts: @escaping () -> Void = {},
      notificationPermission: any NotificationAuthorizing = DeniedNotifications(),
      launchArguments: [String] = [],
      makeDemoSession: @escaping @MainActor () throws -> ServerSession = ServerSession.demo
    ) -> AppServices {
      AppServices(
        desktop: desktop, defaults: defaults, browserDirectory: browserDirectory,
        flushDrafts: flushDrafts, notificationPermission: notificationPermission,
        launchArguments: launchArguments, makeDemoSession: makeDemoSession)
    }
  }

  /// Notification permission in a test host: already decided, so nothing ever asks the person.
  final class DeniedNotifications: NotificationAuthorizing {
    var authorization: DesktopNotificationCenter.Authorization { .denied }
    // swiftlint:disable async_without_await
    func refreshAuthorization() async throws(DesktopNotificationError) {}
    func requestAuthorization() async throws(DesktopNotificationError) -> Bool { false }
    // swiftlint:enable async_without_await
  }

  /// The work that finishes a launch, which reaches outside the app.
  struct LaunchWork {
    /// Reuses or starts the local server.
    let startLocalServer: () -> Void
    /// Starts the stall watch, and a chaos walk or script when the launch asks for one (Debug
    /// builds).
    let startChaos: () -> Void
    /// Starts the updater's scheduled checks.
    let startUpdater: () -> Void

    /// Runs the work in order, unless the process hosts tests: they must not stop or adopt the
    /// user's server and host, check for updates or start a chaos run.
    /// - Parameter isTestHost: Whether the process hosts tests.
    func run(isTestHost: Bool) {
      guard !isTestHost else { return }
      startLocalServer()
      startChaos()
      startUpdater()
    }

    /// Becomes the system's notification delegate, unless the process hosts tests: it must not
    /// take the notification taps of the user's own copy of the app.
    /// - Parameters:
    ///   - isTestHost: Whether the process hosts tests.
    ///   - install: Installs the delegate.
    static func takeNotificationTaps(isTestHost: Bool, install: () -> Void) {
      guard !isTestHost else { return }
      install()
    }
  }
}
