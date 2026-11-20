import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents

/// Each run's plan in an automation's history (web `RunRow` with `useScheduledTaskRunSteps`): a
/// segment per task, what the agent last wrote, the plan's Stop or Continue, the workflow it
/// follows and its graph.
extension AutomationDetailMapping {
  /// What a run's plan needs beyond the run.
  struct RunTasksContext {
    /// Whether a run's session works now: its live state, else the run's own record.
    var sessionWorking: (AutomationRun) -> Bool = { _ in false }
    /// The plans whose Stop is winding down, by plan id.
    var stopping: ([WorkflowRun]) -> Set<String> = { _ in [] }
    /// The plans with a message in flight, by plan id.
    var acting: Set<String> = []
  }

  /// The runs' rows, each with its PRs and, with `tasks`, its plan.
  static func rows(
    _ automation: Automation, pages: PagesStore, now: Date, calendar: Calendar,
    tasks: RunTasksContext?
  ) -> [AutomationRunRow] {
    let runs = pages.automationRuns[automation.id]?.value ?? []
    let pullRequests = pages.automationRunPullRequests[automation.id] ?? [:]
    let plans =
      showsRunSteps(automation, pages: pages) ? pages.automationRunSteps[automation.id] : nil
    let stopping =
      tasks.map { context in
        context.stopping(
          runs.compactMap { run in
            plans?[run.id].flatMap { workflowRun($0, of: run, context: context) }
          })
      } ?? []
    return runs.map { run in
      let steps = plans?[run.id]
      var shown = row(
        run, now: now, calendar: calendar, pullRequests: pullRequests[run.id], steps: steps)
      if let steps, let tasks {
        addTasks(steps, of: run, to: &shown, context: tasks, stopping: stopping)
      }
      return shown
    }
  }

  /// The run's plans show where the server keeps workflows; a viewer gets no session content.
  static func showsRunSteps(_ automation: Automation, pages: PagesStore) -> Bool {
    pages.offered?.workflows == true && !automation.sharedWithMe
  }

  /// `steps` as a workflow run of `run`'s session, with the activity the row shows.
  static func workflowRun(
    _ steps: AutomationRunSteps, of run: AutomationRun, context: RunTasksContext
  ) -> WorkflowRun? {
    guard let sessionID = run.sessionId else { return nil }
    return automationRunWorkflowRun(
      steps: steps, sessionId: sessionID, startedAt: run.startedAt,
      sessionWorking: steps.isCurrent && context.sessionWorking(run))
  }

  /// Adds `steps`'s status line and tasks to `row`.
  static func addTasks(
    _ steps: AutomationRunSteps, of run: AutomationRun, to row: inout AutomationRunRow,
    context: RunTasksContext, stopping: Set<String>
  ) {
    if let status = automationRunStatusText(steps: steps) {
      row.statusText = AutomationRunStatusText(
        label: status.label, text: status.text, isFailure: status.status == .failed)
    }
    guard let workflowRun = workflowRun(steps, of: run, context: context) else { return }
    let working = workflowRun.sessionStatus == .running
    let acts = automationRunTakesActions(steps: steps)
    let isStopping = stopping.contains(workflowRun.id)
    var tasks = WorkflowRunRowState(
      id: workflowRun.id, sessionID: workflowRun.sessionId, title: steps.planName ?? "Workflow",
      startedAt: Date(timeIntervalSince1970: TimeInterval(run.startedAt)), glyph: .waiting,
      stateLabel: "")
    if acts {
      tasks.control = workflowRunControl(
        run: workflowRun, sessionWorking: working, stopping: isStopping, owned: true
      ).map(WorkflowsMapping.control)
    }
    tasks.isActing = context.acting.contains(workflowRun.id)
    let runSteps = workflowRunSteps(
      run: workflowRun, sessionWorking: working, stopping: isStopping, owned: acts)
    let graph = WorkflowsMapping.graph(steps.steps, runSteps: runSteps)
    tasks.steps = graph.steps
    tasks.graph = graph
    tasks.workflowLinkID = steps.workflowId
    row.tasks = tasks
  }

  /// A run's session works now: its open conversation or the session list say so, else the
  /// run's record (web `useSessionWorking`).
  @MainActor
  static func sessionWorking(_ run: AutomationRun, connection: ConnectionStore) -> Bool {
    guard let sessionID = run.sessionId else { return false }
    let live = connection.conversations[sessionID].map {
      TasksAdapter.isWorking($0, summary: nil)
    }
    let listed = connection.sessionList.session(sessionID).map {
      $0.status == .running || $0.backgroundWorkRunning
    }
    return live == true || (listed ?? (run.status == .running || run.sessionRunning))
  }
}

/// The run plans' actions on an automation's page.
extension AutomationDetailAdapter {
  /// What a run's tasks do: open a task or the workflow, stop or continue the plan, act on a
  /// task. Each message reads the runs again.
  func runTaskActions() -> WorkflowDetailActions {
    var actions = WorkflowDetailActions()
    let open = open
    actions.openSession = { open($0) }
    guard let connection else { return actions }
    actions.openTask = { sessionID, stepID in
      connection.tasks(sessionID)?.taskToShow = stepID
      open(sessionID)
    }
    actions.openWorkflow = openWorkflow
    guard let workflows = connection.workflows else { return actions }
    actions.runControl = { planID, control in
      guard let (steps, run) = plan(planID) else { return }
      Task {
        switch control {
        case .stop:
          await connection.stopWorkflowRun(run, planName: steps.planName, workflowID: nil)
        case .play:
          await workflows.continuePlan(run, planName: steps.planName, workflowID: nil)
        case .stopping: break
        }
        await reloadRuns()
      }
    }
    actions.taskAction = { planID, stepID, action in
      guard let (_, run) = plan(planID), let step = run.steps.first(where: { $0.id == stepID })
      else { return }
      Task {
        await workflows.perform(
          TasksAdapter.coreAction(action), task: step.name, in: run, workflowID: nil)
        await reloadRuns()
      }
    }
    return actions
  }

  /// The run plan whose entry is `planID`, as a workflow run of its session.
  private func plan(_ planID: String) -> (AutomationRunSteps, WorkflowRun)? {
    guard let connection else { return nil }
    let runs = pages.automationRuns[automation.id]?.value ?? []
    let context = runTasksContext(connection)
    for (runID, steps) in pages.automationRunSteps[automation.id] ?? [:] {
      guard let run = runs.first(where: { $0.id == runID }),
        let workflowRun = AutomationDetailMapping.workflowRun(steps, of: run, context: context),
        workflowRun.id == planID
      else { continue }
      return (steps, workflowRun)
    }
    return nil
  }

  /// The live facts a run's plan reads.
  func runTasksContext(_ connection: ConnectionStore) -> AutomationDetailMapping.RunTasksContext {
    var context = AutomationDetailMapping.RunTasksContext()
    context.sessionWorking = { AutomationDetailMapping.sessionWorking($0, connection: connection) }
    context.stopping = { connection.stoppingRuns($0) }
    context.acting = connection.workflows?.runActions ?? []
    return context
  }

  /// Reads the runs, their PRs and their plans.
  func reloadRuns() async {
    await pages.loadAutomationRuns(automation.id)
    if AutomationDetailMapping.showsPullRequests(automation, pages: pages) {
      await pages.loadAutomationRunPullRequests(automation.id)
    }
    if AutomationDetailMapping.showsRunSteps(automation, pages: pages) {
      await pages.loadAutomationRunSteps(automation.id)
    }
  }
}
