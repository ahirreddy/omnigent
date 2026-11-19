import Foundation

/// What Run a workflow sends (web `WorkflowRequest`).
nonisolated public struct RunWorkflowRequest: Hashable, Sendable {
  /// A new workflow's description, or a saved one's details for this run, trimmed.
  public var description: String
  /// The run starts with the user reviewing its plan.
  public var reviewPlanFirst: Bool
  /// The saved workflow to run; `nil` describes a new one.
  public var savedWorkflowID: String?

  /// Creates a request.
  public init(description: String, reviewPlanFirst: Bool, savedWorkflowID: String?) {
    self.description = description
    self.reviewPlanFirst = reviewPlanFirst
    self.savedWorkflowID = savedWorkflowID
  }
}

/// The saved workflows Run a workflow offers for a search (web `WorkflowPicker`).
nonisolated public struct RunWorkflowChoices: Hashable, Sendable {
  /// Those with a saved plan whose name matches, the caller's then those shared with them.
  public var rows: [WorkflowRowState] = []
  /// The caller has any saved workflow to pick at all.
  public var hasAny = false
  /// More can be read.
  public var hasMore = false
  /// A further page is being read.
  public var isLoadingMore = false

  /// Creates the choices.
  public init() {}
}

/// Run a workflow from the composer's Add menu or the Tasks tab: the saved workflows to pick,
/// and what a run sends. `nil` where the agent has no workflow skill or the server no workflows.
public struct WorkflowRunSource {
  /// The workflows matching a search.
  public var choices: @MainActor (String) -> RunWorkflowChoices
  /// Reads the next page of workflows.
  public var loadMore: (@MainActor () -> Void)?
  /// Reads the workflows again as the sheet opens, e.g. after the agent saved one.
  public var refresh: @MainActor () -> Void
  /// Why the session can't take the run now, if it can't.
  public var blockedReason: @MainActor () -> String?
  /// Sends the run.
  public var run: @MainActor (RunWorkflowRequest) -> Void
  /// The draft to start a new workflow's description from.
  public var draft: @MainActor () -> String

  /// Creates the source.
  public init(
    choices: @escaping @MainActor (String) -> RunWorkflowChoices,
    loadMore: (@MainActor () -> Void)? = nil, refresh: @escaping @MainActor () -> Void = {},
    blockedReason: @escaping @MainActor () -> String? = { nil },
    run: @escaping @MainActor (RunWorkflowRequest) -> Void,
    draft: @escaping @MainActor () -> String = { "" }
  ) {
    self.choices = choices
    self.loadMore = loadMore
    self.refresh = refresh
    self.blockedReason = blockedReason
    self.run = run
    self.draft = draft
  }
}

/// Save as workflow from the Tasks tab (web `SaveWorkflowDialog`).
public struct WorkflowSaveSource {
  /// The name to start from: the plan's.
  public var initialName: String
  /// Why Save as workflow is disabled, as for a saved workflow's run.
  public var disabledReason: String?
  /// Why the session can't take the request now, if it can't.
  public var blockedReason: @MainActor () -> String?
  /// Asks the agent to save the plan under a name.
  public var save: @MainActor (String) -> Void

  /// Creates the source.
  public init(
    initialName: String, disabledReason: String? = nil,
    blockedReason: @escaping @MainActor () -> String? = { nil },
    save: @escaping @MainActor (String) -> Void
  ) {
    self.initialName = initialName
    self.disabledReason = disabledReason
    self.blockedReason = blockedReason
    self.save = save
  }
}
