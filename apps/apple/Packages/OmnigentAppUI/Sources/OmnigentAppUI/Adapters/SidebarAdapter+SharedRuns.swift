import OmnigentCoreFFI
import OmnigentUIComponents

/// Other users' automation runs shared with the viewer sit in the default automation folder,
/// wherever their owner filed them (the web's `sessionInSidebarFolder` and
/// `withAutomationFolder`).
extension SidebarAdapter {
  /// The placeholder folder's id, apart from any project's.
  static let sharedRunsFolderID = "automation-runs-placeholder"

  /// `folders` with the shared runs among `sessions` filed into the viewer's project named
  /// "Omnigent Automation", else into a placeholder where a new project of that name would
  /// sit: by name, or last under a manual order. Pinned runs stay pinned.
  static func withSharedRuns(
    _ folders: [SessionProject], sessions: [OmnigentCoreFFI.SessionSummary],
    isOwned: (OmnigentCoreFFI.SessionSummary) -> Bool, pinned: Set<String>, manualOrder: Bool
  ) -> [SessionProject] {
    let name = AutomationsMapping.defaultProjectName
    let filed = Set(folders.flatMap(\.sessionIds))
    let runs = sessions.filter { session in
      session.isAutomationRun && !isOwned(session) && !pinned.contains(session.id)
        && !filed.contains(session.id)
    }.map(\.id)
    guard !runs.isEmpty else { return folders }
    var result = folders
    if let index = result.firstIndex(where: { $0.name == name && !$0.isPlaceholder }) {
      // After the project's own, which may keep a dragged order.
      result[index].sessionIds += runs
      return result
    }
    var placeholder = SessionProject(id: sharedRunsFolderID, name: name, sessionIds: runs)
    placeholder.isPlaceholder = true
    let index = manualOrder ? nil : result.firstIndex { $0.name > name }
    result.insert(placeholder, at: index ?? result.count)
    return result
  }
}
