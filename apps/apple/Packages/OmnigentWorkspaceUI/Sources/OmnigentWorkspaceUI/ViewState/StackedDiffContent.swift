public import SwiftUI

/// Where a stacked diff scrolls to. A new ``token`` asks again for the same place.
nonisolated public struct StackedDiffScroll: Hashable, Sendable {
  /// What to bring into view.
  public enum Target: Hashable, Sendable {
    /// A file's header, at the top.
    case file(String)
    /// A line of a file, centred.
    case line(path: String, side: DiffLineAnchor.Side, line: UInt64)
  }

  /// Distinguishes repeated requests.
  public var token: Int
  /// The place.
  public var target: Target

  /// Creates a request.
  /// - Parameters:
  ///   - token: A value new for each request.
  ///   - target: The place.
  public init(token: Int, target: Target) {
    self.token = token
    self.target = target
  }
}

/// What a stacked diff shows: its files, their layout, what is collapsed or expanded, the find
/// match, and the views beside lines and headers.
public struct StackedDiffContent {
  /// Files over this many unified lines wait for Show Diff, as the web's `LARGE_DIFF_THRESHOLD`.
  public static let largeDiffLines = 2_000

  /// The files, in order.
  public var files: [StackedDiffFile]
  /// What shows beside lines and headers.
  public var annotations = StackedDiffAnnotations()
  /// Unified or side by side; ``DiffLayoutMode/automatic`` follows the width.
  public var layout = DiffLayoutMode.unified
  /// Files whose diff is hidden.
  public var collapsed: Set<String> = []
  /// Large files the reader chose to show.
  public var shownLargeFiles: Set<String> = []
  /// Expanded context, by path.
  public var context: [String: DiffContextState] = [:]
  /// The active find match.
  public var highlight: DiffFindMatch?
  /// Where to scroll.
  public var scroll: StackedDiffScroll?
  /// A view after the last file, such as comments no file shows.
  public var footer: AnyView?

  /// Creates content.
  /// - Parameter files: The files.
  public init(files: [StackedDiffFile]) {
    self.files = files
  }
}

/// What a stacked diff's controls do. `nil` leaves a control out.
public struct StackedDiffActions {
  /// Collapses or expands a file.
  public var toggle: (@MainActor (String) -> Void)?
  /// Expands a gap of unchanged lines; `nil` draws plain hunk headers.
  public var expand: (@MainActor (String, DiffGap, DiffExpansion) -> Void)?
  /// Shows a large file's diff.
  public var showLargeFile: (@MainActor (String) -> Void)?
  /// Told the file at the top of the view as it scrolls.
  public var topFileChanged: (@MainActor (String) -> Void)?
  /// Told a scroll request's token once the diff scrolled to it, so it is not repeated.
  public var scrolled: (@MainActor (Int) -> Void)?

  /// No actions.
  public init() {}
}
