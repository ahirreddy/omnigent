import Foundation
import OmnigentWorkspaceUI
import SwiftUI

/// A colored class of code text in a markdown code block.
nonisolated enum CodeToken: Hashable, Sendable {
  /// A token from the shared ``SyntaxHighlighter``.
  case syntax(SyntaxToken)
  /// A diff's added line.
  case inserted
  /// A diff's removed line.
  case deleted
  /// A diff's file header or hunk header.
  case header
}

/// One colored span of a code block, in UTF-16 offsets of its code.
nonisolated struct CodeSpan: Hashable, Sendable {
  var token: CodeToken
  var range: Range<Int>
}

/// Syntax coloring for fenced code: the shared ``SyntaxHighlighter`` for the languages it knows
/// (the web uses Shiki), and added, removed and header lines for diffs.
nonisolated enum CodeHighlighting {
  /// The language a fence's info string names, lowercased: its first word.
  static func fenceName(_ language: String?) -> String? {
    language?.split(whereSeparator: \.isWhitespace).first.map { $0.lowercased() }
  }

  /// Whether `language` names something this highlighter colors.
  static func supports(_ language: String?) -> Bool {
    guard let name = fenceName(language) else { return false }
    return isDiff(name) || SyntaxLanguage(fenceName: name) != nil
  }

  /// The colored spans of `code`, or none for a language it does not know.
  static func spans(_ code: String, language: String?) -> [CodeSpan] {
    guard let name = fenceName(language) else { return [] }
    if isDiff(name) { return diffSpans(code) }
    guard let syntax = SyntaxLanguage(fenceName: name) else { return [] }
    return SyntaxHighlighter(language: syntax).spans(inText: code).map {
      CodeSpan(token: .syntax($0.token), range: $0.range)
    }
  }

  private static func isDiff(_ name: String) -> Bool { name == "diff" || name == "patch" }

  private static func diffSpans(_ code: String) -> [CodeSpan] {
    var spans: [CodeSpan] = []
    var offset = 0
    for line in code.split(separator: "\n", omittingEmptySubsequences: false) {
      let length = line.utf16.count
      let token: CodeToken? =
        if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("@@")
          || line.hasPrefix("diff ") || line.hasPrefix("index ")
        {
          .header
        } else if line.hasPrefix("+") {
          .inserted
        } else if line.hasPrefix("-") {
          .deleted
        } else {
          nil
        }
      if let token, length > 0 {
        spans.append(CodeSpan(token: token, range: offset..<offset + length))
      }
      offset += length + 1
    }
    return spans
  }

  /// `code` with `spans` colored for `scheme`.
  @MainActor static func attributed(_ code: String, spans: [CodeSpan], scheme: ColorScheme)
    -> AttributedString
  {
    attributed(code, spans: spans) { color($0, scheme: scheme) }
  }

  /// `code` with each span in the color `color` gives its token, built in one pass over the
  /// code. Spans come in order without overlapping; one that overlaps or runs past the end, or
  /// splits a character, is skipped.
  static func attributed(
    _ code: String, spans: [CodeSpan], color: (CodeToken) -> Color
  ) -> AttributedString {
    guard !spans.isEmpty else { return AttributedString(code) }
    let utf16 = code.utf16
    var result = AttributedString()
    var position = code.startIndex
    var offset = 0
    for span in spans where span.range.lowerBound >= offset {
      guard
        let lower = utf16.index(
          position, offsetBy: span.range.lowerBound - offset, limitedBy: utf16.endIndex),
        let upper = utf16.index(lower, offsetBy: span.range.count, limitedBy: utf16.endIndex),
        let start = String.Index(lower, within: code), let end = String.Index(upper, within: code)
      else { continue }
      result.append(AttributedString(code[position..<start]))
      var piece = AttributedString(code[start..<end])
      piece.foregroundColor = color(span.token)
      result.append(piece)
      position = end
      offset = span.range.upperBound
    }
    result.append(AttributedString(code[position...]))
    return result
  }

  @MainActor private static func color(_ token: CodeToken, scheme: ColorScheme) -> Color {
    let dark = scheme == .dark
    return switch token {
    case .syntax(let syntax): WorkspaceTheme.tokenColor(syntax, scheme)
    case .inserted: dark ? StatusColors.diffAdded.dark : StatusColors.diffAdded.light
    case .deleted: dark ? StatusColors.diffRemoved.dark : StatusColors.diffRemoved.light
    case .header: dark ? StatusColors.info.dark : StatusColors.info.light
    }
  }
}

/// Highlighted code, cached by code, language and scheme so a transcript's code blocks color
/// once however often they redraw. The spans usually come tokenized already
/// (``MarkdownWarmup``), so a miss here only colors them.
@MainActor
final class CodeHighlightCache {
  static let shared = CodeHighlightCache(limit: 256)

  private struct Key: Hashable {
    var code: String
    var language: String?
    var dark: Bool
  }

  private var entries: BoundedCache<Key, AttributedString>

  init(limit: Int) {
    entries = BoundedCache(limit: limit)
  }

  /// `code` colored for `scheme`, or `nil` when the language is not highlighted.
  func attributed(_ code: String, language: String?, scheme: ColorScheme) -> AttributedString? {
    guard CodeHighlighting.supports(language) else { return nil }
    let key = Key(code: code, language: language, dark: scheme == .dark)
    return entries.value(for: key) {
      CodeHighlighting.attributed(
        code, spans: CodeSpanCache.shared.spans(code, language: language), scheme: scheme)
    }
  }
}
