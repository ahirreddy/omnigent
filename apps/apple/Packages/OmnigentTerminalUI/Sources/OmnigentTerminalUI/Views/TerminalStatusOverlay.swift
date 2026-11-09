import SwiftUI

/// Connection status over the surface: a spinner while connecting, a banner while
/// reconnecting, and a dead-end card with the reason (and Retry where it can help) after a
/// close or failure. The surface stays visible underneath so the last screen remains readable.
struct TerminalStatusOverlay: View {
  let state: TerminalConnectionState
  let retry: () -> Void

  var body: some View {
    switch state {
    case .idle, .attached:
      EmptyView()
    case .connecting:
      ProgressView("Connecting…")
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    case .reconnecting(let failures, let delay, let reason):
      VStack {
        Spacer()
        HStack(spacing: 8) {
          ProgressView().controlSize(.small)
          Text(reconnectText(failures: failures, delay: delay, reason: reason))
            .font(.callout)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .padding(.bottom, 12)
      }
      .accessibilityElement(children: .combine)
    case .closed(let reason):
      card(
        title: closedTitle(reason), detail: closedDetail(reason), systemImage: "terminal",
        canRetry: true)
    case .failed(let failure):
      if Self.shellIsGone(failure.message) {
        card(
          title: "This terminal isn't running",
          detail:
            "Its shell may have ended when the host restarted. Reattach if it comes back, or "
            + "close this tab and open a new terminal.",
          systemImage: "terminal", canRetry: true)
      } else {
        card(
          title: failure.requiresSignIn ? "Sign in again" : "Terminal connection failed",
          detail: failure.message, systemImage: "exclamationmark.triangle",
          canRetry: !failure.requiresSignIn)
      }
    }
  }

  /// The server reached the host, which had no process to attach to.
  static func shellIsGone(_ message: String) -> Bool {
    message.contains("runner attach factory failed")
  }

  private func reconnectText(failures: Int, delay: Int, reason: String) -> String {
    if delay <= 0 { return "Reconnecting…" }
    let seconds = delay / 1000 + (delay % 1000 > 0 ? 1 : 0)
    return "Connection lost (\(reason)). Retrying in \(seconds)s…"
  }

  private func closedTitle(_ reason: TerminalCloseReason) -> String {
    switch reason {
    case .terminalEnded: "Terminal ended"
    case .detached: "Terminal detached"
    case .serverClosed: "Connection closed"
    case .stopped: "Disconnected"
    }
  }

  private func closedDetail(_ reason: TerminalCloseReason) -> String {
    switch reason {
    case .terminalEnded(let reason):
      reason.isEmpty ? "The terminal's program exited." : reason
    case .detached(let reason):
      reason.isEmpty ? "The terminal is still running. Reattach to continue." : reason
    case .serverClosed(let code, let reason):
      reason.isEmpty ? "The server closed the terminal (code \(code))." : "\(reason) (code \(code))"
    case .stopped:
      "You detached from this terminal."
    }
  }

  private func card(title: String, detail: String, systemImage: String, canRetry: Bool)
    -> some View
  {
    VStack(spacing: 10) {
      Image(systemName: systemImage)
        .font(.title2)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      Text(title).font(.headline)
      Text(detail)
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
      if canRetry {
        Button("Reattach", action: retry)
          .buttonStyle(.borderedProminent)
          .accessibilityIdentifier("terminal-reattach")
      }
    }
    .padding(20)
    .frame(maxWidth: 360)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("terminal-status-card")
  }
}
