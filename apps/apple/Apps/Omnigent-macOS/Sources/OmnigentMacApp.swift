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
    // The demo's windows open on its offline server, whatever the default server is; a window
    // opened for a link that launched the app opens on the link's server.
    let defaultServerURL = {
      OmnigentMacAppDelegate.demoServerURL ?? desktop.router.requestedServerURL
        ?? desktop.preferences.defaultServerURL
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
    // Windows carry their own tab strip. Native window tabs (which a full-screen window's new
    // windows join by default) also hand windows between full-screen spaces, which AppKit
    // throws on.
    NSWindow.allowsAutomaticWindowTabbing = false
    if !ToolbarSwapGuard.install() {
      services.logger.error(
        "AppKit lacks the toolbar methods to guard; toolbar swaps are unguarded.")
    }
    if !MenuTitleGuard.install() {
      services.logger.error("AppKit lacks the menu item title setter; nil titles are unguarded.")
    }
    if !TableRowGuard.install() {
      services.logger.error(
        "AppKit lacks the table row methods; drags and menus on removed rows quit.")
    }
    if !WindowsMenuGuard.install() {
      services.logger.error(
        "AppKit lacks the Windows menu methods; arranging while a window changes quits.")
    }
    if !SingleLinePasteGuard.install() {
      services.logger.error("AppKit lacks the text view paste method; pasted lines stay unjoined.")
    }
    #if OMNIGENT_CHROMIUM
      if !ScrollMonitorGuard.install() {
        services.logger.error(
          "AppKit lacks the scroll monitor to guard; its resumes are unguarded.")
      }
    #endif
    services.bind()
    super.applicationWillFinishLaunching(notification)
  }

  override func applicationShouldTerminate(_ sender: NSApplication)
    -> NSApplication.TerminateReply
  {
    askAboutUnsavedEdits(sender) { [self] in finishTerminating(sender) }
  }

  private func finishTerminating(_ sender: NSApplication) -> NSApplication.TerminateReply {
    services.willTerminate()
    return super.applicationShouldTerminate(sender)
  }

  override func applicationDidFinishLaunching(_ notification: Notification) {
    super.applicationDidFinishLaunching(notification)
    #if DEBUG
      let desktop = services.desktop
      let serverURL = { Self.demoServerURL ?? desktop.preferences.defaultServerURL }
      if !ChaosScript.startIfRequested(router: desktop.router, serverURL: serverURL) {
        ChaosDriver.startIfRequested(router: desktop.router, serverURL: serverURL)
      }
    #endif
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
          ServerSettingsContainer(openSession: { [desktop = services.desktop] server, session in
            desktop.router.open(.conversation(sessionID: session), onServer: server)
          })
        },
      ],
      selection: $navigator.tab
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
      // The Settings toolbar is the one with a General item.
      guard let toolbar = window.toolbar,
        toolbar.items.contains(where: { $0.label == SettingsNavigator.generalTab }),
        let item = toolbar.items.first(where: { $0.label == tab }),
        toolbar.selectedItemIdentifier != item.itemIdentifier
      else { continue }
      toolbar.selectedItemIdentifier = item.itemIdentifier
    }
  }
}
