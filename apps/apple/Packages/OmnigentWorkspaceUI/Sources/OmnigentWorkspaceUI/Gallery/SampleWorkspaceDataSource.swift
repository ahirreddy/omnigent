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
    if let file = WorkspaceSamples.files[path] { return file }
    let text = "// \(path)\n"
    return WorkspaceFile(
      path: path, byteCount: UInt64(text.utf8.count),
      preview: .text(TextPreview(text: text, lineCount: 1)))
  }

  /// See `WorkspaceDataSource`.
  public func searchPaths(_ query: String) async throws(WorkspaceFailure) -> PathSearchResult {
    requests.append("search-paths \(query)")
    let needle = query.lowercased()
    let entries = WorkspaceSamples.directories.values.joined().filter {
      !$0.kind.isDirectory && $0.path.lowercased().contains(needle)
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

  /// See `WorkspaceDataSource`.
  public func absoluteLocation(of path: String) -> String? {
    path.isEmpty ? WorkspaceSamples.root : "\(WorkspaceSamples.root)/\(path)"
  }
}

// swiftlint:enable async_without_await
