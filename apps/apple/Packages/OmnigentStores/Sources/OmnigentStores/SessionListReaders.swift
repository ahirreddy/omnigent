public import OmnigentCoreFFI

extension SessionSummary {
  /// This summary with its preview and last-active time blank: what stays the same when the
  /// session only says something new.
  var withoutActivity: SessionSummary {
    var summary = self
    summary.preview = ""
    summary.updatedAt = 0
    return summary
  }

  /// This summary without what its own row says (title, preview, time, status, requests,
  /// background work, terminal prompt, failure, whether its host and runner are up): what is
  /// left decides where the row is and what is around it. A watch's first snapshot tells each
  /// row's liveness, which the list reads leave out, and moves nothing.
  var placement: SessionSummary {
    var summary = withoutActivity
    summary.title = ""
    summary.status = .idle
    summary.pendingRequests = 0
    summary.backgroundWorkRunning = false
    summary.blockedOn = nil
    summary.failureMessage = nil
    summary.canStop = false
    summary.configuration?.hostOnline = nil
    summary.configuration?.runnerOnline = nil
    summary.configuration?.runnerBound = nil
    summary.configuration?.hostResumable = nil
    return summary
  }
}

extension SessionListStore {
  /// How many of `project`'s sessions, archived included, have an agent still working, which
  /// deleting the project stops.
  /// - Parameter project: The project.
  /// - Returns: The count, or `nil` when it could not be read (see ``editError``).
  public func workingSessions(in project: ProjectSummary) async -> Int? {
    var count: UInt32?
    let read = await perform { core in
      count = try await core.projectWorkingSessions(project: project)
    }
    return read ? count.map(Int.init) : nil
  }

  /// The summary of `sessionID`, if known.
  /// - Parameter sessionID: The session.
  /// - Returns: Its summary.
  public func session(_ sessionID: String) -> SessionSummary? {
    access(keyPath: \.[summaryOf: sessionID])
    return self[summaryOf: sessionID]
  }

  /// The attention of `sessionID`; Idle for a session the list does not know.
  /// - Parameter sessionID: The session.
  /// - Returns: Its state and the pending decisions the caller can answer.
  public func attention(of sessionID: String) -> SessionAttention {
    access(keyPath: \.[attentionOf: sessionID])
    return self[attentionOf: sessionID] ?? SessionAttention(state: .idle, requests: 0)
  }

  /// Whether `sessionID` has activity the user has not seen; a view that reads it is not redrawn
  /// for another session's mark.
  /// - Parameter sessionID: The session.
  /// - Returns: Whether it is unread.
  public func isUnread(_ sessionID: String) -> Bool {
    access(keyPath: \.[unreadOf: sessionID])
    return self[unreadOf: sessionID]
  }

  /// Whether the composer of `sessionID` holds an unsent draft, for that session's reader alone.
  /// - Parameter sessionID: The session.
  /// - Returns: Whether it has a draft.
  public func hasDraft(_ sessionID: String) -> Bool {
    access(keyPath: \.[draftOf: sessionID])
    return self[draftOf: sessionID]
  }

  /// The summary of `sessionID` without its preview and last-active time, which come back blank:
  /// a view that reads it is not redrawn for each message the session receives.
  /// - Parameter sessionID: The session.
  /// - Returns: Its summary, with `preview` empty and `updatedAt` zero.
  public func sessionWithoutActivity(_ sessionID: String) -> SessionSummary? {
    access(keyPath: \.[withoutActivityOf: sessionID])
    return self[withoutActivityOf: sessionID]
  }

  /// The parent of a sub-agent session, when the server reported one.
  /// - Parameter sessionID: The session.
  /// - Returns: The parent's id, or `nil` for a top-level (or unknown) session.
  public func parent(of sessionID: String) -> String? {
    sessionWithoutActivity(sessionID)?.configuration?.parentId.flatMap { $0.isEmpty ? nil : $0 }
  }
}
