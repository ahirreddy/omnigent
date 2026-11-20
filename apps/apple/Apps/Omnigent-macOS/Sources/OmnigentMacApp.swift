import AppKit
import OSLog
import OmnigentAppUI
import OmnigentAuthUI
import OmnigentBrowser
import OmnigentDesktop
import OmnigentUIComponents
import OmnigentWorkspaceUI
import SwiftUI

#if OMNIGENT_CHROMIUM
  import OmnigentDesktopUpdate
#endif

/// The macOS app. Both editions (`OmnigentMac`, Developer ID; `OmnigentMacAppStore`) build these
/// sources; `AppEdition` holds the only differences.
@main
struct OmnigentMacApp: App {
  /// Opened by Help > Omnigent Help.
  static let helpURL = URL(string: "https://github.com/omnigent-ai/omnigent")

  @NSApplicationDelegateAdaptor(OmnigentMacAppDelegate.self) private var appDelegate

  /// The server a new window opens on: the demo's offline one, whatever the default is; then the
  /// server of a link that launched the app; then the user's default.
  /// - Parameters:
  ///   - demo: The demo server, in a demo launch.
  ///   - linked: The server a link asked for.
  ///   - preferred: The user's default server.
  /// - Returns: The server, or `nil` for the connect screen.
  static func newWindowServerURL(demo: URL?, linked: URL?, preferred: URL?) -> URL? {
    demo ?? linked ?? preferred
  }

  /// A new window's server, from what this launch's desktop knows.
  /// - Parameters:
  ///   - demo: The demo server, in a demo launch.
  ///   - desktop: The launch's desktop.
  /// - Returns: The server, or `nil` for the connect screen.
  static func newWindowServerURL(demo: URL?, desktop: DesktopController) -> URL? {
    newWindowServerURL(
      demo: demo, linked: desktop.router.requestedServerURL,
      preferred: desktop.preferences.defaultServerURL)
  }

  /// What a new window opens on, read each time one opens.
  /// - Parameter desktop: The launch's desktop.
  /// - Returns: Gives the server, or `nil` for the connect screen.
  static func newWindowServerURL(desktop: DesktopController) -> () -> URL? {
    { newWindowServerURL(demo: OmnigentMacAppDelegate.demoServerURL, desktop: desktop) }
  }

  /// Settings, a page of the front window: Omnigent > Settings (Command-comma) shows it or
  /// goes back from it, and the menu bar's Settings shows it.
  /// - Parameters:
  ///   - desktop: The launch's desktop.
  ///   - toggling: Whether a window already on Settings goes back to its content.
  /// - Returns: Shows Settings.
  static func showSettings(desktop: DesktopController, toggling: Bool) -> () -> Void {
    { desktop.router.showSettings(toggling: toggling) }
  }

  /// A server window's root. Its Settings has Updates in the edition that updates itself.
  /// - Parameters:
  ///   - id: The window's binding.
  ///   - delegate: The launch's delegate.
  /// - Returns: The root view.
  static func windowRoot(_ id: Binding<ServerWindowID>, delegate: OmnigentMacAppDelegate)
    -> ServerWindowRoot
  {
    #if OMNIGENT_CHROMIUM
      ServerWindowRoot(id: id, services: delegate.services, updater: delegate.updater)
    #else
      ServerWindowRoot(id: id, services: delegate.services)
    #endif
  }

  var body: some Scene {
    let services = appDelegate.services
    let desktop = services.desktop
    let defaultServerURL = Self.newWindowServerURL(desktop: desktop)
    ServerWindowScene(
      defaultServerURL: defaultServerURL,
      content: { id in Self.windowRoot(id, delegate: appDelegate) }
    )
    .commands {
      DesktopMenuCommands(
        actions: DesktopCommandActions(
          defaultServerURL: defaultServerURL,
          helpURL: Self.helpURL, checkForUpdates: appDelegate.checkForUpdates,
          showSettings: Self.showSettings(desktop: desktop, toggling: true),
          localServer: desktop.localServer))
      BrowserCommands()
      // The focused browser tab's menu. Edit > Find and View > Zoom already route to the page.
      BrowserTabCommands(includesFindAndZoom: false)
      OmnigentTabCommands(closeWindow: { NSApp.keyWindow?.performClose(nil) })
      OmnigentSessionCommands()
      TranscriptCommands()
      if DebugCommands.isEnabled {
        DebugCommands()
      }
    }
    // Hosting unit tests, the app opens no window of its own (see `isTestHost`).
    .defaultLaunchBehavior(OmnigentMacAppDelegate.isTestHost ? .suppressed : .automatic)

    LocalServerLogsWindow(manager: desktop.localServer, router: desktop.router)

    OmnigentMenuBarExtra(
      desktop: desktop, sessions: services.menuBar,
      showSettings: Self.showSettings(desktop: desktop, toggling: false))
  }
}

