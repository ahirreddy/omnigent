import Foundation

/// How a file changed, as a pull request's file list says it.
nonisolated public enum ChangedFileKind: Hashable, Sendable {
  /// Added.
  case added
  /// Changed in place.
  case modified
  /// Removed.
  case deleted
  /// Moved, possibly with changes.
  case renamed

  /// The status word, as the web's `STATUS_META` labels it.
  public var title: String {
    switch self {
    case .added: "Added"
    case .modified: "Modified"
    case .deleted: "Deleted"
    case .renamed: "Renamed"
    }
  }
}

/// One file of a stacked diff: its place in the change list and its parsed diff, if any.
nonisolated public struct StackedDiffFile: Hashable, Sendable, Identifiable {
  /// The current path.
  public var path: String
  /// The old path of a renamed file.
  public var previousPath: String?
  /// How it changed.
  public var kind: ChangedFileKind
  /// Added lines; `nil` when unknown.
  public var added: UInt64?
  /// Removed lines; `nil` when unknown.
  public var removed: UInt64?
  /// The file's diff from the patch; `nil` when the patch has no text for it.
  public var diff: FileDiff?

  /// The path.
  public var id: String { path }

  /// Creates a file.
  /// - Parameters:
  ///   - path: Current path.
  ///   - previousPath: Old path of a rename.
  ///   - kind: How it changed.
  ///   - added: Added lines.
  ///   - removed: Removed lines.
  ///   - diff: Its diff.
  public init(
    path: String, previousPath: String? = nil, kind: ChangedFileKind, added: UInt64? = nil,
    removed: UInt64? = nil, diff: FileDiff? = nil
  ) {
    self.path = path
    self.previousPath = previousPath
    self.kind = kind
    self.added = added
    self.removed = removed
    self.diff = diff
  }

  /// A file as its own patch describes it (the web's `changedFilesFromPatch`): the status from
  /// the patch, the counts from its hunks.
  /// - Parameter diff: The parsed diff.
  public init(diff: FileDiff) {
    let previous = diff.oldPath.flatMap { $0 != diff.path ? $0 : nil }
    let kind: ChangedFileKind =
      switch diff.change {
      case .added: .added
      case .deleted: .deleted
      case .modified, .renamed, .copied: previous == nil ? .modified : .renamed
      }
    self.init(
      path: diff.path, previousPath: previous, kind: kind, added: diff.added,
      removed: diff.removed, diff: diff)
  }

  /// The old path to show when it differs from the current one.
  public var renamedFrom: String? {
    let previous = previousPath ?? diff?.oldPath
    return previous.flatMap { $0 != path ? $0 : nil }
  }

  /// Lines a unified view draws for the file.
  public var unifiedLineCount: Int {
    diff?.hunks.reduce(0) { $0 + $1.lines.count } ?? 0
  }
}

/// The path filter of a change list (the web's `filterChangedPaths`).
nonisolated public enum ChangedPathFilter {
  /// Files whose path or old path contains `query`, ignoring case and slash direction.
  /// - Parameters:
  ///   - files: The list.
  ///   - query: The filter text.
  /// - Returns: The matching files, in order.
  public static func filter(_ files: [StackedDiffFile], query: String) -> [StackedDiffFile] {
    files.filter { matches($0, query: query) }
  }

  /// Whether `file`'s path or old path contains `query`.
  /// - Parameters:
  ///   - file: The file.
  ///   - query: The filter text.
  /// - Returns: Whether the filter keeps it.
  public static func matches(_ file: StackedDiffFile, query: String) -> Bool {
    let needle = normalized(query.trimmingCharacters(in: .whitespacesAndNewlines))
    return needle.isEmpty
      || [file.path, file.previousPath].contains { path in
        path.map { normalized($0).contains(needle) } ?? false
      }
  }

  /// The files the filter matches, without `hidden` (the web's `selectVisibleFiles`).
  /// - Parameters:
  ///   - files: The list.
  ///   - query: The filter text.
  ///   - hidden: Current paths to leave out, such as viewed files.
  /// - Returns: The visible files.
  public static func visible(
    _ files: [StackedDiffFile], query: String, hiding hidden: Set<String>
  ) -> [StackedDiffFile] {
    let matching = filter(files, query: query)
    return hidden.isEmpty ? matching : matching.filter { !hidden.contains($0.path) }
  }

  private static func normalized(_ text: String) -> String {
    text.replacingOccurrences(of: "\\", with: "/").lowercased()
  }
}

/// A file's hunk fingerprint for viewed marks (the web's `patchFileHashes`): a 53-bit hash of
/// its hunk headers and lines, so a mark survives a new head while the file's hunks are the same.
nonisolated public enum DiffFingerprint {
  /// The fingerprint of `diff`'s hunks; `nil` without hunks (binary, a pure rename).
  /// - Parameter diff: The diff.
  /// - Returns: The fingerprint.
  public static func of(_ diff: FileDiff) -> String? {
    guard !diff.hunks.isEmpty else { return nil }
    var lines: [String] = []
    for hunk in diff.hunks {
      lines.append("@@ -\(hunk.oldStart),\(hunk.oldCount) +\(hunk.newStart),\(hunk.newCount) @@")
      for line in hunk.lines {
        let marker =
          switch line.kind {
          case .context: " "
          case .added: "+"
          case .removed: "-"
          }
        lines.append(marker + line.text)
      }
    }
    return hash(lines.joined(separator: "\n"))
  }

  /// The fingerprint a file gets when its hunks can't be compared; it matches only on `head`.
  /// - Parameter head: The head shown.
  /// - Returns: The stand-in.
  public static func unverified(head: String) -> String { "unverified:\(head)" }

  /// Whether `fingerprint` came from a file's hunks rather than ``unverified(head:)``.
  /// - Parameter fingerprint: A fingerprint.
  /// - Returns: Whether it can be compared across heads.
  public static func isVerified(_ fingerprint: String) -> Bool {
    !fingerprint.hasPrefix("unverified:")
  }

  /// cyrb53 over UTF-16 code units, as the web computes it.
  static func hash(_ text: String) -> String {
    var first: UInt32 = 0xdead_beef
    var second: UInt32 = 0x41c6_ce57
    for unit in text.utf16 {
      first = (first ^ UInt32(unit)) &* 2_654_435_761
      second = (second ^ UInt32(unit)) &* 1_597_334_677
    }
    first =
      ((first ^ (first >> 16)) &* 2_246_822_507) ^ ((second ^ (second >> 13)) &* 3_266_489_909)
    second =
      ((second ^ (second >> 16)) &* 2_246_822_507) ^ ((first ^ (first >> 13)) &* 3_266_489_909)
    let value = UInt64(second & 0x1f_ffff) << 32 | UInt64(first)
    return String(value, radix: 36)
  }
}
