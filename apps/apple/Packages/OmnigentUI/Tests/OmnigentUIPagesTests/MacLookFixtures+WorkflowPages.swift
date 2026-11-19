import SwiftUI

@testable import OmnigentUIComponents

extension LookFixtures {
  // MARK: Workflows pages

  /// A Workflows screen, under a window root's appearance so controls take the theme's accent as
  /// they do in the app.
  @MainActor static func workflows(_ screen: LookScreen) -> AnyView {
    switch screen {
    case .workflowsEmpty:
      var empty = WorkflowsViewState(yours: WorkflowListState())
      empty.offersAutomations = true
      return themed(WorkflowsView(state: empty, actions: listActions))
    case .workflowDetail:
      return themed(detail(PreviewData.workflowDetail))
    case .workflowDetailProposal:
      var state = PreviewData.workflowDetail
      state.proposedDescription =
        "Rerun the suite three times, file an issue for each flaky test, and open a PR for the clear fixes."
      state.hasUnsavedPlan = true
      state.canRun = false
      return themed(detail(state))
    case .workflowDetailDraft:
      var state = WorkflowDetailState(
        id: "wf_release", name: "Draft release notes",
        description: "Collect the merged pull requests since the last tag and draft the notes.")
      state.isDraft = true
      state.share = .enabled
      return themed(
        WorkflowDetailView(
          state: state, actions: detailActions,
          planner: WorkflowPlannerPanel(
            title: "Create plan", expanded: .constant(false), openSession: nil, close: {},
            content: { WorkflowPlannerStart(start: {}) })))
    case .workflowDetailShared:
      var state = PreviewData.workflowDetail
      state.sharedBy = "Ada Lovelace"
      state.automations = nil
      state.runs = .loaded([])
      state.hasMoreRuns = false
      return themed(detail(state))
    case .workflowNew:
      return themed(NewWorkflowSheet(create: { _ in nil }, nameTaken: { _ in false }, close: {}))
    case .workflowRunSheet:
      return themed(RunWorkflowSheet(source: runSource, close: {}))
    case .workflowTasks:
      return themed(workflowTasks)
    default:
      return themed(WorkflowsView(state: PreviewData.workflows, actions: listActions))
    }
  }

  @MainActor private static func themed(_ view: some View) -> AnyView {
    AnyView(view.omnigentAppearance(.omni))
  }

  @MainActor private static func detail(_ state: WorkflowDetailState) -> some View {
    WorkflowDetailView(state: state, actions: detailActions, planner: EmptyView?.none)
  }

  /// Run a workflow's saved workflows: the caller's with a plan and one shared with them.
  @MainActor static var runSource: WorkflowRunSource {
    WorkflowRunSource(
      choices: { search in
        var choices = RunWorkflowChoices()
        let rows =
          PreviewData.workflows.yours.rows.filter { !$0.isDraft }
          + (PreviewData.workflows.shared?.rows ?? [])
        choices.rows = rows.filter { search.isEmpty || $0.name.localizedStandardContains(search) }
        choices.hasAny = true
        return choices
      },
      run: { _ in })
  }

  /// The Tasks tab of a workflow's run: its plan on the graph and Save as workflow.
  @MainActor static var workflowTasks: some View {
    let started = now.addingTimeInterval(-300)
    let list = TaskListState(
      planName: "Triage flaky tests", updatedAt: started, summary: "2 of 4 finished",
      counts: [TaskCountLine(state: .running, text: "1 running")], canStop: true, fromPlan: true,
      rows: PreviewData.workflowRuns[0].steps.map { step in
        TaskRowState(
          id: step.id, number: step.number, name: step.name, state: step.state ?? .waiting,
          stateLabel: step.state == .done ? "Done" : "Running")
      })
    var content = TasksPanelContent(state: .loaded(list))
    content.graph = PreviewData.workflowRuns[0].graph
    content.saveAsWorkflow = WorkflowSaveSource(initialName: "Triage flaky tests", save: { _ in })
    return TasksPanel(content: content)
  }

  @MainActor private static var listActions: WorkflowsActions {
    var actions = WorkflowsActions()
    actions.create = { _ in nil }
    actions.open = { _ in }
    actions.run = { _ in }
    actions.createAutomation = { _ in }
    actions.clone = { _ in }
    actions.delete = { _ in }
    return actions
  }

  @MainActor private static var detailActions: WorkflowDetailActions {
    var actions = WorkflowDetailActions()
    actions.back = {}
    actions.run = {}
    actions.createAutomation = {}
    actions.clone = {}
    actions.delete = {}
    actions.share = {}
    actions.editPlan = {}
    actions.savePlan = {}
    actions.saveDescription = { _ in nil }
    actions.chooseProposedDescription = { _ in }
    actions.openSession = { _ in }
    actions.runControl = { _, _ in }
    actions.loadMoreRuns = {}
    actions.loadMoreDescendants = { _ in }
    return actions
  }
}
