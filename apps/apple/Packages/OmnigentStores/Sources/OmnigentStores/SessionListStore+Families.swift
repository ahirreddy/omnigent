public import OmnigentCoreFFI

/// Moves that respect session families: a nested member moves only with its representative.
extension SessionListStore {
  /// Moves `sessionID` into the nest of `destinationID`, or out of its own with `nil`. The rows
  /// of both nests change once the server answers.
  /// - Parameters:
  ///   - sessionID: The session.
  ///   - destinationID: A session of the nest it joins, or `nil`.
  /// - Returns: Whether it moved; a failure is in ``editError``.
  @discardableResult
  public func moveToNest(_ sessionID: String, destinationID: String?) async -> Bool {
    await perform { core in
      try await core.moveToNest(sessionId: sessionID, destinationId: destinationID)
    }
  }

  /// A page of sessions not archived whose title matches `query`, for the Nests picker.
  /// - Parameters:
  ///   - query: The search text.
  ///   - after: The cursor of the page to read; `nil` for the first.
  ///   - limit: The most to return.
  /// - Returns: The matches, most recent first, and the next page's cursor.
  /// - Throws: The core's error.
  public func searchTitles(_ query: String, after: String?, limit: UInt32 = 20)
    async throws(CoreError) -> SessionSearchPage
  {
    guard let core else {
      throw .InvalidState(message: "Connect to a server before searching sessions.")
    }
    do {
      return try await core.searchSessionTitles(query: query, after: after, limit: limit)
    } catch {
      throw coreError(error)
    }
  }

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
