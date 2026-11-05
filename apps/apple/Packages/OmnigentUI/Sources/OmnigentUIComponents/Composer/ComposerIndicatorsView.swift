import SwiftUI

/// The tray's task indicators, as the web's composer bar has them: background tasks still
/// running, sub-agents in play (a menu that opens each), and the goal pill.
struct ComposerIndicatorsView: View {
  let indicators: ComposerTaskIndicators
  let actions: ComposerIndicatorActions
  /// The goal's objective beside its glyph; the CLI status line shows the glyph alone, as the web
  /// does, with the objective in the tooltip.
  var showsGoalObjective = true

  var body: some View {
    HStack(spacing: Theme.Spacing.small) {
      if indicators.backgroundTasks > 0 {
        BackgroundTasksButton(indicators: indicators)
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
      .labelStyle(GoalLabelStyle(showsTitle: showsGoalObjective))
      .foregroundStyle(.secondary)
    }
    .disabled(actions.openGoal == nil)
    .help("Goal (\(goal.status)): \(goal.objective)")
    .accessibilityLabel("Goal, \(goal.status)")
    .accessibilityValue(goal.objective)
    .accessibilityIdentifier("composer-goal")
  }
}

/// The running background shells: the count, opening a list of what each one runs (web
/// `BackgroundTaskIndicator`).
private struct BackgroundTasksButton: View {
  let indicators: ComposerTaskIndicators
  @State private var isShown = false

  private var label: String {
    let count = indicators.backgroundTasks
    return "\(count) background task\(count == 1 ? "" : "s")"
  }

  var body: some View {
    Button {
      isShown.toggle()
    } label: {
      Label("\(indicators.backgroundTasks)", systemImage: "apple.terminal")
        .monospacedDigit()
        .foregroundStyle(.secondary)
    }
    .help("\(label) still running")
    .accessibilityLabel("\(label) still running")
    .accessibilityIdentifier("composer-background-tasks")
    .popover(isPresented: $isShown, arrowEdge: .top) { list }
    .onChange(of: indicators.backgroundTasks) { _, count in
      if count <= 0, isShown { isShown = false }
    }
  }

  /// Grows with the list up to a cap, then scrolls.
  private var list: some View {
    ViewThatFits(in: .vertical) {
      rows
      ScrollView { rows }
    }
    .frame(width: 360)
    .frame(maxHeight: 380)
    .accessibilityLabel(label)
  }

  private var rows: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
      ForEach(indicators.backgroundTaskList) { task in
        HStack(alignment: .top, spacing: Theme.Spacing.small) {
          Image(systemName: "apple.terminal").foregroundStyle(.secondary)
            .accessibilityHidden(true)
          VStack(alignment: .leading, spacing: Theme.Spacing.tiny) {
            Text(task.title).font(.callout)
            if let command = task.command {
              Text(command).font(.caption.monospaced()).foregroundStyle(.secondary)
                .lineLimit(3)
                .textSelection(.enabled)
            }
          }
          Spacer(minLength: Theme.Spacing.small)
          HStack(spacing: Theme.Spacing.extraSmall) {
            ProgressView().controlSize(.mini)
            Text("Running")
          }
          .font(.caption)
          .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
      }
      if let note = indicators.backgroundTaskNote {
        if !indicators.backgroundTaskList.isEmpty { Divider() }
        Text(note).font(.callout).foregroundStyle(.secondary)
      }
    }
    .padding(Theme.Spacing.medium)
  }
}

/// The goal pill's glyph with or without its objective.
private struct GoalLabelStyle: LabelStyle {
  let showsTitle: Bool

  @ViewBuilder func makeBody(configuration: Configuration) -> some View {
    if showsTitle { Label(configuration) } else { configuration.icon }
  }
}
