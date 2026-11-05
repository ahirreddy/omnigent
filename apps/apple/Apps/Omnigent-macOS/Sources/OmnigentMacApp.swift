import AppKit
import OSLog
import OmnigentAppUI
import OmnigentAuthUI
import OmnigentBrowser
import OmnigentDesktop
import OmnigentTerminalUI
import OmnigentUIComponents
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

  var body: some Scene {
    let services = appDelegate.services
    let desktop = services.desktop
    // The demo's windows open on its offline server, whatever the default server is.
    let defaultServerURL = {
      OmnigentMacAppDelegate.demoServerURL ?? desktop.preferences.defaultServerURL
    }
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
  static let isTestHost: Bool = {
    let environment = ProcessInfo.processInfo.environment
    let keys = ["XCTestConfigurationFilePath", "XCTestBundlePath", "XCTestSessionIdentifier"]
    return keys.contains { environment[$0] != nil } && NSClassFromString("XCTestCase") != nil
  }()

  /// App-wide services, created with the delegate's `DesktopController`.
  private(set) lazy var services = AppServices(desktop: desktop)

  #if OMNIGENT_CHROMIUM
    private(set) lazy var updater = SparkleUpdater { [weak self] issue in
      self?.reportUpdater(issue)
    }
  #endif

  init() {
    super.init(
      desktop: DesktopController(localServerCapability: AppEdition.current.localServerCapability))
  }

  /// Omnigent > Check for Updates..., in the Developer ID edition only.
  var checkForUpdates: (() -> Void)? {
    #if OMNIGENT_CHROMIUM
      { [weak self] in self?.updater.checkForUpdates() }
    #else
      nil
    #endif
  }

  override func applicationWillFinishLaunching(_ notification: Notification) {
    if Self.isTestHost {
      // No Dock icon, no menu bar, never the active app; no windows restored from a real run.
      NSApp.setActivationPolicy(.prohibited)
      UserDefaults.standard.register(defaults: ["ApplePersistenceIgnoreState": true])
    }
    if Self.isDemo {
      // The demo starts with one window on its sessions, never the windows an earlier (perhaps
      // killed) run left for restoration.
      UserDefaults.standard.register(defaults: ["ApplePersistenceIgnoreState": true])
    }
    services.bind()
    super.applicationWillFinishLaunching(notification)
  }

  override func applicationShouldTerminate(_ sender: NSApplication)
    -> NSApplication.TerminateReply
  {
    services.willTerminate()
    return super.applicationShouldTerminate(sender)
  }

  override func applicationDidFinishLaunching(_ notification: Notification) {
    super.applicationDidFinishLaunching(notification)
    #if OMNIGENT_CHROMIUM
      do {
        try updater.start()
      } catch {
        // `reportUpdater` already logged it and recorded it for Settings.
        services.logger.notice("Automatic updates are off for this run.")
      }
    #endif
  }

  #if OMNIGENT_CHROMIUM
    private func reportUpdater(_ issue: SparkleUpdaterIssue) {
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
  @Bindable private var navigator = SettingsNavigator.shared

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
        },
        SettingsTabItem(SettingsNavigator.terminalTab, systemImage: "apple.terminal") {
          TerminalSettingsView()
        },
        SettingsTabItem("Phone", systemImage: "iphone") {
          PairingSettingsView(servers: services.pairingServers())
        },
        // Each signed-in server's settings, as the web's /settings server sections.
        SettingsTabItem(SettingsNavigator.serversTab, systemImage: "network", isWide: true) {
          ServerSettingsContainer(openSession: { [desktop = services.desktop] server, session in
            desktop.router.open(.conversation(sessionID: session), onServer: server)
          })
        },
      ],
      selection: $navigator.tab
    ) {
      ComposerSettingsSection()
      SessionSettingsSection()
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
  }
}
