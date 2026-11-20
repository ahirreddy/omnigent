import Foundation
import OmnigentCoreFFI
import OmnigentPlatform
import OmnigentStores
import OmnigentUIComponents
import SwiftUI

/// A workflow's page over ``WorkflowsStore`` (web `WorkflowDetailPage`): the workflow and its
/// runs, read again while the page shows; the planning chat's proposal from its journal; the
/// automations that run it; and its actions.
struct WorkflowDetailAdapter: View {
  let connection: ConnectionStore
  let store: WorkflowsStore
  let workflowID: String
  let routes: WorkflowRoutes
  let back: @MainActor () -> Void
  /// Opens another workflow's page.
  let open: @MainActor (String) -> Void
  /// The proposal whose description the user chose over the current one.
  @State private var acceptedProposalID: String?
  /// The planning chat beside the page: until chosen, open for a draft.
  @State private var plannerOpen = PlannerChoice.followsWorkflow
  @State private var plannerExpanded = false
  @State private var confirmingDelete = false
  @State private var sharing = false
  @State private var banner: TransientBanner?

  var body: some View {
    content
      .task { await store.loadDetail(workflowID) }
      .task(id: workflowID) { await pollRuns() }
      .task(id: planningSessionID) { await readProposal() }
      .task(id: sourceToPlace) {
        if let planningSessionID, let sourceToPlace {
          await store.placeSource(sessionID: planningSessionID, entryID: sourceToPlace)
        }
      }
      .task {
        if offered?.automations == true { await connection.pages?.loadAutomations() }
      }
      .sheet(isPresented: $sharing) { shareSheet }
      .transientBanner($banner)
  }

  private var offered: ServerPages? { connection.pages?.offered }
  private var detail: WorkflowDetail? { store.details[workflowID]?.value }
  private var planningSessionID: String? {
    guard let detail, !detail.workflow.sharedWithMe else { return nil }
    return detail.planningSessionId
  }
  private var planningJournal: SessionTasksStore? {
    planningSessionID.flatMap { connection.tasks($0) }
  }
  private var entries: [JournalEntry] { planningJournal?.entries ?? [] }
  private var sourceToPlace: String? {
    detail.flatMap { descriptionSourceToPlace(workflow: $0, entries: entries) }
  }

  @ViewBuilder private var content: some View {
    switch store.details[workflowID] {
    case .loaded(let detail):
      page(detail)
    case .failed(let error):
      failure(error)
    case .idle, .loading, nil:
      LoadingCaption(title: "Loading workflow\u{2026}")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("workflow-detail-loading")
    }
  }

  /// A 404 is a workflow that is gone; anything else can be tried again.
  @ViewBuilder private func failure(_ error: CoreError) -> some View {
    let missing = if case .HttpStatus(404, _) = error { true } else { false }
    ContentUnavailableView {
      Label(
        missing ? "This workflow couldn\u{2019}t be found." : "Couldn\u{2019}t load this workflow.",
        systemImage: "flowchart")
    } description: {
      if missing { Text("It may have been deleted, or the link is out of date.") }
    } actions: {
      Button("Workflows", systemImage: "chevron.backward", action: back)
      if !missing {
        Button("Try Again") { Task { await store.loadDetail(workflowID) } }
      }
    }
    .accessibilityIdentifier(missing ? "workflow-detail-not-found" : "workflow-detail-load-error")
  }

  private func page(_ detail: WorkflowDetail) -> some View {
    let proposal = proposal(detail)
    let showsPlanner =
      !detail.workflow.sharedWithMe && plannerOpen.isOpen(draft: detail.workflow.isDraft)
    return WorkflowDetailView(
      state: state(detail, proposal: proposal),
      actions: actions(detail, proposal: proposal),
      plannerExpanded: $plannerExpanded,
      planner: showsPlanner ? planner(detail) : nil
    )
  }

  private func proposal(_ detail: WorkflowDetail) -> PlanProposal? {
    guard planningJournal != nil else { return nil }
    let position = detail.descriptionSource.flatMap { store.sourcePositions[$0] } ?? .unknown
    return workflowPlanProposal(workflow: detail, entries: entries, sourcePosition: position)
  }

