import Foundation

// The protocol requires `async`; this in-memory source never suspends.
// swiftlint:disable async_without_await

/// An in-memory `WorkspaceDataSource` over `WorkspaceSamples`, for previews, the gallery and
/// tests. It pages directories, can fail chosen paths, and counts requests.
public final class SampleWorkspaceDataSource: WorkspaceDataSource {
  /// Entries per directory page.
  public var pageSize: Int
  /// Paths whose reads fail with the given failure.
  public var failures: [String: WorkspaceFailure]
  /// The failure every content search returns, when set.
  public var searchFailure: WorkspaceFailure?
  /// Every request, as `"<operation> <path>"`.
  public private(set) var requests: [String] = []
  /// Text saved by `save`, by path; reads return it.
  public var savedTexts: [String: String] = [:]
  /// Review comments, as left with `addComment`, in the order they were left.
  public var comments: [SampleComment] = []
  private var nextCommentID = 0

  /// A sample source.
  /// - Parameters:
  ///   - pageSize: Entries per directory page.
  ///   - failures: Paths whose reads fail.
  public init(pageSize: Int = 1_000, failures: [String: WorkspaceFailure] = [:]) {
    self.pageSize = max(pageSize, 1)
    self.failures = failures
  }

  /// See `WorkspaceDataSource`.
  public func listDirectory(_ path: String, after cursor: String?) async throws(WorkspaceFailure)
    -> DirectoryPage
  {
    requests.append("list \(path)\(cursor.map { " after \($0)" } ?? "")")
    if let failure = failures[path] { throw failure }
    guard let entries = WorkspaceSamples.directories[path] else {
      throw WorkspaceFailure(.notFound, message: "Path '\(path)' not found")
    }
    let start =
      cursor.flatMap { cursor in entries.firstIndex { $0.path == cursor } }.map { $0 + 1 } ?? 0
    let end = min(start + pageSize, entries.count)
    let page = Array(entries[start..<end])
    return DirectoryPage(
      directory: path, entries: page, nextCursor: end < entries.count ? page.last?.path : nil)
  }

  /// See `WorkspaceDataSource`.
  public func readFile(_ path: String) async throws(WorkspaceFailure) -> WorkspaceFile {
    requests.append("read \(path)")
    if let failure = failures[path] { throw failure }
    if let saved = savedTexts[path] {
      let lines = UInt64(saved.count { $0 == "\n" })
      return WorkspaceFile(
        path: path, byteCount: UInt64(saved.utf8.count),
        preview: .text(TextPreview(text: saved, lineCount: lines)))
    }
    if let file = WorkspaceSamples.files[path] { return file }
    let text = "// \(path)\n"
    return WorkspaceFile(
      path: path, byteCount: UInt64(text.utf8.count),
      preview: .text(TextPreview(text: text, lineCount: 1)))
  }

  /// See `WorkspaceDataSource`.
  public func searchPaths(_ query: String, include: String, exclude: String)
    async throws(WorkspaceFailure) -> PathSearchResult
  {
    requests.append("search-paths \(query)")
    let needle = query.lowercased()
    let excluded = exclude.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    let entries = WorkspaceSamples.directories.values.joined().filter { entry in
      !entry.kind.isDirectory && entry.path.lowercased().contains(needle)
        && !excluded.contains { !$0.isEmpty && entry.path.hasPrefix($0) }
    }
    return PathSearchResult(entries: entries.sorted { $0.path < $1.path })
  }

  /// See `WorkspaceDataSource`.
  public func searchContent(_ query: ContentSearchQuery) async throws(WorkspaceFailure)
    -> ContentSearchResult
  {
    requests.append("search-content \(query.query)")
    if let searchFailure { throw searchFailure }
    if query.query.lowercased().contains("fixture needle") { return WorkspaceSamples.searchResult }
    return ContentSearchResult(files: [])
  }

