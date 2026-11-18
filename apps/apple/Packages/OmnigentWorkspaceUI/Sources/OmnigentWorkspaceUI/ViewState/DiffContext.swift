import Foundation

/// Which way an expansion of hidden unchanged lines grows.
nonisolated public enum DiffExpansion: Hashable, Sendable {
  /// The lines just above the next hunk, growing upward.
  case above
  /// The lines just below the previous hunk, growing downward.
  case below
  /// Every hidden line of the gap.
  case all
}

/// Unchanged lines a patch leaves out before hunk ``index``, or after the last hunk when
/// ``index`` is the hunk count.
nonisolated public struct DiffGap: Hashable, Sendable {
  /// The hunk the gap comes before; the hunk count for the gap after the last one.
  public var index: Int
  /// The first hidden old line.
  public var oldStart: UInt64
  /// The first hidden new line.
  public var newStart: UInt64
  /// How many lines it hides; `nil` for the gap after the last hunk until the text is read.
  public var count: Int?
}

/// Lines shown in a gap: from its top (below the previous hunk) and from its bottom (above the
/// next one).
nonisolated public struct DiffGapReveal: Hashable, Sendable {
  /// Lines shown below the previous hunk.
  public var top = 0
  /// Lines shown above the next hunk.
  public var bottom = 0

  /// Nothing shown.
  public init(top: Int = 0, bottom: Int = 0) {
    self.top = top
    self.bottom = bottom
  }
}

/// One file's expanded context: the text the unchanged lines come from, once read, and what each
/// gap shows (the web's `expansionLineCount` steps of 10).
nonisolated public struct DiffContextState: Hashable, Sendable {
  /// How many lines one expansion shows.
  public static let step = 10

  /// The file's text at the head, once read (unchanged lines read the same on both sides).
  public var text: DiffContextText?
  /// What each gap shows, by gap index.
  public var reveals: [Int: DiffGapReveal] = [:]
  /// The text is being read.
  public var isLoading = false
  /// Why the text could not be read.
  public var failure: String?

  /// Nothing expanded.
  public init() {}

  /// Nothing expanded yet, over `lines`.
  /// - Parameter lines: The file's lines at the head.
  public init(lines: [String]) {
    text = DiffContextText(lines: lines)
  }

  /// The file's lines, split as a diff counts them: without breaks, and no empty line after a
  /// final break.
  /// - Parameter text: The file's text.
  /// - Returns: Its lines.
  public static func lines(of text: String) -> [String] {
    var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    if lines.last?.isEmpty == true { lines.removeLast() }
    return lines
  }

  /// `gap` after expanding it by `expansion`.
  /// - Parameters:
  ///   - gap: The gap.
  ///   - expansion: Which way.
  /// - Returns: The new state.
  public func expanding(_ gap: DiffGap, _ expansion: DiffExpansion) -> Self {
    guard let count = gap.count ?? text.map({ Self.trailingCount(gap, total: $0.lines.count) })
    else {
      return self
    }
    var next = self
    var reveal = reveals[gap.index] ?? DiffGapReveal()
    let hidden = max(count - reveal.top - reveal.bottom, 0)
    switch expansion {
    case .above: reveal.bottom += min(Self.step, hidden)
    case .below: reveal.top += min(Self.step, hidden)
    case .all: reveal.top += hidden
    }
    next.reveals[gap.index] = reveal
    return next
  }

  static func trailingCount(_ gap: DiffGap, total: Int) -> Int {
    max(total - Int(gap.newStart) + 1, 0)
  }
}

/// A file's lines, as expanding context reads them.
nonisolated public struct DiffContextText: Hashable, Sendable {
  /// The lines, without breaks.
  public var lines: [String]

  /// Creates the text.
  /// - Parameter lines: The lines.
  public init(lines: [String]) {
    self.lines = lines
  }
}

/// The gaps of a file's diff and the unchanged lines expanding them shows.
nonisolated public enum DiffContext {
  /// Every gap of `diff`: before each hunk and after the last. A gap of no lines is left out.
  /// - Parameters:
  ///   - diff: The diff.
  ///   - lineCount: The file's line count at the head, once its text is read.
  /// - Returns: The gaps, in order.
  public static func gaps(_ diff: FileDiff, lineCount: Int?) -> [DiffGap] {
    guard !diff.hunks.isEmpty, diff.change != .added, diff.change != .deleted else { return [] }
    var gaps: [DiffGap] = []
    var old: UInt64 = 1
    var new: UInt64 = 1
    for (index, hunk) in diff.hunks.enumerated() {
      let count = hunk.newFirst > new ? Int(hunk.newFirst - new) : 0
      if count > 0 {
        gaps.append(DiffGap(index: index, oldStart: old, newStart: new, count: count))
      }
      old = hunk.oldEnd
      new = hunk.newEnd
    }
    let trailing = DiffGap(index: diff.hunks.count, oldStart: old, newStart: new, count: nil)
    let total = lineCount.map { DiffContextState.trailingCount(trailing, total: $0) }
    if total != 0 {
      gaps.append(DiffGap(index: trailing.index, oldStart: old, newStart: new, count: total))
    }
    return gaps
  }

  /// The unchanged lines `reveal` shows of `gap`, read from `lines`: from the top, then from
  /// the bottom. Lines past the text's end are left out.
  /// - Parameters:
  ///   - gap: The gap.
  ///   - reveal: What it shows.
  ///   - lines: The file's lines at the head.
  /// - Returns: The top and bottom lines.
  public static func revealed(_ gap: DiffGap, _ reveal: DiffGapReveal, lines: [String])
    -> (top: [DiffLine], bottom: [DiffLine])
  {
    let count = gap.count ?? DiffContextState.trailingCount(gap, total: lines.count)
    let top = min(reveal.top, count)
    let bottom = min(reveal.bottom, count - top)
    func line(_ offset: Int) -> DiffLine? {
      let number = Int(gap.newStart) + offset
      guard number >= 1, number <= lines.count else { return nil }
      return DiffLine(
        kind: .context, oldNumber: gap.oldStart + UInt64(offset), newNumber: UInt64(number),
        text: lines[number - 1])
    }
    return (
      (0..<top).compactMap(line),
      ((count - bottom)..<count).compactMap(line)
    )
  }

  /// How many of `gap`'s lines stay hidden.
  /// - Parameters:
  ///   - gap: The gap.
  ///   - reveal: What it shows.
  /// - Returns: The hidden count; `nil` while the trailing gap's length is unknown.
  public static func hidden(_ gap: DiffGap, _ reveal: DiffGapReveal?) -> Int? {
    gap.count.map { max($0 - (reveal?.top ?? 0) - (reveal?.bottom ?? 0), 0) }
  }
}
