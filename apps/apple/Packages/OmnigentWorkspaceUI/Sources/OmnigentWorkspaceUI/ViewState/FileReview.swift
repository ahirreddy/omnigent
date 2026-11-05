public import Foundation

/// What saving an edited file did (`workspace::FileSave`).
nonisolated public enum FileSaveResult: Hashable, Sendable {
  /// The text was written.
  case saved
  /// Someone else changed the file since it was read, so nothing was written. `latest` is its
  /// text now, `nil` when it was deleted or is no longer text.
  case conflict(latest: String?)
}

/// An open review comment on a file and the line it starts on.
nonisolated public struct FileCommentLine: Hashable, Sendable, Identifiable {
  /// The comment's id.
  public var id: String
  /// The 1-based line; `nil` when it has no position in the current text.
  public var line: UInt64?
  /// The comment.
  public var body: String
  /// The commented text when it was left.
  public var anchor: String?
  /// Who left it; `nil` in single-user mode.
  public var author: String?
  /// When it was left.
  public var createdAt: Date

  /// A comment.
  /// - Parameters:
  ///   - id: Its id.
  ///   - line: The 1-based line it starts on.
  ///   - body: The comment.
  ///   - anchor: The commented text.
  ///   - author: Who left it.
  ///   - createdAt: When.
  public init(
    id: String, line: UInt64?, body: String, anchor: String? = nil, author: String? = nil,
    createdAt: Date = .now
  ) {
    self.id = id
    self.line = line
    self.body = body
    self.anchor = anchor
    self.author = author
    self.createdAt = createdAt
  }
}

/// A span of a file's text chosen for review: a selection, or a whole line.
nonisolated public struct FileTextSpan: Hashable, Sendable {
  /// The file.
  public var path: String
  /// Where it starts: a 0-based character (Unicode scalar) offset, as comments count.
  public var start: UInt64
  /// Where it ends, exclusive.
  public var end: UInt64
  /// The first 1-based line.
  public var firstLine: UInt64
  /// The last 1-based line.
  public var lastLine: UInt64
  /// The text.
  public var text: String

  /// A span.
  /// - Parameters:
  ///   - path: The file.
  ///   - start: The start offset.
  ///   - end: The end offset, exclusive.
  ///   - firstLine: The first line.
  ///   - lastLine: The last line.
  ///   - text: The text.
  public init(
    path: String, start: UInt64, end: UInt64, firstLine: UInt64, lastLine: UInt64, text: String
  ) {
    self.path = path
    self.start = start
    self.end = end
    self.firstLine = firstLine
    self.lastLine = lastLine
    self.text = text
  }

  /// `range` of `text`, or `nil` when it is empty or only whitespace.
  /// - Parameters:
  ///   - range: The selected range.
  ///   - text: The file's text, with `\n` line breaks.
  ///   - path: The file.
  /// - Returns: The span.
  public static func selection(_ range: Range<String.Index>, in text: String, path: String)
    -> Self?
  {
    let selected = String(text[range])
    guard !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    let before = text[..<range.lowerBound].unicodeScalars
    let start = UInt64(before.count)
    let firstLine = UInt64(before.count { $0 == "\n" }) + 1
    // A selection that ends with the line break stays on the line it breaks.
    let scalars = selected.unicodeScalars
    let lastLine =
      firstLine
      + UInt64(
        scalars.dropLast(scalars.last == "\n" ? 1 : 0)
          .count { $0 == "\n" })
    return Self(
      path: path, start: start, end: start + UInt64(selected.unicodeScalars.count),
      firstLine: firstLine, lastLine: lastLine, text: selected)
  }

  /// The 1-based `line` of `text`, without its line break, or `nil` past the last line.
  /// - Parameters:
  ///   - line: The line.
  ///   - text: The file's text, with `\n` line breaks.
  ///   - path: The file.
  /// - Returns: The span.
  public static func line(_ line: UInt64, in text: String, path: String) -> Self? {
    guard line > 0 else { return nil }
    var start: UInt64 = 0
    for (index, segment) in text.unicodeScalars
      .split(separator: "\n", omittingEmptySubsequences: false).enumerated()
    {
      let length = UInt64(segment.count)
      if UInt64(index) + 1 == line {
        let content = String(segment.last == "\r" ? segment.dropLast() : segment)
        return Self(
          path: path, start: start, end: start + UInt64(content.unicodeScalars.count),
          firstLine: line, lastLine: line, text: content)
      }
      start += length + 1
    }
    return nil
  }

  /// The composer's reference to the span, as the web's "Attach to agent": `path:3-7`.
  public var reference: String { "\(path):\(firstLine)-\(lastLine)" }

  /// "line 3" or "lines 3-7".
  public var linesTitle: String {
    firstLine == lastLine ? "line \(firstLine)" : "lines \(firstLine)-\(lastLine)"
  }
}
