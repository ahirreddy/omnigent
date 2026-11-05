import Foundation
public import Observation
public import OmnigentCoreFFI
public import OmnigentWorkspaceUI

/// One session environment's files for the workspace views, backed by the core: directory
/// pages in tree order, file previews, path and content search, the changed files and diffs.
/// The core validates paths, decodes, orders and diffs; this store only maps the records.
@Observable
public final class WorkspaceStore: WorkspaceDataSource {
  /// The session.
  public let sessionID: String
  /// The environment, for example `default`.
  public let environmentID: String
  /// The environment, once ``loadEnvironment()`` read it.
  public private(set) var environment: OmnigentCoreFFI.WorkspaceEnvironment?
  /// Bumped when the server invalidated the changed files: views showing them should reload.
  public private(set) var changesRevision = 0
  /// The changed files the core re-read on the last invalidation.
  public private(set) var lastChangedFiles: ChangedFilesUpdate?
  /// The last failure outside a data-source call (environment read, absolute location).
  public private(set) var lastError: CoreError?

  private let core: ClientCore

  init(sessionID: String, environmentID: String, core: ClientCore) {
    self.sessionID = sessionID
    self.environmentID = environmentID
    self.core = core
  }

  /// Reads the environment, including its absolute root (for Reveal and Copy Path).
  public func loadEnvironment() async {
    do {
      environment = try await core.workspaceEnvironment(
        sessionId: sessionID, environmentId: environmentID)
      lastError = nil
    } catch {
      lastError = coreError(error)
    }
  }

  func changedFilesInvalidated(environmentID: String, update: ChangedFilesUpdate) {
    guard environmentID == self.environmentID else { return }
    lastChangedFiles = update
    changesRevision += 1
  }

  // MARK: WorkspaceDataSource

  /// One page of the directory `path`, in tree order.
  /// - Parameters:
  ///   - path: The directory, `""` for the root.
  ///   - cursor: The previous page's `nextCursor`.
  /// - Returns: The page.
  /// - Throws: The failure to show.
  public func listDirectory(_ path: String, after cursor: String?) async throws(WorkspaceFailure)
    -> OmnigentWorkspaceUI.DirectoryPage
  {
    let page = try await call {
      try await core.listWorkspaceDirectory(
        sessionId: sessionID, environmentId: environmentID, path: path, after: cursor, limit: nil)
    }
    return OmnigentWorkspaceUI.DirectoryPage(
      directory: page.directory, entries: page.entries.map(WorkspaceMapping.entry),
      nextCursor: page.nextCursor)
  }

  /// The file `path` and its preview.
  /// - Parameter path: The file.
  /// - Returns: The file.
  /// - Throws: The failure to show.
  public func readFile(_ path: String) async throws(WorkspaceFailure)
    -> OmnigentWorkspaceUI.WorkspaceFile
  {
    let file = try await call {
      try await core.readWorkspaceFile(
        sessionId: sessionID, environmentId: environmentID, path: path)
    }
    return OmnigentWorkspaceUI.WorkspaceFile(
      path: file.path, byteCount: file.byteCount, preview: WorkspaceMapping.preview(file.preview))
  }

  /// The file `path`'s bytes as the server returned them, binary files included.
  /// - Parameter path: The file.
  /// - Returns: The content.
  /// - Throws: The failure to show.
  public func fileContents(_ path: String) async throws(WorkspaceFailure)
    -> OmnigentWorkspaceUI.WorkspaceFileContents
  {
    let file = try await call {
      try await core.readWorkspaceFileBytes(
        sessionId: sessionID, environmentId: environmentID, path: path)
    }
    return OmnigentWorkspaceUI.WorkspaceFileContents(
      path: file.path, data: file.bytes, truncated: file.truncated)
  }

  /// Files whose name or path contains `query`.
  /// - Parameter query: The text to find.
  /// - Returns: The matches.
  /// - Throws: The failure to show.
  public func searchPaths(_ query: String) async throws(WorkspaceFailure)
    -> OmnigentWorkspaceUI.PathSearchResult
  {
    let result = try await call {
      try await core.searchWorkspacePaths(
        sessionId: sessionID, environmentId: environmentID,
        query: OmnigentCoreFFI.PathSearchQuery(query: query))
    }
    return OmnigentWorkspaceUI.PathSearchResult(
      entries: result.entries.map(WorkspaceMapping.entry),
      truncated: result.truncated || result.hasMore)
  }

