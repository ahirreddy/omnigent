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
  /// The signed-in user, who may edit and delete their own comments.
  @ObservationIgnored public var viewerID: () -> String? = { nil }

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
    return await WorkspaceMapping.file(file)
  }

  /// The table of a data file's unsaved text, as the core parses it.
  /// - Parameters:
  ///   - text: The edited text.
  ///   - path: The file.
  /// - Returns: The table, or `nil` without rows.
  public func dataTable(_ text: String, path: String) -> DataTablePreview? {
    workspaceDataTable(text: text, path: path).map(WorkspaceMapping.dataTable)
  }

  /// Where text selected in an HTML file's preview is in its source, as the core matches it.
  /// - Parameters:
  ///   - selected: The rendered text.
  ///   - occurrence: Which copy of it was selected.
  ///   - html: The file's source.
  /// - Returns: The character range, or `nil` when the source doesn't have it.
  public func htmlSourceRange(of selected: String, occurrence: Int, in html: String)
    -> Range<UInt64>?
  {
    OmnigentCoreFFI.htmlSourceRange(
      source: html, selected: selected, occurrence: UInt64(clamping: max(0, occurrence))
    ).map { $0.startIndex..<max($0.startIndex, $0.endIndex) }
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

  /// The whole file `path`, downloaded without the read cap.
  /// - Parameter path: The file.
  /// - Returns: Its bytes.
  /// - Throws: The failure to show.
  public func download(_ path: String) async throws(WorkspaceFailure)
    -> OmnigentWorkspaceUI.WorkspaceFileContents
  {
    let file = try await call {
      try await core.downloadWorkspaceFile(
        sessionId: sessionID, environmentId: environmentID, path: path, offset: nil, length: nil)
    }
    return OmnigentWorkspaceUI.WorkspaceFileContents(path: file.path, data: file.bytes)
  }

  /// `length` bytes of the video `path` from `offset`, with the type the player accepts it as.
  /// - Parameters:
  ///   - path: The video.
  ///   - offset: The first byte.
  ///   - length: How many bytes.
  /// - Returns: The bytes and what the server said about the file.
  /// - Throws: The failure to show.
  public func readVideo(_ path: String, offset: UInt64, length: UInt64)
    async throws(WorkspaceFailure) -> WorkspaceVideoChunk
  {
    let part = try await call {
      try await core.downloadWorkspaceFile(
        sessionId: sessionID, environmentId: environmentID, path: path, offset: offset,
        length: length)
    }
    return WorkspaceVideoChunk(
      data: part.bytes, offset: part.offset, totalLength: part.totalLength,
      videoType: workspaceVideoType(contentType: part.contentType, path: path))
  }

  /// The chapters of the recording `path`, from its `.chapters.vtt` file; none without one.
  /// - Parameter path: The recording.
  /// - Returns: The chapters file and its chapters, by start.
  public func videoChapters(_ path: String) async -> VideoChapters {
    let chaptersPath = videoChaptersPath(path: path)
    let file: OmnigentCoreFFI.WorkspaceFile
    do {
      file = try await core.readWorkspaceFile(
        sessionId: sessionID, environmentId: environmentID, path: chaptersPath)
    } catch {
      // Most recordings have no chapters file; the web shows none whatever the read's error.
      return .none
    }
    guard case .text(let text) = file.preview, !text.clipped, !text.serverTruncated else {
      return .none
    }
    let chapters = parseVideoChapters(text: text.text).map {
      OmnigentWorkspaceUI.VideoChapter(time: $0.time, end: $0.end, title: $0.title)
    }
    return VideoChapters(file: chapters.isEmpty ? nil : chaptersPath, chapters: chapters)
  }

  /// Files whose name or path contains `query`, anywhere in the environment.
  /// - Parameters:
  ///   - query: The text to find.
  ///   - include: Comma-separated globs a match must match.
  ///   - exclude: Comma-separated globs a match must not match.
  /// - Returns: The matches.
  /// - Throws: The failure to show.
  public func searchPaths(_ query: String, include: String, exclude: String)
    async throws(WorkspaceFailure) -> OmnigentWorkspaceUI.PathSearchResult
  {
    let search = OmnigentCoreFFI.PathSearchQuery(
      query: query, include: splitWorkspaceGlobs(raw: include),
      exclude: splitWorkspaceGlobs(raw: exclude))
    let result = try await call {
      try await core.searchWorkspacePaths(
        sessionId: sessionID, environmentId: environmentID, query: search)
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

  /// Saves an edit of `path`; with `base` the core first checks nobody else changed the file.
  /// - Parameters:
  ///   - path: The file.
  ///   - text: The new text.
  ///   - base: The text the edit started from.
  /// - Returns: Whether it was saved.
  /// - Throws: The failure to show.
  public func save(_ path: String, text: String, base: String?) async throws(WorkspaceFailure)
    -> FileSaveResult
  {
    let result = try await call {
      try await core.saveWorkspaceFile(
        sessionId: sessionID, environmentId: environmentID, path: path, content: text,
        base: base)
    }
    switch result {
    case .saved: return .saved
    case .conflict(let latest): return .conflict(latest: latest)
    }
  }

  /// The review comments on `path`, open and sent, each with the line of `text` it starts on.
  /// The viewer may edit and delete their own comments and unattributed ones, as the server.
  /// - Parameters:
  ///   - path: The file.
  ///   - text: Its text.
  /// - Returns: The comments.
  /// - Throws: The failure to show.
  public func comments(on path: String, text: String) async throws(WorkspaceFailure)
    -> [OmnigentWorkspaceUI.FileCommentLine]
  {
    let comments = try await call { try await core.sessionComments(sessionId: sessionID) }
    let viewer = viewerID()
    return fileCommentLines(comments: comments, path: path, text: text).map { line in
      var comment = OmnigentWorkspaceUI.FileCommentLine(
        id: line.comment.id, line: line.line, body: line.comment.body,
        anchor: line.comment.anchor.map(anchorDisplayText), author: line.comment.author,
        createdAt: Date(timeIntervalSince1970: TimeInterval(line.comment.createdAt)),
        isOpen: line.comment.isOpen,
        canModify: line.comment.author == nil || line.comment.author == viewer)
      comment.pdfMark = Self.pdfMark(line.comment.anchor)
      comment.htmlOccurrence = line.htmlOccurrence.map { Int(clamping: $0) }
      return comment
    }
  }

  // swiftlint:disable discouraged_optional_boolean
  /// Edits, resolves (`open` false) or reopens a comment.
  /// - Parameters:
  ///   - id: The comment.
  ///   - body: The new text; `nil` keeps it.
  ///   - open: The new state; `nil` keeps it.
  /// - Throws: The failure to show.
  public func updateComment(_ id: String, body: String?, open: Bool?)
    async throws(WorkspaceFailure)
  {
    _ = try await call {
      try await core.updateSessionComment(
        sessionId: sessionID, commentId: id, body: body, open: open)
    }
  }
  // swiftlint:enable discouraged_optional_boolean

  /// Deletes a comment.
  /// - Parameter id: The comment.
  /// - Throws: The failure to show.
  public func deleteComment(_ id: String) async throws(WorkspaceFailure) {
    try await call { try await core.deleteSessionComment(sessionId: sessionID, commentId: id) }
  }

  /// Sends comments to the agent as one message; the core reopens them when it fails.
  /// - Parameter ids: The comments.
  /// - Throws: The failure to show.
  public func sendCommentsToAgent(_ ids: [String]) async throws(WorkspaceFailure) {
    _ = try await call {
      try await core.sendCommentsToAgent(sessionId: sessionID, commentIds: ids)
    }
  }

  /// Leaves a review comment on `span`.
  /// - Parameters:
  ///   - body: The comment.
  ///   - span: The commented range.
  /// - Throws: The failure to show.
  public func addComment(_ body: String, on span: FileTextSpan) async throws(WorkspaceFailure) {
    // A PDF's selection is stored as the web stores it: its page, lines and text.
    let pdf = Self.pdfAnchor(span)
    _ = try await call {
      try await core.addSessionComment(
        sessionId: sessionID, path: span.path, body: body,
        startIndex: pdf?.startIndex ?? span.start, endIndex: pdf?.endIndex ?? span.end,
        anchor: pdf?.anchorContent ?? span.text)
    }
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
