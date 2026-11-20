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
    /// Opens a run's session.
    var openSession: (@MainActor (String) -> Void)?
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
    let view = Self.view(tasks: tasks, conversation: conversation, summary: summary)
    if !readOnly {
      content.saveAsWorkflow = WorkflowComposerAdapter.saveSource(
        composer: composer, offered: workflows != nil, planName: list.planName,
        workflowID: view?.workflowId, blockedReason: blocked)
    }
    if let workflows, let workflowID = view?.workflowId {
      addRun(
        to: &content, workflows: workflows, workflowID: workflowID,
        sessionID: conversation.sessionID)
    }
  }

  /// The session's current run of the plan's workflow, for "Ran N workflows" below the tasks
  /// (web `SessionDescendantRuns`), read as the tab shows.
  private static func addRun(
    to content: inout TasksPanelContent, workflows: Workflows, workflowID: String,
    sessionID: String
  ) {
    let store = workflows.store
    content.loadWorkflowRun = {
      await store.loadSessionRun(workflowID: workflowID, sessionID: sessionID)
    }
    let key = WorkflowsStore.sessionRunKey(workflowID: workflowID, sessionID: sessionID)
    guard let run = store.sessionRuns[key], !run.descendantRuns.isEmpty else { return }
    let context = WorkflowsMapping.RunContext(
      workflowID: workflowID, stopping: store.stoppingRuns, acting: store.runActions,
      descendants: { store.descendants(of: $0) },
      hasMoreDescendants: { store.hasMoreDescendants(of: $0) },
      loadingDescendants: store.loadingDescendants)
    // The server names a workflow only for its owner, who alone acts on its runs.
    content.workflowRun = WorkflowsMapping.run(
      run, owned: run.workflowName != nil, context: context)
    var actions = WorkflowDetailActions()
    actions.openSession = workflows.openSession
    let below = { (id: String) in store.descendants(of: run).first { $0.id == id } }
    actions.runControl = { runID, control in
      guard let target = below(runID) else { return }
      let name = target.workflowName
      Task {
        switch control {
        case .stop: await store.stop(target, planName: name, workflowID: workflowID)
        case .play: await store.continuePlan(target, planName: name, workflowID: workflowID)
        case .stopping: break
        }
      }
    }
    actions.loadMoreDescendants = { _ in
      Task { await store.loadMoreDescendants(of: run, workflowID: workflowID) }
    }
    content.workflowRunActions = actions
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
