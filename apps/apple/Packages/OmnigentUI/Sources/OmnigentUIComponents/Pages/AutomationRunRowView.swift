import SwiftUI

/// One run: its status icon, when it fired, how long it took, its session's cost, what it is
/// doing or waiting on, why it failed, and the PRs it made, at the row's top right. A run with
/// a session opens it.
struct AutomationRunRowView: View {
  let run: AutomationRunRow
  let open: (@MainActor () -> Void)?
  var openPullRequest: (@MainActor (URL) -> Void)?
  @State private var isHovered = false

  var body: some View {
    let row = HStack(
      alignment: run.failureReason == nil ? .center : .top, spacing: Theme.Spacing.medium
    ) {
      indicator.frame(width: 20, height: 20)
      VStack(alignment: .leading, spacing: Theme.Spacing.tiny) {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
          Text(run.timestamp)
          if let duration = run.duration {
            Text(duration).foregroundStyle(.secondary)
          }
          if let cost = run.sessionCost {
            Text(cost).foregroundStyle(.secondary)
              .accessibilityIdentifier("automation-run-cost-\(run.id)")
          }
          if let label = run.statusLabel, !run.needsApproval {
            Text(label).foregroundStyle(.secondary)
          }
        }
        if run.needsApproval {
          Text("Session needs approval \u{00B7} Open to review")
            .foregroundStyle(Theme.warning)
            .accessibilityIdentifier("automation-run-approval-\(run.id)")
        }
        if let reason = run.failureReason {
          Text(failureText(reason)).foregroundStyle(.secondary)
          if let detail = run.errorDetail {
            Text(detail).foregroundStyle(.secondary).textSelection(.enabled)
              .accessibilityIdentifier("automation-run-detail-\(run.id)")
          }
        }
      }
      .font(.callout)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, Theme.Spacing.small).padding(.vertical, Theme.Spacing.small)
    .background(
      RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
        .fill(isHovered && open != nil ? AutomationStyle.mutedFill : .clear)
    )
    .contentShape(Rectangle())
    .accessibilityIdentifier("automation-run-\(run.id)")
    HStack(alignment: .top, spacing: Theme.Spacing.small) {
      if let open {
        Button(action: open) { row }.buttonStyle(.plain).onHover { isHovered = $0 }
      } else {
        row
      }
      if let summary = run.pullRequestSummary, !run.pullRequests.isEmpty {
        pullRequests(summary).padding(.top, Theme.Spacing.small)
      }
    }
  }

  /// The run's PRs as one underlined line that opens the list, as the web's `RunPullRequests`.
  private func pullRequests(_ summary: String) -> some View {
    Menu {
      ForEach(run.pullRequests) { pullRequest in
        Button {
          openPullRequest?(pullRequest.url)
        } label: {
          Text("\(pullRequest.number) \(pullRequest.title)")
          Text(
            "\(pullRequest.status) \u{00B7} \(pullRequest.repository) \u{00B7} \(pullRequest.origin)"
          )
        }
      }
    } label: {
      Text(summary).font(.callout).underline().foregroundStyle(.secondary)
    }
    .menuStyle(.button)
    .buttonStyle(.borderless)
    .menuIndicator(.hidden)
    .fixedSize()
    .accessibilityLabel("\(summary). Show pull requests")
    .accessibilityIdentifier("automation-run-prs-\(run.id)")
  }

  private func failureText(_ reason: String) -> AttributedString {
    guard let stage = run.failureStage else { return AttributedString(reason) }
    var text = AttributedString(stage)
    text.font = .callout.weight(.medium)
    text.foregroundColor = .primary.opacity(0.8)
    return text + AttributedString(" \u{00B7} \(reason)")
  }

  @ViewBuilder private var indicator: some View {
    switch run.indicator {
    case .failed:
      Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.warning)
        .help("Failed").accessibilityLabel("Failed")
    case .skipped:
      Image(systemName: "calendar.badge.minus").foregroundStyle(.secondary)
        .help("Skipped").accessibilityLabel("Skipped")
    case .inFlight:
      ProgressView().controlSize(.mini)
    case .sessionRunning:
      ProgressView().controlSize(.mini).help("Session still running")
    case .unread:
      Circle().fill(Theme.unread).frame(width: 8, height: 8)
        .help("Unread").accessibilityLabel("Unread")
    case .completed:
      Circle().fill(.secondary.opacity(0.4)).frame(width: 8, height: 8)
        .help("Completed").accessibilityLabel("Completed")
    case .queued:
      Circle().fill(.secondary.opacity(0.4)).frame(width: 8, height: 8).accessibilityLabel("Queued")
    }
  }
}