/// The desktop delegate, plus the app's own services bound before launch finishes so cold-start
/// deep links and issues reach them.
final class OmnigentMacAppDelegate: OmnigentDesktopAppDelegate {
  /// Launched with `-OmnigentDemo`: the core's offline demo server instead of a real one.
  static let isDemo = ProcessInfo.processInfo.arguments.contains("-OmnigentDemo")
  /// The demo server's URL in a demo launch.
  static let demoServerURL = isDemo ? URL(string: ServerSession.demoServerURL) : nil
  /// Launched by `xcodebuild` to host the unit tests (`OmnigentMacTests`), which load into
  /// this process. The app then stays in the background with no windows, so test runs do not
  /// take focus from whatever the user is doing.
  static let isTestHost = TestHost.isHosting(
    environment: ProcessInfo.processInfo.environment,
    hasXCTest: NSClassFromString("XCTestCase") != nil)

  /// Set when hosting tests: the delegate's state lives here, not with the user's.
  let testHostIsolation: TestHost.Isolation?

  /// App-wide services, created with the delegate's `DesktopController`.
  private(set) lazy var services =
    testHostIsolation?.makeServices(desktop: desktop) ?? AppServices(desktop: desktop)

  #if OMNIGENT_CHROMIUM
    private(set) lazy var updater = SparkleUpdater(reportIssue: updaterIssueReporter)

    /// Where the updater's issues go; it must not keep the delegate alive.
    var updaterIssueReporter: SparkleUpdaterIssueReporter {
      { [weak self] issue in
        self?.reportUpdater(issue)
      }
    }
  #endif

  init() {
    let isolation = Self.isolationForLaunch(isTestHost: Self.isTestHost)
    testHostIsolation = isolation
    super.init(desktop: Self.makeDesktop(isolation: isolation))
  }

  /// The test host's private store. Failing to make one ends the run: the alternative is running
  /// the tests against the user's preferences and server records.
  static func isolationForLaunch(isTestHost: Bool) -> TestHost.Isolation? {
    guard isTestHost else { return nil }
    do {
      let isolation = try TestHost.Isolation.forHostProcess()
      try isolation.replaceStandardDefaults()
      try TestHostNotifications.install()
      return isolation
      // coverage:off ends the process hosting the tests; TestHostTests pin each thrown failure
    } catch {
      fatalError(error.description)
    }
  }
  // coverage:on

  /// The shell services of a launch.
  /// - Parameter isolation: The test host's private store; `nil` in a real launch.
  /// - Returns: The services.
  static func makeDesktop(isolation: TestHost.Isolation?) -> DesktopController {
    isolation?.makeDesktop()
      ?? DesktopController(localServerCapability: AppEdition.current.localServerCapability)
  }

  /// A test host restores no windows from a real run, and the demo starts with one window on its
  /// sessions, never the windows an earlier (perhaps killed) run left. Other launches restore.
  /// - Parameters:
  ///   - isTestHost: Whether the process hosts tests.
  ///   - isDemo: Whether this is a demo launch.
  /// - Returns: Whether to ignore the windows saved for restoration.
  static func ignoresSavedWindows(isTestHost: Bool, isDemo: Bool) -> Bool {
    isTestHost || isDemo
  }

  /// Omnigent > Check for Updates..., in the Developer ID edition only.
  var checkForUpdates: (() -> Void)? {
    #if OMNIGENT_CHROMIUM
      // coverage:off Sparkle's real check and window; on the VM flow backlog (Check for Updates)
      { [weak self] in self?.updater.checkForUpdates() }
    // coverage:on
    #else
      nil
    #endif
  }

