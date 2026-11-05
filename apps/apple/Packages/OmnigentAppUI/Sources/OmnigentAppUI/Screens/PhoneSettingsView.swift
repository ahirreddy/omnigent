#if os(iOS)
  import Foundation
  import OmnigentPlatform
  import OmnigentStores
  import OmnigentTerminalUI
  import OmnigentUIComponents
  import SwiftUI

  extension View {
    /// Gives a scene the Settings screen: the server menu's Settings item, the palette's Go to
    /// Settings, New Session's Import and the Appearance and Notifications items open it.
    /// - Parameters:
    ///   - supervision: The app's coordinator, for Notifications.
    ///   - connection: The scene's signed-in connection, whose server the screen shows.
    ///   - selection: The scene's destination, set when Unarchive opens a session.
    /// - Returns: The view.
    func phoneSettings(
      supervision: PhoneSupervision, connection: ConnectionStore?,
      selection: Binding<SidebarDestination?>
    ) -> some View {
      modifier(
        PhoneSettingsHost(supervision: supervision, connection: connection, selection: selection))
    }
  }

  private struct PhoneSettingsHost: ViewModifier {
    let supervision: PhoneSupervision
    let connection: ConnectionStore?
    @Binding var selection: SidebarDestination?
    @State private var router = PhoneSettingsRouter()
    @Environment(\.themePreferences) private var theme

    func body(content: Content) -> some View {
      router.sceneServer = { [connection] in connection?.supervisedServerURL }
      return
        content
        .environment(\.openSettingsAt, router.openAt)
        .environment(\.openSettingsScreen, OpenSettingsScreenAction(presenter: router.screen))
        .focusedSceneValue(
          \.openSettingsScreen, OpenSettingsScreenAction(presenter: router.screen)
        )
        .environment(
          \.openAppearanceSettings, OpenAppearanceSettingsAction(presenter: router.appearance)
        )
        .environment(
          \.openNotificationSettings,
          OpenNotificationSettingsAction(presenter: router.notifications)
        )
        .sheet(isPresented: $router.isPresented) {
          PhoneSettingsView(
            router: router, supervision: supervision, connection: connection, theme: theme,
            openSession: openSession)
        }
        #if DEBUG
          .task(id: connection?.supervisedServerURL) { openFromLaunchArguments() }
          .perfHooks(Self.perfPages.map { "settings.\($0)" }) { openForMeasurement($0) }
        #endif
    }

    #if DEBUG
      /// `-OmnigentOpenSettings <page>` opens the screen once the scene is signed in (`usage`
      /// opens the Usage page instead, to check it at this width).
      private func openFromLaunchArguments() {
        guard let server = connection?.supervisedServerURL,
          let name = UserDefaults.standard.string(forKey: "OmnigentOpenSettings")
        else { return }
        if name == "usage" {
          selection = .usage
          return
        }
        router.show(PhoneSettingsRoute.Page(launchName: name), server: server)
      }

      /// The pages `ai.omnigent.perf.settings.<page>` opens (docs/performance.md); `close`
      /// dismisses the screen.
      private static let perfPages =
        ["close", "usage", "root"] + PhoneSettingsPage.allCases.map(\.rawValue)
        + ServerSettingsPane.allCases.map(\.rawValue)

      private func openForMeasurement(_ hook: String) {
        let name = String(hook.dropFirst("settings.".count))
        switch name {
        case "close": router.isPresented = false
        case "usage": selection = .usage
        default:
          router.show(
            PhoneSettingsRoute.Page(launchName: name), server: connection?.supervisedServerURL)
        }
      }
    #endif

    /// Unarchive's open: the scene shows the session when it is on the scene's server.
    private func openSession(_ server: URL, _ sessionID: String) {
      guard let current = connection?.supervisedServerURL,
        SupervisionConnections.key(current) == SupervisionConnections.key(server.absoluteString)
      else { return }
      router.isPresented = false
      selection = .session(sessionID)
    }
  }

  /// Settings on iPhone and iPad: General, Appearance, Notifications and Terminal, then the
  /// server's panes, in one navigation stack (the Mac shows them in its Settings window).
  struct PhoneSettingsView: View {
    @Bindable var router: PhoneSettingsRouter
    let supervision: PhoneSupervision
    /// The scene's connection, listed even before its sign-in handlers register it.
    let connection: ConnectionStore?
    let theme: ThemePreferences?
    let openSession: @MainActor (URL, String) -> Void

    var body: some View {
      NavigationStack(path: $router.path) {
        ServerSettingsContainer(
          connections: { [connection] in
            SupervisionConnections.shared.connections(including: connection)
          },
          navigator: router.navigator, openSession: openSession,
          leadingSections: AnyView(appSection)
        )
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: PhoneSettingsPage.self) { page($0) }
        .task { router.screenAppeared() }
        .toolbar {
          ToolbarItem(placement: .confirmationAction) {
            Button("Done") { router.isPresented = false }
              .accessibilityIdentifier("settings-done")
          }
        }
      }
      .presentationSizing(.page)
      .accessibilityIdentifier("settings-screen")
    }

    private var appSection: some View {
      Section {
        ForEach(PhoneSettingsPage.allCases.filter { $0 != .appearance || theme != nil }) { page in
          NavigationLink(value: page) {
            Label(page.title, systemImage: page.systemImage)
              .foregroundStyle(ThemeColor.primary)
          }
          .accessibilityIdentifier("settings-page-\(page.rawValue)")
        }
      }
    }

    private func page(_ page: PhoneSettingsPage) -> some View {
      content(page)
        .navigationTitle(page.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder private func content(_ page: PhoneSettingsPage) -> some View {
      switch page {
      case .general:
        Form {
          ComposerSettingsSection()
          SessionSettingsSection()
          LinksAndSessionsSettingsSection()
        }
        .formStyle(.grouped)
      case .appearance:
        if let theme {
          Form {
            ThemeSettingsView(preferences: theme)
            SettingsDataSection(theme: theme)
          }
          .formStyle(.grouped)
          .environment(
            \.pickerVisibilitySource,
            PickerVisibilityAdapter.source(
              connection.map { [$0] } ?? SupervisionConnections.shared.connections))
        }
      case .notifications:
        PhoneNotificationSettingsView(supervision: supervision)
      case .terminal:
        TerminalSettingsView()
      }
    }
  }
#endif
