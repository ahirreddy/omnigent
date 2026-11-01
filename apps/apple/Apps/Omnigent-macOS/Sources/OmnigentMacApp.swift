import OmnigentBrowser
import OmnigentDesktop
import SwiftUI

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
          helpURL: Self.helpURL))
      BrowserCommands()
    }

    BrowserWindowScene(services: services)

    Settings {
      AppSettingsView(services: services)
    }
  }
}

/// The desktop delegate, plus the app's own services bound before launch finishes so cold-start
/// deep links and issues reach them.
final class OmnigentMacAppDelegate: OmnigentDesktopAppDelegate {
  /// App-wide services, created with the delegate's `DesktopController`.
  private(set) lazy var services = AppServices(desktop: desktop)

  override func applicationWillFinishLaunching(_ notification: Notification) {
    services.bind()
    super.applicationWillFinishLaunching(notification)
  }
}

/// Settings: the desktop tabs, with this edition's browser engines on the General tab.
struct AppSettingsView: View {
  let services: AppServices

  var body: some View {
    OmnigentSettingsView(
      desktop: services.desktop, recentServers: services.recentServers.urls
    ) {
      BrowserEngineSettingsView(
        preferences: services.browserPreferences, provider: services.browserProvider)
    }
  }
}
