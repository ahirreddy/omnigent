import OmnigentCoreFFI

/// What the list holds as the core reads it: the projects and their sort mode, and whether the
/// pages hold archived sessions, which they do only while the sidebar shows them (as the web's).
extension SessionListStore {
  /// The projects and their sort mode, as the core read them.
  func projectsLoaded(_ projects: [ProjectSummary], sortMode: ProjectSortMode) {
    if projects != self.projects { self.projects = projects }
    if sortMode != projectSortMode { projectSortMode = sortMode }
    if projectsError != nil { projectsError = nil }
  }

  /// Re-reads the project list (empty on a server without projects) and its sort mode, at once:
  /// the folders show as soon as their list lands.
  public func loadProjects() async {
    guard let core else { return }
    async let mode = core.projectSortMode()
    do {
      let projects = try await core.projects()
      if projects != self.projects { self.projects = projects }
    } catch {
      // The sort mode is not wanted without the projects: leaving it cancels its read.
      projectsError = coreError(error)
      return
    }
    do {
      let mode = try await mode
      if mode != projectSortMode { projectSortMode = mode }
      if projectsError != nil { projectsError = nil }
    } catch {
      projectsError = coreError(error)
    }
  }

  /// The connection is back: read failures that only said the server could not be reached go;
  /// the core reads the list, projects and hosts again.
  func connectionRecovered() {
    if lastError?.isConnectivityProblem == true { lastError = nil }
    if projectsError?.isConnectivityProblem == true { projectsError = nil }
    if hostsError?.isConnectivityProblem == true { hostsError = nil }
  }

  /// The filter changed. To or from Archived, the core also reads the pages with or without
  /// archived sessions.
  func filterChanged(from previous: SessionFilter) {
    if (filter == .archived) != (previous == .archived) {
      core?.setSidebarShowsArchived(shown: filter == .archived)
    }
    queryChanged()
  }
}
