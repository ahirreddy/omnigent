public import SwiftUI

/// A numbered line of one side of a file's diff, as review threads anchor to it.
nonisolated public struct DiffLineAnchor: Hashable, Sendable {
  /// The side of the diff.
  public enum Side: Hashable, Sendable {
    /// The old text: removed lines, and unchanged lines by their old number.
    case old
    /// The new text: added lines, and unchanged lines by their new number.
    case new
  }

  /// The file.
  public var path: String
  /// The side.
  public var side: Side
  /// The 1-based line number on that side.
  public var line: UInt64

  /// Creates an anchor.
  /// - Parameters:
  ///   - path: File.
  ///   - side: Side.
  ///   - line: Line number.
  public init(path: String, side: Side, line: UInt64) {
    self.path = path
    self.side = side
    self.line = line
  }

  /// Where a click on `line`'s number points: the old side for a removed line, else the new.
  static func of(_ line: DiffLine, path: String) -> Self? {
    switch line.kind {
    case .removed: line.oldNumber.map { Self(path: path, side: .old, line: $0) }
    case .added, .context: line.newNumber.map { Self(path: path, side: .new, line: $0) }
    }
  }

  /// Every anchor `line` carries: an unchanged line has a number on both sides.
  static func all(_ line: DiffLine, path: String) -> [Self] {
    var anchors: [Self] = []
    if line.kind != .added, let old = line.oldNumber {
      anchors.append(Self(path: path, side: .old, line: old))
    }
    if line.kind != .removed, let new = line.newNumber {
      anchors.append(Self(path: path, side: .new, line: new))
    }
    return anchors
  }
}

/// Lines chosen on one side of one hunk, for a new review thread.
nonisolated public struct DiffLineSelection: Hashable, Sendable {
  /// The file.
  public var path: String
  /// The side.
  public var side: DiffLineAnchor.Side
  /// The first line.
  public var start: UInt64
  /// The last line.
  public var end: UInt64
  /// The hunk the lines are in; a range never spans two.
  public var hunk: Int

  /// Creates a selection.
  /// - Parameters:
  ///   - path: File.
  ///   - side: Side.
  ///   - start: First line.
  ///   - end: Last line.
  ///   - hunk: Hunk index.
  public init(path: String, side: DiffLineAnchor.Side, start: UInt64, end: UInt64, hunk: Int) {
    self.path = path
    self.side = side
    self.start = min(start, end)
    self.end = max(start, end)
    self.hunk = hunk
  }

  /// Whether `anchor` falls in the selection.
  public func contains(_ anchor: DiffLineAnchor) -> Bool {
    anchor.path == path && anchor.side == side && (start...end).contains(anchor.line)
  }

  /// The selection a click on `anchor` in `hunk` makes: the line alone, or with Shift the
  /// range from this selection's first line, when both are on one side of one hunk.
  public func extended(to anchor: DiffLineAnchor, hunk index: Int) -> Self {
    guard anchor.path == path, anchor.side == side, index == hunk else {
      return Self(
        path: anchor.path, side: anchor.side, start: anchor.line, end: anchor.line, hunk: index)
    }
    let from = anchor.line < start ? end : start
    return Self(path: path, side: side, start: from, end: anchor.line, hunk: hunk)
  }
}

/// What a stacked diff shows beside its lines: views under some lines (review conversations),
/// views under a file's header (ones no line holds), and choosing lines by their numbers.
public struct StackedDiffAnnotations {
  /// A view under a line.
  public var lines: [DiffLineAnchor: AnyView] = [:]
  /// A view under a file's header, by path.
  public var files: [String: AnyView] = [:]
  /// The lines chosen, highlighted.
  public var selection: DiffLineSelection?
  /// Choosing lines by their numbers; `nil` leaves the numbers plain.
  public var select: (@MainActor (DiffLineSelection) -> Void)?

  /// Nothing beside the lines.
  public init() {}
}
