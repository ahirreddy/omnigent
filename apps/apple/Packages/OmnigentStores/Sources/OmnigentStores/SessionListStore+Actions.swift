public import OmnigentCoreFFI

/// The sidebar row menu's actions beyond rename, pin and archive, and the project folders. Each
/// reports a failure in ``SessionListStore/editError`` and returns whether it succeeded; the
/// list itself changes through the core's events.
extension SessionListStore {
  /// Marks `sessionID` unread, or read.
  /// - Parameters:
  ///   - sessionID: The session.
  ///   - unread: Unread or read.
  /// - Returns: Whether the mark was saved.
  @discardableResult
  public func setUnread(_ sessionID: String, _ unread: Bool) async -> Bool {
    await perform { core in try await core.setSessionUnread(sessionId: sessionID, unread: unread) }
  }

  /// Ends the live process of `sessionID`; the transcript stays.
  /// - Parameter sessionID: The session.
  /// - Returns: Whether the stop was sent.
  @discardableResult
  public func stop(_ sessionID: String) async -> Bool {
    await perform { core in try await core.stopSession(sessionId: sessionID) }
  }

  /// Deletes `sessionID` and its history (owner).
  /// - Parameter sessionID: The session.
  /// - Returns: Whether it was deleted.
  @discardableResult
  public func delete(_ sessionID: String) async -> Bool {
    await perform { core in try await core.deleteSession(sessionId: sessionID) }
  }

  /// Deletes `sessionID` and its history, and with `deleteBranch` its worktree's local git
  /// branch (irreversible).
  /// - Parameters:
  ///   - sessionID: The session.
  ///   - deleteBranch: Also delete the branch.
  /// - Returns: Whether it was deleted.
  @discardableResult
  public func delete(_ sessionID: String, deleteBranch: Bool) async -> Bool {
    await perform { core in
      try await core.deleteSessionWithBranch(sessionId: sessionID, deleteBranch: deleteBranch)
    }
  }

  /// Leaves `sessionID`, shared with the caller.
  /// - Parameter sessionID: The session.
  /// - Returns: Whether the caller left it.
  @discardableResult
  public func leave(_ sessionID: String) async -> Bool {
    await perform { core in try await core.leaveSession(sessionId: sessionID) }
  }

  /// Files `sessionID` into `project`, or removes it from its project. A label-only project
  /// is promoted to a first-class one first, as the web does.
  /// - Parameters:
  ///   - sessionID: The session.
  ///   - project: The project, or `nil`.
  /// - Returns: Whether it moved.
  @discardableResult
  public func move(_ sessionID: String, to project: ProjectSummary?) async -> Bool {
    var projectID = project?.id
    if let project, projectID == nil {
      guard let promoted = await renameProject(project, to: project.name) else { return false }
      projectID = promoted.id
    }
    let moved = await edit(sessionID, .project(projectId: projectID))
    // A label-only folder disappears once its last session leaves it.
    if moved { await loadProjects() }
    return moved
  }

  /// Creates an empty project.
  /// - Parameters:
  ///   - name: Its name.
  ///   - icon: An emoji icon, or `nil`.
  /// - Returns: The project, or `nil` on failure.
  @discardableResult
  public func createProject(named name: String, icon: String? = nil) async -> ProjectSummary? {
    var created: ProjectSummary?
    let succeeded = await perform { core in
      created = try await core.createProject(name: name)
      if let icon, let project = created {
        created = try await core.setProjectIcon(project: project, icon: icon)
      }
    }
    if succeeded || created != nil { await loadProjects() }
    return created
  }

  /// Renames `project` when `name` differs and sets its icon when `icon` differs.
  /// - Parameters:
  ///   - project: The project.
  ///   - name: The name.
  ///   - icon: The emoji icon, or `nil` for the folder.
  /// - Returns: Whether every change was saved.
  @discardableResult
  public func editProject(_ project: ProjectSummary, name: String, icon: String?) async -> Bool {
    var current = project
    let succeeded = await perform { core in
      if name != project.name {
        current = try await core.renameProject(project: current, name: name)
      }
      if icon != project.icon {
        current = try await core.setProjectIcon(project: current, icon: icon)
      }
    }
    await loadProjects()
    return succeeded
  }

  /// Sorts projects by name, or keeps `projects` (their order on screen) as the manual order.
  /// - Parameters:
  ///   - mode: The sort mode.
  ///   - projects: The projects in display order, saved for a manual order.
  /// - Returns: Whether it saved.
  @discardableResult
  public func setProjectSortMode(_ mode: ProjectSortMode, projects: [ProjectSummary]) async
    -> Bool
  {
    switch mode {
    case .manual:
      return await saveProjectOrder(projects)
    case .alphabetical:
      let saved = await perform { core in try await core.sortProjectsAlphabetically() }
      await loadProjects()
      return saved
    }
  }

