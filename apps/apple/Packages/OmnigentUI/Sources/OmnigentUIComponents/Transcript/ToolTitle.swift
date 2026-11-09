import Foundation

/// A tool call's title as a person reads it, as the web's `toolTitle` does: "Read notes.md",
/// "$ ls -la", "Turn diff". The raw name stays on the activity, where layout rules match it.
nonisolated enum ToolTitle {
  private static let titleCharacters = 200

  /// The title of a call to `tool`.
  /// - Parameters:
  ///   - tool: The tool's raw name.
  ///   - arguments: The call's arguments (JSON), when known.
  /// - Returns: A formatted title, else the name as a sentence-case label.
  static func text(tool: String, arguments: String?) -> String {
    let (server, name) = split(tool)
    let formatted = server == nil ? format(name, arguments: object(arguments)) : nil
    let title = formatted ?? humanized(name, server: server)
    let firstLine = title.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? title
    return String(firstLine.prefix(titleCharacters))
  }

  /// Splits `mcp__linear__get_issue` and `linear__get_issue` into server and tool. Omnigent's own
  /// MCP server carries the built-in tools, so its name is dropped.
  static func split(_ name: String) -> (server: String?, tool: String) {
    let bare = name.hasPrefix("mcp__") ? String(name.dropFirst("mcp__".count)) : name
    guard let separator = bare.range(of: "__") else { return (nil, name) }
    let server = String(bare[..<separator.lowerBound])
    let tool = String(bare[separator.upperBound...])
    let isAlphanumeric = { (character: Character?) in
      character?.isLetter == true || character?.isNumber == true
    }
    guard isAlphanumeric(server.first), isAlphanumeric(server.last), isAlphanumeric(tool.first)
    else { return (nil, name) }
    return server == "omnigent" ? split(tool) : (server, tool)
  }

  /// `manage_todo_list` as "Manage todo list": without `sys_`, a repeat of the server's name or a
  /// trailing verb out of place (`sys_timer_set` reads "Set timer").
  static func humanized(_ tool: String, server: String? = nil) -> String {
    var words = identifierWords(tool)
    if words.count > 1, words.first == "sys" { words.removeFirst() }
    let serverWords = server.map(identifierWords) ?? []
    var shared = 0
    while shared < serverWords.count, shared < words.count - 1, words[shared] == serverWords[shared]
    {
      shared += 1
    }
    words.removeFirst(shared)
    if words.count > 1, let last = words.last, trailingVerbs.contains(last),
      !trailingVerbs.contains(words[0]), !leadingVerbs.contains(words[0])
    {
      words = [last] + words.dropLast()
    }
    let label = sentenceCase(words)
    return label.isEmpty ? tool : label
  }

  /// Peels Codex's login-shell wrapper off a command: `/bin/bash -lc 'ls'` is `ls`. Anything after
  /// the wrapper that is not exactly one shell word stays as it was.
  static func unwrappedShellCommand(_ command: String) -> String {
    let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
    let wrapper = #/^(?:\S+\/)?(?:bash|zsh|sh|dash|fish)\s+-l?c\s+(?<word>[\s\S]+)$/#
    guard let match = trimmed.wholeMatch(of: wrapper) else { return trimmed }
    let word = String(match.word).trimmingCharacters(in: .whitespacesAndNewlines)
    guard let inner = shellWord(word)?.trimmingCharacters(in: .whitespacesAndNewlines),
      !inner.isEmpty
    else { return trimmed }
    return inner
  }

  private static func format(_ name: String, arguments: [String: Any]) -> String? {
    if let label = labels[name] { return label }
    let text = { (key: String) in (arguments[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
    if let (verb, keys) = argumentTitles[name] {
      return keys.lazy.compactMap(text).first.map { "\(verb) \($0)" }
    }
    let quoted = text("query").map { "\"\($0)\"" }
    return switch name {
    case "sys_os_shell", "bash": text("command").map { "$ \($0)" }
    case "shell": text("command").map { "$ \(unwrappedShellCommand($0))" }
    case "Bash": text("description") ?? text("command").map { "$ \($0)" }
    case "WebSearch", "web_search": quoted.map { "Web search: \($0)" }
    case "web_fetch": (quoted ?? text("url")).map { "Web fetch: \($0)" }
    case "Task": text("description").map { "Sub-agent: \($0)" } ?? "Run sub-agent"
    case "apply_patch": patchTitle(arguments["changes"])
    default: nil
    }
  }

  /// Tools titled by a verb and the first argument present among `keys`.
  private static let argumentTitles: [String: (verb: String, keys: [String])] = [
    "sys_os_read": ("Read", ["path"]), "sys_os_write": ("Write", ["path"]),
    "sys_os_edit": ("Edit", ["path"]), "Read": ("Read", ["file_path"]),
    "Write": ("Write", ["file_path"]), "Edit": ("Edit", ["file_path"]),
    "MultiEdit": ("Edit", ["file_path"]), "NotebookEdit": ("Edit", ["notebook_path"]),
    "read": ("Read", ["filePath", "path"]), "write": ("Write", ["filePath", "path"]),
    "edit": ("Edit", ["filePath", "path"]), "Grep": ("Search:", ["pattern"]),
    "Glob": ("Find files:", ["pattern"]), "WebFetch": ("Web fetch:", ["url"]),
    "sys_session_send": ("Send to session:", ["session_id"]),
  ]

  /// "Edit a.swift", or "Edit 3 files" for a patch touching several.
  private static func patchTitle(_ changes: Any?) -> String? {
    guard let changes = changes as? [Any], !changes.isEmpty else { return nil }
    if changes.count == 1, let path = (changes[0] as? [String: Any])?["path"] as? String,
      !path.isEmpty
    {
      return "Edit \(path)"
    }
    return "Edit \(changes.count) files"
  }

  private static let labels = [
    "TodoWrite": "Update todos", "sys_read_inbox": "Read inbox", "list_tasks": "List tasks",
    "sys_session_list": "List child sessions", "sys_agent_list": "List agents",
    "sys_terminal_list": "List terminals",
  ]

  private static func object(_ arguments: String?) -> [String: Any] {
    guard let data = arguments?.data(using: .utf8) else { return [:] }
    do {
      return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    } catch {
      // A truncated preview or plain text names nothing: the title falls back to the tool's name.
      return [:]
    }
  }

  /// One shell word decoded (`'it'\''s'`, `"a \"b\""`, `ls`), or `nil` when it is more than one.
  private static func shellWord(_ text: String) -> String? {
    var decoded = ""
    var rest = Substring(text)
    while let first = rest.first {
      if first == "'" {
        let body = rest.dropFirst()
        guard let end = body.firstIndex(of: "'") else { return nil }
        decoded += body[..<end]
        rest = body[body.index(after: end)...]
      } else if first == "\"" {
        guard let (inner, after) = doubleQuoted(rest.dropFirst()) else { return nil }
        decoded += inner
        rest = after
      } else if first == "\\" {
        guard let escaped = rest.dropFirst().first else { return nil }
        decoded.append(escaped)
        rest = rest.dropFirst(2)
      } else if first.isWhitespace {
        return nil
      } else {
        decoded.append(first)
        rest = rest.dropFirst()
      }
    }
    return decoded
  }

  private static func doubleQuoted(_ text: Substring) -> (String, Substring)? {
    var decoded = ""
    var rest = text
    while let first = rest.first {
      rest = rest.dropFirst()
      if first == "\"" { return (decoded, rest) }
      if first == "\\", let next = rest.first {
        if !"\\\"$`".contains(next) { decoded.append(first) }
        decoded.append(next)
        rest = rest.dropFirst()
      } else {
        decoded.append(first)
      }
    }
    return nil
  }

  private static func identifierWords(_ identifier: String) -> [String] {
    identifier
      .replacing(#/(?<lower>[a-z0-9])(?<upper>[A-Z])/#) { "\($0.lower) \($0.upper)" }
      .replacing(#/(?<run>[A-Z]+)(?<next>[A-Z][a-z])/#) { "\($0.run) \($0.next)" }
      .split { $0.isWhitespace || $0 == "_" || $0 == "." || $0 == "-" }
      .map { $0.lowercased() }
  }

  private static func sentenceCase(_ words: [String]) -> String {
    words.enumerated().map { index, word in
      if let acronym = acronyms[word] { return acronym }
      return index == 0 ? word.prefix(1).uppercased() + word.dropFirst() : word
    }
    .joined(separator: " ")
  }

  private static let acronyms = [
    "ai": "AI", "api": "API", "cli": "CLI", "csv": "CSV", "db": "DB", "html": "HTML",
    "http": "HTTP", "id": "ID", "ids": "IDs", "json": "JSON", "llm": "LLM", "mcp": "MCP",
    "os": "OS", "pdf": "PDF", "pr": "PR", "prs": "PRs", "sdk": "SDK", "sql": "SQL", "ssh": "SSH",
    "ui": "UI", "uri": "URI", "url": "URL", "urls": "URLs",
  ]

  private static let trailingVerbs: Set = [
    "add", "cancel", "close", "create", "delete", "get", "launch", "read", "remove", "rename",
    "send", "set", "start", "stop", "update", "write",
  ]

  private static let leadingVerbs: Set = [
    "apply", "check", "edit", "execute", "fetch", "find", "list", "load", "manage", "merge", "open",
    "poll", "post", "query", "reply", "resolve", "run", "search", "submit",
  ]
}

extension Activity {
  /// The title to show: a tool call's reads as a person would say it, anything else as reported.
  var displayTitle: String {
    kind == .toolCall ? ToolTitle.text(tool: title, arguments: detail("arguments")) : title
  }
}
