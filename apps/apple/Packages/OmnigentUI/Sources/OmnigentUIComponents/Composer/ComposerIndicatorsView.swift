import SwiftUI

/// The tray's task indicators, as the web's composer bar has them: background tasks still
/// running, sub-agents still in play (each a count that opens its list), and the goal pill.
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
        SubagentsButton(indicators: indicators, open: actions.openSubagent)
      }
      if let goal = indicators.goal {
        goalPill(goal)
      }
    }
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
      .contentShape(Rectangle())
    }
    .disabled(actions.openGoal == nil)
    .help("Goal (\(goal.status)): \(goal.objective)")
    .accessibilityLabel("Goal, \(goal.status)")
    .accessibilityValue(goal.objective)
    .accessibilityIdentifier("composer-goal")
  }
}

/// A count's list in its popover: grows with its rows up to a cap, then scrolls.
private struct IndicatorList<Rows: View>: View {
  let label: String
  @ViewBuilder let rows: Rows

  var body: some View {
    ViewThatFits(in: .vertical) {
      rows
      ScrollView { rows }
    }
    .frame(width: 360)
    .frame(maxHeight: 380)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(label)
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
        .contentShape(Rectangle())
    }
    .help("\(label) still running")
    .accessibilityLabel("\(label) still running")
    .accessibilityHint("Lists what each one runs")
    .accessibilityIdentifier("composer-background-tasks")
    .popover(isPresented: $isShown, arrowEdge: .top) {
      IndicatorList(label: label) { BackgroundTaskRows(indicators: indicators) }
    }
  }
}

/// Each running shell: its description or command, the command under a description, and that it
/// is running; then what is said about the ones the session did not name.
struct BackgroundTaskRows: View {
  let indicators: ComposerTaskIndicators

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
      ForEach(indicators.backgroundTaskList) { task in
        HStack(alignment: .top, spacing: Theme.Spacing.small) {
          Image(systemName: "apple.terminal").foregroundStyle(.secondary)
            .accessibilityHidden(true)
          VStack(alignment: .leading, spacing: Theme.Spacing.tiny) {
            Text(task.title).font(.callout)
            if let command = task.command {
              BackgroundTaskCommand(command: command)
            }
          }
          Spacer(minLength: Theme.Spacing.small)
          RunningLabel()
        }
        .accessibilityElement(children: .contain)
      }
      if let note = indicators.backgroundTaskNote {
        if !indicators.backgroundTaskList.isEmpty { Divider() }
        Text(note).font(.callout).foregroundStyle(.secondary)
      }
    }
    .padding(Theme.Spacing.medium)
  }
}

/// A task's command, two lines until expanded; the chevron shows only when the command is cut
/// (web `TaskCommand`).
private struct BackgroundTaskCommand: View {
  let command: String
  @State private var isExpanded = false
  @State private var isClipped = false

