import SwiftUI

/// A failed turn's card, as the web's error block: the core's headline (the runner's title or
/// the failure code's sentence), the message, why it failed and the next step, then the actions
/// the failure allows (Retry or Resume, a fork for failures only a new session gets past, copying
/// the recovery command). Notices and spent budgets read neutral instead of as failures.
struct ErrorRowView: View {
  let row: Row
  let activity: Activity
  @State private var isExpanded = false
  @Environment(\.conversationActions) private var actions

  /// Failures a new session gets past, with the action's label.
  static func forkLabel(code: String?) -> String? {
    switch code {
    case "workspace_missing": "Continue in Another Directory\u{2026}"
    case "session_agent_missing", "codex_compaction_model_failed": "Fork Session\u{2026}"
    default: nil
    }
  }

  private var isNeutral: Bool { activity.status == "info" }
  private var tint: ThemeColor { isNeutral ? Theme.secondary : Theme.failure }
  /// The message under the headline, unless the headline already says it.
  private var message: String? {
    activity.summary.isEmpty || activity.summary == activity.title ? nil : activity.summary
  }
  /// The sections shown inline; the rest stay under Details.
  private static let inlineDetails: Set<String> = ["message", "cause", "remediation"]

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.small) {
      HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
        Image(systemName: isNeutral ? "info.circle.fill" : "exclamationmark.octagon.fill")
          .foregroundStyle(tint)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: Theme.Spacing.extraSmall) {
          Text(activity.title).font(.callout.weight(.semibold))
            .fixedSize(horizontal: false, vertical: true)
          if let message {
            Text(message)
              .font(.callout)
              .textSelection(.enabled)
              .fixedSize(horizontal: false, vertical: true)
          }
          if let cause = activity.detail("cause") {
            Text(cause).font(.callout).foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
          if let remediation = activity.detail("remediation") {
            Text(remediation).font(Theme.codeFont).textSelection(.enabled)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        Spacer(minLength: 0)
        CopyButton(text: row.text.isEmpty ? activity.summary : row.text, label: "Copy error")
      }
      actionRow
      let details = activity.details.filter { !Self.inlineDetails.contains($0.id) }
      if !details.isEmpty {
        DisclosureGroup("View Diagnostics", isExpanded: $isExpanded) {
          DetailSectionsView(sections: details, rowID: row.id)
            .padding(.top, Theme.Spacing.small)
        }
        .font(.caption)
      }
    }
    .padding(Theme.Spacing.medium)
    .cardSurface(cornerRadius: Theme.Radius.medium, tint: tint, stroke: tint.opacity(0.35))
    .accessibilityElement(children: .contain)
    .accessibilityLabel("\(isNeutral ? "Notice" : "Error"): \(activity.title)")
    .accessibilityIdentifier("error-\(row.id)")
  }

  @ViewBuilder private var actionRow: some View {
    let forkLabel = Self.forkLabel(code: activity.detail("code"))
    let remediation = activity.detail("remediation")
    let retry = activity.recovery.flatMap { recovery in
      actions.retryFailedTurn.map { (recovery, $0) }
    }
    if retry != nil || (forkLabel != nil && actions.forkFrom != nil) || remediation != nil {
      HStack(spacing: Theme.Spacing.small) {
        if let (recovery, retry) = retry {
          Button(recovery == .continue ? "Retry" : "Resume") { retry(row) }
            .buttonStyle(.bordered)
            .help(
              recovery == .continue
                ? "Continue the turn from where it stopped" : "Restart the agent and continue"
            )
            .accessibilityIdentifier("error-retry-\(row.id)")
        }
        if let forkLabel, let fork = actions.forkFrom {
          Button(forkLabel, systemImage: "arrow.triangle.branch") { fork(row) }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("error-fork-\(row.id)")
        }
        if let remediation {
          CopyButton(
            text: remediation, label: "Copy Recovery Command",
            identifier: "error-copy-recovery-\(row.id)", showsLabel: true)
        }
      }
      .padding(.leading, Theme.Spacing.large)
    }
  }
}
