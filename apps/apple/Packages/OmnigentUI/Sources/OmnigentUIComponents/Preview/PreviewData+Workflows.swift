import Foundation

extension PreviewData {
  /// The Workflows page: three of the caller's, a draft among them, and one shared with them.
  static var workflows: WorkflowsViewState {
    var draft = WorkflowRowState(
      id: "wf_release", name: "Draft release notes",
      description: "Collect the merged pull requests since the last tag and draft the notes.")
    draft.isDraft = true
    var yours = WorkflowListState()
    yours.hasAny = true
    yours.rows = [
      WorkflowRowState(
        id: "wf_triage", name: "Triage flaky tests",
        description:
          "Rerun the suite a few times, file an issue for each flaky test, and fix the clear ones. Give it: the test suite."
      ),
      draft,
      WorkflowRowState(
        id: "wf_review", name: "Review a pull request",
        description: "Read the change, run its tests, and leave review comments."),
    ]
    var theirs = WorkflowRowState(
      id: "wf_oncall", name: "On-call handoff",
      description: "Summarize the week's incidents and open follow-ups.")
    theirs.sharedBy = "Ada Lovelace"
    var shared = WorkflowListState()
    shared.hasAny = true
    shared.rows = [theirs]
    var state = WorkflowsViewState(yours: yours, shared: shared)
    state.offersAutomations = true
    return state
  }

  /// A workflow's steps: explore, then two at once, then a pull request.
  static func workflowGraph(states: [String: TaskState] = [:]) -> WorkflowGraphState {
    func step(
      _ id: String, _ number: Int, _ name: String, _ goal: String?, at place: (row: Int, half: Int)
    ) -> WorkflowStepState {
      var step = WorkflowStepState(
        id: id, number: number, name: name, goal: goal, row: place.row, halfColumn: place.half)
      step.goalPreview = goal.map { $0.replacingOccurrences(of: "**", with: "") }
      step.state = states[id]
      return step
    }
    return WorkflowGraphState(
      steps: [
        step(
          "explore", 1, "Explore the failing tests", "**Inputs:** the test suite and CI history.",
          at: (0, 1)),
        step("rerun", 2, "Rerun the suite", nil, at: (1, 0)),
        step(
          "history", 3, "Check the history",
          "**What it does:** finds when each test began failing.",
          at: (1, 2)),
        step(
          "file", 4, "File issues and fix", "**Outputs:** one issue per flaky test, and a PR.",
          at: (2, 1)),
      ],
      edges: [
        .init(from: "explore", to: "rerun"), .init(from: "explore", to: "history"),
        .init(from: "rerun", to: "file"), .init(from: "history", to: "file"),
      ],
      rows: 3, columns: 2)
  }

  /// A workflow's page: its saved plan, an automation, a running run with a run below it, and
  /// a finished one.
  static var workflowDetail: WorkflowDetailState {
    var state = WorkflowDetailState(
      id: "wf_triage", name: "Triage flaky tests",
      description:
        "Rerun the suite a few times, file an issue for each flaky test, and fix the clear ones. Give it: the test suite."
    )
    state.canRun = true
    state.share = .enabled
    state.offersAutomations = true
    state.graph = workflowGraph()
    var automation = WorkflowAutomationRowState(
      id: "t1", name: "Nightly triage", isPaused: false,
      schedule: "Every day at 2:00 AM \u{00B7} Next run in 6 hours")
    automation.lastRun = "Last run 18 hours ago"
    state.automations = .loaded([automation])
    state.runs = .loaded(workflowRuns)
    state.hasMoreRuns = true
    return state
  }

  /// The page's runs.
  static var workflowRuns: [WorkflowRunRowState] {
    let graph = workflowGraph(states: [
      "explore": .done, "rerun": .running, "history": .done, "file": .waiting,
    ])
    var running = WorkflowRunRowState(
      id: "run_1", sessionID: sessionID, title: "Triage the upload tests",
      startedAt: now.addingTimeInterval(-1_800), glyph: .running, stateLabel: "2 of 4 done")
    running.control = .stop
    running.steps = graph.steps
    running.graph = graph
    running.startedBy = WorkflowRunStarterState(sessionID: "s_nightly", title: "Nightly triage")
    var nested = WorkflowRunRowState(
      id: "run_2", sessionID: "s_nested", title: "Review the fix",
      startedAt: now.addingTimeInterval(-900), glyph: .needsInput, stateLabel: "Waiting for you")
    nested.isWaiting = true
    nested.workflowLinkID = "wf_review"
    var descendants = WorkflowDescendantsState(
      label: "Ran 2 workflows", startsOpen: true, rows: [nested])
    descendants.hasMore = true
    running.descendants = descendants
    let doneGraph = workflowGraph(states: [
      "explore": .done, "rerun": .done, "history": .done, "file": .done,
    ])
    var done = WorkflowRunRowState(
      id: "run_3", sessionID: "s_done", title: "Triage the login tests",
      startedAt: now.addingTimeInterval(-90_000), glyph: .done, stateLabel: "Done")
    done.steps = doneGraph.steps
    done.graph = doneGraph
    done.isArchived = true
    return [running, done]
  }
}
