import Foundation

/// What a diff line is (`workspace::DiffLineKind`).
nonisolated public enum DiffLineKind: Hashable, Sendable {
  /// Unchanged.
  case context
  /// Only in the new text.
  case added
  /// Only in the old text.
  case removed
}

/// One line of a hunk (`workspace::DiffLine`).
nonisolated public struct DiffLine: Hashable, Sendable {
  /// What it is.
  public var kind: DiffLineKind
  /// 1-based old line number, for context and removed lines.
  public var oldNumber: UInt64?
  /// 1-based new line number, for context and added lines.
  public var newNumber: UInt64?
  /// The text, without its newline.
  public var text: String
  /// The line ends its side without a newline.
  public var missingNewline: Bool

  /// A line.
  /// - Parameters:
  ///   - kind: What it is.
  ///   - oldNumber: Old line number.
  ///   - newNumber: New line number.
  ///   - text: The text.
  ///   - missingNewline: Whether it ends its side without a newline.
  public init(
    kind: DiffLineKind, oldNumber: UInt64?, newNumber: UInt64?, text: String,
    missingNewline: Bool = false
  ) {
    self.kind = kind
    self.oldNumber = oldNumber
    self.newNumber = newNumber
    self.text = text
    self.missingNewline = missingNewline
  }
}

/// One `@@` hunk (`workspace::DiffHunk`).
nonisolated public struct DiffHunk: Hashable, Sendable {
  /// The `@@ -a,b +c,d @@ section` header, as the core renders it.
  public var header: String
  /// The lines.
  public var lines: [DiffLine]

  /// A hunk.
  /// - Parameters:
  ///   - header: The rendered header.
  ///   - lines: The lines.
  public init(header: String, lines: [DiffLine]) {
    self.header = header
    self.lines = lines
  }
}

/// One side of a side-by-side row (`workspace::SplitCell`).
nonisolated public struct SplitCell: Hashable, Sendable {
  /// What the line is.
  public var kind: DiffLineKind
  /// 1-based line number on its side.
  public var number: UInt64
  /// The text.
  public var text: String
  /// For a paired change: the differing span, in UTF-8 bytes of `text`.
  public var changed: TextRange?

  /// A cell.
  /// - Parameters:
  ///   - kind: What the line is.
  ///   - number: Line number on its side.
  ///   - text: The text.
  ///   - changed: The differing span, in UTF-8 bytes.
  public init(kind: DiffLineKind, number: UInt64, text: String, changed: TextRange? = nil) {
    self.kind = kind
    self.number = number
    self.text = text
    self.changed = changed
  }
}

/// One row of the side-by-side view (`workspace::SplitRow`), as the core pairs them.
nonisolated public enum SplitRow: Hashable, Sendable {
  /// The start of hunk `index`.
  case hunk(index: Int, header: String)
  /// A line pair; a missing side is blank.
  case line(left: SplitCell?, right: SplitCell?)
}

/// How a file changed (`workspace::FileChangeKind`).
nonisolated public enum FileChangeKind: Hashable, Sendable {
  /// A new file.
  case added
  /// A removed file.
  case deleted
  /// Changed in place.
  case modified
  /// Moved.
  case renamed
  /// Copied.
  case copied
}

