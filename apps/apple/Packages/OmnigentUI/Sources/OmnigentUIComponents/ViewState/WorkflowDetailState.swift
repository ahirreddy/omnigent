public import Foundation

/// One step of a workflow, or of a run, as its graph and its list draw it.
nonisolated public struct WorkflowStepState: Hashable, Sendable, Identifiable {
  /// The step's id.
  public var id: String
  /// Its place in the workflow, from 1.
  public var number: Int
  /// One line.
  public var name: String
  /// Its description in Markdown.
  public var goal: String?
  /// The description as one plain line, for its box.
  public var goalPreview: String?
  /// Where it stands in a run; `nil` for the workflow itself.
  public var state: TaskState?
  /// What its menu offers in a run.
  public var action: TaskMenuItem?
  /// Its row, from 0, and its left edge in half columns (the core's layout).
  public var row: Int
  /// Its left edge in half columns, so each row centers under the widest.
  public var halfColumn: Int

  /// Creates a step.
  public init(
    id: String, number: Int, name: String, goal: String? = nil, row: Int = 0, halfColumn: Int = 0
  ) {
    self.id = id
    self.number = number
    self.name = name
    self.goal = goal
    self.row = row
    self.halfColumn = halfColumn
  }
}

/// A workflow's steps as a graph: boxes in dependency rows and the arrows between them.
nonisolated public struct WorkflowGraphState: Hashable, Sendable {
  /// One arrow.
  public struct Edge: Hashable, Sendable {
    /// The step waited for.
    public var from: String
    /// The step that waits.
    public var to: String

    /// Creates an arrow.
    public init(from: String, to: String) {
      self.from = from
      self.to = to
    }
  }

  /// The steps, in the workflow's order.
  public var steps: [WorkflowStepState]
  /// The dependencies no other path already implies.
  public var edges: [Edge]
  /// How many rows.
  public var rows: Int
  /// How many columns the widest row has.
  public var columns: Int

  /// Creates a graph.
  public init(steps: [WorkflowStepState], edges: [Edge], rows: Int, columns: Int) {
    self.steps = steps
    self.edges = edges
    self.rows = rows
    self.columns = columns
  }
}

/// What a plan's run button shows.
nonisolated public enum WorkflowRunControl: Hashable, Sendable {
  /// Continue the plan.
  case play
  /// Stop the plan.
  case stop
  /// Stop was asked; the run winds down.
  case stopping
}

/// One run of a workflow: a session that ran it (web `WorkflowRunRow`).
nonisolated public struct WorkflowRunRowState: Hashable, Sendable, Identifiable {
  /// The run's id.
  public var id: String
  /// Its session.
  public var sessionID: String
  /// The session's title, or "Untitled session".
  public var title: String
  /// When it started.
  public var startedAt: Date
  /// Its glyph's state.
  public var glyph: TaskState
  /// Its one line: "2 of 5 done", "Waiting for you".
  public var stateLabel: String
  /// It waits for the user, which the line shows in the attention color.
  public var isWaiting = false
  /// Its session is archived.
  public var isArchived = false
  /// The session that started it, when another did: its id and title.
  public var startedBy: WorkflowRunStarterState?
  /// Its stop, continue or "Stopping…" control.
  public var control: WorkflowRunControl?
  /// A Stop or Continue is in flight.
  public var isActing = false
  /// Its steps and where each stands.
  public var steps: [WorkflowStepState] = []
  /// Its graph, for View on the graph.
  public var graph: WorkflowGraphState?
  /// The workflow a run below another follows, which its row opens; `nil` otherwise.
  public var workflowLinkID: String?
  /// "Ran 3 workflows" and the runs below it; `nil` without any.
  public var descendants: WorkflowDescendantsState?

  /// Creates a row.
  public init(
    id: String, sessionID: String, title: String, startedAt: Date, glyph: TaskState,
    stateLabel: String
  ) {
    self.id = id
    self.sessionID = sessionID
    self.title = title
    self.startedAt = startedAt
    self.glyph = glyph
    self.stateLabel = stateLabel
  }
}

/// The session that started a run ("Started by …").
nonisolated public struct WorkflowRunStarterState: Hashable, Sendable {
  /// Its id.
  public var sessionID: String
  /// Its title, or "Untitled session".
  public var title: String

  /// Creates a starter.
  public init(sessionID: String, title: String) {
    self.sessionID = sessionID
    self.title = title
  }
}

/// "Ran N workflows": the workflow runs below a run, each right after the run that started it.
nonisolated public struct WorkflowDescendantsState: Hashable, Sendable {
  /// "Ran 3 workflows".
  public var label: String
  /// One of them works or waits, so the list starts open.
  public var startsOpen: Bool
  /// The rows read so far.
  public var rows: [WorkflowRunRowState]
  /// More can be read.
  public var hasMore = false
  /// A further page is being read.
  public var isLoadingMore = false

  /// Creates the list.
  public init(label: String, startsOpen: Bool, rows: [WorkflowRunRowState]) {
    self.label = label
    self.startsOpen = startsOpen
    self.rows = rows
  }
}

