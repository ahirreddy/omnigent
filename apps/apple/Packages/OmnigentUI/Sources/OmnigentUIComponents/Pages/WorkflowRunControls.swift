import SwiftUI

/// A run's tasks as one segment each, colored by where it stands (web `RunTimeline`); a click
/// opens that task in the run's session, and a segment's menu offers its action.
struct WorkflowRunStrip: View {
  let run: WorkflowRunRowState
  let actions: WorkflowDetailActions

  var body: some View {
    HStack(spacing: run.steps.count > 16 ? 1 : 3) {
      ForEach(run.steps) { step in
        Button {
          actions.openTask?(run.sessionID, step.id)
        } label: {
          Capsule()
            .fill(TaskStyle.segment(step.state ?? .waiting))
            .frame(height: 6)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Task \(step.number) of \(run.steps.count): \(step.name)")
        .contextMenu {
          if let action = step.action, let perform = actions.taskAction {
            Button(action.title, systemImage: TaskStyle.symbol(action.kind)) {
              perform(run.id, step.id, action.kind)
            }
          }
        }
        .accessibilityLabel("Task \(step.number), \(step.name)")
        .accessibilityIdentifier("workflow-run-segment-\(run.id)-\(step.id)")
      }
    }
  }
}

/// A run's buttons at its row's right: stop, continue or "Stopping…", the workflow it follows,
/// and View on the graph.
struct WorkflowRunControls: View {
  let run: WorkflowRunRowState
  let actions: WorkflowDetailActions
  @State private var showsGraph = false

  var body: some View {
    HStack(spacing: Theme.Spacing.extraSmall) {
      if let control = run.control { runControl(control) }
      if let workflowID = run.workflowLinkID, let open = actions.openWorkflow {
        Button("Open the workflow", systemImage: "flowchart") { open(workflowID) }
          .labelStyle(.iconOnly)
          .buttonStyle(.borderless)
          .help("Open the workflow")
          .accessibilityIdentifier("workflow-run-workflow-\(run.id)")
      }
      if let graph = run.graph, !graph.steps.isEmpty {
        Button("View this run on the graph", systemImage: "arrow.up.left.and.arrow.down.right") {
          showsGraph = true
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .help("View this run on the graph")
        .accessibilityIdentifier("workflow-run-graph-\(run.id)")
        .sheet(isPresented: $showsGraph) {
          WorkflowRunGraphSheet(run: run, graph: graph, actions: actions) { showsGraph = false }
        }
      }
    }
    .foregroundStyle(.secondary)
  }

  @ViewBuilder private func runControl(_ control: WorkflowRunControl) -> some View {
    switch control {
    case .stopping:
      Label {
        Text("Stopping\u{2026}")
      } icon: {
        ProgressView().controlSize(.mini)
      }
      .font(.caption)
      .accessibilityIdentifier("workflow-run-stopping-\(run.id)")
    case .stop:
      Button("Stop", systemImage: "stop.fill") { actions.runControl?(run.id, .stop) }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .disabled(run.isActing)
        .help("Stop")
        .accessibilityIdentifier("workflow-run-stop-\(run.id)")
    case .play:
      Button("Continue the plan", systemImage: "play.fill") { actions.runControl?(run.id, .play) }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .disabled(run.isActing)
        .help("Continue the plan")
        .accessibilityIdentifier("workflow-run-continue-\(run.id)")
    }
  }
}

/// A run on its workflow's graph: the title, when it started and where it stands, then each
/// task's box in its state, with the task's action in its menu.
private struct WorkflowRunGraphSheet: View {
  let run: WorkflowRunRowState
  let graph: WorkflowGraphState
  let actions: WorkflowDetailActions
  let close: @MainActor () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: Theme.Spacing.tiny) {
          Text(run.title).font(.headline)
          Text(
            ([TaskTimes.stamp(run.startedAt, now: .now)] + [run.stateLabel].filter { !$0.isEmpty })
              .joined(separator: " \u{00B7} ")
          )
          .font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        if let open = actions.openSession {
          Button("Open Session") {
            close()
            open(run.sessionID)
          }
          .accessibilityIdentifier("workflow-run-graph-open-session")
        }
        Button("Done", action: close).keyboardShortcut(.cancelAction)
      }
      WorkflowStepsGraph(graph: graph) { step, action in
        actions.taskAction?(run.id, step.id, action)
      }
    }
    .padding(Theme.Spacing.large)
    #if os(macOS)
      .frame(minWidth: 560, idealWidth: 720, minHeight: 420)
    #endif
    .accessibilityIdentifier("workflow-run-graph-sheet")
  }
}