  override func applicationWillFinishLaunching(_ notification: Notification) {
    // No Dock icon, no menu bar, never the active app.
    if Self.isTestHost { NSApp.setActivationPolicy(.prohibited) }
    if Self.ignoresSavedWindows(isTestHost: Self.isTestHost, isDemo: Self.isDemo) {
      UserDefaults.standard.register(defaults: ["ApplePersistenceIgnoreState": true])
    }
    // Windows carry their own tab strip. Native window tabs (which a full-screen window's new
    // windows join by default) also hand windows between full-screen spaces, which AppKit
    // throws on.
    NSWindow.allowsAutomaticWindowTabbing = false
    #if DEBUG
      // Lets a chaos run compare behavior without the guard.
      if !UserDefaults.standard.bool(forKey: "OmnigentNoTextUndoGuard") { TextUndoGuard.install() }
    #else
      TextUndoGuard.install()
    #endif
    Self.install(Self.appKitGuards, logger: services.logger)
    services.bind()
    takeNotificationTaps(notification, isTestHost: Self.isTestHost)
  }

  /// Becomes the system's notification delegate, unless the process hosts tests.
  /// - Parameters:
  ///   - notification: The launch notification.
  ///   - isTestHost: Whether the process hosts tests.
  func takeNotificationTaps(_ notification: Notification, isTestHost: Bool) {
    TestHost.LaunchWork.takeNotificationTaps(isTestHost: isTestHost) {
      super.applicationWillFinishLaunching(notification)
    }
  }

  override func applicationShouldTerminate(_ sender: NSApplication)
    -> NSApplication.TerminateReply
  {
    askAboutUnsavedEdits(
      sender, quit: Self.isTestHost ? nil : UnsavedEditsQuit(), paths: UnsavedFileEdits.paths
    ) { [self] in finishTerminating(sender) }
  }

  private func finishTerminating(_ sender: NSApplication) -> NSApplication.TerminateReply {
    services.willTerminate()
    return super.applicationShouldTerminate(sender)
  }

  override func applicationDidFinishLaunching(_ notification: Notification) {
    finishLaunching(notification, isTestHost: Self.isTestHost, startUpdates: startUpdates)
  }

  /// The work that finishes a launch.
  /// - Parameters:
  ///   - notification: The launch notification.
  ///   - isTestHost: Whether the process hosts tests, which runs none of it.
  ///   - startUpdates: Starts the updater's scheduled checks.
  func finishLaunching(
    _ notification: Notification, isTestHost: Bool, startUpdates: @escaping () throws -> Void
  ) {
    TestHost.LaunchWork(
      startLocalServer: { super.applicationDidFinishLaunching(notification) },
      startChaos: startDiagnostics,
      startUpdater: { [self] in startUpdater(startUpdates) }
    ).run(isTestHost: isTestHost, isDemo: Self.isDemo)
  }

  // coverage:off Sparkle's real scheduled checks; a real launch in the VM starts them
  /// Starts the updater's scheduled checks, in the Developer ID edition only. A hosted test must
  /// never call it: the checks are real.
  private func startUpdates() throws {
    #if OMNIGENT_CHROMIUM
      try updater.start()
    #endif
  }
  // coverage:on

  /// Watches the main thread for stalls, in every build, before any chaos run.
  private func startDiagnostics() {
    MainThreadWatch.shared.start()
    startChaosIfRequested()
  }

  private func startChaosIfRequested() {
    #if DEBUG
      let desktop = services.desktop
      let serverURL = { Self.demoServerURL ?? desktop.preferences.defaultServerURL }
      if !ChaosScript.startIfRequested(router: desktop.router, serverURL: serverURL) {
        ChaosDriver.startIfRequested(router: desktop.router, serverURL: serverURL)
      }
    #endif
  }

  private func startUpdater(_ startUpdates: () throws -> Void) {
    do {
      try startUpdates()
    } catch {
      // `reportUpdater` already logged it and recorded it for Settings.
      services.logger.notice("Automatic updates are off for this run.")
    }
  }

  #if OMNIGENT_CHROMIUM
    func reportUpdater(_ issue: SparkleUpdaterIssue) {
      let message: String
      switch issue {
      case .startFailed(let error):
        message = "Automatic updates could not start: \(error.localizedDescription)"
        services.updaterIssue = message
      case .updateAborted(let error):
        message = "The update stopped: \(error.localizedDescription)"
      }
      services.logger.error("\(message, privacy: .public)")
    }
  #endif
}
