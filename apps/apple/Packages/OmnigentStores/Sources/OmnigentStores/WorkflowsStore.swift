import Foundation
public import Observation
public import OmnigentCoreFFI

/// Saved workflows (the web's `useSavedWorkflows` and `useWorkflow`): the caller's list and those
/// shared with them, a page at a time, each workflow with its steps, and their writes. Where runs
/// stand, what a proposal offers and the messages that run them are the core's.
@Observable
public final class WorkflowsStore {
  /// The caller's workflows, drafts included, as far as paged.
  public private(set) var owned: CreationLoad<[SavedWorkflow]> = .idle
  /// The next page of ``owned``; `nil` on the last.
  public private(set) var ownedCursor: String?
  /// A further page of ``owned`` is being read.
  public private(set) var isLoadingMoreOwned = false
  /// The workflows shared with the caller, as far as paged.
  public private(set) var shared: CreationLoad<[SavedWorkflow]> = .idle
  /// The next page of ``shared``; `nil` on the last.
  public private(set) var sharedCursor: String?
  /// A further page of ``shared`` is being read.
  public private(set) var isLoadingMoreShared = false
  /// Each workflow with its steps, by id.
  public internal(set) var details: [String: CreationLoad<WorkflowDetail>] = [:]
  /// Workflows with a write in flight.
  public internal(set) var busyIDs: Set<String> = []
  /// A clone is in flight.
  public private(set) var isCloning = false
  /// The last failed list action (clone, delete, a run's message), until dismissed.
  public var actionError: CoreError?
  /// Why the last Save plan failed, by workflow, until the next try.
  public internal(set) var planErrors: [String: CoreError] = [:]
  /// Where each placed description source sits in its planning chat's journal, by entry id.
  public internal(set) var sourcePositions: [String: SourcePosition] = [:]
  /// A workflow the Workflows page should open: a new draft, a clone or a link.
  public var requestedWorkflowID: String?
  /// A workflow the Automations page should make an automation of, once.
  public var pendingAutomation: SavedWorkflow?

  /// Each workflow's runs, newest first, as far as paged.
  public internal(set) var runs: [String: CreationLoad<[WorkflowRun]>] = [:]
  /// The next page of each workflow's runs.
  public internal(set) var runCursors: [String: String] = [:]
  /// Workflows reading a further page of runs.
  public internal(set) var loadingMoreRuns: Set<String> = []
  /// The pages of runs below each run read after its first, by run id.
  public internal(set) var moreDescendants: [String: [WorkflowRun]] = [:]
  /// Where the next page of runs below each run starts, once one was read; `nil` after the last.
  public internal(set) var descendantCursors: [String: String?] = [:]
  /// Runs reading a further page of the runs below them.
  public internal(set) var loadingDescendants: Set<String> = []
  /// Runs whose Stop was taken, until their session is seen idle.
  public internal(set) var stoppingRuns: Set<String> = []
  /// Runs with a Stop or Continue in flight.
  public internal(set) var runActions: Set<String> = []

  /// Who each workflow is shared with.
  public internal(set) var grants: [String: CreationLoad<[AutomationGrant]>] = [:]
  /// A share change is in flight.
  public internal(set) var isSavingGrant = false
  /// The last failed share change, until the sheet closes.
  public internal(set) var grantError: CoreError?

  let core: ClientCore
  /// The server and account what was read belongs to.
  @ObservationIgnored private var owner: String?

  init(core: ClientCore) {
    self.core = core
  }

  /// Ties what is read to `owner`, one server and account; another one's workflows are
  /// forgotten.
  func belong(to owner: String) {
    guard owner != self.owner else { return }
    self.owner = owner
    reset()
  }

  /// Forgets everything read, for another server or account.
  func reset() {
    owned = .idle
    ownedCursor = nil
    shared = .idle
    sharedCursor = nil
    details = [:]
    busyIDs = []
    actionError = nil
    planErrors = [:]
    sourcePositions = [:]
    requestedWorkflowID = nil
    runs = [:]
    runCursors = [:]
    moreDescendants = [:]
    descendantCursors = [:]
    stoppingRuns = []
    grants = [:]
  }

  /// The caller's workflow or one shared with them, from the lists.
  public func listed(_ id: String) -> SavedWorkflow? {
    owned.value?.first { $0.id == id } ?? shared.value?.first { $0.id == id }
  }

  // MARK: Lists

  /// Reads the first page of the caller's workflows and, where workflows are shared, of those
  /// shared with them. A reload keeps the lists on screen until it lands.
  /// - Parameter sharing: The server shares workflows.
  public func loadLists(sharing: Bool) async {
    await loadOwned()
    if sharing { await loadShared() }
  }

  /// Reads the first page of the caller's workflows.
  public func loadOwned() async {
    if owned.value == nil { owned = .loading }
    do {
      let page = try await core.workflows(after: nil)
      owned = .loaded(page.workflows)
      ownedCursor = page.nextCursor
    } catch {
      owned = .failed(coreError(error))
    }
  }

  /// Reads the next page of the caller's workflows; a failure keeps the rows read.
  public func loadMoreOwned() async {
    guard let cursor = ownedCursor, !isLoadingMoreOwned else { return }
    isLoadingMoreOwned = true
    defer { isLoadingMoreOwned = false }
    do {
      let page = try await core.workflows(after: cursor)
      owned = .loaded(Self.appending(page.workflows, to: owned.value ?? []))
      ownedCursor = page.nextCursor == cursor ? nil : page.nextCursor
    } catch {
      actionError = coreError(error)
    }
  }

