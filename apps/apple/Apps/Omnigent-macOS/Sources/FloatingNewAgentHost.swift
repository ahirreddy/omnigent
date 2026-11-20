import AppKit
import OmnigentAppUI
import OmnigentCoreFFI
import OmnigentDesktop
import OmnigentStores
import OmnigentUIComponents
import SwiftUI

/// The floating New Agent panel (`floating_composer`): server windows whose server turns the
/// panel on announce it, which registers the system-wide shortcut; pressing it shows the panel
/// for the server of the most recently focused of those windows. A started session opens in a
/// window behind the panel, which hides and clears for the next prompt.
@MainActor
final class FloatingNewAgentHost {
  private let desktop: DesktopController
  private let theme: ThemePreferences
  private let panel = FloatingPanelController()
  /// The connection of each window whose server offers the panel.
  private var supporting: [UUID: ConnectionStore] = [:]
  /// The windows that offer the panel, most recently focused last.
  private var focusOrder: [UUID] = []
  /// The connection the panel's content was built for.
  private weak var shown: ConnectionStore?
  /// Each offering window's Settings, where the panel's Settings links open.
  private var settings: [UUID: SettingsNavigator] = [:]

  init(desktop: DesktopController, theme: ThemePreferences) {
    self.desktop = desktop
    self.theme = theme
    desktop.floatingPanelShortcut.onPress = { [weak self] in self?.show() }
  }

  /// Records whether `window`'s server offers the panel.
  /// - Parameters:
  ///   - window: The window's instance.
  ///   - connection: Its connection when its server turns `floating_composer` on, else `nil`.
  ///   - settings: The window's Settings.
  func announce(window: UUID, connection: ConnectionStore?, settings: SettingsNavigator? = nil) {
    supporting[window] = connection
    self.settings[window] = connection == nil ? nil : settings
    if connection == nil { focusOrder.removeAll { $0 == window } }
    desktop.floatingPanelShortcut.isAvailable = !supporting.isEmpty
    if let shown, !supporting.values.contains(where: { $0 === shown }) { closePanel() }
  }

  /// Records that `window` took the keyboard, so the panel opens for its server next.
  /// - Parameter window: The window's instance.
  func focused(_ window: UUID) {
    guard supporting[window] != nil else { return }
    focusOrder.removeAll { $0 == window }
    focusOrder.append(window)
  }

  /// The window closed.
  /// - Parameter window: The window's instance.
  func closed(_ window: UUID) {
    announce(window: window, connection: nil)
  }

  /// The connection the panel opens for: the most recently focused window's that offers it.
  var target: ConnectionStore? {
    targetWindow.flatMap { supporting[$0] }
  }

  /// The window whose server the panel opens for.
  private var targetWindow: UUID? {
    focusOrder.reversed().first { supporting[$0] != nil } ?? supporting.keys.first
  }

  /// Opens Settings at `destination` in the window of the panel's server, else the front one.
  private func openSettings(_ destination: SettingsDestination) {
    guard let window = targetWindow, let navigator = settings[window] else {
      desktop.router.showSettings()
      return
    }
    navigator.open(destination)
    desktop.router.showSettings(in: window)
  }

  /// Shows the panel, built for the target server (rebuilt when that server changed).
  func show() {
    guard let connection = target else { return }
    if let shown, shown !== connection { panel.replaceContent(content(connection)) }
    shown = connection
    panel.show { content(connection) }
  }

  private func closePanel() {
    panel.hide()
    shown = nil
    panel.replaceContent(AnyView(EmptyView()))
  }

  private func content(_ connection: ConnectionStore) -> AnyView {
    AnyView(
      FloatingNewAgentView(
        connection: connection,
        claimsEscape: { [weak self] claimed in self?.panel.contentClaimsEscape = claimed },
        opened: { [weak self, weak connection] sessionID in
          guard let self, let connection else { return }
          self.launched(sessionID, on: connection)
        }
      )
      .appearanceSettings(theme)
      .omnigentAppearance(theme)
      .environment(\.useThisMachine, useThisMachine)
      .environment(
        \.openSettingsAt,
        OpenSettingsDestinationAction { [weak self] destination in
          self?.openSettings(destination)
        })
    )
  }

  /// "Use This Mac" in the panel's Connect a Host, where this edition runs the CLI.
  private var useThisMachine: UseThisMachineAction? {
    let server = desktop.localServer
    guard server.capability.isAvailable else { return nil }
    return UseThisMachineAction { url in
      await server.startHost(serverURL: url)
      return server.host.summary
    }
  }

  /// Opens the started session in a window behind the panel, then hides and clears the panel.
  private func launched(_ sessionID: String, on connection: ConnectionStore) {
    if let url = connection.supervisedServerURL.flatMap(URL.init(string:)) {
      desktop.router.openBehind(.conversation(sessionID: sessionID), onServer: url)
    } else {
      desktop.onIssue(.routingFailed("the panel's session \(sessionID) has no server to open on"))
    }
    panel.hide()
    panel.replaceContent(content(connection))
  }
}

extension View {
  /// Tells the floating New Agent panel whether this window's server offers it, and when the
  /// window takes the keyboard, as the desktop app's main windows announce support.
  func floatingNewAgentSupport(
    _ connection: ConnectionStore, window: UUID, registry: ServerWindowRegistry,
    host: FloatingNewAgentHost, settings: SettingsNavigator
  ) -> some View {
    modifier(
      FloatingNewAgentSupport(
        connection: connection, window: window, registry: registry, host: host,
        settings: settings))
  }
}

private struct FloatingNewAgentSupport: ViewModifier {
  let connection: ConnectionStore
  let window: UUID
  let registry: ServerWindowRegistry
  let host: FloatingNewAgentHost
  let settings: SettingsNavigator

  func body(content: Content) -> some View {
    let offered = connection.pages?.offered?.floatingComposer == true
    return
      content
      .onChange(of: offered, initial: true) { _, offered in
        host.announce(
          window: window, connection: offered ? connection : nil, settings: settings)
        if offered, registry.keyWindow == window { host.focused(window) }
      }
      .onChange(of: registry.keyWindow == window) { _, isKey in
        if isKey { host.focused(window) }
      }
      .onDisappear { host.closed(window) }
  }
}
