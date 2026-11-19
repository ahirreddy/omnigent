#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents
  @testable import OmnigentUITestSupport

  @Suite("Workflows pages, clicked", .serialized)
  @MainActor
  struct WorkflowsViewTests {
    private let log = ActionLog()

    private var listActions: WorkflowsActions {
      let log = log
      var actions = WorkflowsActions()
      actions.search = { log.record("search [\($0)]") }
      actions.create = { _ in nil }
      actions.open = { log.record("open \($0)") }
      actions.run = { log.record("run \($0)") }
      actions.createAutomation = { log.record("automation \($0)") }
      actions.clone = { log.record("clone \($0)") }
      actions.delete = { log.record("delete \($0)") }
      actions.loadMore = { log.record("more") }
      return actions
    }

    private func list(_ state: WorkflowsViewState) -> OffscreenWindow<WorkflowsView> {
      SystemSideEffects.reset()
      return OffscreenWindow(
        WorkflowsView(state: state, actions: listActions), width: 1_000, height: 800)
    }

    @Test("rows name a draft and a shared workflow's owner, and their menus offer what each can")
    func rowsAndMenus() throws {
      var state = PreviewData.workflows
      state.yours.hasMore = true
      let screen = list(state)
      defer { screen.close() }
      #expect(try screen.shows("Reusable step-by-step routines that agents can run for you."))
      #expect(try screen.shows("Draft \u{00B7} No saved plan"))
      #expect(try screen.shows("Shared with you"))
      #expect(try screen.shows("Shared by Ada Lovelace"))
      let menus = screen.popUps
      #expect(menus.count == 4, "a menu per row")
      let first = try #require(menus.first)
      #expect(
        try screen.titles(inPopUp: first).filter { !$0.isEmpty }
          == ["Run", "Create automation", "Clone", "Delete"])
      try screen.choose("Run", inPopUp: first)
      try screen.choose("Clone", inPopUp: first)
      // The draft's Run and Create automation are disabled; Clone still works.
      let draft = try #require(menus.dropFirst().first)
      try screen.choose("Run", inPopUp: draft)
      try screen.choose("Create automation", inPopUp: draft)
      try screen.choose("Clone", inPopUp: draft)
      // A shared workflow can't be deleted or make an automation here.
      let shared = try #require(menus.last)
      #expect(try screen.titles(inPopUp: shared).filter { !$0.isEmpty } == ["Run", "Clone"])
      #expect(log.entries == ["run wf_triage", "clone wf_triage", "clone wf_release"])
      #expect(try screen.shows("Load more workflows"))
    }

    @Test("a click on a row opens its workflow, and the search reports what is typed")
    func openAndSearch() throws {
      let screen = list(PreviewData.workflows)
      defer { screen.close() }
      try screen.clickElement("workflow-wf_review")
      #expect(log.entries == ["open wf_review"])
      let field = try #require(screen.searchFields.first)
      try screen.replaceText(in: field, with: "tr")
      #expect(log.entries.suffix(2) == ["search [t]", "search [tr]"])
    }

    @Test("with no workflows the page says how to start, and a failed read offers Retry")
    func emptyAndFailed() throws {
      let empty = list(WorkflowsViewState(yours: WorkflowListState()))
      defer { empty.close() }
      #expect(try empty.shows("No workflows yet"))
      #expect(try empty.shows("Create a workflow to get started."))
      #expect(empty.searchFields.isEmpty, "nothing to search yet")
      var failed = WorkflowListState()
      failed.loadError = "HTTP 500"
      var actions = listActions
      let log = log
      actions.retry = { log.record("retry") }
      let screen = OffscreenWindow(
        WorkflowsView(state: WorkflowsViewState(yours: failed), actions: actions), width: 900,
        height: 600)
      defer { screen.close() }
      #expect(try screen.shows("Couldn\u{2019}t load workflows."))
      try screen.clickElement("workflows-load-error")
      #expect(try screen.shows("Retry"))
    }

    @Test("Run a workflow picks a saved one, then runs it with its details and no review")
    func runSheet() throws {
      var sent: [RunWorkflowRequest] = []
      var source = LookFixtures.runSource
      source.run = { sent.append($0) }
      let screen = OffscreenWindow(
        RunWorkflowSheet(source: source, close: {}), width: 560, height: 480)
      defer { screen.close() }
      #expect(try screen.shows("On-call handoff"), "a shared workflow is offered too")
      #expect(try !screen.shows("Draft release notes"), "a draft can't run")
      try screen.clickElement("run-workflow-pick-wf_triage")
      #expect(try screen.shows("Run Triage flaky tests"))
      try screen.clickElement("run-workflow-run")
      #expect(
        sent == [
          RunWorkflowRequest(description: "", reviewPlanFirst: false, savedWorkflowID: "wf_triage")
        ])
    }

    @Test("a plan's Tasks tab offers its graph and Save as workflow, disabled once saved")
    func tasksControls() throws {
      let screen = OffscreenWindow(LookFixtures.workflowTasks, width: 480, height: 560)
      defer { screen.close() }
      _ = try screen.withAccessibilityTree { try screen.accessibilityFrame("tasks-plan-graph") }
      let menu = try #require(screen.popUps.first)
      #expect(try screen.titles(inPopUp: menu).contains("Save as workflow\u{2026}"))
    }

    @Test("the delete prompt names the automations that run the workflow")
    func deletePromptMessage() {
      let prompt = WorkflowDeletePrompt.ready(
        id: "wf", name: "Triage", automations: ["Nightly", "Weekly"])
      #expect(prompt.automationsTitle == "This workflow is used by 2 automations")
      #expect(
        prompt.message
          == "\u{201C}Triage\u{201D} will be deleted. This cannot be undone.\n\nFuture runs of \u{201C}Nightly\u{201D} and \u{201C}Weekly\u{201D} won\u{2019}t be able to load this workflow. Edit or delete these automations first."
      )
      let alone = WorkflowDeletePrompt.ready(id: "wf", name: "Triage", automations: [])
      #expect(alone.automationsTitle == nil)
      #expect(alone.message == "\u{201C}Triage\u{201D} will be deleted. This cannot be undone.")
    }
  }

  @Suite("A workflow's page, clicked", .serialized)
  @MainActor
  struct WorkflowDetailViewTests {
    private let log = ActionLog()

    private var actions: WorkflowDetailActions {
      let log = log
      var actions = WorkflowDetailActions()
      actions.back = { log.record("back") }
      actions.run = { log.record("run") }
      actions.createAutomation = { log.record("automation") }
      actions.clone = { log.record("clone") }
      actions.share = { log.record("share") }
      actions.editPlan = { log.record("edit plan") }
      actions.savePlan = { log.record("save plan") }
      actions.chooseProposedDescription = { log.record("proposed \($0)") }
      actions.saveDescription = { _ in nil }
      actions.openSession = { log.record("session \($0)") }
      actions.runControl = { log.record("control \($0) \($1)") }
      actions.loadMoreRuns = { log.record("more runs") }
      actions.loadMoreDescendants = { log.record("more below \($0)") }
      return actions
    }

    private func page(_ state: WorkflowDetailState) -> OffscreenWindow<
      WorkflowDetailView<EmptyView>
    > {
      SystemSideEffects.reset()
      return OffscreenWindow(
        WorkflowDetailView(state: state, actions: actions, planner: nil), width: 1_000,
        height: 1_600)
    }

    @Test("the page shows its plan, automations and runs, and Run starts one")
    func savedWorkflow() throws {
      let screen = page(PreviewData.workflowDetail)
      defer { screen.close() }
      #expect(try screen.shows("Saved plan"))
      #expect(try screen.shows("Explore the failing tests"))
      #expect(try screen.shows("Nightly triage"))
      #expect(try screen.shows("Ran 2 workflows"))
      #expect(try screen.shows("Waiting for you"))
      #expect(try screen.shows("Archived"))
      try screen.clickElement("workflow-detail-run")
      try screen.clickElement("workflow-detail-clone")
      try screen.clickElement("workflow-run-stop-run_1")
      try screen.clickElement("workflow-run-descendants-more-run_1")
      try screen.clickElement("workflow-runs-more")
      try screen.clickElement("workflow-run-open-run_3")
      #expect(
        log.entries == [
          "run", "clone", "control run_1 stop", "more below run_1", "more runs",
          "session s_done",
        ])
    }

    @Test("a proposal offers both descriptions and Save plan, and Run waits for the save")
    func proposal() throws {
      var state = PreviewData.workflowDetail
      state.proposedDescription = "Rerun it twice."
      state.hasUnsavedPlan = true
      state.canRun = false
      let screen = page(state)
      defer { screen.close() }
      #expect(try screen.shows("Unsaved changes"))
      #expect(try screen.shows("Keep current"))
      #expect(try screen.shows("Rerun it twice."))
      try screen.clickElement("workflow-detail-use-proposed-description")
      try screen.clickElement("workflow-save-plan")
      try screen.clickElement("workflow-detail-run")
      #expect(log.entries == ["proposed true", "save plan"], "Run is disabled")
    }

    @Test("a shared workflow names its owner and keeps its owner's actions disabled")
    func shared() throws {
      var state = PreviewData.workflowDetail
      state.sharedBy = "Ada Lovelace"
      state.automations = nil
      let screen = page(state)
      defer { screen.close() }
      #expect(try screen.shows("Shared by Ada Lovelace"))
      try screen.clickElement("workflow-detail-edit")
      try screen.clickElement("workflow-detail-share")
      #expect(log.entries.isEmpty, "a viewer can't edit or share it")
      #expect(try !screen.shows("Create automation"))
    }

    @Test("a draft says it has no plan and offers to create one")
    func draft() throws {
      var state = WorkflowDetailState(id: "wf", name: "Release notes", description: "Draft them.")
      state.isDraft = true
      let screen = page(state)
      defer { screen.close() }
      #expect(try screen.shows("Draft"))
      #expect(try screen.shows("No plan yet"))
      try screen.clickElement("workflow-create-plan")
      #expect(log.entries == ["edit plan"])
    }
  }
#endif
