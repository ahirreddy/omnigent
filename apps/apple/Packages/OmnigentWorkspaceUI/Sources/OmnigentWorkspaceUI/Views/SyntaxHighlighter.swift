import Foundation

/// A token class the highlighter assigns.
nonisolated public enum SyntaxToken: Hashable, Sendable {
  /// A language keyword.
  case keyword
  /// A string or character literal.
  case string
  /// A comment.
  case comment
  /// A numeric literal.
  case number
  /// A type-like identifier (capitalized), or a markup heading.
  case type
}

/// A cheap single-line highlighter: line comments, quoted strings, numbers, keywords and
/// capitalized identifiers. It never spans lines, so block comments and multi-line strings are
/// only partly colored; correctness of the text never depends on it.
nonisolated public struct SyntaxHighlighter: Sendable {
  /// One colored span, in UTF-16 offsets of the line.
  public struct Span: Hashable, Sendable {
    /// The token class.
    public var token: SyntaxToken
    /// The range, in UTF-16 code units.
    public var range: Range<Int>
  }

  private let keywords: Set<String>
  private let lineComments: [String]
  private let quotes: Set<Character>
  private let markup: Bool

  /// A highlighter for `language`.
  /// - Parameter language: The core's language hint.
  public init(language: SyntaxLanguage) {
    let rules = Self.rules(for: language)
    keywords = rules.keywords
    lineComments = rules.comments
    quotes = rules.quotes
    markup = language == .markdown
  }

  /// The spans of `line`.
  /// - Parameter line: One line, without its newline.
  /// - Returns: Non-overlapping spans, in order.
  public func spans(in line: String) -> [Span] {
    if markup { return markupSpans(in: line) }
    let characters = Array(line.utf16)
    var spans: [Span] = []
    var index = 0
    while index < characters.count {
      if startsComment(characters, at: index) {
        spans.append(Span(token: .comment, range: index..<characters.count))
        break
      }
      let unit = characters[index]
      if let scalar = Unicode.Scalar(unit), quotes.contains(Character(scalar)) {
        let end = stringEnd(characters, from: index, quote: unit)
        spans.append(Span(token: .string, range: index..<end))
        index = end
        continue
      }
      if Self.isIdentifierStart(unit) {
        var end = index + 1
        while end < characters.count, Self.isIdentifierPart(characters[end]) { end += 1 }
        let word = String(decoding: characters[index..<end], as: UTF16.self)
        if keywords.contains(word) {
          spans.append(Span(token: .keyword, range: index..<end))
        } else if let first = word.unicodeScalars.first,
          CharacterSet.uppercaseLetters.contains(first)
        {
          spans.append(Span(token: .type, range: index..<end))
        }
        index = end
        continue
      }
      if Self.isDigit(unit), index == 0 || !Self.isIdentifierPart(characters[index - 1]) {
        var end = index + 1
        while end < characters.count, Self.isNumberPart(characters[end]) { end += 1 }
        spans.append(Span(token: .number, range: index..<end))
        index = end
        continue
      }
      index += 1
    }
    return spans
  }

  private func startsComment(_ characters: [UInt16], at index: Int) -> Bool {
    lineComments.contains { marker in
      let units = Array(marker.utf16)
      return index + units.count <= characters.count
        && Array(characters[index..<index + units.count]) == units
    }
  }

  private func stringEnd(_ characters: [UInt16], from start: Int, quote: UInt16) -> Int {
    var index = start + 1
    let backslash = UInt16(UInt8(ascii: "\\"))
    while index < characters.count {
      if characters[index] == backslash {
        index += 2
        continue
      }
      if characters[index] == quote { return index + 1 }
      index += 1
    }
    return characters.count
  }

  private func markupSpans(in line: String) -> [Span] {
    let length = line.utf16.count
    if line.hasPrefix("#") { return [Span(token: .type, range: 0..<length)] }
    if line.hasPrefix("```") || line.hasPrefix("    ") {
      return [Span(token: .string, range: 0..<length)]
    }
    if line.hasPrefix(">") { return [Span(token: .comment, range: 0..<length)] }
    return []
  }

  private static func isIdentifierStart(_ unit: UInt16) -> Bool {
    (unit >= 0x41 && unit <= 0x5A) || (unit >= 0x61 && unit <= 0x7A) || unit == 0x5F
      || unit == 0x40 || unit == 0x24
  }

  private static func isIdentifierPart(_ unit: UInt16) -> Bool {
    isIdentifierStart(unit) || isDigit(unit)
  }

  private static func isDigit(_ unit: UInt16) -> Bool { unit >= 0x30 && unit <= 0x39 }

  private static func isNumberPart(_ unit: UInt16) -> Bool {
    isIdentifierPart(unit) || unit == 0x2E
  }

  private struct Rules {
    var keywords: Set<String>
    var comments: [String]
    var quotes: Set<Character>
  }

  private static let cFamily: Set<String> = [
    "break", "case", "const", "continue", "default", "do", "else", "enum", "for", "if",
    "return", "static", "struct", "switch", "typedef", "void", "while", "true", "false", "null",
    "class", "public", "private", "protected", "new", "this", "import", "package", "try",
    "catch", "throw", "finally", "interface", "extends", "implements", "final", "abstract",
    "int", "char", "long", "double", "float", "bool", "unsigned", "include", "define",
  ]

  // A table of per-language keyword lists reads best as one switch.
  // swiftlint:disable:next function_body_length cyclomatic_complexity
  private static func rules(for language: SyntaxLanguage) -> Rules {
    let slash = ["//"]
    let hash = ["#"]
    let standard: Set<Character> = ["\"", "'"]
    switch language {
    case .swift:
      return Rules(
        keywords: [
          "actor", "any", "as", "async", "await", "break", "case", "catch", "class", "continue",
          "default", "defer", "do", "else", "enum", "extension", "false", "fileprivate", "for",
          "func", "guard", "if", "import", "in", "init", "inout", "internal", "is", "let", "nil",
          "nonisolated", "open", "private", "protocol", "public", "repeat", "return", "self",
          "Self", "some", "static", "struct", "super", "switch", "throw", "throws", "true", "try",
          "typealias", "var", "where", "while",
        ], comments: slash, quotes: ["\""])
    case .rust:
      return Rules(
        keywords: [
          "as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum",
          "extern", "false", "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod",
          "move", "mut", "pub", "ref", "return", "self", "Self", "static", "struct", "super",
          "trait", "true", "type", "unsafe", "use", "where", "while",
        ], comments: slash, quotes: ["\""])
    case .python:
      return Rules(
        keywords: [
          "and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del",
          "elif", "else", "except", "False", "finally", "for", "from", "global", "if", "import",
          "in", "is", "lambda", "None", "nonlocal", "not", "or", "pass", "raise", "return",
          "True", "try", "while", "with", "yield", "self",
        ], comments: hash, quotes: standard)
    case .javascript, .typescript:
      return Rules(
        keywords: [
          "async", "await", "break", "case", "catch", "class", "const", "continue", "default",
          "delete", "do", "else", "export", "extends", "false", "finally", "for", "from",
          "function", "if", "import", "in", "instanceof", "interface", "let", "new", "null",
          "return", "super", "switch", "this", "throw", "true", "try", "type", "typeof",
          "undefined", "var", "void", "while", "yield",
        ], comments: slash, quotes: ["\"", "'", "`"])
    case .go:
      return Rules(
        keywords: [
          "break", "case", "chan", "const", "continue", "default", "defer", "else", "false",
          "for", "func", "go", "if", "import", "interface", "map", "nil", "package", "range",
          "return", "select", "struct", "switch", "true", "type", "var",
        ], comments: slash, quotes: ["\"", "'", "`"])
    case .ruby:
      return Rules(
        keywords: [
          "begin", "class", "def", "do", "else", "elsif", "end", "false", "if", "module", "nil",
          "require", "return", "self", "true", "unless", "until", "when", "while", "yield",
        ], comments: hash, quotes: standard)
    case .bash, .dockerfile, .makefile, .toml, .yaml:
      return Rules(
        keywords: [
          "if", "then", "else", "elif", "fi", "for", "in", "do", "done", "case", "esac",
          "function", "return", "export", "local", "true", "false", "FROM", "RUN", "COPY",
          "ENV", "WORKDIR", "CMD", "ENTRYPOINT", "ARG", "null",
        ], comments: hash, quotes: standard)
    case .sql:
      return Rules(
        keywords: [
          "SELECT", "FROM", "WHERE", "AND", "OR", "INSERT", "INTO", "VALUES", "UPDATE", "SET",
          "DELETE", "CREATE", "TABLE", "JOIN", "LEFT", "ON", "GROUP", "BY", "ORDER", "AS", "NULL",
          "select", "from", "where", "and", "or", "insert", "into", "update", "delete", "join",
        ], comments: ["--"], quotes: standard)
    case .json:
      return Rules(keywords: ["true", "false", "null"], comments: [], quotes: ["\""])
    case .html, .xml, .markdown:
      return Rules(keywords: [], comments: [], quotes: ["\""])
    case .css:
      return Rules(keywords: ["important"], comments: [], quotes: standard)
    case .php:
      return Rules(
        keywords: cFamily.union(["function", "echo", "use"]), comments: slash + hash,
        quotes: standard)
    case .c, .cpp, .csharp, .java, .kotlin, .objectiveC, .scala:
      return Rules(
        keywords: cFamily.union(["fun", "val", "var", "object", "namespace", "using", "auto"]),
        comments: slash, quotes: standard)
    }
  }
}