  /// Renames `project` and re-files its sessions.
  /// - Parameters:
  ///   - project: The project.
  ///   - name: The new name.
  /// - Returns: The renamed project, or `nil` on failure.
  @discardableResult
  public func renameProject(_ project: ProjectSummary, to name: String) async -> ProjectSummary? {
    var renamed: ProjectSummary?
    let succeeded = await perform { core in
      renamed = try await core.renameProject(project: project, name: name)
    }
    if succeeded { await loadProjects() }
    return renamed
  }

  /// Deletes `project` after archiving and unfiling its sessions (never deleting them).
  /// - Parameter project: The project.
  /// - Returns: Whether it was deleted.
  @discardableResult
  public func deleteProject(_ project: ProjectSummary) async -> Bool {
    let deleted = await perform { core in try await core.deleteProject(project: project) }
    await loadProjects()
    return deleted
  }

  /// Moves `sessionID` into `targetID`'s slot of the Pinned section, pinning it if needed.
  /// - Parameters:
  ///   - sessionID: The dragged session.
  ///   - targetID: The pinned session it was dropped on.
  /// - Returns: Whether every write was saved.
  @discardableResult
  public func movePin(_ sessionID: String, slotOf targetID: String) async -> Bool {
    await perform { core in try await core.movePin(sessionId: sessionID, targetId: targetID) }
  }

  /// Saves `projects` as the project order (promoting label-only ones), then re-reads them.
  /// - Parameter projects: The projects, in their new order.
  /// - Returns: Whether the order was saved.
  @discardableResult
  public func saveProjectOrder(_ projects: [ProjectSummary]) async -> Bool {
    let previous = self.projects
    self.projects = projects
    let saved = await perform { core in _ = try await core.saveProjectOrder(projects: projects) }
    if !saved { self.projects = previous }
    await loadProjects()
    return saved
  }

  /// Re-reads the hosts and where a session on each runs.
  /// - Parameter serverURL: The connected server, which decides whether a host is this Mac.
  public func loadHosts(serverURL: String) async {
    guard let core else { return }
    do {
      let hosts = try await core.hosts()
      let environments = OmnigentCoreFFI.hostEnvironments(
        hosts: hosts, serverUrl: serverURL, thisMachineHostId: thisMachineHostID())
      let byID = Dictionary(
        environments.map { ($0.hostId, $0.environment) }, uniquingKeysWith: { first, _ in first })
      if byID != hostEnvironments { hostEnvironments = byID }
      hostsError = nil
    } catch {
      hostsError = coreError(error)
    }
  }

  /// Records whether `sessionID`'s composer holds a draft.
  /// - Parameters:
  ///   - sessionID: The session.
  ///   - hasDraft: Whether it does.
  public func setDraft(_ sessionID: String, _ hasDraft: Bool) {
    guard draftSessionIDs.contains(sessionID) != hasDraft else { return }
    if hasDraft {
      draftSessionIDs.insert(sessionID)
    } else {
      draftSessionIDs.remove(sessionID)
    }
  }

  /// Re-reads the project list (empty on a server without projects) and its sort mode.
  public func loadProjects() async {
    guard let core else { return }
    do {
      let projects = try await core.projects()
      if projects != self.projects { self.projects = projects }
      let mode = try await core.projectSortMode()
      if mode != projectSortMode { projectSortMode = mode }
      if projectsError != nil { projectsError = nil }
    } catch {
      projectsError = coreError(error)
    }
  }

  /// The visible session ids in each project, in display order: sessions the viewer owns that
  /// carry the project's id or legacy label (the core's `projectMembers`).
  /// - Parameter sessions: The sessions to group, in display order.
  /// - Returns: One id list per entry of ``projects``.
  public func members(of sessions: [SessionSummary]) -> [[String]] {
    projectMembers(projects: projects, sessions: sessions, viewerId: viewerID)
  }

  /// Whether the viewer owns `session` (an unreported owner counts as the viewer's).
  /// - Parameter session: The session.
  /// - Returns: Whether it is the viewer's own.
  public func isOwned(_ session: SessionSummary) -> Bool {
    sessionIsOwnedBy(session: session, viewerId: viewerID)
  }

  /// Sessions on the server whose title, or message content, matches `query` (archived
  /// included), beyond the loaded list.
  /// - Parameters:
  ///   - query: The search text.
  ///   - inMessages: Match message content instead of titles; previews are the snippets.
  ///   - limit: The most to return.
  /// - Returns: The matches, most recent first.
  /// - Throws: The core's error.
  public func search(_ query: String, inMessages: Bool, limit: UInt32 = 10) async throws(CoreError)
    -> [SessionSummary]
  {
    guard let core else {
      throw .InvalidState(message: "Connect to a server before searching sessions.")
    }
    do {
      return try await core.searchSessions(query: query, inMessages: inMessages, limit: limit)
    } catch {
      throw coreError(error)
    }
  }

  private func perform(_ operation: (ClientCore) async throws -> Void) async -> Bool {
    guard let core else {
      setEditError(.InvalidState(message: "Connect to a server before editing sessions."))
      return false
    }
    do {
      try await operation(core)
      setEditError(nil)
      return true
    } catch {
      setEditError(coreError(error))
      return false
    }
  }
}
