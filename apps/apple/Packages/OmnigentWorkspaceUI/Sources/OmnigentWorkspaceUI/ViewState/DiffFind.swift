import Foundation

/// One searchable string of a patch: a file's path, or a line of its hunks.
nonisolated public struct DiffFindTarget: Hashable, Sendable {
  /// What the string is.
  public enum Kind: Hashable, Sendable {
    /// A path (current or old) of the file.
    case path
    /// A line of the file's hunks.
    case line
  }

  /// The current path of the file whose section shows the match.
  public var path: String
  /// Path or line.
  public var kind: Kind
  /// A line's side: unchanged lines count once, on the new side.
  public var side: DiffLineAnchor.Side?
  /// A line's number on its side.
  public var line: UInt64?
  /// The text, as the diff draws it.
  public var text: String
}

/// One occurrence of the query.
nonisolated public struct DiffFindMatch: Hashable, Sendable {
  /// Where.
  public var target: DiffFindTarget
  /// UTF-16 offsets into ``DiffFindTarget/text``.
  public var range: Range<Int>
}

/// The query's matches in a corpus.
nonisolated public struct DiffFindResult: Hashable, Sendable {
  /// The matches, in corpus order.
  public var matches: [DiffFindMatch] = []
  /// More matches than ``DiffFind/limit`` were found.
  public var truncated = false
  /// The query is not a valid regular expression.
  public var invalid = false

  /// No matches.
  public init() {}
}

/// The find bar's state, kept per pull request.
nonisolated public struct DiffFindState: Hashable, Sendable {
  /// The bar shows.
  public var isOpen = false
  /// The query.
  public var query = ""
  /// Case-sensitive.
  public var matchCase = false
  /// A regular expression.
  public var regex = false

  /// A closed bar.
  public init() {}
}

/// Find in a stacked diff, as the web's Changes tab finds in the fetched patch.
nonisolated public enum DiffFind {
  /// Matches beyond this count are dropped and the result is marked truncated.
  public static let limit = 10_000

  /// Path targets for every file, then the lines of its hunks.
  /// - Parameter files: The files, in order.
  /// - Returns: The corpus.
  public static func corpus(_ files: [StackedDiffFile]) -> [DiffFindTarget] {
    var corpus: [DiffFindTarget] = []
    for file in files {
      corpus.append(DiffFindTarget(path: file.path, kind: .path, text: file.path))
      if let previous = file.renamedFrom {
        corpus.append(DiffFindTarget(path: file.path, kind: .path, text: previous))
      }
      for hunk in file.diff?.hunks ?? [] {
        for line in hunk.lines {
          let side: DiffLineAnchor.Side = line.kind == .removed ? .old : .new
          guard let number = side == .old ? line.oldNumber : line.newNumber else { continue }
          corpus.append(
            DiffFindTarget(
              path: file.path, kind: .line, side: side, line: number,
              text: DiffText.display(line.text)))
        }
      }
    }
    return corpus
  }

  /// Every non-empty occurrence of `query` in `corpus`; a blank query finds nothing.
  /// - Parameters:
  ///   - corpus: What to search.
  ///   - query: The query.
  ///   - matchCase: Case-sensitive.
  ///   - regex: `query` is a regular expression.
  ///   - limit: The most matches kept.
  /// - Returns: The result.
  public static func matches(
    in corpus: [DiffFindTarget], query: String, matchCase: Bool, regex: Bool,
    limit: Int = limit
  ) -> DiffFindResult {
    var result = DiffFindResult()
    guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return result }
    let pattern = regex ? query : NSRegularExpression.escapedPattern(for: query)
    let expression: NSRegularExpression
    do {
      expression = try NSRegularExpression(
        pattern: pattern, options: matchCase ? [] : [.caseInsensitive])
    } catch {
      result.invalid = true
      return result
    }
    for target in corpus {
      let length = target.text.utf16.count
      for found in expression.matches(
        in: target.text, range: NSRange(location: 0, length: length))
      where found.range.length > 0 {
        if result.matches.count == limit {
          result.truncated = true
          return result
        }
        let range = found.range.location..<(found.range.location + found.range.length)
        result.matches.append(DiffFindMatch(target: target, range: range))
      }
    }
    return result
  }

  /// The first match in a file at or below `top` (in `paths` order), else the first.
  /// - Parameters:
  ///   - matches: The matches.
  ///   - paths: The visible files' paths, in order.
  ///   - top: The file at the top of the view.
  /// - Returns: An index into `matches`.
  public static func firstAtOrBelow(_ matches: [DiffFindMatch], paths: [String], top: String?)
    -> Int
  {
    let order = Dictionary(
      paths.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
    let start = top.flatMap { order[$0] } ?? 0
    return matches.firstIndex { (order[$0.target.path] ?? 0) >= start } ?? 0
  }

  /// Where `previous` is in a refreshed list: the same occurrence, else the nearest line on its
  /// side of its file, else its file's path match, else the first.
  /// - Parameters:
  ///   - matches: The refreshed matches.
  ///   - previous: The match shown before.
  /// - Returns: An index into `matches`.
  public static func refreshedIndex(_ matches: [DiffFindMatch], previous: DiffFindMatch) -> Int {
    let target = previous.target
    if let same = matches.firstIndex(where: {
      $0.target == target && $0.range.lowerBound == previous.range.lowerBound
    }) {
      return same
    }
    if target.kind == .path {
      return matches.firstIndex { $0.target.path == target.path && $0.target.kind == .path } ?? 0
    }
    let inFile = matches.indices.filter { matches[$0].target.path == target.path }
    let onSide = inFile.filter {
      matches[$0].target.kind == target.kind && matches[$0].target.side == target.side
    }
    let candidates = onSide.isEmpty ? inFile : onSide
    let line = Int(target.line ?? 0)
    return candidates.min { left, right in
      abs(Int(matches[left].target.line ?? 0) - line)
        < abs(Int(matches[right].target.line ?? 0) - line)
    } ?? 0
  }

  /// The match a step lands on: the next or previous one, wrapping; with none active, the first
  /// or the last.
  /// - Parameters:
  ///   - active: The active index, or `nil`.
  ///   - forward: Toward the end.
  ///   - count: The match count.
  /// - Returns: The index.
  public static func step(from active: Int?, forward: Bool, count: Int) -> Int {
    guard count > 0 else { return 0 }
    guard let active else { return forward ? 0 : count - 1 }
    return (active + (forward ? 1 : -1) + count) % count
  }

  /// The bar's status: blank without a query, "Invalid", "No results", "12 matches" before one
  /// is chosen, else "3 of 12", with "+" when truncated.
  /// - Parameters:
  ///   - query: The query.
  ///   - result: Its matches.
  ///   - position: 1-based active match, 0 for none.
  /// - Returns: The status.
  public static func status(query: String, result: DiffFindResult, position: Int) -> String {
    guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
    if result.invalid { return "Invalid" }
    if result.matches.isEmpty { return "No results" }
    let count = "\(result.matches.count)\(result.truncated ? "+" : "")"
    return position == 0 ? "\(count) matches" : "\(position) of \(count)"
  }
}