  private func state(_ detail: WorkflowDetail, proposal: PlanProposal?) -> WorkflowDetailState {
    let workflow = detail.workflow
    var state = WorkflowDetailState(
      id: workflow.id, name: workflow.name, description: workflow.description)
    state.isDraft = workflow.isDraft
    if workflow.sharedWithMe { state.sharedBy = workflow.ownerDisplayName ?? "another user" }
    let hasChanges = proposal?.hasChanges == true
    state.canRun = !workflow.isDraft && !hasChanges
    state.share = shareButton(workflow)
    state.isCloning = store.isCloning
    state.offersAutomations = offered?.automations == true
    if let proposed = proposal?.newDescription {
      state.proposedDescription = proposed
      state.usesProposedDescription = acceptedProposalID == proposal?.entryId
    }
    let shownSteps = proposal.flatMap { $0.steps.isEmpty ? nil : $0.steps } ?? detail.steps
    state.graph = WorkflowsMapping.graph(shownSteps)
    state.hasUnsavedPlan = hasChanges
    state.isSavingPlan = store.busyIDs.contains(workflow.id)
    state.planError = store.planErrors[workflow.id]?.message
    if case .failed(let error) = planningJournal?.journal { state.proposalError = error.message }
    if offered?.automations == true, !workflow.isDraft, !workflow.sharedWithMe,
      let pages = connection.pages
    {
      state.automations = WorkflowsMapping.automations(
        pages.automations, workflowID: workflow.id, now: .now)
    }
    if !workflow.isDraft { state.runs = runs(workflow) }
    state.hasMoreRuns = store.runCursors[workflow.id] != nil
    state.isLoadingMoreRuns = store.loadingMoreRuns.contains(workflow.id)
    state.hasPlanningSession = planningSessionID != nil
    state.actionError = store.actionError?.message
    return state
  }

  private func runs(_ workflow: SavedWorkflow) -> WorkflowSectionLoad<WorkflowRunRowState> {
    switch store.runs[workflow.id] {
    case .idle, .loading, nil: return .loading
    case .failed(let error): return .failed(error.message)
    case .loaded(let runs):
      // A Stop from a run's Tasks tab shows on its row too.
      let shown = runs + runs.flatMap { store.descendants(of: $0) }
      let context = WorkflowsMapping.RunContext(
        workflowID: workflow.id, stopping: connection.stoppingRuns(shown),
        acting: store.runActions,
        descendants: { store.descendants(of: $0) },
        hasMoreDescendants: { store.hasMoreDescendants(of: $0) },
        loadingDescendants: store.loadingDescendants)
      // Someone it is shared with only reads it, so acts on none of its runs.
      return .loaded(
        runs.map { WorkflowsMapping.run($0, owned: !workflow.sharedWithMe, context: context) })
    }
  }

  private func shareButton(_ workflow: SavedWorkflow) -> WorkflowShareButton? {
    guard offered?.workflowSharing == true, !workflow.sharedWithMe else { return nil }
    if offered?.sharingDisabled == true {
      return .disabled("Sharing is turned off on this server.")
    }
    if !workflow.shareable {
      return .disabled(
        "This workflow was saved before sharing was available. Clone it, then share the copy.")
    }
    return .enabled
  }

  /// Reads the runs now and every few seconds while the page shows: other sessions and
  /// automations start runs meanwhile.
  private func pollRuns() async {
    while !Task.isCancelled {
      if detail?.workflow.isDraft == false { await store.loadRuns(workflowID) }
      do {
        try await Task.sleep(for: WorkflowsStore.runsRefresh)
      } catch {
        return  // The page closed.
      }
    }
  }

  /// Reads the planning chat's journal, which the stream keeps current while its chat is open.
  private func readProposal() async {
    await planningJournal?.load()
  }
}

/// The page's actions and its planning chat.
extension WorkflowDetailAdapter {
  private func actions(_ detail: WorkflowDetail, proposal: PlanProposal?) -> WorkflowDetailActions {
    let workflow = detail.workflow
    var actions = WorkflowDetailActions()
    actions.back = back
    actions.run = { routes.run(workflow) }
    if offered?.automations == true, !workflow.sharedWithMe {
      actions.createAutomation = { routes.createAutomation(workflow) }
    }
    actions.clone = { Task { await store.clone(workflow.id) } }
    if !workflow.sharedWithMe {
      actions.delete = {
        Task { if await store.delete(workflow.id) { back() } }
      }
      actions.editPlan = { plannerOpen = .open }
      actions.closePlanner = {
        plannerOpen = .closed
        plannerExpanded = false
      }
      actions.share = { sharing = true }
      actions.saveDescription = { text in await saveDescription(text, detail, proposal) }
    } else {
      // A viewer sees the owner's actions disabled, with why.
      actions.editPlan = {}
      actions.delete = {}
    }
    if let proposal {
      actions.savePlan = { savePlan(detail, proposal) }
      actions.chooseProposedDescription = { useProposed in
        acceptedProposalID = useProposed ? proposal.entryId : nil
      }
    }
    actions.retryProposal = { Task { await planningJournal?.retry() } }
    actions.openSession = routes.openSession
    actions.openTask = routes.openTask
    actions.openAutomation = routes.openAutomation
    actions.openWorkflow = open
    actions.runControl = { runID, control in runControl(runID, control, workflow: workflow) }
    actions.taskAction = { runID, stepID, action in
      taskAction(runID, stepID, action, workflow: workflow)
    }
    actions.loadMoreRuns = { Task { await store.loadMoreRuns(workflow.id) } }
    actions.loadMoreDescendants = { runID in
      guard let run = run(runID) else { return }
      Task { await store.loadMoreDescendants(of: run, workflowID: workflow.id) }
    }
    actions.dismissError = { store.actionError = nil }
    return actions
  }