  /// Lines whose text matches `query`, grouped by file.
  /// - Parameter query: The search.
  /// - Returns: The matches.
  /// - Throws: The failure to show.
  public func searchContent(_ query: OmnigentWorkspaceUI.ContentSearchQuery)
    async throws(WorkspaceFailure) -> OmnigentWorkspaceUI.ContentSearchResult
  {
    let search = OmnigentCoreFFI.ContentSearchQuery(
      query: query.query, caseSensitive: query.caseSensitive, regex: query.regex,
      include: splitWorkspaceGlobs(raw: query.include),
      exclude: splitWorkspaceGlobs(raw: query.exclude))
    let result = try await call {
      try await core.searchWorkspaceContent(
        sessionId: sessionID, environmentId: environmentID, query: search)
    }
    return OmnigentWorkspaceUI.ContentSearchResult(
      files: result.files.map { file in
        OmnigentWorkspaceUI.ContentSearchFile(
          path: file.path,
          matches: file.matches.map { found in
            OmnigentWorkspaceUI.ContentMatch(
              path: found.path, line: found.line, column: found.column, text: found.text,
              match: OmnigentWorkspaceUI.TextRange(
                start: Int(found.matchUtf16.start), end: Int(found.matchUtf16.end)))
          })
      },
      truncated: result.truncated, warning: result.warning)
  }

  /// The session's changed files, sorted by path, with totals.
  /// - Returns: The list.
  /// - Throws: The failure to show.
  public func changes() async throws(WorkspaceFailure) -> OmnigentWorkspaceUI.ChangesList {
    let list = try await call {
      try await core.workspaceChanges(sessionId: sessionID, environmentId: environmentID)
    }
    return OmnigentWorkspaceUI.ChangesList(
      files: list.files.map { file in
        OmnigentWorkspaceUI.ChangedFile(
          path: file.path, status: WorkspaceMapping.status(file.status),
          linesAdded: file.linesAdded,
          linesRemoved: file.linesRemoved, modifiedAt: WorkspaceMapping.date(file.modifiedAt))
      },
      totals: OmnigentWorkspaceUI.ChangeTotals(
        created: list.totals.created, modified: list.totals.modified,
        deleted: list.totals.deleted, linesAdded: list.totals.linesAdded,
        linesRemoved: list.totals.linesRemoved),
      hasMore: list.hasMore)
  }

  /// The diff of the changed file `path`.
  /// - Parameter path: The file.
  /// - Returns: The diff.
  /// - Throws: The failure to show.
  public func diff(_ path: String) async throws(WorkspaceFailure) -> OmnigentWorkspaceUI.FileDiff {
    let diff = try await call {
      try await core.workspaceFileDiff(
        sessionId: sessionID, environmentId: environmentID, path: path)
    }
    return WorkspaceMapping.fileDiff(diff)
  }

  /// The absolute location of `path` under the environment's root, once
  /// ``loadEnvironment()`` read it; `nil` before. An invalid path is recorded in ``lastError``.
  /// - Parameter path: An environment-relative path.
  /// - Returns: The absolute path.
  public func absoluteLocation(of path: String) -> String? {
    guard let root = environment?.root else { return nil }
    do {
      return try OmnigentCoreFFI.absoluteLocation(root: root, path: path)
    } catch {
      lastError = coreError(error)
      return nil
    }
  }

  // MARK: Mapping

  private func call<Value>(_ body: () async throws -> Value) async throws(WorkspaceFailure)
    -> Value
  {
    do {
      return try await body()
    } catch {
      throw Self.failure(coreError(error))
    }
  }

  /// The workspace view's failure for a core error, keeping its kind and the core's text.
  /// - Parameter error: The error.
  /// - Returns: The failure to show.
  public static func failure(_ error: CoreError) -> WorkspaceFailure {
    guard case .Workspace(let kind, let message, _) = error else {
      return WorkspaceFailure(
        error.requiresSignIn ? .notConnected : .server, message: error.message)
    }
    let mapped = WorkspaceMapping.kind(kind)
    return WorkspaceFailure(mapped, message: message)
  }
}
