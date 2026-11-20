import Foundation
public import OmnigentCoreFFI

/// A workflow's runs (web `useWorkflowRuns` and `useWorkflowRunDescendants`), Stop and Continue
/// on a run's row, and who a workflow is shared with.
extension WorkflowsStore {
  /// How often an open workflow page reads its runs again: other sessions and automations start
  /// runs while it shows.
  public static let runsRefresh: Duration = .seconds(10)

  /// Reads the newest page of a workflow's runs, keeping the older pages read; a reload keeps
  /// the runs on screen until it lands.
  public func loadRuns(_ workflowID: String) async {
    if runs[workflowID]?.value == nil { runs[workflowID] = .loading }
    do {
      let page = try await core.workflowRuns(id: workflowID, before: nil, sessionId: nil)
      let older = (runs[workflowID]?.value ?? []).filter { known in
        !page.runs.contains { $0.id == known.id }
      }
      let kept = runCursors[workflowID] == nil ? [] : older
      runs[workflowID] = .loaded(page.runs + kept)
      if kept.isEmpty { runCursors[workflowID] = page.nextCursor }
      settleStops(page.runs)
    } catch {
      runs[workflowID] = .failed(coreError(error))
    }
  }

  /// Reads the next page of a workflow's runs; a failure keeps the runs read.
  public func loadMoreRuns(_ workflowID: String) async {
    guard let cursor = runCursors[workflowID], !loadingMoreRuns.contains(workflowID) else {
      return
    }
    loadingMoreRuns.insert(workflowID)
    defer { loadingMoreRuns.remove(workflowID) }
    do {
      let page = try await core.workflowRuns(id: workflowID, before: cursor, sessionId: nil)
      let known = runs[workflowID]?.value ?? []
      let ids = Set(known.map(\.id))
      runs[workflowID] = .loaded(known + page.runs.filter { !ids.contains($0.id) })
      runCursors[workflowID] = page.nextCursor == cursor ? nil : page.nextCursor
    } catch {
      actionError = coreError(error)
    }
  }

  /// The ``sessionRuns`` key of `sessionID`'s run of `workflowID`.
  public static func sessionRunKey(workflowID: String, sessionID: String) -> String {
    "\(workflowID)\n\(sessionID)"
  }

  /// Reads `sessionID`'s current run of `workflowID`, for the runs it started below it (web
  /// `SessionDescendantRuns`). A failed read keeps the run last read.
  public func loadSessionRun(workflowID: String, sessionID: String) async {
    let key = Self.sessionRunKey(workflowID: workflowID, sessionID: sessionID)
    guard
      let page = try? await core.workflowRuns(id: workflowID, before: nil, sessionId: sessionID)
    else { return }
    sessionRuns[key] = page.runs.first(where: \.isCurrent)
    settleStops(page.runs)
  }

  /// The runs below `run`: its first page and those read since, each once.
  public func descendants(of run: WorkflowRun) -> [WorkflowRun] {
    mergeDescendantRuns(run: run, more: moreDescendants[run.id] ?? [])
  }

  /// Whether more runs below `run` can be read.
  public func hasMoreDescendants(of run: WorkflowRun) -> Bool {
    if let cursor = descendantCursors[run.id] { return cursor != nil }
    return run.descendantRunsCursor != nil
  }

  /// Reads the next page of the runs below `run` of `workflowID`; a failure keeps those read.
  public func loadMoreDescendants(of run: WorkflowRun, workflowID: String) async {
    let cursor = descendantCursors[run.id] ?? run.descendantRunsCursor
    guard let cursor, !loadingDescendants.contains(run.id) else { return }
    loadingDescendants.insert(run.id)
    defer { loadingDescendants.remove(run.id) }
    do {
      let page = try await core.workflowRunDescendants(
        workflowId: run.workflowId.isEmpty ? workflowID : run.workflowId, runId: run.id,
        sessionId: run.sessionId, after: cursor)
      moreDescendants[run.id, default: []].append(contentsOf: page.runs)
      descendantCursors[run.id] = page.nextCursor == cursor ? .some(nil) : .some(page.nextCursor)
    } catch {
      actionError = coreError(error)
    }
  }

  /// Asks a run's main agent to stop the plan and its workers; the row shows "Stopping…" until
  /// the session is seen idle. A failure is in ``actionError``.
  @discardableResult
  public func stop(_ run: WorkflowRun, planName: String?, workflowID: String) async -> Bool {
    let sent = await message(run, stopPlanMessage(planName: planName), workflowID: workflowID)
    if sent { stoppingRuns.insert(run.id) }
    return sent
  }

  /// Asks a run's main agent to pick its plan back up; a failure is in ``actionError``.
  @discardableResult
  public func continuePlan(_ run: WorkflowRun, planName: String?, workflowID: String) async
    -> Bool
  {
    stoppingRuns.remove(run.id)
    return await message(run, continuePlanMessage(planName: planName), workflowID: workflowID)
  }

  /// Sends a task's action to a run's session; a failure is in ``actionError``.
  @discardableResult
  public func perform(_ action: TaskAction, task: String, in run: WorkflowRun, workflowID: String)
    async -> Bool
  {
    if action == .stop { return await stop(run, planName: nil, workflowID: workflowID) }
    guard let text = taskActionMessage(action: action, taskName: task) else { return false }
    return await message(run, text, workflowID: workflowID)
  }

  private func message(_ run: WorkflowRun, _ text: String, workflowID: String) async -> Bool {
    guard !runActions.contains(run.id) else { return false }
    runActions.insert(run.id)
    defer { runActions.remove(run.id) }
    do {
      try await core.sendWorkflowRunMessage(
        sessionId: run.sessionId, workflowRunId: run.id, text: text)
    } catch {
      actionError = coreError(error)
      await loadRuns(workflowID)
      return false
    }
    await loadRuns(workflowID)
    return true
  }

  /// A Stop ends once its run's session is seen not working.
  private func settleStops(_ listed: [WorkflowRun]) {
    for run in listed where stoppingRuns.contains(run.id) && !isWorkflowRunWorking(run: run) {
      stoppingRuns.remove(run.id)
    }
  }

  // MARK: Sharing

  /// Reads who a workflow is shared with.
  public func loadGrants(_ id: String) async {
    if grants[id]?.value == nil { grants[id] = .loading }
    do {
      grants[id] = .loaded(try await core.workflowGrants(id: id))
    } catch {
      grants[id] = .failed(coreError(error))
    }
  }

  /// Shares a workflow with `userID` at read access; a failure is in ``grantError``.
  @discardableResult
  public func grant(_ id: String, to userID: String) async -> Bool {
    await changeGrant(id) { core in try await core.grantWorkflowAccess(id: id, userId: userID) }
  }

  /// Stops sharing a workflow with `userID`; a failure is in ``grantError``.
  @discardableResult
  public func revoke(_ id: String, from userID: String) async -> Bool {
    await changeGrant(id) { core in try await core.revokeWorkflowAccess(id: id, userId: userID) }
  }

  /// Forgets the last share failure, as the sheet closes.
  public func dismissGrantError() {
    grantError = nil
  }

  private func changeGrant(_ id: String, _ body: (ClientCore) async throws -> Void) async -> Bool {
    guard !isSavingGrant else { return false }
    isSavingGrant = true
    grantError = nil
    defer { isSavingGrant = false }
    do {
      try await body(core)
    } catch {
      grantError = coreError(error)
      return false
    }
    await loadGrants(id)
    return true
  }
}
