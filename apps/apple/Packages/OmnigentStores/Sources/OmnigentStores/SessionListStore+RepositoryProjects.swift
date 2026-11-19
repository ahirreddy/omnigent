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

  /// Creates the folder `~/<name>` on a host for a new project's working directory.
  /// - Returns: The folder's absolute path, or the words to show in the sheet.
  public func createProjectFolder(hostID: String, name: String) async -> Result<
    String, CoreError
  > {
    guard let core else {
      return .failure(.InvalidState(message: "Connect to a server before creating a project."))
    }
    do {
      return .success(try await core.createProjectFolder(hostId: hostID, name: name))
    } catch {
      return .failure(coreError(error))
    }
  }

  /// Makes a project whose sessions start on a host, in a working directory when one is given.
  /// - Returns: The project, or the words to show in the sheet; nothing goes to ``editError``.
  public func createFolderProject(_ request: FolderProjectRequest) async -> Result<
    ProjectSummary, CoreError
  > {
    guard let core else {
      return .failure(.InvalidState(message: "Connect to a server before creating a project."))
    }
    do {
      let project = try await core.createFolderProject(request: request)
      await loadProjects()
      return .success(project)
    } catch {
      return .failure(coreError(error))
    }
  }
}
