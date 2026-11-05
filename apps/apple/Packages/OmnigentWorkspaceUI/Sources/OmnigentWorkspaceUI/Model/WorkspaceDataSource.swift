public import Foundation

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

  /// The file's whole content, for sharing it or previewing it in another app.
  /// - Parameter path: The file.
  /// - Returns: Its bytes.
  /// - Throws: The failure to show.
  func fileContents(_ path: String) async throws(WorkspaceFailure) -> WorkspaceFileContents
}

extension WorkspaceDataSource {
  /// The content from the viewer's preview: complete text or a complete image. A source that
  /// can read raw bytes (the core's) overrides this, so binary files share too.
  /// - Parameter path: The file.
  /// - Returns: Its bytes.
  /// - Throws: The failure to show, also when the preview is not the whole file.
  public func fileContents(_ path: String) async throws(WorkspaceFailure)
    -> WorkspaceFileContents
  {
    let file = try await readFile(path)
    switch file.preview {
    case .text(let text) where !text.clipped && !text.serverTruncated:
      return WorkspaceFileContents(path: file.path, data: Data(text.text.utf8))
    case .image(_, let data):
      return WorkspaceFileContents(path: file.path, data: data)
    case .text, .binary:
      throw WorkspaceFailure(
        .unavailable, message: "\(WorkspacePaths.name(of: path)) cannot be exported from here.")
    }
  }
}

/// A file's whole content, read to share or preview it outside the workspace views.
nonisolated public struct WorkspaceFileContents: Hashable, Sendable {
  /// Environment-relative path.
  public var path: String
  /// The bytes.
  public var data: Data
  /// The server returned only part of the file.
  public var truncated: Bool

  /// Content.
  /// - Parameters:
  ///   - path: Environment-relative path.
  ///   - data: The bytes.
  ///   - truncated: The server returned only part of the file.
  public init(path: String, data: Data, truncated: Bool = false) {
    self.path = path
    self.data = data
    self.truncated = truncated
  }
}

/// Host hooks for actions the package cannot perform itself. `nil` hides the action.
public struct WorkspaceActions {
  /// Reveal the absolute path in Finder (macOS) or the Files app.
  public var reveal: ((String) -> Void)?
  /// Open the absolute path in the user's editor.
  public var openExternally: ((String) -> Void)?
  /// Share an environment-relative file (iOS: the share sheet).
  public var share: ((String) -> Void)?
  /// Preview an environment-relative file with Quick Look.
  public var quickLook: ((String) -> Void)?
  /// Insert a path reference into the composer, for example `@src/main.rs`.
  public var mention: ((String) -> Void)?

  /// Hooks.
  /// - Parameters:
  ///   - reveal: Reveal an absolute path.
  ///   - openExternally: Open an absolute path in an editor.
  ///   - mention: Insert a path reference into the composer.
  ///   - share: Share an environment-relative file.
  ///   - quickLook: Preview an environment-relative file.
  public init(
    reveal: ((String) -> Void)? = nil, openExternally: ((String) -> Void)? = nil,
    mention: ((String) -> Void)? = nil, share: ((String) -> Void)? = nil,
    quickLook: ((String) -> Void)? = nil
  ) {
    self.reveal = reveal
    self.openExternally = openExternally
    self.mention = mention
    self.share = share
    self.quickLook = quickLook
  }

  /// No hooks.
  public static let none = Self()
}
