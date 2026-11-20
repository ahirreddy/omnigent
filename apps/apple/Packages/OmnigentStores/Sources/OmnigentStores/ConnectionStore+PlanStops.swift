public import OmnigentCoreFFI

/// A plan's Stop seen alike from a workflow run's row and its session's Tasks tab (the web's
/// `planStops`, kept by session).
extension ConnectionStore {
  /// Stops `run`'s plan from its row; its session's Tasks tab shows "Stopping…" at once too.
  /// - Parameters:
  ///   - run: The run.
  ///   - planName: The plan's name, which the stop message names.
  ///   - workflowID: The workflow whose page lists the run.
  /// - Returns: Whether the session took the stop message.
  @discardableResult
  public func stopWorkflowRun(_ run: WorkflowRun, planName: String?, workflowID: String) async
    -> Bool
  {
    guard let workflows else { return false }
    let tasks = tasksStores[run.sessionId]
    let stop = tasks?.beginPlanStop(latest: conversations[run.sessionId]?.latestRequest)
    let sent = await workflows.stop(run, planName: planName, workflowID: workflowID)
    if let stop { tasks?.planStopDelivered(stop, taken: sent) }
    return sent
  }

  /// The runs stopping: those whose row took Stop, and those whose session's Tasks tab took one
  /// that hasn't settled.
  /// - Parameter runs: The runs a page shows.
  /// - Returns: Their ids.
  public func stoppingRuns(_ runs: [WorkflowRun]) -> Set<String> {
    var stopping = workflows?.stoppingRuns ?? []
    for run in runs {
      guard let tasks = tasksStores[run.sessionId] else { continue }
      let latest = conversations[run.sessionId]?.latestRequest
      if tasks.isPlanStopping(working: isWorkflowRunWorking(run: run), latest: latest) {
        stopping.insert(run.id)
      }
    }
    return stopping
  }
}
