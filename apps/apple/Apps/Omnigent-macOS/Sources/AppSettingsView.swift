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

/// A window's Settings page: the desktop tabs, plus Appearance (theme, under the web's keys),
/// Terminal, Phone and Servers, as the categories of a sidebar, with the composer's send
/// shortcut and this edition's browser engines on General.
struct AppSettingsView: View {
  let services: AppServices
  #if OMNIGENT_CHROMIUM
    /// Backs General › Updates; a window without one leaves the section out.
    var updater: SparkleUpdater?
  #endif
  /// The window's navigator: its links and menus open Settings at a tab or server pane, and
  /// Back leaves, through it.
  let navigator: SettingsNavigator

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
          ServerSettingsContainer(navigator: navigator, openSession: services.openSession)
        },
      ],
      selection: Bindable(navigator).tab
    ) {
      ComposerSettingsSection()
      ProjectBoardSettingsSection()
      SessionSettingsSection()
      LinksAndSessionsSettingsSection()
      BrowserEngineSettingsView(
        preferences: services.browserPreferences, provider: services.browserProvider)
      BrowserSettingsView(environment: services.browser)
      Section("Downloads") {
        BrowserDownloadSettingsView(settings: BrowserPromptPresenter.shared.downloadSettings)
      }
      #if OMNIGENT_CHROMIUM
        if let updater {
          UpdateSettingsSection(updater: updater, issue: services.updaterIssue)
        }
      #endif
    } page: { tabs, selection in
      SettingsPage(
        categories: tabs.map(Self.category), selection: selection, back: { navigator.close() })
    }
  }

  /// A tab as a category of the page.
  static func category(_ tab: SettingsTabItem) -> SettingsPageCategory {
    SettingsPageCategory(
      tab.title, systemImage: tab.systemImage, isWide: tab.isWide, content: tab.content)
  }
}
