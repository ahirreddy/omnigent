public import OmnigentCoreFFI

/// Moves that respect session families: a nested member moves only with its representative.
extension SessionListStore {
  /// Files `sessionIDs` into `project`, or removes them from their project, as one change of
  /// the list (the bulk bar's Move to project). A label-only project is promoted first. A nested
  /// family member moves with its representative, which must be among them
  /// (`sessionsCanMoveTogether`); otherwise every move is refused before any request.
  /// - Parameters:
  ///   - sessionIDs: The sessions.
  ///   - project: The project, or `nil`.
  /// - Returns: The sessions that did not move; the first failure is in ``editError``.
  @discardableResult
  public func move(_ sessionIDs: [String], to project: ProjectSummary?) async -> Set<String> {
    guard let core else {
      setEditError(.InvalidState(message: "Connect to a server before editing sessions."))
      return Set(sessionIDs)
    }
    var projectID = project?.id
    if let project, projectID == nil {
      guard let promoted = await renameProject(project, to: project.name) else {
        return Set(sessionIDs)
      }
      projectID = promoted.id
    }
    let edits = sessionIDs.map { sessionID in
      SessionEdit(sessionId: sessionID, change: .project(projectId: projectID))
    }
    let failures = await core.editSessions(edits: edits)
    await eventsBeforeAnswer()
    setEditError(failures.first?.error)
    // A label-only folder disappears once its last session leaves it.
    if failures.count < sessionIDs.count { await loadProjects() }
    return Set(failures.map(\.sessionId))
  }
}
