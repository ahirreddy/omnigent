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

/// A cheap highlighter: comments, quoted strings, numbers, keywords and capitalized identifiers.
/// ``spans(in:)`` colors one line, so block comments and multi-line strings are only partly
/// colored there; ``spans(inText:)`` colors a whole text and carries them across lines.
/// Correctness of the text never depends on it.
nonisolated public struct SyntaxHighlighter: Sendable {
  /// One colored span, in UTF-16 offsets of the line or text.
  public struct Span: Hashable, Sendable {
    /// The token class.
    public var token: SyntaxToken
    /// The range, in UTF-16 code units.
    public var range: Range<Int>
  }

  private struct Delimiters: Sendable {
    var lineComments: [[UInt16]]
    var blockComments: [(open: [UInt16], close: [UInt16])]
    var quotes: Set<UInt16>
    var multilineQuotes: Set<UInt16>
    var tripleQuotes: [[UInt16]]
  }

  private let keywords: Set<String>
  private let delimiters: Delimiters
  private let markup: Bool

  /// A highlighter for `language`.
  /// - Parameter language: The core's language hint.
  public init(language: SyntaxLanguage) {
    let rules = Self.rules(for: language)
    keywords = rules.keywords
    delimiters = Delimiters(
      lineComments: rules.comments.map { Array($0.utf16) },
      blockComments: Self.blockComments(for: language).map { (Array($0.utf16), Array($1.utf16)) },
      quotes: Set(rules.quotes.flatMap(\.utf16)),
      multilineQuotes: Set(Self.multilineQuotes(for: language).flatMap(\.utf16)),
      tripleQuotes: Self.tripleQuotes(for: language).map { Array($0.utf16) })
    markup = language == .markdown
  }

  /// The spans of `line`.
  /// - Parameter line: One line, without its newline.
  /// - Returns: Non-overlapping spans, in order.
  public func spans(in line: String) -> [Span] {
    if markup { return markupSpans(in: line, offset: 0) }
    return scan(Array(line.utf16))
  }

  /// The spans of `text`, which may hold many lines. Block comments and multi-line strings
  /// continue across lines; line comments and ordinary strings end with their line.
  /// - Parameter text: The text.
  /// - Returns: Non-overlapping spans, in order, in UTF-16 offsets of `text`.
  public func spans(inText text: String) -> [Span] {
    guard markup else { return scan(Array(text.utf16)) }
    var spans: [Span] = []
    var offset = 0
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
      spans += markupSpans(in: String(line), offset: offset)
      offset += line.utf16.count + 1
    }
    return spans
  }

  private func scan(_ characters: [UInt16]) -> [Span] {
    var spans: [Span] = []
    var index = 0
    while index < characters.count {
      if let (token, end) = delimited(characters, at: index) {
        spans.append(Span(token: token, range: index..<end))
        index = end
        continue
      }
      let unit = characters[index]
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

  /// A comment or string starting at `index`, with the offset where it ends.
  private func delimited(_ characters: [UInt16], at index: Int) -> (SyntaxToken, Int)? {
    if delimiters.lineComments.contains(where: { Self.matches($0, in: characters, at: index) }) {
      return (.comment, characters[index...].firstIndex(of: Self.newline) ?? characters.count)
    }
    for block in delimiters.blockComments where Self.matches(block.open, in: characters, at: index)
    {
      return (.comment, Self.end(of: block.close, in: characters, from: index + block.open.count))
    }
    for triple in delimiters.tripleQuotes where Self.matches(triple, in: characters, at: index) {
      return (.string, Self.end(of: triple, in: characters, from: index + triple.count))
    }
    if delimiters.quotes.contains(characters[index]) {
      return (.string, stringEnd(characters, from: index, quote: characters[index]))
    }
    return nil
  }

  private func stringEnd(_ characters: [UInt16], from start: Int, quote: UInt16) -> Int {
    var index = start + 1
    let backslash = UInt16(UInt8(ascii: "\\"))
    let spansLines = delimiters.multilineQuotes.contains(quote)
    while index < characters.count {
      if characters[index] == backslash {
        index += 2
        continue
      }
      if characters[index] == quote { return index + 1 }
      if characters[index] == Self.newline, !spansLines { return index }
      index += 1
    }
    return min(index, characters.count)
  }

  private func markupSpans(in line: String, offset: Int) -> [Span] {
    let range = offset..<offset + line.utf16.count
    if line.hasPrefix("#") { return [Span(token: .type, range: range)] }
    if line.hasPrefix("```") || line.hasPrefix("    ") {
      return [Span(token: .string, range: range)]
    }
    if line.hasPrefix(">") { return [Span(token: .comment, range: range)] }
    return []
  }

  private static let newline = UInt16(UInt8(ascii: "\n"))

  private static func matches(_ marker: [UInt16], in characters: [UInt16], at index: Int) -> Bool {
    guard !marker.isEmpty, index + marker.count <= characters.count else { return false }
    return characters[index..<index + marker.count].elementsEqual(marker)
  }

  /// The offset just past `close` at or after `start`, or the end when it never closes.
  private static func end(of close: [UInt16], in characters: [UInt16], from start: Int) -> Int {
    var index = start
    while index + close.count <= characters.count {
      if matches(close, in: characters, at: index) { return index + close.count }
      index += 1
    }
    return characters.count
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
}

// Per-language tables.
nonisolated extension SyntaxHighlighter {
  fileprivate struct Rules {
    var keywords: Set<String>
    var comments: [String]
    var quotes: Set<Character>
  }

  fileprivate static let cFamily: Set<String> = [
    "break", "case", "const", "continue", "default", "do", "else", "enum", "for", "if",
    "return", "static", "struct", "switch", "typedef", "void", "while", "true", "false", "null",
    "class", "public", "private", "protected", "new", "this", "import", "package", "try",
    "catch", "throw", "finally", "interface", "extends", "implements", "final", "abstract",
    "int", "char", "long", "double", "float", "bool", "unsigned", "include", "define",
  ]

  // A table of per-language keyword lists reads best as one switch.
  // swiftlint:disable:next function_body_length cyclomatic_complexity
  fileprivate static func rules(for language: SyntaxLanguage) -> Rules {
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

  fileprivate static func blockComments(for language: SyntaxLanguage) -> [(String, String)] {
    switch language {
    case .html, .xml, .markdown: [("<!--", "-->")]
    case .python, .ruby, .bash, .dockerfile, .makefile, .toml, .yaml, .json: []
    default: [("/*", "*/")]
    }
  }

  /// Quotes whose strings may continue onto the next line.
  fileprivate static func multilineQuotes(for language: SyntaxLanguage) -> [String] {
    switch language {
    case .javascript, .typescript, .go: ["`"]
    default: []
    }
  }

  /// Triple-quoted (multi-line) string delimiters.
  fileprivate static func tripleQuotes(for language: SyntaxLanguage) -> [String] {
    switch language {
    case .python: ["\"\"\"", "'''"]
    case .swift, .kotlin, .scala, .java, .toml: ["\"\"\""]
    default: []
    }
  }
}

nonisolated extension SyntaxLanguage {
  /// The language a fenced code block's info string names (`ts`, `py`, `sh`, `rust`...), or
  /// `nil` when it names none this highlighter knows.
  /// - Parameter fenceName: The info string's first word, any case.
  public init?(fenceName: String) {
    let name = fenceName.lowercased()
    if let language = Self(rawValue: name) ?? Self.fenceAliases[name] {
      self = language
    } else {
      return nil
    }
  }

  private static let fenceAliases: [String: Self] = [
    "sh": .bash, "shell": .bash, "zsh": .bash, "console": .bash, "shellsession": .bash,
    "h": .c, "c++": .cpp, "cc": .cpp, "hpp": .cpp, "cxx": .cpp, "cs": .csharp, "c#": .csharp,
    "scss": .css, "less": .css, "docker": .dockerfile, "golang": .go, "htm": .html,
    "vue": .html, "svelte": .html, "js": .javascript, "jsx": .javascript, "mjs": .javascript,
    "cjs": .javascript, "jsonc": .json, "json5": .json, "jsonl": .json, "kt": .kotlin,
    "kts": .kotlin, "make": .makefile, "just": .makefile, "justfile": .makefile,
    "md": .markdown, "mdx": .markdown, "objc": .objectiveC, "objective-c": .objectiveC,
    "py": .python, "python3": .python, "rb": .ruby, "rs": .rust, "ts": .typescript,
    "tsx": .typescript, "mts": .typescript, "svg": .xml, "plist": .xml, "yml": .yaml,
    "psql": .sql, "postgresql": .sql, "mysql": .sql, "sqlite": .sql,
  ]
}
