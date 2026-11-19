import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents

/// Maps saved workflows from the core's records to the Workflows page and a workflow's page.
enum WorkflowsMapping {
  /// The Workflows page over `store`, narrowed to `search`.
  static func list(
    _ store: WorkflowsStore, offered: ServerPages?, search: String,
    deletePrompt: WorkflowDeletePrompt?
  ) -> WorkflowsViewState {
    var state = WorkflowsViewState(
      yours: list(
        store.owned, search: search, cursor: store.ownedCursor,
        isLoadingMore: store.isLoadingMoreOwned, busy: store.busyIDs))
    if offered?.workflowSharing == true {
      state.shared = list(
        store.shared, search: search, cursor: store.sharedCursor,
        isLoadingMore: store.isLoadingMoreShared, busy: store.busyIDs)
    }
    state.actionError = store.actionError?.message
    state.isCloning = store.isCloning
    state.offersAutomations = offered?.automations == true
    state.deletePrompt = deletePrompt
    return state
  }

  private static func list(
    _ load: CreationLoad<[SavedWorkflow]>, search: String, cursor: String?, isLoadingMore: Bool,
    busy: Set<String>
  ) -> WorkflowListState {
    var list = WorkflowListState()
    let all = load.value ?? []
    list.hasAny = !all.isEmpty
    list.rows = matchingWorkflows(workflows: all, query: search).map { row($0, busy: busy) }
    list.isLoading = load == .loading || load == .idle
    list.loadError = load.error?.message
    list.hasMore = cursor != nil
    list.isLoadingMore = isLoadingMore
    return list
  }

  static func row(_ workflow: SavedWorkflow, busy: Set<String> = []) -> WorkflowRowState {
    var row = WorkflowRowState(
      id: workflow.id, name: workflow.name, description: workflow.description)
    row.isDraft = workflow.isDraft
    if workflow.sharedWithMe { row.sharedBy = workflow.ownerDisplayName ?? "someone else" }
    row.isBusy = busy.contains(workflow.id)
    return row
  }

  /// The names New workflow refuses: the caller's own workflows'.
  static func takenNames(_ store: WorkflowsStore) -> [String] {
    (store.owned.value ?? []).map(\.name)
  }

  /// The names of the automations that run `workflowID`, in list order.
  static func automationNames(_ automations: [Automation], running workflowID: String) -> [String] {
    automations.filter { promptRunsWorkflow(prompt: $0.prompt, workflowId: workflowID) }
      .map(\.name)
  }

  // MARK: The steps

