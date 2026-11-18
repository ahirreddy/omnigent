public import OmnigentCoreFFI

extension SessionListStore {
  /// Makes a project from a repository: cloned onto a host first, or saved for a sandbox.
  /// - Returns: The project, or the words to show in the sheet; nothing goes to ``editError``.
  public func createRepositoryProject(_ request: RepositoryProjectRequest) async -> Result<
    ProjectSummary, CoreError
  > {
    guard let core else {
      return .failure(.InvalidState(message: "Connect to a server before creating a project."))
    }
    do {
      let project = try await core.createRepositoryProject(request: request)
      await loadProjects()
      return .success(project)
    } catch {
      return .failure(coreError(error))
    }
  }
}
