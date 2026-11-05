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
  /// Review comments left with `addComment`.
  public private(set) var comments: [FileTextSpan: [String]] = [:]

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
    comments.filter { $0.key.path == path }
      .sorted { $0.key.start < $1.key.start }
      .flatMap { span, bodies in
        bodies.enumerated().map { index, body in
          FileCommentLine(
            id: "\(span.start)-\(index)", line: span.firstLine, body: body, anchor: span.text)
        }
      }
  }

  /// See `WorkspaceDataSource`.
  public func addComment(_ body: String, on span: FileTextSpan) async throws(WorkspaceFailure) {
    requests.append("comment \(span.reference)")
    comments[span, default: []].append(body)
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

// swiftlint:enable async_without_await