  /// `steps` as their graph, each with where it stands in a run, when given.
  static func graph(_ steps: [PlanStep], runSteps: [RunStep] = []) -> WorkflowGraphState {
    let layout = layoutWorkflowSteps(steps: steps)
    let byID = Dictionary(steps.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let running = Dictionary(
      runSteps.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let nodes = layout.nodes.compactMap { node -> WorkflowStepState? in
      guard let step = byID[node.id] else { return nil }
      var state = WorkflowStepState(
        id: step.id, number: Int(node.number), name: step.name, goal: step.goal,
        row: Int(node.row), halfColumn: Int(node.halfColumn))
      state.goalPreview = step.goal.map { markdownPreviewText(markdown: $0) }
      if let run = running[step.id] {
        state.state = TasksAdapter.state(run.state)
        if let action = run.action, let title = run.actionTitle {
          state.action = TaskMenuItem(kind: TasksAdapter.menuAction(action), title: title)
        }
      }
      return state
    }
    return WorkflowGraphState(
      steps: nodes, edges: layout.edges.map { .init(from: $0.from, to: $0.to) },
      rows: Int(layout.rows), columns: Int(layout.columns))
  }

  // MARK: Runs

  /// What a run's row needs to know beyond the run.
  struct RunContext {
    /// The workflow whose page lists the run.
    var workflowID: String
    /// Runs whose Stop was taken.
    var stopping: Set<String>
    /// Runs with a message in flight.
    var acting: Set<String>
    /// The session that started the runs listed below it.
    var parentSessionID: String?
    /// The runs below each run read after its first page.
    var descendants: (WorkflowRun) -> [WorkflowRun]
    /// Whether more runs below a run can be read.
    var hasMoreDescendants: (WorkflowRun) -> Bool
    /// Runs reading more runs below them.
    var loadingDescendants: Set<String>
  }

  /// One run's row; `owned` says whether the caller owns its workflow and so acts on it.
  static func run(_ run: WorkflowRun, owned: Bool, context: RunContext) -> WorkflowRunRowState {
    let working = isWorkflowRunWorking(run: run)
    let stopping = context.stopping.contains(run.id)
    let described = describeWorkflowRun(run: run, sessionWorking: working)
    var row = WorkflowRunRowState(
      id: run.id, sessionID: run.sessionId,
      title: run.title.isEmpty ? "Untitled session" : run.title,
      startedAt: Date(timeIntervalSince1970: TimeInterval(run.startedAt)),
      glyph: TasksAdapter.state(workflowRunGlyphState(kind: described.kind)),
      stateLabel: described.label)
    row.isWaiting = described.kind == .waiting
    row.isArchived = run.archived
    if let starter = workflowRunStarterShown(run: run, parentSessionId: context.parentSessionID) {
      row.startedBy = WorkflowRunStarterState(
        sessionID: starter.sessionId,
        title: starter.title.isEmpty ? "Untitled session" : starter.title)
    }
    row.control = workflowRunControl(
      run: run, sessionWorking: working, stopping: stopping, owned: owned
    ).map(control)
    row.isActing = context.acting.contains(run.id)
    let steps = workflowRunSteps(
      run: run, sessionWorking: working, stopping: stopping, owned: owned)
    let graph = graph(run.steps, runSteps: steps)
    row.steps = graph.steps
    row.graph = graph
    if context.parentSessionID != nil, owned, !run.workflowId.isEmpty {
      row.workflowLinkID = run.workflowId
    }
    if context.parentSessionID == nil, !run.descendantRuns.isEmpty {
      row.descendants = descendants(of: run, context: context)
    }
    return row
  }

  private static func descendants(of run: WorkflowRun, context: RunContext)
    -> WorkflowDescendantsState
  {
    let all = context.descendants(run)
    var nested = context
    nested.parentSessionID = run.sessionId
    // The server names a workflow only for its owner, who alone acts on its runs.
    let rows = all.map { Self.run($0, owned: $0.workflowName != nil, context: nested) }
    let count = run.descendantRunCount > 0 ? run.descendantRunCount : UInt32(all.count)
    var state = WorkflowDescendantsState(
      label: ranWorkflowsLabel(count: count),
      startsOpen: descendantRunsActive(run: run, descendants: all), rows: rows)
    state.hasMore = context.hasMoreDescendants(run)
    state.isLoadingMore = context.loadingDescendants.contains(run.id)
    return state
  }

  static func control(_ control: PlanRunControl) -> WorkflowRunControl {
    switch control {
    case .play: .play
    case .stop: .stop
    case .stopping: .stopping
    }
  }

  // MARK: Automations

  /// The automations that run `workflowID`, as the workflow's page lists them.
  static func automations(_ load: CreationLoad<[Automation]>, workflowID: String, now: Date)
    -> WorkflowSectionLoad<WorkflowAutomationRowState>
  {
    switch load {
    case .idle, .loading: return .loading
    case .failed(let error): return load.value == nil ? .failed(error.message) : .loading
    case .loaded(let automations):
      let seconds = Int64(now.timeIntervalSince1970)
      let rows = automations.filter {
        promptRunsWorkflow(prompt: $0.prompt, workflowId: workflowID)
      }
      .map { automation -> WorkflowAutomationRowState in
        var schedule = automation.isTrigger ? "Runs when new items match" : automation.scheduleText
        if !automation.isTrigger, automation.state != .paused, let next = automation.nextRunAt {
          schedule += " \u{00B7} Next run \(formatNextRun(nextRunAt: next, now: seconds))"
        }
        var row = WorkflowAutomationRowState(
          id: automation.id, name: automation.name, isPaused: automation.state == .paused,
          schedule: schedule)
        row.lastRunFailed = automation.lastRunStatus == "failed"
        if let last = automation.lastRunAt {
          let when = Date(timeIntervalSince1970: TimeInterval(last))
            .formatted(.relative(presentation: .named))
          row.lastRun = "\(row.lastRunFailed ? "Last run failed" : "Last run") \(when)"
        }
        return row
      }
      return .loaded(rows)
    }
  }
}