  /// Reads the first page of the workflows shared with the caller.
  public func loadShared() async {
    if shared.value == nil { shared = .loading }
    do {
      let page = try await core.sharedWorkflows(after: nil)
      shared = .loaded(page.workflows)
      sharedCursor = page.nextCursor
    } catch {
      shared = .failed(coreError(error))
    }
  }

  /// Reads the next page of shared workflows; a failure keeps the rows read.
  public func loadMoreShared() async {
    guard let cursor = sharedCursor, !isLoadingMoreShared else { return }
    isLoadingMoreShared = true
    defer { isLoadingMoreShared = false }
    do {
      let page = try await core.sharedWorkflows(after: cursor)
      shared = .loaded(Self.appending(page.workflows, to: shared.value ?? []))
      sharedCursor = page.nextCursor == cursor ? nil : page.nextCursor
    } catch {
      actionError = coreError(error)
    }
  }

  /// `page` after `known`, each workflow once.
  static func appending(_ page: [SavedWorkflow], to known: [SavedWorkflow]) -> [SavedWorkflow] {
    let ids = Set(known.map(\.id))
    return known + page.filter { !ids.contains($0.id) }
  }

  // MARK: A workflow

  /// Reads a workflow with its steps; a reload keeps it on screen until it lands.
  public func loadDetail(_ id: String) async {
    if details[id]?.value == nil { details[id] = .loading }
    do {
      details[id] = .loaded(try await core.workflow(id: id))
    } catch {
      details[id] = .failed(coreError(error))
    }
  }

  /// Saves a draft and asks the page to open it.
  /// - Returns: The draft, or why it was not saved.
  public func createDraft(name: String, description: String) async -> Result<
    WorkflowDetail, CoreError
  > {
    do {
      let draft = try await core.createWorkflowDraft(name: name, description: description)
      saved(draft)
      requestedWorkflowID = draft.workflow.id
      return .success(draft)
    } catch {
      return .failure(coreError(error))
    }
  }

  /// Copies a workflow's saved plan into a new one and asks the page to open it; a failure is in
  /// ``actionError``.
  @discardableResult
  public func clone(_ id: String) async -> WorkflowDetail? {
    guard !isCloning else { return nil }
    isCloning = true
    defer { isCloning = false }
    do {
      let copy = try await core.cloneWorkflow(id: id)
      saved(copy)
      requestedWorkflowID = copy.workflow.id
      return copy
    } catch {
      actionError = coreError(error)
      return nil
    }
  }

  /// Deletes one of the caller's workflows; a failure is in ``actionError``.
  @discardableResult
  public func delete(_ id: String) async -> Bool {
    await write(id) { core in
      try await core.deleteWorkflow(id: id)
      self.details[id] = nil
      self.runs[id] = nil
      if case .loaded(let rows) = self.owned { self.owned = .loaded(rows.filter { $0.id != id }) }
    }
  }

  /// Applies a reviewed proposal; a failure is in ``planErrors``.
  @discardableResult
  public func savePlan(_ id: String, steps: [PlanStep], description: DescriptionWrite?) async
    -> Bool
  {
    planErrors[id] = nil
    guard !busyIDs.contains(id) else { return false }
    busyIDs.insert(id)
    defer { busyIDs.remove(id) }
    do {
      saved(try await core.saveWorkflowPlan(id: id, steps: steps, description: description))
      return true
    } catch {
      planErrors[id] = coreError(error)
      return false
    }
  }

  /// Replaces the description with the user's wording.
  /// - Returns: Why it was not saved; `nil` once saved.
  public func saveDescription(_ id: String, _ description: String) async -> CoreError? {
    busyIDs.insert(id)
    defer { busyIDs.remove(id) }
    do {
      saved(try await core.saveWorkflowDescription(id: id, description: description))
      return nil
    } catch {
      return coreError(error)
    }
  }

  /// Keeps `sessionID` as the workflow's planning chat, so it reopens on any device.
  @discardableResult
  public func setPlanningSession(_ id: String, sessionID: String) async -> Bool {
    await write(id) { core in
      self.saved(try await core.setWorkflowPlanningSession(id: id, sessionId: sessionID))
    }
  }

  /// Places a description's source proposal in its planning chat's journal, once.
  public func placeSource(sessionID: String, entryID: String) async {
    guard sourcePositions[entryID] == nil else { return }
    do {
      let position = try await core.journalEntryPosition(sessionId: sessionID, entryId: entryID)
      sourcePositions[entryID] = position.map { .at(position: $0) } ?? .elsewhere
    } catch {
      // Unplaced, the page offers no description: an edit made since must stand.
      sourcePositions[entryID] = nil
    }
  }

  /// A write's answer: the workflow as saved, and the lists read again for its name and state.
  func saved(_ detail: WorkflowDetail) {
    details[detail.workflow.id] = .loaded(detail)
    let summary = detail.workflow
    if case .loaded(var rows) = owned {
      if let index = rows.firstIndex(where: { $0.id == summary.id }) {
        rows[index] = summary
      } else {
        rows.append(summary)
        rows.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
      }
      owned = .loaded(rows)
    }
  }

  /// Runs a write for workflow `id`; a failure is in ``actionError``.
  func write(_ id: String, _ body: (ClientCore) async throws -> Void) async -> Bool {
    guard !busyIDs.contains(id) else { return false }
    busyIDs.insert(id)
    defer { busyIDs.remove(id) }
    do {
      try await body(core)
      return true
    } catch {
      actionError = coreError(error)
      return false
    }
  }
}
