import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents

/// The Tasks tab's workflow actions (web `TasksPanel`): the plan on its graph, Save as workflow,
/// and Run a workflow from the empty tab.
extension TasksAdapter {
  /// The saved workflows a session reaches, and whether the server shares them.
  struct Workflows {
    var store: WorkflowsStore
    var sharing: Bool
  }

  /// Adds the plan's graph, Save as workflow and Run a workflow to `content`.
  static func addWorkflows(
    to content: inout TasksPanelContent, tasks: SessionTasksStore?,
    conversation: ConversationStore, summary: OmnigentCoreFFI.SessionSummary?,
    workflows: Workflows?
  ) {
    let composer = conversation.composer
    let blocked: @MainActor () -> String? = { blockedReason(conversation) }
    let readOnly = ComposerAdapter.isReadOnly(conversation)
    guard case .loaded(let list) = content.state else {
      if content.state == .empty, !readOnly, let workflows {
        content.runWorkflow = WorkflowComposerAdapter.runSource(
          composer: composer, store: workflows.store, sharing: workflows.sharing,
          blockedReason: blocked)
      }
      return
    }
    guard list.fromPlan, let entries = tasks?.entries else { return }
    let steps = journalPlanSteps(entries: entries)
    if !steps.isEmpty {
      let states = list.rows.map { row in
        RunStep(
          id: row.id, number: UInt32(row.number), name: row.name, state: coreState(row.state),
          goal: row.goal, action: nil, actionTitle: nil)
      }
      content.graph = WorkflowsMapping.graph(steps, runSteps: states)
    }
    if !readOnly {
      let view = Self.view(tasks: tasks, conversation: conversation, summary: summary)
      content.saveAsWorkflow = WorkflowComposerAdapter.saveSource(
        composer: composer, offered: workflows != nil, planName: list.planName,
        workflowID: view?.workflowId, blockedReason: blocked)
    }
  }

  static func coreState(_ state: TaskState) -> StepState {
    switch state {
    case .waiting: .waiting
    case .ready: .ready
    case .running: .running
    case .stopped: .stopped
    case .needsInput: .needsInput
    case .done: .done
    case .failed: .failed
    }
  }
}
