public import Foundation

nonisolated extension SidebarViewState {
  /// What choosing a row opens: an Add nested agent composer's provisional row reopens that
  /// composer, so it stays highlighted while it is open; any other row opens its session.
  /// - Parameter session: The row.
  /// - Returns: The destination the row stands for.
  public func destination(of session: SessionSummary) -> SidebarDestination {
    nestedDrafts[session.id].map { .nestedSession(sourceID: $0) } ?? .session(session.id)
  }

  /// The actions a row's menu offers: a provisional row, which is no session yet, offers only
  /// Delete Draft, and only it does.
  @MainActor
  func rowActions(_ session: SessionSummary, _ actions: SessionListActions) -> SessionListActions {
    guard nestedDrafts[session.id] != nil else {
      var sessionActions = actions
      sessionActions.deleteNestedDraft = nil
      return sessionActions
    }
    var draftActions = SessionListActions()
    draftActions.deleteNestedDraft = actions.deleteNestedDraft
    return draftActions
  }
}

extension SidebarNavigationOrder {
  /// Opens what hides `sessionID`'s row, as opening its Add nested agent composer does on the
  /// web: its family wherever it is collapsed, its project folder, and the section it is in.
  /// - Parameters:
  ///   - sessionID: The session.
  ///   - state: The sidebar.
  ///   - defaults: Where the sidebar keeps its collapsed sections and expanded projects.
  /// - Returns: The collapsed families left (``SidebarViewState/collapsedFamilies``).
  @MainActor public static func reveal(
    _ sessionID: String, in state: SidebarViewState, defaults: UserDefaults = .standard
  ) -> Set<String> {
    let family = state.list.sessions.first { $0.id == sessionID }?.family?.id ?? sessionID
    let sections = SidebarSections.sections(state)
    let folder = state.projects.first { $0.sessionIds.contains(sessionID) }
    let scopes =
      sections.map { SidebarFamilyScope.section($0.title) }
      + state.projects.map { SidebarFamilyScope.project($0.id) }
    let section =
      folder != nil
      ? sections.first(where: \.isProjects)
      : sections.first { $0.sessions.contains { $0.id == sessionID } }
    if let section {
      let collapsed = lines(defaults.string(forKey: collapsedSectionsKey)).subtracting([
        section.title
      ])
      defaults.set(collapsed.sorted().joined(separator: "\n"), forKey: collapsedSectionsKey)
    }
    if let folder {
      let expanded = lines(defaults.string(forKey: expandedProjectsKey)).union([folder.id])
      defaults.set(expanded.sorted().joined(separator: "\n"), forKey: expandedProjectsKey)
    }
    return state.collapsedFamilies.subtracting(scopes.map { $0.key(family: family) })
  }
}
