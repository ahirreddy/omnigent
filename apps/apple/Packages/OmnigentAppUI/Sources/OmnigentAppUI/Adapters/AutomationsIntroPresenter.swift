import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents
import SwiftUI

/// Shows the Automations guide once per server and user, after the page's first successful
/// load, as the web does. Closing it any way marks it seen.
struct AutomationsIntroPresenter: ViewModifier {
  let connection: ConnectionStore
  let defaults: UserDefaults
  @State private var isPresented = false

  /// The seen flag's key, or `nil` until the server and user are known.
  static func seenKey(baseURL: String?, userID: String?) -> String? {
    guard let baseURL, let userID else { return nil }
    return "omnigent.automationsIntro.v1.\(baseURL).\(userID)"
  }

  private var key: String? {
    Self.seenKey(
      baseURL: connection.connectedServer?.baseUrl, userID: connection.connectedServer?.userId)
  }

  private var isLoaded: Bool { connection.pages?.automations.value != nil }

  func body(content: Content) -> some View {
    content
      .onChange(of: isLoaded, initial: true) {
        guard isLoaded, let key, !defaults.bool(forKey: key) else { return }
        isPresented = true
      }
      .sheet(isPresented: $isPresented, onDismiss: markSeen) {
        AutomationsIntro(
          steps: AutomationsIntro.steps(
            sessionModes: connection.pages?.offered?.automationSessionModes == true,
            sandboxes: connection.creationStore?.catalog.value?.managedSandboxes == true),
          dismiss: { isPresented = false })
      }
  }

  private func markSeen() {
    guard let key, !defaults.bool(forKey: key) else { return }
    defaults.set(true, forKey: key)
  }
}

extension View {
  /// Shows the Automations guide on the first visit.
  func automationsIntro(_ connection: ConnectionStore, defaults: UserDefaults = .standard)
    -> some View
  {
    modifier(AutomationsIntroPresenter(connection: connection, defaults: defaults))
  }
}
