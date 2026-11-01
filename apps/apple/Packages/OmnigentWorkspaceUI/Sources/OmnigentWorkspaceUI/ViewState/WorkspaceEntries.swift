public import Foundation

// View-state mirrors of `omnigent_core::workspace` records. The Rust core decodes, validates
// and orders everything; these types only carry the result to SwiftUI. Paths are the core's
// normalized environment-relative `WorkspacePath` text: no leading slash, `""` for the root.

/// What a filesystem entry is (`workspace::EntryKind`).
nonisolated public enum WorkspaceEntryKind: Hashable, Sendable {
  /// A regular file.
  case file
  /// A directory.
  case directory
  /// A symbolic link the server did not resolve.
  case symlink
  /// A socket, device or other special file.
  case other
  /// A type newer than this client, as the server sent it.
  case unknown(String)

  /// Whether the entry can be expanded in a tree.
  public var isDirectory: Bool { self == .directory }
}

/// One file or directory (`workspace::WorkspaceEntry`).
nonisolated public struct WorkspaceEntry: Hashable, Sendable, Identifiable {
  /// Environment-relative path.
  public var path: String
  /// The base name.
  public var name: String
  /// What it is.
  public var kind: WorkspaceEntryKind
  /// Size in bytes, for files.
  public var size: UInt64?
  /// Last modification.
  public var modifiedAt: Date?

  /// The path, which is unique within an environment.
  public var id: String { path }

  /// An entry.
  /// - Parameters:
  ///   - path: Environment-relative path.
  ///   - name: The base name; defaults to the last path segment.
  ///   - kind: What it is.
  ///   - size: Size in bytes, for files.
  ///   - modifiedAt: Last modification.
  public init(
    path: String, name: String? = nil, kind: WorkspaceEntryKind, size: UInt64? = nil,
    modifiedAt: Date? = nil
  ) {
    self.path = path
    self.name = name ?? WorkspacePaths.name(of: path)
    self.kind = kind
    self.size = size
    self.modifiedAt = modifiedAt
  }
}

/// One page of a directory listing (`workspace::DirectoryPage`).
nonisolated public struct DirectoryPage: Hashable, Sendable {
  /// The directory listed.
  public var directory: String
  /// Entries in tree order.
  public var entries: [WorkspaceEntry]
  /// The cursor for the next page; `nil` on the last page.
  public var nextCursor: String?

  /// A page.
  /// - Parameters:
  ///   - directory: The directory listed.
  ///   - entries: Entries in tree order.
  ///   - nextCursor: The cursor for the next page.
  public init(directory: String, entries: [WorkspaceEntry], nextCursor: String? = nil) {
    self.directory = directory
    self.entries = entries
    self.nextCursor = nextCursor
  }
}

/// Matches from a file-name search (`workspace::PathSearchResult`).
nonisolated public struct PathSearchResult: Hashable, Sendable {
  /// Matches, environment-relative.
  public var entries: [WorkspaceEntry]
  /// The server stopped before covering the tree, so a missing file may exist.
  public var truncated: Bool

  /// A result.
  /// - Parameters:
  ///   - entries: Matches.
  ///   - truncated: Whether the scan was cut short.
  public init(entries: [WorkspaceEntry], truncated: Bool = false) {
    self.entries = entries
    self.truncated = truncated
  }
}

/// How a file changed this session (`workspace::ChangeStatus`).
nonisolated public enum ChangeStatus: Hashable, Sendable {
  /// New this session.
  case created
  /// Changed, including renames (git reports the new path).
  case modified
  /// Removed.
  case deleted
  /// A status newer than this client.
  case unknown(String)

  /// The one-letter badge.
  public var badge: String {
    switch self {
    case .created: "A"
    case .modified: "M"
    case .deleted: "D"
    case .unknown: "?"
    }
  }

  /// The spoken and tooltip name.
  public var label: String {
    switch self {
    case .created: "Added"
    case .modified: "Modified"
    case .deleted: "Deleted"
    case .unknown(let raw): raw.isEmpty ? "Changed" : raw.capitalized
    }
  }
}

/// One changed file (`workspace::ChangedFileEntry`).
nonisolated public struct ChangedFile: Hashable, Sendable, Identifiable {
  /// Environment-relative path.
  public var path: String
  /// The status.
  public var status: ChangeStatus
  /// Lines added, when the server counted them.
  public var linesAdded: UInt64?
  /// Lines removed, when the server counted them.
  public var linesRemoved: UInt64?
  /// Last modification.
  public var modifiedAt: Date?

  /// The path.
  public var id: String { path }

  /// A changed file.
  /// - Parameters:
  ///   - path: Environment-relative path.
  ///   - status: The status.
  ///   - linesAdded: Lines added, when known.
  ///   - linesRemoved: Lines removed, when known.
  ///   - modifiedAt: Last modification.
  public init(
    path: String, status: ChangeStatus, linesAdded: UInt64? = nil, linesRemoved: UInt64? = nil,
    modifiedAt: Date? = nil
  ) {
    self.path = path
    self.status = status
    self.linesAdded = linesAdded
    self.linesRemoved = linesRemoved
    self.modifiedAt = modifiedAt
  }
}

/// Summary counts for the changed files (`workspace::ChangeTotals`).
nonisolated public struct ChangeTotals: Hashable, Sendable {
  /// Created files.
  public var created: UInt64
  /// Modified files.
  public var modified: UInt64
  /// Deleted files.
  public var deleted: UInt64
  /// Known added lines.
  public var linesAdded: UInt64
  /// Known removed lines.
  public var linesRemoved: UInt64

  /// Totals.
  /// - Parameters:
  ///   - created: Created files.
  ///   - modified: Modified files.
  ///   - deleted: Deleted files.
  ///   - linesAdded: Known added lines.
  ///   - linesRemoved: Known removed lines.
  public init(
    created: UInt64 = 0, modified: UInt64 = 0, deleted: UInt64 = 0, linesAdded: UInt64 = 0,
    linesRemoved: UInt64 = 0
  ) {
    self.created = created
    self.modified = modified
    self.deleted = deleted
    self.linesAdded = linesAdded
    self.linesRemoved = linesRemoved
  }

  /// All files.
  public var files: UInt64 { created + modified + deleted }
}

/// The session's changed files (`workspace::ChangesList`).
nonisolated public struct ChangesList: Hashable, Sendable {
  /// Entries in display order.
  public var files: [ChangedFile]
  /// Totals, computed by the core.
  public var totals: ChangeTotals
  /// The server capped the list.
  public var hasMore: Bool

  /// A list.
  /// - Parameters:
  ///   - files: Entries in display order.
  ///   - totals: Totals, computed by the core.
  ///   - hasMore: Whether the server capped the list.
  public init(files: [ChangedFile], totals: ChangeTotals, hasMore: Bool = false) {
    self.files = files
    self.totals = totals
    self.hasMore = hasMore
  }
}

/// Path text helpers for display only. Validation and normalization belong to the core.
nonisolated public enum WorkspacePaths {
  /// The last segment of `path`.
  /// - Parameter path: An environment-relative path.
  /// - Returns: The name, or `""` for the root.
  public static func name(of path: String) -> String {
    path.split(separator: "/").last.map(String.init) ?? ""
  }

  /// The directory part of `path`.
  /// - Parameter path: An environment-relative path.
  /// - Returns: The parent path, `""` for a top-level entry.
  public static func directory(of path: String) -> String {
    guard let slash = path.lastIndex(of: "/") else { return "" }
    return String(path[..<slash])
  }
}
