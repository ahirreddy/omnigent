import SwiftUI

/// The tray's task indicators, as the web's composer bar has them: background tasks still
/// running, sub-agents in play (a menu that opens each), and the goal pill.
struct ComposerIndicatorsView: View {
  let indicators: ComposerTaskIndicators
  let actions: ComposerIndicatorActions

  var body: some View {
    HStack(spacing: Theme.Spacing.small) {
      if indicators.backgroundTasks > 0 {
        let label =
          "\(indicators.backgroundTasks) background task"
          + (indicators.backgroundTasks == 1 ? "" : "s")
        Label("\(indicators.backgroundTasks)", systemImage: "apple.terminal")
          .monospacedDigit()
          .foregroundStyle(.secondary)
          .help("\(label) still running")
          .accessibilityLabel("\(label) still running")
          .accessibilityIdentifier("composer-background-tasks")
      }
      if !indicators.subagents.isEmpty {
        subagents
      }
      if let goal = indicators.goal {
        goalPill(goal)
      }
    }
  }

  private var subagents: some View {
    let summary = indicators.subagentSummary
    let needsYou = indicators.subagents.contains { $0.status == .needsYou }
    return Menu {
      ForEach(indicators.subagents) { child in
        Button {
          actions.openSubagent?(child.id)
        } label: {
          Text(child.title)
          Text(child.status.title)
        }
        .disabled(actions.openSubagent == nil)
      }
    } label: {
      HStack(spacing: Theme.Spacing.extraSmall) {
        Image(systemName: "person.2").accessibilityHidden(true)
        Text("\(indicators.subagents.count)").monospacedDigit()
        if needsYou {
          Circle().fill(Theme.attention).frame(width: 6, height: 6).accessibilityHidden(true)
        }
      }
      .foregroundStyle(.secondary)
    }
    .menuIndicator(.hidden)
    .fixedSize()
    .help(summary)
    .accessibilityLabel(summary)
    .accessibilityIdentifier("composer-subagents")
  }

  private func goalPill(_ goal: ComposerGoal) -> some View {
    Button {
      actions.openGoal?()
    } label: {
      Label {
        Text(goal.objective).lineLimit(1).truncationMode(.tail)
          .frame(maxWidth: Theme.Control.serverNameWidth, alignment: .leading)
          .fixedSize(horizontal: true, vertical: false)
      } icon: {
        Image(systemName: goal.canResume ? "pause.circle" : "target")
      }
      .foregroundStyle(.secondary)
    }
    .disabled(actions.openGoal == nil)
    .help("Goal (\(goal.status)): \(goal.objective)")
    .accessibilityLabel("Goal, \(goal.status)")
    .accessibilityValue(goal.objective)
    .accessibilityIdentifier("composer-goal")
  }
}
