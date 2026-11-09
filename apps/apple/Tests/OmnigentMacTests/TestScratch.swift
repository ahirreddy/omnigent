import Foundation
import OSLog
import OmnigentAppUI
import OmnigentCoreFFI
import OmnigentDesktop
import OmnigentStores
import OmnigentTestSupport
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
  ///   - localServerCapability: Whether local processes are on; a test turning them on starts
  ///     none.
  ///   - makeDemoSession: Makes the sessions of a launch with `-OmnigentDemo`; the host's own
  ///     when `nil`.
  /// - Throws: `TestHost.IsolationError` when the private store can't be made.
  init(
    managedByOwnSuite: Bool = false, launchArguments: [String] = [],
    notificationPermission: (any NotificationAuthorizing)? = nil,
    flushDrafts: @escaping () -> Void = {},
    localServerCapability: LocalServerCapability = .unavailable(.disabled("A hosted unit test.")),
    makeDemoSession: (@MainActor () throws -> ServerSession)? = nil
  ) throws {
    suite = "ai.omnigent.tests.\(UUID().uuidString)"
    isolation = try TestHost.Isolation(
      suite: suite,
      root: FileManager.default.temporaryDirectory.appending(
        path: suite, directoryHint: .isDirectory))
    desktop = isolation.makeDesktop(
      managedDomains: managedByOwnSuite ? [suite] : [],
      localServerCapability: localServerCapability)
    let permission = notificationPermission ?? TestHost.DeniedNotifications()
    if let makeDemoSession {
      services = isolation.makeServices(
        desktop: desktop, flushDrafts: flushDrafts, notificationPermission: permission,
        launchArguments: launchArguments, makeDemoSession: makeDemoSession)
    } else {
      services = isolation.makeServices(
        desktop: desktop, flushDrafts: flushDrafts, notificationPermission: permission,
        launchArguments: launchArguments)
    }
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

/// What the app logged in this process, so a test can see a failure was reported.
enum AppLog {
  /// The app log's messages holding `text`. Make `text` unique to the test: suites run in parallel.
  /// - Parameter text: The text to look for.
  /// - Returns: The messages, oldest first.
  /// - Throws: When the process's log can't be read.
  static func messages(containing text: String) throws -> [String] {
    let store = try OSLogStore(scope: .currentProcessIdentifier)
    let subsystem = Bundle.main.bundleIdentifier ?? "ai.omnigent.mac"
    return try store.getEntries().compactMap { $0 as? OSLogEntryLog }
      .filter { $0.subsystem == subsystem && $0.composedMessage.contains(text) }
      .map(\.composedMessage)
  }

  /// Waits for at least `count` messages holding `text`.
  /// - Parameters:
  ///   - text: The text to look for.
  ///   - count: How many to wait for.
  /// - Returns: Whether they arrived in time.
  /// - Throws: When the log can't be read.
  static func waitFor(_ text: String, count: Int = 1) async throws -> Bool {
    for _ in 0..<100 {
      if try messages(containing: text).count >= count { return true }
      try await Task.sleep(for: .milliseconds(50))
    }
    return false
  }
}

/// A server session over a core with fake transports: nothing reaches the network or the Keychain.
@MainActor
enum FakeServerSession {
  /// The session.
  /// - Parameter http: Answers the core's requests.
  /// - Returns: The session.
  /// - Throws: `CoreError` when the core can't start.
  static func make(http: FakeHttpTransport) throws -> ServerSession {
    let core = try ClientCore(
      http: http, streams: FakeEventStreamTransport(), sockets: FakeWebSocketTransport(),
      clock: TestClock(), scheduler: TestScheduler(), secureStore: InMemorySecureStore(),
      entropy: FixedEntropySource(),
      config: HostConfig(urlPolicy: .development, oidcRedirect: .none))
    return ServerSession(connection: ConnectionStore(core: core))
  }
}
