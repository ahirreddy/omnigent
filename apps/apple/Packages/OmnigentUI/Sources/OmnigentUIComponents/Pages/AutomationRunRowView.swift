import SwiftUI

/// One run: its status icon, when it fired, how long it took, its session's cost, what it is
/// doing or waiting on, why it failed, and the PRs it made, at the row's top right. A run with
/// a session opens it.
struct AutomationRunRowView: View {
  let run: AutomationRunRow
  let open: (@MainActor () -> Void)?
  var openPullRequest: (@MainActor (URL) -> Void)?
  @State private var isHovered = false
  @Environment(\.layoutWidth) private var layoutWidth

  var body: some View {
    let row = HStack(
      alignment: run.failureReason == nil ? .center : .top, spacing: Theme.Spacing.medium
    ) {
      indicator.frame(width: 20, height: 20)
      VStack(alignment: .leading, spacing: Theme.Spacing.tiny) {
        // Wraps a whole item at a time on a narrow screen, as the web's line does.
        FlowLayout(spacing: Theme.Spacing.small) {
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
      .font(AutomationStyle.detail)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, Theme.Spacing.small).padding(.vertical, Theme.Spacing.small)
    .background(
      RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
        .fill(isHovered && open != nil ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear))
    )
    .contentShape(Rectangle())
    .accessibilityIdentifier("automation-run-\(run.id)")
    let summary = run.pullRequestSummary.flatMap { run.pullRequests.isEmpty ? nil : $0 }
    // On a phone the PR line goes under the run, which it would otherwise squeeze.
    let layout =
      layoutWidth == .compact
      ? AnyLayout(VStackLayout(alignment: .leading, spacing: 0))
      : AnyLayout(HStackLayout(alignment: .top, spacing: Theme.Spacing.small))
    layout {
      if let open {
        Button(action: open) { row }.buttonStyle(.plain).onHover { isHovered = $0 }
      } else {
        row
      }
      if let summary {
        pullRequests(summary)
          .padding(.top, layoutWidth == .compact ? 0 : Theme.Spacing.small)
          .padding(.leading, layoutWidth == .compact ? 40 : 0)
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
      Label(summary, systemImage: "arrow.triangle.pull").font(AutomationStyle.detail)
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
      Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
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
