import Foundation

/// A Markdown file cut at its headings, for the preview's table of contents (the web's
/// `MarkdownTableOfContents`): each section renders on its own, so a heading can be scrolled to.
nonisolated struct MarkdownOutline: Equatable {
  /// One heading and the text it starts.
  struct Section: Equatable, Identifiable {
    /// Its place in the file.
    let id: Int
    /// The heading as it reads, without its marks; `nil` for the text before the first one.
    let title: String?
    /// 1 for `#`, up to 6.
    let level: Int
    /// The heading line and what follows it, up to the next heading.
    let text: String
  }

  let sections: [Section]

  /// The headings, for the contents list.
  var headings: [Section] { sections.filter { $0.title != nil } }

  /// `markdown` cut before each ATX heading outside code fences. Link reference definitions
  /// go with every section, so links that use them still resolve.
  init(_ markdown: String) {
    let lines = markdown.components(separatedBy: "\n")
    var fence: Substring?
    var starts: [(line: Int, heading: Heading)] = []
    var references: [String] = []
    for (index, line) in lines.enumerated() {
      let trimmed = line.drop { $0 == " " }
      if let open = fence {
        if trimmed.hasPrefix(open) { fence = nil }
        continue
      }
      if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
        fence = trimmed.prefix(3)
        continue
      }
      guard line.prefix(while: { $0 == " " }).count < 4 else { continue }
      if let heading = Self.heading(trimmed) {
        starts.append((index, heading))
      } else if Self.isReference(trimmed) {
        references.append(line)
      }
    }
    let suffix = references.isEmpty ? "" : "\n\n" + references.joined(separator: "\n")
    var sections: [Section] = []
    let bounds = starts.map(\.line) + [lines.count]
    if let first = starts.first?.line, first > 0 {
      sections.append(
        Section(
          id: 0, title: nil, level: 0, text: lines[0..<first].joined(separator: "\n") + suffix))
    } else if starts.isEmpty {
      sections.append(Section(id: 0, title: nil, level: 0, text: markdown))
    }
    for (offset, start) in starts.enumerated() {
      let end = bounds[offset + 1]
      sections.append(
        Section(
          id: sections.count, title: start.heading.title, level: start.heading.level,
          text: lines[start.line..<end].joined(separator: "\n") + suffix))
    }
    self.sections = sections
  }

  /// A heading's text and level.
  struct Heading: Equatable {
    let title: String
    let level: Int
  }

  /// A heading line's text and level: `## Title ##` reads "Title" at 2.
  static func heading(_ line: Substring) -> Heading? {
    let marks = line.prefix { $0 == "#" }.count
    guard (1...6).contains(marks) else { return nil }
    let rest = line.dropFirst(marks)
    guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
    var title = rest.trimmingCharacters(in: .whitespaces)
    // A closing run of `#` after a space is not part of the title.
    if let closing = title.range(of: #"\s#+$"#, options: .regularExpression) {
      title.removeSubrange(closing)
    } else if title.allSatisfy({ $0 == "#" }) {
      title = ""
    }
    let plain = plainText(title)
    return plain.isEmpty ? nil : Heading(title: plain, level: marks)
  }

  /// Inline Markdown as it reads: links by their text, without emphasis or code marks.
  static func plainText(_ text: String) -> String {
    var plain = text.replacingOccurrences(
      of: #"!?\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
    plain = plain.replacingOccurrences(
      of: #"\[([^\]]*)\]\[[^\]]*\]"#, with: "$1", options: .regularExpression)
    for mark in ["**", "__", "`", "*", "~~"] {
      plain = plain.replacingOccurrences(of: mark, with: "")
    }
    return plain.trimmingCharacters(in: .whitespaces)
  }

  private static func isReference(_ line: Substring) -> Bool {
    line.range(of: #"^\[[^\]]+\]:\s*\S"#, options: .regularExpression) != nil
  }
}
