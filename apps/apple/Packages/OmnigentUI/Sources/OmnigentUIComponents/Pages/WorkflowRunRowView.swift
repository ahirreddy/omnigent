import SwiftUI

/// "Runs": the sessions that ran the workflow, newest first, a page at a time.
struct WorkflowRunsSection: View {
  let runs: WorkflowSectionLoad<WorkflowRunRowState>
  let hasMore: Bool
  let isLoadingMore: Bool
  let actions: WorkflowDetailActions

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.small) {
      Text("Runs").font(AutomationStyle.sectionTitle).accessibilityAddTraits(.isHeader)
      switch runs {
      case .loading:
        AutomationLoadingRow(title: "Loading runs\u{2026}", verticalPadding: Theme.Spacing.medium)
      case .failed:
        Text("Couldn\u{2019}t load runs.").foregroundStyle(.secondary)
          .accessibilityIdentifier("workflow-runs-error")
      case .loaded(let rows) where rows.isEmpty && !hasMore:
        Text("No runs yet.").foregroundStyle(.secondary)
          .accessibilityIdentifier("workflow-runs-empty")
      case .loaded(let rows):
        LazyVStack(alignment: .leading, spacing: Theme.Spacing.extraSmall) {
          ForEach(rows) { run in WorkflowRunRowView(run: run, actions: actions) }
        }
        .accessibilityIdentifier("workflow-runs")
        if hasMore, let more = actions.loadMoreRuns {
          Button(action: more) {
            HStack(spacing: Theme.Spacing.small) {
              if isLoadingMore { ProgressView().controlSize(.mini) }
              Text(isLoadingMore ? "Loading\u{2026}" : "Load more")
            }
          }
          .controlSize(.small)
          .disabled(isLoadingMore)
          .accessibilityIdentifier("workflow-runs-more")
        }
      }
    }
  }
}

/// One run (web `WorkflowRunRow`): its state's glyph, its session's title opening it, when it
/// started and where it stands, who started it, a segment per task, and "Ran N workflows" for
/// the runs below it; at the right its stop or continue control, the workflow a run below another
/// follows, and View on the graph.
struct WorkflowRunRowView: View {
  let run: WorkflowRunRowState
  let actions: WorkflowDetailActions
  var nested = false
  @State private var isHovered = false

  var body: some View {
    HStack(alignment: .top, spacing: Theme.Spacing.medium) {
      TaskGlyph(state: run.glyph, number: 0).padding(.top, 1)
      VStack(alignment: .leading, spacing: Theme.Spacing.tiny) {
        Button {
          actions.openSession?(run.sessionID)
        } label: {
          Text(run.title).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open the session")
        .accessibilityIdentifier("workflow-run-open-\(run.id)")
        line
        if let starter = run.startedBy { startedBy(starter) }
        if !run.steps.isEmpty {
          WorkflowRunStrip(run: run, actions: actions).padding(.top, Theme.Spacing.small)
        }
        if !nested, let descendants = run.descendants {
          WorkflowDescendantsList(run: run, descendants: descendants, actions: actions)
            .padding(.top, Theme.Spacing.small)
        }
      }
      WorkflowRunControls(run: run, actions: actions)
    }
    .padding(.horizontal, Theme.Spacing.small).padding(.vertical, Theme.Spacing.small)
    .background(
      RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
        .fill(isHovered ? AnyShapeStyle(.quaternary.opacity(0.6)) : AnyShapeStyle(.clear))
    )
    .onHover { isHovered = $0 }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("workflow-run-\(run.id)")
  }

  private var line: some View {
    TimelineView(.periodic(from: .now, by: 60)) { context in
      HStack(spacing: Theme.Spacing.small) {
        Text(TaskTimes.stamp(run.startedAt, now: context.date))
        Text(run.stateLabel)
          .foregroundStyle(
            run.isWaiting ? AnyShapeStyle(Theme.brandAccent) : AnyShapeStyle(.secondary)
          )
          .accessibilityIdentifier("workflow-run-state-\(run.id)")
        if run.isArchived { Text("Archived") }
      }
      .font(.caption)
      .foregroundStyle(.secondary)
    }
  }

  private func startedBy(_ starter: WorkflowRunStarterState) -> some View {
    Button {
      actions.openSession?(starter.sessionID)
    } label: {
      HStack(spacing: Theme.Spacing.extraSmall) {
        Image(systemName: "arrow.turn.left.up").imageScale(.small).accessibilityHidden(true)
        Text("Started by \(Text(starter.title).foregroundStyle(.primary).fontWeight(.medium))")
          .foregroundStyle(.secondary)
      }
      .font(.caption)
      .lineLimit(1)
    }
    .buttonStyle(.plain)
    .help("Open the session that started this run")
    .accessibilityIdentifier("workflow-run-started-by-\(run.id)")
  }
}

/// "Ran N workflows" under a run, open while one of them works or waits; each below its starter
/// (web `DescendantRuns`).
struct WorkflowDescendantsList: View {
  let run: WorkflowRunRowState
  let descendants: WorkflowDescendantsState
  let actions: WorkflowDetailActions
  @State private var descendantsOpen = DisclosureChoice.followsRuns

  var body: some View {
    let shown = descendantsOpen.isOpen(byDefault: descendants.startsOpen)
    VStack(alignment: .leading, spacing: Theme.Spacing.extraSmall) {
      Button {
        withAnimation(Theme.Motion.disclosure) { descendantsOpen = shown ? .closed : .open }
      } label: {
        HStack(spacing: Theme.Spacing.extraSmall) {
          Image(systemName: "chevron.right")
            .font(.caption2.weight(.semibold))
            .rotationEffect(.degrees(shown ? 90 : 0))
          Text(descendants.label)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityValue(shown ? "Expanded" : "Collapsed")
      .accessibilityIdentifier("workflow-run-descendants-\(run.id)")
      if shown {
        VStack(alignment: .leading, spacing: Theme.Spacing.extraSmall) {
          ForEach(descendants.rows) { row in
            WorkflowRunRowView(run: row, actions: actions, nested: true)
          }
          if descendants.hasMore, let more = actions.loadMoreDescendants {
            Button {
              more(run.id)
            } label: {
              HStack(spacing: Theme.Spacing.small) {
                if descendants.isLoadingMore { ProgressView().controlSize(.mini) }
                Text("Show more")
              }
            }
            .controlSize(.small)
            .disabled(descendants.isLoadingMore)
            .accessibilityIdentifier("workflow-run-descendants-more-\(run.id)")
          }
        }
        .padding(.leading, Theme.Spacing.medium)
        .overlay(alignment: .leading) {
          Rectangle().fill(.separator).frame(width: 2)
        }
      }
    }
  }
}

/// Whether a list the user can fold is open: as the data says until the user chooses.
enum DisclosureChoice: Hashable, Sendable {
  /// It follows its default.
  case followsRuns
  /// The user opened it.
  case open
  /// The user closed it.
  case closed

  /// Whether it shows, given what it would do by itself.
  func isOpen(byDefault: Bool) -> Bool {
    switch self {
    case .followsRuns: byDefault
    case .open: true
    case .closed: false
    }
  }
}