/// An automation that runs the workflow (web `WorkflowAutomations`).
nonisolated public struct WorkflowAutomationRowState: Hashable, Sendable, Identifiable {
  /// The automation's id.
  public var id: String
  /// Its name.
  public var name: String
  /// It is paused.
  public var isPaused: Bool
  /// "Weekdays at 8:00 AM · Next run in 3 hours", or that a trigger runs when items match.
  public var schedule: String
  /// "Last run 2 hours ago", or that it failed; `nil` before any run.
  public var lastRun: String?
  /// The last run failed.
  public var lastRunFailed = false

  /// Creates a row.
  public init(id: String, name: String, isPaused: Bool, schedule: String) {
    self.id = id
    self.name = name
    self.isPaused = isPaused
    self.schedule = schedule
  }
}

/// A section that loads: its rows, or why it could not.
nonisolated public enum WorkflowSectionLoad<Row: Hashable & Sendable>: Hashable, Sendable {
  /// Being read.
  case loading
  /// Read.
  case loaded([Row])
  /// Could not be read.
  case failed(String)
}

/// How Share shows on a workflow's page.
nonisolated public enum WorkflowShareButton: Hashable, Sendable {
  /// Offered.
  case enabled
  /// Shown disabled, with why.
  case disabled(String)
}

/// A workflow's page (the web's `/workflows/:id`).
nonisolated public struct WorkflowDetailState: Hashable, Sendable {
  /// Id.
  public var id: String
  /// Name.
  public var name: String
  /// The description as saved.
  public var description: String
  /// It has no saved plan.
  public var isDraft = false
  /// Whose it is, when shared with the caller, who may run and clone it only.
  public var sharedBy: String?
  /// Run and Create automation are allowed: a saved plan with no unsaved proposal.
  public var canRun = false
  /// Share on this page; `nil` hides it.
  public var share: WorkflowShareButton?
  /// A clone is in flight.
  public var isCloning = false
  /// The server runs automations: Create automation and the Automations section show.
  public var offersAutomations = false
  /// A newer proposal's different description, which Save plan may apply.
  public var proposedDescription: String?
  /// The proposed description is chosen over the current one.
  public var usesProposedDescription = false
  /// The steps shown: the proposal's, else the saved plan's.
  public var graph: WorkflowGraphState?
  /// The proposal differs from the saved plan.
  public var hasUnsavedPlan = false
  /// Save plan is in flight.
  public var isSavingPlan = false
  /// Why the last Save plan failed.
  public var planError: String?
  /// Why the planning chat's proposal could not be read.
  public var proposalError: String?
  /// The automations that run it; `nil` hides the section.
  public var automations: WorkflowSectionLoad<WorkflowAutomationRowState>?
  /// Its runs, newest first; `nil` hides the section, as for a draft.
  public var runs: WorkflowSectionLoad<WorkflowRunRowState>?
  /// More runs can be read.
  public var hasMoreRuns = false
  /// A further page of runs is being read.
  public var isLoadingMoreRuns = false
  /// The planning chat beside the page: it has a session to show.
  public var hasPlanningSession = false
  /// Why the last action failed, until dismissed.
  public var actionError: String?

  /// The caller only reads it.
  public var isReadOnly: Bool { sharedBy != nil }

  /// Creates the state.
  public init(id: String, name: String, description: String) {
    self.id = id
    self.name = name
    self.description = description
  }
}

/// What a workflow's page can do. Missing actions hide their controls.
public struct WorkflowDetailActions {
  /// Back to the Workflows page.
  public var back: (@MainActor () -> Void)?
  /// Starts a run.
  public var run: (@MainActor () -> Void)?
  /// Opens New automation with this workflow.
  public var createAutomation: (@MainActor () -> Void)?
  /// Copies its plan into a new workflow.
  public var clone: (@MainActor () -> Void)?
  /// Deletes it, after the page confirms.
  public var delete: (@MainActor () -> Void)?
  /// Opens the share sheet.
  public var share: (@MainActor () -> Void)?
  /// Opens, or brings forward, the planning chat.
  public var editPlan: (@MainActor () -> Void)?
  /// Closes the planning chat.
  public var closePlanner: (@MainActor () -> Void)?
  /// Applies the proposal.
  public var savePlan: (@MainActor () -> Void)?
  /// Chooses the proposed description (`true`) or the current one.
  public var chooseProposedDescription: (@MainActor (Bool) -> Void)?
  /// Saves an edited description; resolves to why it failed, `nil` once handled.
  public var saveDescription: (@MainActor (String) async -> String?)?
  /// Reads the planning chat's proposal again.
  public var retryProposal: (@MainActor () -> Void)?
  /// Opens a session.
  public var openSession: (@MainActor (String) -> Void)?
  /// Opens a session's Tasks tab at a step.
  public var openTask: (@MainActor (String, String) -> Void)?
  /// Opens an automation's page.
  public var openAutomation: (@MainActor (String) -> Void)?
  /// Opens another workflow's page.
  public var openWorkflow: (@MainActor (String) -> Void)?
  /// Stops or continues a run, by its id.
  public var runControl: (@MainActor (String, WorkflowRunControl) -> Void)?
  /// A run's task action: its run id, the step id and what it asks.
  public var taskAction: (@MainActor (String, String, TaskMenuAction) -> Void)?
  /// Reads older runs.
  public var loadMoreRuns: (@MainActor () -> Void)?
  /// Reads more runs below a run, by its id.
  public var loadMoreDescendants: (@MainActor (String) -> Void)?
  /// Clears ``WorkflowDetailState/actionError``.
  public var dismissError: (@MainActor () -> Void)?

  /// No actions.
  public init() {}
}
