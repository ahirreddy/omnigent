import AppKit
import OSLog
import OmnigentAppUI
import OmnigentAuthUI
import OmnigentBrowser
import OmnigentDesktop
import OmnigentTerminalUI
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

  var body: some Scene {
    let services = appDelegate.services
    let desktop = services.desktop
    let defaultServerURL = Self.newWindowServerURL(desktop: desktop)
    ServerWindowScene(
      defaultServerURL: defaultServerURL,
      content: { id in ServerWindowRoot(id: id, services: services) }
    )
    .commands {
      OmnigentDesktopCommands(
        actions: DesktopCommandActions(
          defaultServerURL: defaultServerURL,
          helpURL: Self.helpURL, checkForUpdates: appDelegate.checkForUpdates,
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

    OmnigentMenuBarExtra(desktop: desktop, sessions: services.menuBar)

    Settings {
      #if OMNIGENT_CHROMIUM
        AppSettingsView(services: services, updater: appDelegate.updater)
          .omnigentTheme(services.theme.theme, appearance: services.theme.mode)
      #else
        AppSettingsView(services: services)
          .omnigentTheme(services.theme.theme, appearance: services.theme.mode)
      #endif
    }
    // Each tab sets its size, so a saved smaller frame never clips a pane.
    .windowResizability(.contentSize)
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
    ).run(isTestHost: isTestHost)
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

/// Settings: the desktop tabs, plus Appearance (theme, under the web's keys), Terminal, Phone and
/// Servers, with the composer's send shortcut and this edition's browser engines on General.
struct AppSettingsView: View {
  let services: AppServices
  #if OMNIGENT_CHROMIUM
    /// Backs General › Updates.
    let updater: SparkleUpdater
  #endif
  /// Other windows open Settings at a tab or server pane through it.
  private var navigator: SettingsNavigator { .shared }

  var body: some View {
    OmnigentSettingsView(
      desktop: services.desktop, recentServers: services.recentServers.urls,
      extraTabs: [
        SettingsTabItem(SettingsNavigator.appearanceTab, systemImage: "paintpalette") {
          Form {
            ThemeSettingsView(preferences: services.theme)
            SettingsDataSection(theme: services.theme)
          }
          .formStyle(.grouped)
          .environment(\.pickerVisibilitySource, PickerVisibilityAdapter.source())
        },
        SettingsTabItem(SettingsNavigator.terminalTab, systemImage: "apple.terminal") {
          TerminalSettingsView()
        },
        SettingsTabItem("Phone", systemImage: "iphone") {
          PairingSettingsView(servers: services.pairingServers())
        },
        // Each signed-in server's settings, as the web's /settings server sections.
        SettingsTabItem(SettingsNavigator.serversTab, systemImage: "network", isWide: true) {
          ServerSettingsContainer(openSession: services.openSession)
        },
      ],
      selection: Bindable(navigator).tab
    ) {
      ComposerSettingsSection()
      SessionSettingsSection()
      LinksAndSessionsSettingsSection()
      BrowserEngineSettingsView(
        preferences: services.browserPreferences, provider: services.browserProvider)
      BrowserSettingsView(environment: services.browser)
      Section("Downloads") {
        BrowserDownloadSettingsView(settings: BrowserPromptPresenter.shared.downloadSettings)
      }
      #if OMNIGENT_CHROMIUM
        UpdateSettingsSection(updater: updater, issue: services.updaterIssue)
      #endif
    }
    // A link that moves to a wide tab rebuilds the toolbar with the old tab highlighted.
    .onChange(of: navigator.tab, initial: true) { _, tab in
      Task { @MainActor in
        SettingsToolbarHighlight.select(tab)
        try? await Task.sleep(for: .milliseconds(150))
        SettingsToolbarHighlight.select(tab)
      }
    }
  }
}

/// Keeps the Settings toolbar's highlighted item on the shown tab.
enum SettingsToolbarHighlight {
  /// Highlights the toolbar item titled `tab` in the window that shows the Settings tabs.
  @MainActor static func select(_ tab: String) {
    for window in NSApp.windows where window.isVisible {
      if let toolbar = window.toolbar { select(tab, in: toolbar) }
    }
  }

  /// Highlights the item titled `tab` when `toolbar` is the Settings one, which has a General item.
  @MainActor static func select(_ tab: String, in toolbar: NSToolbar) {
    guard toolbar.items.contains(where: { $0.label == SettingsNavigator.generalTab }),
      let item = toolbar.items.first(where: { $0.label == tab }),
      toolbar.selectedItemIdentifier != item.itemIdentifier
    else { return }
    toolbar.selectedItemIdentifier = item.itemIdentifier
  }
}
