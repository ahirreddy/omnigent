public import Foundation

/// A syntax-highlighting hint (`workspace::SyntaxLanguage`), detected by the core from the file
/// name.
nonisolated public enum SyntaxLanguage: String, Hashable, Sendable, CaseIterable {
  /// Shell scripts.
  case bash
  /// C.
  case c  // swiftlint:disable:this identifier_name
  /// C++.
  case cpp
  /// C#.
  case csharp
  /// CSS and its dialects.
  case css
  /// Dockerfiles.
  case dockerfile
  /// Go.
  case go  // swiftlint:disable:this identifier_name
  /// HTML.
  case html
  /// Java.
  case java
  /// JavaScript.
  case javascript
  /// JSON.
  case json
  /// Kotlin.
  case kotlin
  /// Makefiles and justfiles.
  case makefile
  /// Markdown.
  case markdown
  /// Objective-C.
  case objectiveC
  /// PHP.
  case php
  /// Python.
  case python
  /// Ruby.
  case ruby
  /// Rust.
  case rust
  /// Scala.
  case scala
  /// SQL.
  case sql
  /// Swift.
  case swift
  /// TOML.
  case toml
  /// TypeScript.
  case typescript
  /// XML, plists and SVG.
  case xml
  /// YAML.
  case yaml

  /// The name shown in the viewer's header.
  public var displayName: String {
    switch self {
    case .bash: "Shell"
    case .c: "C"
    case .cpp: "C++"
    case .csharp: "C#"
    case .css: "CSS"
    case .dockerfile: "Dockerfile"
    case .go: "Go"
    case .html: "HTML"
    case .java: "Java"
    case .javascript: "JavaScript"
    case .json: "JSON"
    case .kotlin: "Kotlin"
    case .makefile: "Makefile"
    case .markdown: "Markdown"
    case .objectiveC: "Objective-C"
    case .php: "PHP"
    case .python: "Python"
    case .ruby: "Ruby"
    case .rust: "Rust"
    case .scala: "Scala"
    case .sql: "SQL"
    case .swift: "Swift"
    case .toml: "TOML"
    case .typescript: "TypeScript"
    case .xml: "XML"
    case .yaml: "YAML"
    }
  }
}

/// Line terminators found in a text file (`workspace::LineEnding`).
nonisolated public enum LineEnding: String, Hashable, Sendable {
  /// `\n`.
  case lf = "LF"  // swiftlint:disable:this identifier_name
  /// `\r\n`.
  case crlf = "CRLF"
  /// Both.
  case mixed = "Mixed"
}

/// Raster image formats the core recognizes by magic number (`workspace::ImageFormat`).
nonisolated public enum ImageFormat: String, Hashable, Sendable {
  /// PNG.
  case png = "PNG"
  /// JPEG.
  case jpeg = "JPEG"
  /// GIF.
  case gif = "GIF"
  /// WebP.
  case webp = "WebP"
  /// BMP.
  case bmp = "BMP"
  /// TIFF.
  case tiff = "TIFF"
  /// HEIC or HEIF.
  case heic = "HEIC"
  /// ICO.
  case ico = "ICO"
}

/// Why a file is not previewed (`workspace::BinaryReason`).
nonisolated public enum BinaryReason: Hashable, Sendable {
  /// The bytes are not UTF-8.
  case notText
  /// The text contains NUL bytes.
  case nulBytes
  /// An image the server truncated.
  case truncatedImage

  /// What the viewer says.
  public var explanation: String {
    switch self {
    case .notText: "This file is not text."
    case .nulBytes: "This file looks binary."
    case .truncatedImage: "This image is larger than the server's preview limit."
    }
  }
}

/// Text ready for the viewer (`workspace::TextPreview`).
nonisolated public struct TextPreview: Hashable, Sendable {
  /// The text shown.
  public var text: String
  /// Lines in `text`.
  public var lineCount: UInt64
  /// Line terminators.
  public var lineEnding: LineEnding
  /// The highlighting hint.
  public var language: SyntaxLanguage?
  /// Skip highlighting (a line is very long, as in minified files).
  public var skipHighlighting: Bool
  /// The core cut the text at its preview limits.
  public var clipped: Bool
  /// The server returned only part of the file.
  public var serverTruncated: Bool

  /// A preview.
  /// - Parameters:
  ///   - text: The text shown.
  ///   - lineCount: Lines in `text`.
  ///   - lineEnding: Line terminators.
  ///   - language: The highlighting hint.
  ///   - skipHighlighting: Skip highlighting.
  ///   - clipped: The core cut the text.
  ///   - serverTruncated: The server returned part of the file.
  public init(
    text: String, lineCount: UInt64, lineEnding: LineEnding = .lf,
    language: SyntaxLanguage? = nil, skipHighlighting: Bool = false, clipped: Bool = false,
    serverTruncated: Bool = false
  ) {
    self.text = text
    self.lineCount = lineCount
    self.lineEnding = lineEnding
    self.language = language
    self.skipHighlighting = skipHighlighting
    self.clipped = clipped
    self.serverTruncated = serverTruncated
  }
}

/// What the viewer shows for a file (`workspace::FilePreview`).
nonisolated public enum FilePreview: Hashable, Sendable {
  /// Text.
  case text(TextPreview)
  /// A complete image.
  case image(format: ImageFormat, data: Data)
  /// Neither.
  case binary(reason: BinaryReason)
}