/// The diff of one file (`workspace::FileDiff` with its `stats()` and `side_by_side()`).
nonisolated public struct FileDiff: Hashable, Sendable, Identifiable {
  /// The old path; `nil` for an added file.
  public var oldPath: String?
  /// The new path; `nil` for a deleted file.
  public var newPath: String?
  /// How it changed.
  public var change: FileChangeKind
  /// The hunks.
  public var hunks: [DiffHunk]
  /// Side-by-side rows, paired by the core.
  public var splitRows: [SplitRow]
  /// Added lines.
  public var added: UInt64
  /// Removed lines.
  public var removed: UInt64
  /// The patch says the file is binary.
  public var binary: Bool
  /// The core's edit budget ran out: the change is one removal and one addition.
  public var approximate: Bool
  /// The change is too large to diff.
  public var tooLarge: Bool

  /// The path to show: the new path, or the old one for a deletion.
  public var path: String { newPath ?? oldPath ?? "" }

  /// The path.
  public var id: String { path }

  /// Nothing to show.
  public var isIdentical: Bool { hunks.isEmpty && !binary && !tooLarge }

  /// A diff.
  /// - Parameters:
  ///   - oldPath: The old path.
  ///   - newPath: The new path.
  ///   - change: How it changed.
  ///   - hunks: The hunks.
  ///   - splitRows: Side-by-side rows.
  ///   - added: Added lines.
  ///   - removed: Removed lines.
  ///   - binary: Whether the file is binary.
  ///   - approximate: Whether the change is approximate.
  ///   - tooLarge: Whether it was too large to diff.
  public init(
    oldPath: String?, newPath: String?, change: FileChangeKind, hunks: [DiffHunk],
    splitRows: [SplitRow], added: UInt64, removed: UInt64, binary: Bool = false,
    approximate: Bool = false, tooLarge: Bool = false
  ) {
    self.oldPath = oldPath
    self.newPath = newPath
    self.change = change
    self.hunks = hunks
    self.splitRows = splitRows
    self.added = added
    self.removed = removed
    self.binary = binary
    self.approximate = approximate
    self.tooLarge = tooLarge
  }
}

/// Why a workspace read failed (`workspace::WorkspaceError`), already worded by the core.
nonisolated public struct WorkspaceFailure: Error, Hashable, Sendable {
  /// What kind of failure it is, for icons and recovery actions.
  nonisolated public enum Kind: Hashable, Sendable {
    /// Not connected, signed out, or the connection changed.
    case notConnected
    /// Invalid input; nothing was sent.
    case invalidInput
    /// The path does not exist.
    case notFound
    /// The file has no changes this session.
    case notChanged
    /// The session has no workspace files.
    case unavailable
    /// No access, or outside the environment's reach.
    case forbidden
    /// The session's runner is offline.
    case runnerOffline
    /// Content search is turned off on the server.
    case searchDisabled
    /// The search ran and failed (for example an invalid regular expression).
    case searchFailed
    /// The network or server failed.
    case server
  }

  /// The kind.
  public var kind: Kind
  /// The message to show.
  public var message: String

  /// A failure.
  /// - Parameters:
  ///   - kind: The kind.
  ///   - message: The message to show.
  public init(_ kind: Kind, message: String) {
    self.kind = kind
    self.message = message
  }

  /// The SF Symbol for the kind.
  public var symbol: String {
    switch kind {
    case .notConnected: "bolt.horizontal.circle"
    case .invalidInput: "exclamationmark.circle"
    case .notFound, .notChanged: "questionmark.folder"
    case .unavailable: "folder.badge.questionmark"
    case .forbidden: "lock"
    case .runnerOffline: "powersleep"
    case .searchDisabled: "magnifyingglass"
    case .searchFailed: "exclamationmark.magnifyingglass"
    case .server: "exclamationmark.triangle"
    }
  }
}

/// The state of one asynchronous read.
nonisolated public enum LoadState<Value: Sendable>: Sendable {
  /// Not requested.
  case idle
  /// In flight.
  case loading
  /// Loaded.
  case loaded(Value)
  /// Failed; shown in place of the content.
  case failed(WorkspaceFailure)

  /// The loaded value.
  public var value: Value? {
    if case .loaded(let value) = self { return value }
    return nil
  }

  /// The failure.
  public var failure: WorkspaceFailure? {
    if case .failed(let failure) = self { return failure }
    return nil
  }

  /// Whether a read is in flight.
  public var isLoading: Bool {
    if case .loading = self { return true }
    return false
  }
}

extension LoadState: Equatable where Value: Equatable {}
extension LoadState: Hashable where Value: Hashable {}
