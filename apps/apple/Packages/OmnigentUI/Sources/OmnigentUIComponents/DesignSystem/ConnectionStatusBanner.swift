public import SwiftUI

/// What the window's connection line says while the server cannot be reached, and for a moment
/// once it is back.
nonisolated public enum ConnectionBannerState: Hashable, Sendable {
  /// The live connection dropped and is being restored on its own; `detail` says why.
  case reconnecting(detail: String?)
  /// Retrying stopped, or the server could not be reached; Retry tries again.
  case unreachable(detail: String?)
  /// The connection is back: shown briefly, then gone.
  case reconnected

  /// The line's headline.
  public var title: String {
    switch self {
    case .reconnecting: "Connection lost. Reconnecting\u{2026}"
    case .unreachable: "Can\u{2019}t reach the server"
    case .reconnected: "Reconnected"
    }
  }

  /// Why, when known.
  public var detail: String? {
    switch self {
    case .reconnecting(let detail), .unreachable(let detail): detail
    case .reconnected: nil
    }
  }

  /// What VoiceOver hears when the line appears or changes kind.
  public var announcement: String {
    switch self {
    case .reconnecting: "Connection lost. Reconnecting."
    case .unreachable: "Can\u{2019}t reach the server."
    case .reconnected: "Reconnected"
    }
  }

  /// The line's kind, which changing announces again; a new reason or attempt does not.
  var kind: Int {
    switch self {
    case .reconnecting: 0
    case .unreachable: 1
    case .reconnected: 2
    }
  }
}

/// The connection line above the detail: a quiet bar while reconnecting, an orange one with
/// Retry when the server can't be reached, and a green "Reconnected" that the caller removes
/// after a moment. Each new kind is announced to VoiceOver.
public struct ConnectionStatusBanner: View {
  private let state: ConnectionBannerState
  private let retry: (@MainActor () -> Void)?

  /// Creates the line.
  /// - Parameters:
  ///   - state: What it says.
  ///   - retry: Tries the server now; shown while it is not back.
  public init(state: ConnectionBannerState, retry: (@MainActor () -> Void)? = nil) {
    self.state = state
    self.retry = retry
  }

  /// The line.
  public var body: some View {
    HStack(spacing: Theme.Spacing.small) {
      icon
      VStack(alignment: .leading, spacing: 1) {
        Text(state.title).font(.callout.weight(.medium))
        if let detail = state.detail {
          Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      if let retry, state != .reconnected {
        Button("Retry Now", action: retry)
          .controlSize(.small)
          .accessibilityIdentifier("connection.retry")
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(tint.opacity(0.1))
    .background(.bar)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier(identifier)
    .task(id: state.kind) { AccessibilityNotification.Announcement(state.announcement).post() }
  }

  @ViewBuilder private var icon: some View {
    switch state {
    case .reconnecting:
      ProgressView().controlSize(.small).accessibilityHidden(true)
    case .unreachable:
      Image(systemName: "wifi.exclamationmark")
        .foregroundStyle(Theme.warning)
        .accessibilityHidden(true)
    case .reconnected:
      Image(systemName: "checkmark.circle.fill")
        .foregroundStyle(Theme.success)
        .accessibilityHidden(true)
    }
  }

  private var tint: Color {
    switch state {
    case .reconnecting: .clear
    case .unreachable: .orange
    case .reconnected: .green
    }
  }

  private var identifier: String {
    switch state {
    case .reconnecting: "connection.reconnecting"
    case .unreachable: "connection.unreachable"
    case .reconnected: "connection.reconnected"
    }
  }
}