/// A file read for the viewer (`workspace::FileContent` plus its preview).
nonisolated public struct WorkspaceFile: Hashable, Sendable, Identifiable {
  /// Environment-relative path.
  public var path: String
  /// Bytes the server returned.
  public var byteCount: UInt64
  /// What to show.
  public var preview: FilePreview

  /// The path.
  public var id: String { path }

  /// A file.
  /// - Parameters:
  ///   - path: Environment-relative path.
  ///   - byteCount: Bytes the server returned.
  ///   - preview: What to show.
  public init(path: String, byteCount: UInt64, preview: FilePreview) {
    self.path = path
    self.byteCount = byteCount
    self.preview = preview
  }
}

/// A half-open offset range (`workspace::TextRange`).
nonisolated public struct TextRange: Hashable, Sendable {
  /// First offset.
  public var start: Int
  /// One past the last offset.
  public var end: Int

  /// A range.
  /// - Parameters:
  ///   - start: First offset.
  ///   - end: One past the last offset.
  public init(start: Int, end: Int) {
    self.start = start
    self.end = end
  }

  /// The `String` indices of this range read as UTF-16 offsets into `text`, when it fits.
  /// - Parameter text: The text the offsets index.
  /// - Returns: The range, or `nil` when it is outside `text` or splits a character.
  public func utf16Range(in text: String) -> Range<String.Index>? {
    let view = text.utf16
    guard start >= 0, start <= end, end <= view.count else { return nil }
    let lower = view.index(view.startIndex, offsetBy: start)
    let upper = view.index(view.startIndex, offsetBy: end)
    guard let low = lower.samePosition(in: text), let high = upper.samePosition(in: text) else {
      return nil
    }
    return low..<high
  }

  /// The `String` indices of this range read as UTF-8 offsets into `text`, when it fits.
  /// - Parameter text: The text the offsets index.
  /// - Returns: The range, or `nil` when it is outside `text` or splits a character.
  public func utf8Range(in text: String) -> Range<String.Index>? {
    let view = text.utf8
    guard start >= 0, start <= end, end <= view.count else { return nil }
    let lower = view.index(view.startIndex, offsetBy: start)
    let upper = view.index(view.startIndex, offsetBy: end)
    guard let low = lower.samePosition(in: text), let high = upper.samePosition(in: text) else {
      return nil
    }
    return low..<high
  }
}

/// One matching line (`workspace::ContentMatch`).
nonisolated public struct ContentMatch: Hashable, Sendable, Identifiable {
  /// Environment-relative path.
  public var path: String
  /// 1-based line number.
  public var line: UInt64
  /// 1-based column, in UTF-16 code units.
  public var column: UInt64
  /// The line preview.
  public var text: String
  /// The match within `text`, in UTF-16 code units.
  public var match: TextRange

  /// Path, line and column.
  public var id: String { "\(path):\(line):\(column)" }

  /// A match.
  /// - Parameters:
  ///   - path: Environment-relative path.
  ///   - line: 1-based line number.
  ///   - column: 1-based column.
  ///   - text: The line preview.
  ///   - match: The match within `text`, in UTF-16 code units.
  public init(path: String, line: UInt64, column: UInt64, text: String, match: TextRange) {
    self.path = path
    self.line = line
    self.column = column
    self.text = text
    self.match = match
  }
}

/// Matches in one file (`workspace::ContentSearchFile`).
nonisolated public struct ContentSearchFile: Hashable, Sendable, Identifiable {
  /// The file.
  public var path: String
  /// Its matches, by line.
  public var matches: [ContentMatch]

  /// The path.
  public var id: String { path }

  /// A file's matches.
  /// - Parameters:
  ///   - path: The file.
  ///   - matches: Its matches.
  public init(path: String, matches: [ContentMatch]) {
    self.path = path
    self.matches = matches
  }
}

/// A finished content search (`workspace::ContentSearchResult`, grouped by `files()`).
nonisolated public struct ContentSearchResult: Hashable, Sendable {
  /// Matches grouped by file, files by path.
  public var files: [ContentSearchFile]
  /// The search stopped early; results are partial.
  public var truncated: Bool
  /// Why results may be incomplete, in the server's words.
  public var warning: String?

  /// A result.
  /// - Parameters:
  ///   - files: Matches grouped by file.
  ///   - truncated: Whether the search stopped early.
  ///   - warning: The server's warning.
  public init(files: [ContentSearchFile], truncated: Bool = false, warning: String? = nil) {
    self.files = files
    self.truncated = truncated
    self.warning = warning
  }

  /// All matches.
  public var matchCount: Int { files.reduce(into: 0) { $0 += $1.matches.count } }
}

/// The inputs of a content search (`workspace::ContentSearchQuery`).
nonisolated public struct ContentSearchQuery: Hashable, Sendable {
  /// The text or regular expression.
  public var query: String
  /// Letter case must match.
  public var caseSensitive: Bool
  /// `query` is a regular expression.
  public var regex: Bool
  /// Comma-separated include globs, as typed.
  public var include: String
  /// Comma-separated exclude globs, as typed.
  public var exclude: String

  /// A query.
  /// - Parameters:
  ///   - query: The text or regular expression.
  ///   - caseSensitive: Letter case must match.
  ///   - regex: `query` is a regular expression.
  ///   - include: Include globs.
  ///   - exclude: Exclude globs.
  public init(
    query: String = "", caseSensitive: Bool = false, regex: Bool = false, include: String = "",
    exclude: String = ""
  ) {
    self.query = query
    self.caseSensitive = caseSensitive
    self.regex = regex
    self.include = include
    self.exclude = exclude
  }

  /// Whether there is something to search for.
  public var isSubmittable: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

  /// Whether a file filter is set.
  public var hasFilters: Bool {
    !include.trimmingCharacters(in: .whitespaces).isEmpty
      || !exclude.trimmingCharacters(in: .whitespaces).isEmpty
  }
}