  /// See `WorkspaceDataSource`.
  public func changes() async throws(WorkspaceFailure) -> ChangesList {
    requests.append("changes")
    if let failure = failures["#changes"] { throw failure }
    return WorkspaceSamples.changes
  }

  /// See `WorkspaceDataSource`.
  public func diff(_ path: String) async throws(WorkspaceFailure) -> FileDiff {
    requests.append("diff \(path)")
    if let failure = failures[path] { throw failure }
    guard let diff = WorkspaceSamples.diffs[path] else {
      throw WorkspaceFailure(.notChanged, message: "This file has no changes in this session.")
    }
    return diff
  }

  /// See `WorkspaceDataSource`. Fails with `failures["#save"]` when set.
  public func save(_ path: String, text: String, base: String?) async throws(WorkspaceFailure)
    -> FileSaveResult
  {
    requests.append("save \(path)")
    if let failure = failures["#save"] { throw failure }
    let current = try await currentText(path)
    if let base, current != base, current != text { return .conflict(latest: current) }
    savedTexts[path] = text
    return .saved
  }

  /// See `WorkspaceDataSource`.
  public func comments(on path: String, text: String) async throws(WorkspaceFailure)
    -> [FileCommentLine]
  {
    comments.filter { $0.path == path }.map(\.comment)
      .sorted { ($0.line ?? .max, $0.id) < ($1.line ?? .max, $1.id) }
  }

  /// See `WorkspaceDataSource`.
  public func addComment(_ body: String, on span: FileTextSpan) async throws(WorkspaceFailure) {
    requests.append("comment \(span.reference)")
    if let failure = failures["#comment"] { throw failure }
    nextCommentID += 1
    comments.append(
      SampleComment(
        comment: FileCommentLine(
          id: "c\(nextCommentID)", line: span.firstLine, body: body, anchor: span.text),
        path: span.path))
  }

  // swiftlint:disable discouraged_optional_boolean
  /// See `WorkspaceDataSource`.
  public func updateComment(_ id: String, body: String?, open: Bool?)
    async throws(WorkspaceFailure)
  {
    requests.append("update-comment \(id)")
    if let failure = failures["#comment"] { throw failure }
    guard let index = comments.firstIndex(where: { $0.comment.id == id }) else {
      throw WorkspaceFailure(.notFound, message: "Comment not found")
    }
    if let body { comments[index].comment.body = body }
    if let open { comments[index].comment.isOpen = open }
  }
  // swiftlint:enable discouraged_optional_boolean

  /// See `WorkspaceDataSource`.
  public func deleteComment(_ id: String) async throws(WorkspaceFailure) {
    requests.append("delete-comment \(id)")
    if let failure = failures["#comment"] { throw failure }
    comments.removeAll { $0.comment.id == id }
  }

  /// See `WorkspaceDataSource`.
  public func sendCommentsToAgent(_ ids: [String]) async throws(WorkspaceFailure) {
    requests.append("send-comments \(ids.joined(separator: ","))")
    if let failure = failures["#send"] { throw failure }
    for index in comments.indices where ids.contains(comments[index].comment.id) {
      comments[index].comment.isOpen = false
    }
  }

  private func currentText(_ path: String) async throws(WorkspaceFailure) -> String? {
    guard case .text(let text) = try await readFile(path).preview else { return nil }
    return text.text
  }

  /// See `WorkspaceDataSource`.
  public func absoluteLocation(of path: String) -> String? {
    path.isEmpty ? WorkspaceSamples.root : "\(WorkspaceSamples.root)/\(path)"
  }
}

/// A comment the sample source keeps, with its file.
public struct SampleComment: Hashable, Sendable {
  /// The comment.
  public var comment: FileCommentLine
  /// Its file.
  public var path: String

  /// A comment.
  /// - Parameters:
  ///   - comment: The comment.
  ///   - path: Its file.
  public init(comment: FileCommentLine, path: String) {
    self.comment = comment
    self.path = path
  }
}

// swiftlint:enable async_without_await
