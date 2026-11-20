import SwiftUI

/// The reconnect sheet's one-click way back when the offline host is this Mac (the web's
/// "Reconnecting this machine…"): it starts this Mac's host again, then checks the session.
struct ReconnectThisMachineSection: View {
  let reconnect: @MainActor () async -> String?
  let checkAgain: (@MainActor () -> Void)?
  @State private var isReconnecting = false
  @State private var status: String?

  var body: some View {
    Section {
      Button {
        Task {
          isReconnecting = true
          status = await reconnect()
          isReconnecting = false
          checkAgain?()
        }
      } label: {
        if isReconnecting {
          Label {
            Text("Reconnecting this Mac\u{2026}")
          } icon: {
            ProgressView().controlSize(.small)
          }
        } else {
          Label("Reconnect This Mac", systemImage: "bolt.horizontal.circle")
        }
      }
      .disabled(isReconnecting)
      .accessibilityIdentifier("reconnect-session-this-machine")
      if let status {
        Text(status).font(.callout).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("reconnect-session-this-machine-status")
      }
    } footer: {
      Text("This session\u{2019}s host is this Mac. Reconnect it here, or run the command below.")
    }
  }
}