  /// The run with `id`, listed or below a listed one.
  private func run(_ id: String) -> WorkflowRun? {
    let listed = store.runs[workflowID]?.value ?? []
    if let run = listed.first(where: { $0.id == id }) { return run }
    for parent in listed {
      if let run = store.descendants(of: parent).first(where: { $0.id == id }) { return run }
    }
    return nil
  }

  private func runControl(_ runID: String, _ control: WorkflowRunControl, workflow: SavedWorkflow) {
    guard let run = run(runID) else { return }
    let name = run.workflowName ?? workflow.name
    Task {
      switch control {
      case .stop: await connection.stopWorkflowRun(run, planName: name, workflowID: workflow.id)
      case .play: await store.continuePlan(run, planName: name, workflowID: workflow.id)
      case .stopping: break
      }
    }
  }

  private func taskAction(
    _ runID: String, _ stepID: String, _ action: TaskMenuAction, workflow: SavedWorkflow
  ) {
    guard let run = run(runID), let step = run.steps.first(where: { $0.id == stepID }) else {
      return
    }
    Task {
      await store.perform(
        TasksAdapter.coreAction(action), task: step.name, in: run, workflowID: workflow.id)
    }
  }

  private func savePlan(_ detail: WorkflowDetail, _ proposal: PlanProposal) {
    let description = planSaveDescription(
      workflow: detail, proposal: proposal,
      useProposed: acceptedProposalID == proposal.entryId)
    Task {
      if await store.savePlan(detail.workflow.id, steps: proposal.steps, description: description) {
        banner = TransientBanner(message: "Plan saved")
      }
    }
  }

  /// Either offered wording, unedited, is a choice for Save plan rather than a write.
  private func saveDescription(
    _ text: String, _ detail: WorkflowDetail, _ proposal: PlanProposal?
  ) async -> String? {
    let proposed = proposal?.newDescription
    switch workflowDescriptionEdit(
      draft: text, current: detail.workflow.description, proposed: proposed)
    {
    case .blank: return "A workflow needs a description."
    case .keepCurrent:
      acceptedProposalID = nil
      return nil
    case .useProposed:
      acceptedProposalID = proposal?.entryId
      return nil
    case .write(let description):
      return await store.saveDescription(detail.workflow.id, description)?.message
    }
  }

  @ViewBuilder private var shareSheet: some View {
    let grants = store.grants[workflowID]
    let state = AutomationShareState(
      people: (grants?.value ?? []).map {
        AutomationShareState.Person(id: $0.userId, name: $0.displayName)
      },
      isLoading: grants == .loading, isSaving: store.isSavingGrant,
      errorMessage: store.grantError?.message ?? grants?.error?.message,
      subject: .workflow)
    AutomationShareSheet(
      state: state,
      add: { person in Task { await store.grant(workflowID, to: person) } },
      remove: { person in Task { await store.revoke(workflowID, from: person) } },
      done: {
        store.dismissGrantError()
        sharing = false
      }
    )
    .task { await store.loadGrants(workflowID) }
  }

  /// The planning chat beside the page: its session's chat, or a way to start one.
  private func planner(_ detail: WorkflowDetail) -> some View {
    WorkflowPlannerPanel(
      title: detail.steps.isEmpty ? "Create plan" : "Edit plan",
      expanded: $plannerExpanded,
      openSession: planningSessionID.map { id in { routes.openSession(id) } },
      close: {
        plannerOpen = .closed
        plannerExpanded = false
      },
      content: {
        if let id = planningSessionID, let chat = routes.chat(id) {
          chat
        } else {
          WorkflowPlannerStart(start: { routes.plan(detail) })
        }
      })
  }
}

/// Whether the planning chat shows beside a workflow's page: open for a draft until chosen.
private enum PlannerChoice {
  case followsWorkflow
  case open
  case closed

  func isOpen(draft: Bool) -> Bool {
    switch self {
    case .followsWorkflow: draft
    case .open: true
    case .closed: false
    }
  }
}
