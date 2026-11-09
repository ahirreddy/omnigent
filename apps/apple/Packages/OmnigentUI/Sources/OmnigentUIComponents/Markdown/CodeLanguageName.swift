/// What a code block's header calls its language: "Python" for a ```` ```py title=x ```` fence.
nonisolated enum CodeLanguageName {
  /// The language's name as people write it, a name this table doesn't know as the fence wrote it,
  /// and "Code" when the fence names none.
  /// - Parameter language: The fence's info string.
  /// - Returns: The header's label.
  static func label(for language: String?) -> String {
    guard let name = CodeHighlighting.fenceName(language) else { return "Code" }
    if let known = known[name] { return known }
    return language?.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? name
  }

  private static let known = [
    "bash": "Bash", "c": "C", "c#": "C#", "c++": "C++", "console": "Console", "cpp": "C++",
    "cs": "C#", "csharp": "C#", "css": "CSS", "diff": "Diff", "dockerfile": "Dockerfile",
    "go": "Go", "golang": "Go", "html": "HTML", "java": "Java", "javascript": "JavaScript",
    "js": "JavaScript", "json": "JSON", "jsx": "JSX", "kotlin": "Kotlin", "makefile": "Makefile",
    "markdown": "Markdown", "md": "Markdown", "patch": "Diff", "plaintext": "Text",
    "py": "Python", "python": "Python", "rb": "Ruby", "rs": "Rust", "ruby": "Ruby", "rust": "Rust",
    "scss": "SCSS", "sh": "Shell", "shell": "Shell", "sql": "SQL", "swift": "Swift", "text": "Text",
    "toml": "TOML", "ts": "TypeScript", "tsx": "TSX", "typescript": "TypeScript", "xml": "XML",
    "yaml": "YAML", "yml": "YAML", "zsh": "Zsh",
  ]
}
