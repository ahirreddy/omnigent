import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents
import SwiftUI

/// Connection-level failures and the updates socket's state, above the detail. Failures stay
/// until the user dismisses them.
struct ConnectionIssuesBanner: View {
  let connection: ConnectionStore

  var body: some View {
    VStack(spacing: 0) {
      if let status = Self.describe(connection.updatesLink) {
        Self.bannerRow(systemImage: "arrow.triangle.2.circlepath", text: status, isError: false)
          .accessibilityIdentifier("connection.status")
      }
      if let issue = connection.issues.last {
        HStack {
          Self.bannerRow(
            systemImage: "exclamationmark.triangle",
            text: connection.issues.count > 1
              ? "\(issue.error.message) (\(connection.issues.count) problems)"
              : issue.error.message,
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
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("connection.issues")
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

  /// The updates socket's state when it is not live, `nil` while live or idle.
  static func describe(_ state: LinkState) -> String? {
    switch state {
    case .idle, .live, .stopped: return nil
    case .connecting: return "Connecting to live updates\u{2026}"
    case .reconnecting(let reason, _, let delayMs):
      let seconds = max(1, Int((Double(delayMs) / 1_000).rounded()))
      return "Live updates reconnecting in \(seconds)s: \(reason.message)"
    case .closed: return "Live updates closed."
    case .failed(let error): return "Live updates failed: \(error.message)"
    }
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
