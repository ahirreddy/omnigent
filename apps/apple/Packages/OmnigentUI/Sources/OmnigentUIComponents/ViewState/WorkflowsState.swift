import Foundation

/// One saved workflow in the Workflows list (web `WorkflowRow`).
nonisolated public struct WorkflowRowState: Hashable, Sendable, Identifiable {
  /// Id.
  public var id: String
  /// Name.
  public var name: String
  /// What it does and what a run needs.
  public var description: String
  /// It has no saved plan, so it can't run or start an automation yet.
  public var isDraft = false
  /// Whose it is, when someone shared it with the caller: they may run and clone it only.
  public var sharedBy: String?
  /// A write for it is in flight.
  public var isBusy = false

  /// The caller only reads it.
  public var isReadOnly: Bool { sharedBy != nil }

  /// Creates a row.
  public init(id: String, name: String, description: String) {
    self.id = id
    self.name = name
    self.description = description
  }
}

/// One of the page's lists: the caller's workflows, or those shared with them.
nonisolated public struct WorkflowListState: Hashable, Sendable {
  /// The rows matching the search, in the server's order.
  public var rows: [WorkflowRowState] = []
  /// The list has any workflow at all, whatever the search.
  public var hasAny = false
  /// The first page is being read.
  public var isLoading = false
  /// Why the list could not be read.
  public var loadError: String?
  /// More pages remain.
  public var hasMore = false
  /// A further page is being read.
  public var isLoadingMore = false

  /// Creates a list.
  public init() {}
}

/// The Workflows page (the web's `/workflows`).
nonisolated public struct WorkflowsViewState: Hashable, Sendable {
  /// The caller's workflows.
  public var yours: WorkflowListState
  /// The workflows shared with the caller; `nil` where the server doesn't share them.
  public var shared: WorkflowListState?
  /// Why the last action failed, until dismissed.
  public var actionError: String?
  /// A clone is in flight, so Clone waits.
  public var isCloning = false
  /// The server runs automations, so rows offer Create automation.
  public var offersAutomations = false
  /// The Delete confirmation to show, if any.
  public var deletePrompt: WorkflowDeletePrompt?

  /// Whether the caller has any workflow, theirs or shared, whatever the search.
  public var hasAnyWorkflow: Bool { yours.hasAny || shared?.hasAny == true }

  /// Creates the state.
  public init(yours: WorkflowListState, shared: WorkflowListState? = nil) {
    self.yours = yours
    self.shared = shared
  }
}

/// What New workflow asks: a name, and what the workflow should do.
nonisolated public struct NewWorkflowDraft: Hashable, Sendable {
  /// The name as typed.
  public var name = ""
  /// What it should do, as typed.
  public var description = ""

  /// An empty draft.
  public init() {}
}

/// The workflow a Delete confirmation is about, and what the check of its automations found.
nonisolated public enum WorkflowDeletePrompt: Hashable, Sendable, Identifiable {
  /// The automations that run it are being checked; Delete waits.
  case checking(id: String, name: String)
  /// The check failed; Delete waits for a retry.
  case checkFailed(id: String, name: String)
  /// Ready: the names of the automations that run it, which can't load it once it is gone.
  case ready(id: String, name: String, automations: [String])

  /// The workflow's id.
  public var id: String {
    switch self {
    case .checking(let id, _), .checkFailed(let id, _), .ready(let id, _, _): id
    }
  }

  /// The workflow's name.
  public var name: String {
    switch self {
    case .checking(_, let name), .checkFailed(_, let name), .ready(_, let name, _): name
    }
  }

  /// The confirmation's message (web `DeleteWorkflowDialog`).
  public var message: String {
    var text = "\u{201C}\(name)\u{201D} will be deleted. This cannot be undone."
    if case .ready(_, _, let automations) = self, !automations.isEmpty {
      let quoted = automations.map { "\u{201C}\($0)\u{201D}" }
      let names = TaskTimes.names(quoted)
      let which = automations.count == 1 ? "the automation" : "these automations"
      text +=
        "\n\nFuture runs of \(names) won\u{2019}t be able to load this workflow. Edit or delete \(which) first."
    }
    return text
  }

  /// The warning's title when automations run it.
  public var automationsTitle: String? {
    guard case .ready(_, _, let automations) = self, !automations.isEmpty else { return nil }
    return automations.count == 1
      ? "This workflow is used by an automation"
      : "This workflow is used by \(automations.count) automations"
  }
}

/// What the Workflows page can do. Missing actions hide their controls.
public struct WorkflowsActions {
  /// Narrow both lists to a search.
  public var search: (@MainActor (String) -> Void)?
  /// Saves a New workflow draft and opens it; resolves to why it failed, `nil` once saved.
  public var create: (@MainActor (NewWorkflowDraft) async -> String?)?
  /// Whether a name is one of the caller's workflows already.
  public var nameTaken: (@MainActor (String) -> Bool)?
  /// Opens a workflow's page.
  public var open: (@MainActor (String) -> Void)?
  /// Starts a run of a workflow.
  public var run: (@MainActor (String) -> Void)?
  /// Opens New automation with the workflow chosen.
  public var createAutomation: (@MainActor (String) -> Void)?
  /// Copies a workflow's plan into a new one.
  public var clone: (@MainActor (String) -> Void)?
  /// Asks to delete a workflow; the page then shows ``WorkflowsViewState/deletePrompt``.
  public var delete: (@MainActor (String) -> Void)?
  /// Deletes the workflow of the confirmation.
  public var confirmDelete: (@MainActor (String) -> Void)?
  /// Checks the confirmation's automations again.
  public var retryDeleteCheck: (@MainActor () -> Void)?
  /// Closes the confirmation.
  public var cancelDelete: (@MainActor () -> Void)?
  /// Reads the caller's list again.
  public var retry: (@MainActor () -> Void)?
  /// Reads the next page of the caller's list.
  public var loadMore: (@MainActor () -> Void)?
  /// Reads the shared list again.
  public var retryShared: (@MainActor () -> Void)?
  /// Reads the next page of the shared list.
  public var loadMoreShared: (@MainActor () -> Void)?
  /// Clears ``WorkflowsViewState/actionError``.
  public var dismissError: (@MainActor () -> Void)?

  /// No actions.
  public init() {}
}