  var body: some View {
    HStack(alignment: .top, spacing: Theme.Spacing.extraSmall) {
      text
        .lineLimit(isExpanded ? nil : 2)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { if !isExpanded { clipProbe } }
      if isClipped || isExpanded {
        Button {
          isExpanded.toggle()
        } label: {
          Image(systemName: "chevron.right")
            .font(.caption.weight(.semibold))
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
            .frame(width: 16, height: 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .accessibilityLabel(isExpanded ? "Collapse command" : "Expand command")
        .accessibilityIdentifier("background-task-command-toggle")
      }
    }
  }

  private var text: some View {
    Text(command).font(.caption.monospaced()).foregroundStyle(.secondary)
  }

  /// Picks the whole command when it fits in the two lines' height, else marks it cut.
  private var clipProbe: some View {
    ViewThatFits(in: .vertical) {
      text.fixedSize(horizontal: false, vertical: true).hidden()
        .onAppear { isClipped = false }
      Color.clear.onAppear { isClipped = true }
    }
    .accessibilityHidden(true)
  }
}

/// "Running" with a spinner, as each running item of a count's list ends.
private struct RunningLabel: View {
  var body: some View {
    HStack(spacing: Theme.Spacing.extraSmall) {
      ProgressView().controlSize(.mini)
      Text("Running")
    }
    .font(.caption)
    .foregroundStyle(.secondary)
  }
}

/// The sub-agents still in play: the count, tinted for a failure or a request, opening a list
/// where each row opens its sub-agent (web `SubagentTaskIndicator`).
private struct SubagentsButton: View {
  let indicators: ComposerTaskIndicators
  let open: (@MainActor (String) -> Void)?
  @State private var isShown = false

  var body: some View {
    let summary = indicators.subagentSummary
    Button {
      isShown.toggle()
    } label: {
      Label("\(indicators.subagents.count)", systemImage: SubagentRows.symbol)
        .monospacedDigit()
        .foregroundStyle(tint)
        .contentShape(Rectangle())
    }
    .help(summary)
    .accessibilityLabel(summary)
    .accessibilityHint("Lists them; choosing one opens it")
    .accessibilityIdentifier("composer-subagents")
    .popover(isPresented: $isShown, arrowEdge: .top) {
      IndicatorList(label: summary) { SubagentRows(children: indicators.subagents, open: choose) }
    }
  }

  /// Closes the list as it opens the sub-agent, as the web's link does.
  private var choose: (@MainActor (String) -> Void)? {
    guard let open else { return nil }
    return { id in
      isShown = false
      open(id)
    }
  }

  private var tint: ThemeColor {
    switch indicators.subagentAlert {
    case .failed: Theme.failure
    case .needsYou: Theme.attention
    default: ThemeColor.secondary
    }
  }
}

/// Each sub-agent in play: its task, its tool when that says something else, and where it
/// stands. The whole row opens it (web `SubagentNavigationRow`).
struct SubagentRows: View {
  /// The glyph for a sub-agent, on the count and each row.
  static let symbol = "person.2"

  let children: [SubagentChild]
  let open: (@MainActor (String) -> Void)?

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(children) { child in
        row(child)
      }
    }
    .padding(Theme.Spacing.small)
  }

  private func row(_ child: SubagentChild) -> some View {
    Button {
      open?(child.id)
    } label: {
      HStack(alignment: .top, spacing: Theme.Spacing.small) {
        Image(systemName: Self.symbol)
          .foregroundStyle(.secondary)
          .frame(width: 20)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: Theme.Spacing.tiny) {
          HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
            Text(child.name).font(.callout).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: Theme.Spacing.small)
            SubagentStatusLabel(status: child.status, label: child.statusLabel)
          }
          if let agent = child.agent, agent != child.name {
            Text(agent).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
          }
        }
      }
      .padding(.horizontal, Theme.Spacing.extraSmall)
      .padding(.vertical, Theme.Spacing.small)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(open == nil)
    .help(child.name)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(child.name), \(child.statusLabel)")
    .accessibilityHint(open == nil ? "" : "Opens the sub-agent")
    .accessibilityIdentifier("composer-subagent-\(child.id)")
  }
}

/// Where a sub-agent stands: a spinner while it starts or works, else a tinted dot.
private struct SubagentStatusLabel: View {
  let status: AgentTreeActivity
  let label: String

  var body: some View {
    HStack(spacing: Theme.Spacing.extraSmall) {
      switch status {
      case .launching, .working:
        ProgressView().controlSize(.mini)
      default:
        Circle().fill(tint).frame(width: 6, height: 6)
      }
      Text(label).lineLimit(1)
    }
    .font(.caption)
    .foregroundStyle(tint)
    .fixedSize()
  }

  private var tint: ThemeColor {
    switch status {
    case .needsYou: Theme.attention
    case .failed: Theme.failure
    default: ThemeColor.secondary
    }
  }
}

/// The goal pill's glyph with or without its objective.
private struct GoalLabelStyle: LabelStyle {
  let showsTitle: Bool

  @ViewBuilder func makeBody(configuration: Configuration) -> some View {
    if showsTitle { Label(configuration) } else { configuration.icon }
  }
}
