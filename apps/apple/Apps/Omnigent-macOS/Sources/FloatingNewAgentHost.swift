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

  init(desktop: DesktopController, theme: ThemePreferences) {
    self.desktop = desktop
    self.theme = theme
    desktop.floatingPanelShortcut.onPress = { [weak self] in self?.show() }
  }

  /// Records whether `window`'s server offers the panel.
  /// - Parameters:
  ///   - window: The window's instance.
  ///   - connection: Its connection when its server turns `floating_composer` on, else `nil`.
  func announce(window: UUID, connection: ConnectionStore?) {
    supporting[window] = connection
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
    focusOrder.reversed().lazy.compactMap { self.supporting[$0] }.first
      ?? supporting.values.first
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
      FloatingNewAgentView(connection: connection) { [weak self, weak connection] sessionID in
        guard let self, let connection else { return }
        self.launched(sessionID, on: connection)
      }
      .appearanceSettings(theme)
      .omnigentAppearance(theme)
      .environment(\.useThisMachine, useThisMachine)
      .environment(
        \.openSettingsAt,
        OpenSettingsDestinationAction { [weak self] _ in self?.desktop.router.showSettings() })
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
    host: FloatingNewAgentHost
  ) -> some View {
    modifier(
      FloatingNewAgentSupport(
        connection: connection, window: window, registry: registry, host: host))
  }
}

private struct FloatingNewAgentSupport: ViewModifier {
  let connection: ConnectionStore
  let window: UUID
  let registry: ServerWindowRegistry
  let host: FloatingNewAgentHost

  func body(content: Content) -> some View {
    let offered = connection.pages?.offered?.floatingComposer == true
    return
      content
      .onChange(of: offered, initial: true) { _, offered in
        host.announce(window: window, connection: offered ? connection : nil)
        if offered, registry.keyWindow == window { host.focused(window) }
      }
      .onChange(of: registry.keyWindow == window) { _, isKey in
        if isKey { host.focused(window) }
      }
      .onDisappear { host.closed(window) }
  }
}
