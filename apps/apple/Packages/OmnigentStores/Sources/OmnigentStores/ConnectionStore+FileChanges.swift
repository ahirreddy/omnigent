import OmnigentCoreFFI

extension ConnectionStore {
  /// How many file changes reached the workspace of `sessionID`: its own agent's, and those of
  /// the open sessions that work in the same directory. A reader is told of this session's alone.
  /// - Parameter sessionID: The session.
  /// - Returns: The count; it only ever grows.
  public func fileChanges(in sessionID: String) -> Int {
    access(keyPath: \.[fileChangesIn: sessionID])
    return self[fileChangesIn: sessionID]
  }

  subscript(fileChangesIn sessionID: String) -> Int { fileChangeCounts[sessionID, default: 0] }

  /// Counts a file change by the agent of `sessionID` for each open session that can show it.
  func countFileChange(in sessionID: String) {
    let changed = sessionList.session(sessionID)
    for open in workspaceStores.keys
    where open == sessionID || Self.sharesWorkspace(changed, sessionList.session(open)) {
      withMutation(keyPath: \.[fileChangesIn: open]) { fileChangeCounts[open, default: 0] += 1 }
    }
  }

  /// Whether a file one session changes can show in the other's workspace: the same host, and
  /// one's directory the other's or inside it. What the list does not know counts as shared, so
  /// no workspace is left showing old files.
  nonisolated static func sharesWorkspace(_ first: SessionSummary?, _ second: SessionSummary?)
    -> Bool
  {
    guard let first, let second else { return true }
    if let firstHost = first.configuration?.hostId, let secondHost = second.configuration?.hostId,
      firstHost != secondHost
    {
      return false
    }
    let firstPath = directories(first.workspace)
    let secondPath = directories(second.workspace)
    return firstPath.starts(with: secondPath) || secondPath.starts(with: firstPath)
  }

  /// A workspace path's directory names, on a host of either kind; none for an unknown path.
  private nonisolated static func directories(_ workspace: String) -> [Substring] {
    workspace.split { $0 == "/" || $0 == "\\" }
  }
}
