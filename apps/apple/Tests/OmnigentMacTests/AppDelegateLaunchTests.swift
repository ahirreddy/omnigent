import AppKit
import OSLog
import OmnigentAppUI
import OmnigentDesktop
import Testing

#if OMNIGENT_CHROMIUM
  import OmnigentDesktopUpdate
  @testable import OmnigentMac
#else
  @testable import OmnigentMacAppStore
#endif

/// The delegate's launch and quit paths with what reaches outside the app replaced: a second
/// delegate in the host, over its private store.
@MainActor
struct AppDelegateLaunchTests {
  private struct UpdatesRefused: Error {}

  /// One for the suite: making a delegate resets the host's preferences, which other suites use.
  private static let delegate = OmnigentMacAppDelegate()

  private let launched = Notification(name: NSApplication.didFinishLaunchingNotification)

  @Test func everyGuardInstallsOnThisAppKit() {
    let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "", category: "app")
    let missing = OmnigentMacAppDelegate.install(
      OmnigentMacAppDelegate.appKitGuards, logger: logger)
    #expect(missing.isEmpty, "\(missing)")
  }

  /// A later macOS that lacks a private method must say what is unguarded, and the rest still go on.
  @Test func aGuardWithoutItsMethodsIsReportedAndTheRestInstall() async throws {
    let unguarded = "first is off \(UUID().uuidString)"
    var installed: [String] = []
    let missing = OmnigentMacAppDelegate.install(
      [
        AppKitGuard(
          install: {
            installed.append("first")
            return false
          }, missing: unguarded),
        AppKitGuard(
          install: {
            installed.append("second")
            return true
          }, missing: "second is off"),
      ],
      logger: Logger(subsystem: Bundle.main.bundleIdentifier ?? "", category: "app"))
    #expect(installed == ["first", "second"])
    #expect(missing == [unguarded])
    #expect(try await AppLog.waitFor(unguarded))
  }

  /// A real launch's last steps run, and an updater that can't start doesn't stop the app.
  @Test func aRealLaunchFinishesWithAnUpdaterThatCantStart() {
    let delegate = Self.delegate
    var starts = 0
    delegate.finishLaunching(
      launched, isTestHost: false,
      startUpdates: {
        starts += 1
        throw UpdatesRefused()
      })
    #expect(starts == 1)
    #expect(!delegate.desktop.localServer.capability.isAvailable)
    #expect(delegate.desktop.localServer.server.endpoint == nil)
  }

  @Test func aTestHostStartsNoUpdates() {
    Self.delegate.finishLaunching(
      launched, isTestHost: true,
      startUpdates: { Issue.record("a test host started the updater") })
  }

  /// A real launch takes the notification taps; the system center is replaced in this process.
  @Test func aRealLaunchBecomesTheNotificationDelegate() {
    let delegate = Self.delegate
    var issues: [DesktopIssue] = []
    delegate.desktop.onIssue = { issues.append($0) }
    delegate.takeNotificationTaps(launched, isTestHost: false)
    #expect(issues.isEmpty, "\(issues)")
  }

  /// A new window reads the default server when it opens, not when the scene was built.
  @Test func aNewWindowReadsTheDefaultServerWhenItOpens() throws {
    let scratch = try TestScratch()
    defer { scratch.remove() }
    let defaultServerURL = OmnigentMacApp.newWindowServerURL(desktop: scratch.desktop)
    #expect(defaultServerURL() == nil)
    let server = try #require(URL(string: "https://omnigent.example.com"))
    scratch.desktop.preferences.defaultServerURL = server
    #expect(defaultServerURL() == server)
  }

  /// Quitting asks through `quit`; a test host has none and quits at once.
  @Test func quittingAsksAboutUnsavedEditsOnlyWithAQuestion() {
    let delegate = Self.delegate
    var proceeds = 0
    let proceed: () -> NSApplication.TerminateReply = {
      proceeds += 1
      return .terminateNow
    }
    let hosted = delegate.askAboutUnsavedEdits(NSApp, quit: nil, paths: ["/a"], then: proceed)
    #expect(hosted == .terminateNow)
    #expect(proceeds == 1)

    var asked: [[String]] = []
    let canceled = delegate.askAboutUnsavedEdits(
      NSApp,
      quit: UnsavedEditsQuit(ask: { paths in
        asked.append(paths)
        return .cancel
      }),
      paths: ["/a"], then: proceed)
    #expect(canceled == .terminateCancel)
    #expect(asked == [["/a"]])
    #expect(proceeds == 1, "canceling went on quitting")
  }

  #if OMNIGENT_CHROMIUM
    private struct Refused: LocalizedError {
      let errorDescription: String? = "the feed refused"
    }

    /// The updater's start failures reach Settings through the delegate.
    @Test func theUpdatersIssuesReachSettings() {
      Self.delegate.updaterIssueReporter(.startFailed(Refused()))
      #expect(Self.delegate.services.updaterIssue?.contains("the feed refused") == true)
    }
  #endif
}
