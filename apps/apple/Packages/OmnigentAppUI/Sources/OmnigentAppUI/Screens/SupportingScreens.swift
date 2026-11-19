import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents
import SwiftUI

/// The connection's state and connection-level failures, above the detail. The state line comes
/// from the one reachability, shows "Reconnected" for a moment once the server is back, and
/// clears itself; other failures stay until the user dismisses them.
struct ConnectionIssuesBanner: View {
  let connection: ConnectionStore
  /// Tries the server now.
  var retry: (@MainActor () -> Void)?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    let status = Self.status(connection.health)
    let issues = Self.shownIssues(connection)
    VStack(spacing: 0) {
      if let status {
        ConnectionStatusBanner(state: status, retry: retry)
          .transition(.move(edge: .top).combined(with: .opacity))
      }
      if let issue = issues.last {
        HStack {
          Self.bannerRow(
            systemImage: "exclamationmark.triangle",
            text: issues.count > 1
              ? "\(issue.error.message) (\(issues.count) problems)" : issue.error.message,
            isError: true
          )
          .accessibilityIdentifier("connection.issue")
          Button("Dismiss") { connection.dismissIssues() }
            .controlSize(.small)
            .padding(.trailing, 10)
            .accessibilityIdentifier("issues.dismiss")
        }
        .background(.red.opacity(0.08))
      }
    }
    .background(.bar)
    .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: status)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("connection.issues")
  }

  /// The state line: "Reconnected" just after a return, else the disruption. Offline has its
  /// own lines under the sidebar and the composer.
  static func status(_ health: ConnectionHealth) -> ConnectionBannerState? {
    if health.showsReconnected { return .reconnected }
    switch health.reachability {
    case .online, .offline: return nil
    case .reconnecting(let reason, _): return .reconnecting(detail: reason.message)
    case .unreachable(let error): return .unreachable(detail: error.message)
    }
  }

  /// The failures to show: while the server can't be reached the state line says so, and its
  /// return clears them, so failures that only say the network is down wait unseen.
  static func shownIssues(_ connection: ConnectionStore) -> [CoreIssue] {
    guard connection.health.reachability.isDisrupted else { return connection.issues }
    return connection.issues.filter { !$0.error.isConnectivityProblem }
  }

  static func bannerRow(systemImage: String, text: String, isError: Bool) -> some View {
    Label(text, systemImage: systemImage)
      .font(.callout)
      .foregroundStyle(isError ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
      .lineLimit(3)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 12)
      .padding(.vertical, 6)
  }
}

/// A tab that could not open, such as a terminal the session's runner refused, until dismissed.
/// A banner rather than an alert: a modal opened as a Mac menu closes can stop answering clicks.
struct TabFailureBanner: View {
  let message: String
  let dismiss: () -> Void

  var body: some View {
    HStack {
      ConnectionIssuesBanner.bannerRow(
        systemImage: "exclamationmark.triangle", text: message, isError: true)
      Button("Dismiss", action: dismiss)
        .controlSize(.small)
        .padding(.trailing, 10)
        .accessibilityIdentifier("tab-failure.dismiss")
    }
    .background(.red.opacity(0.08))
    .background(.bar)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("tab-failure")
  }
}
