import Foundation

/// Where the workspace views read from. The app implements it over the Rust core
/// (`ClientCore::list_workspace_directory`, `read_workspace_file`, `search_workspace_paths`,
/// `search_workspace_content`, `workspace_changes` and `workspace_file_diff`, with the preview,
/// tree order, grouping and diff computed by the core) and maps `WorkspaceError` to
/// `WorkspaceFailure`. Previews and the gallery use `SampleWorkspaceDataSource`.
///
/// Every method throws a `WorkspaceFailure` the views show as is; nothing is retried here.
public protocol WorkspaceDataSource: AnyObject {
  /// One page of a directory, in tree order.
  /// - Parameters:
  ///   - path: The directory, `""` for the root.
  ///   - cursor: The previous page's `nextCursor`.
  /// - Returns: The page.
  /// - Throws: The failure to show.
  func listDirectory(_ path: String, after cursor: String?) async throws(WorkspaceFailure)
    -> DirectoryPage

  /// A file and its preview.
  /// - Parameter path: The file.
  /// - Returns: The file.
  /// - Throws: The failure to show.
  func readFile(_ path: String) async throws(WorkspaceFailure) -> WorkspaceFile

  /// Files whose name or path contains `query`.
  /// - Parameter query: The text to find.
  /// - Returns: The matches.
  /// - Throws: The failure to show.
  func searchPaths(_ query: String) async throws(WorkspaceFailure) -> PathSearchResult

  /// Lines whose text matches `query`.
  /// - Parameter query: The search.
  /// - Returns: The matches, grouped by file.
  /// - Throws: The failure to show.
  func searchContent(_ query: ContentSearchQuery) async throws(WorkspaceFailure)
    -> ContentSearchResult

  /// The session's changed files.
  /// - Returns: The list.
  /// - Throws: The failure to show.
  func changes() async throws(WorkspaceFailure) -> ChangesList

  /// The diff of a changed file.
  /// - Parameter path: The file.
  /// - Returns: The diff.
  /// - Throws: The failure to show.
  func diff(_ path: String) async throws(WorkspaceFailure) -> FileDiff

  /// The absolute location of `path` on the machine running the environment, when known
  /// (the core's `absolute_location` over the environment's reported root).
  /// - Parameter path: An environment-relative path.
  /// - Returns: The absolute path, or `nil` when the root is unknown.
  func absoluteLocation(of path: String) -> String?
}

/// Host hooks for actions the package cannot perform itself. `nil` hides the action.
public struct WorkspaceActions {
  /// Reveal the absolute path in Finder (macOS) or the Files app.
  public var reveal: ((String) -> Void)?
  /// Open the absolute path in the user's editor.
  public var openExternally: ((String) -> Void)?
  /// Insert a path reference into the composer, for example `@src/main.rs`.
  public var mention: ((String) -> Void)?

  /// Hooks.
  /// - Parameters:
  ///   - reveal: Reveal an absolute path.
  ///   - openExternally: Open an absolute path in an editor.
  ///   - mention: Insert a path reference into the composer.
  public init(
    reveal: ((String) -> Void)? = nil, openExternally: ((String) -> Void)? = nil,
    mention: ((String) -> Void)? = nil
  ) {
    self.reveal = reveal
    self.openExternally = openExternally
    self.mention = mention
  }

  /// No hooks.
  public static let none = Self()
}
