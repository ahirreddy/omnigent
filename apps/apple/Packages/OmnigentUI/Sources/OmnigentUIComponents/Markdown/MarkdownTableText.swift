import Foundation

/// A Markdown table as text to copy or save: Markdown, CSV (RFC 4180 quoting) or TSV.
enum MarkdownTableText {
  /// The table as a GitHub-flavored Markdown table.
  static func markdown(_ table: MarkdownTable) -> String {
    let columns = columnCount(table)
    let escape = { (cell: String) in
      cell.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")
    }
    let row = { (cells: [String]) in
      "| " + padded(cells, to: columns).map(escape).joined(separator: " | ") + " |"
    }
    let rule = (0..<columns).map { column in
      switch column < table.alignments.count ? table.alignments[column] : .leading {
      case .leading: "---"
      case .center: ":---:"
      case .trailing: "---:"
      }
    }
    return
      ([row(plain(table.header)), "| " + rule.joined(separator: " | ") + " |"]
      + table.rows.map { row(plain($0)) }).joined(separator: "\n") + "\n"
  }

  /// The table as comma-separated values; cells with a comma, quote or line break are quoted.
  static func csv(_ table: MarkdownTable) -> String {
    delimited(table, separator: ",") { cell in
      guard cell.contains(where: { $0 == "," || $0 == "\"" || $0.isNewline }) else { return cell }
      return "\"" + cell.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
  }

  /// The table as tab-separated values; tabs and line breaks in cells become spaces.
  static func tsv(_ table: MarkdownTable) -> String {
    delimited(table, separator: "\t") { cell in
      String(cell.map { $0 == "\t" || $0.isNewline ? " " : $0 })
    }
  }

  private static func delimited(
    _ table: MarkdownTable, separator: String, escape: (String) -> String
  ) -> String {
    let columns = columnCount(table)
    return ([table.header] + table.rows)
      .map { padded(plain($0), to: columns).map(escape).joined(separator: separator) }
      .joined(separator: "\n") + "\n"
  }

  private static func plain(_ cells: [AttributedString]) -> [String] {
    cells.map { String($0.characters) }
  }

  private static func columnCount(_ table: MarkdownTable) -> Int {
    ([table.header.count] + table.rows.map(\.count)).max() ?? 0
  }

  private static func padded(_ cells: [String], to count: Int) -> [String] {
    cells + Array(repeating: "", count: max(count - cells.count, 0))
  }
}

/// The file extension for a code block's language, for downloads.
enum CodeFileExtension {
  /// `language`'s usual extension; `txt` when unknown.
  static func `for`(_ language: String?) -> String {
    let name = (language ?? "").lowercased().trimmingCharacters(in: .whitespaces)
    if let fence = CodeHighlighting.fenceName(language), let known = known[fence] { return known }
    let isPlainName = !name.isEmpty && name.count <= 10 && name.allSatisfy(\.isLetter)
    return isPlainName ? name : "txt"
  }

  private static let known: [String: String] = [
    "python": "py", "py": "py", "javascript": "js", "js": "js", "typescript": "ts", "ts": "ts",
    "tsx": "tsx", "jsx": "jsx", "rust": "rs", "rs": "rs", "swift": "swift", "go": "go",
    "golang": "go", "ruby": "rb", "rb": "rb", "kotlin": "kt", "java": "java", "c": "c",
    "cpp": "cpp", "c++": "cpp", "csharp": "cs", "c#": "cs", "cs": "cs", "shell": "sh",
    "bash": "sh", "sh": "sh", "zsh": "sh", "console": "sh", "json": "json", "yaml": "yaml",
    "yml": "yaml", "toml": "toml", "html": "html", "css": "css", "scss": "scss", "sql": "sql",
    "markdown": "md", "md": "md", "diff": "diff", "patch": "diff", "xml": "xml",
    "dockerfile": "dockerfile", "makefile": "mk", "text": "txt", "plaintext": "txt",
  ]
}
