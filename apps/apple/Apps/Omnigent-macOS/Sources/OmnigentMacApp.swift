import AppKit
import OSLog
import OmnigentAppUI
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
    ServerWindowScene(
      defaultServerURL: { desktop.preferences.defaultServerURL },
      content: { id in ServerWindowRoot(id: id, services: services) }
    )
    .commands {
      OmnigentDesktopCommands(
        actions: DesktopCommandActions(
          defaultServerURL: { desktop.preferences.defaultServerURL },
          helpURL: Self.helpURL, checkForUpdates: appDelegate.checkForUpdates,
          localServer: desktop.localServer))
      BrowserCommands()
      // The focused browser tab's menu. Edit > Find and View > Zoom already route to the page.
      BrowserTabCommands(includesFindAndZoom: false)
      OmnigentTabCommands(closeWindow: { NSApp.keyWindow?.performClose(nil) })
      OmnigentSessionCommands()
      if DebugCommands.isEnabled {
        DebugCommands()
      }
    }

    LocalServerLogsWindow(manager: desktop.localServer)

    OmnigentMenuBarExtra(desktop: desktop, sessions: services.menuBar)

    Settings {
      AppSettingsView(services: services)
        .omnigentTheme(services.theme.theme, appearance: services.theme.mode)
    }
  }
}

/// The desktop delegate, plus the app's own services bound before launch finishes so cold-start
/// deep links and issues reach them.
final class OmnigentMacAppDelegate: OmnigentDesktopAppDelegate {
  /// App-wide services, created with the delegate's `DesktopController`.
  private(set) lazy var services = AppServices(desktop: desktop)

  #if OMNIGENT_CHROMIUM
    private lazy var updater = SparkleUpdater { [weak self] issue in
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

/// Settings: the desktop tabs, plus Appearance (theme, under the web's keys) and Terminal, with
/// this edition's browser engines on the General tab.
struct AppSettingsView: View {
  let services: AppServices

  var body: some View {
    OmnigentSettingsView(
      desktop: services.desktop, recentServers: services.recentServers.urls,
      extraTabs: [
        SettingsTabItem("Appearance", systemImage: "paintpalette") {
          Form { ThemeSettingsView(preferences: services.theme) }.formStyle(.grouped)
        },
        SettingsTabItem("Terminal", systemImage: "apple.terminal") { TerminalSettingsView() },
      ]
    ) {
      BrowserEngineSettingsView(
        preferences: services.browserPreferences, provider: services.browserProvider)
      BrowserSettingsView(environment: services.browser)
      Section("Downloads") {
        BrowserDownloadSettingsView(settings: BrowserPromptPresenter.shared.downloadSettings)
      }
      if let issue = services.updaterIssue {
        Section("Updates") {
          Label(issue, systemImage: "exclamationmark.triangle")
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("settings.updater-issue")
        }
      }
    }
  }
}
