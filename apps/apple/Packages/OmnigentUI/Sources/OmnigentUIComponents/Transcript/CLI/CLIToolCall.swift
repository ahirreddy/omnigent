import Foundation

/// One step of the plan a tool call updates.
nonisolated struct CLIPlanStep: Hashable, Sendable {
  enum Status: Hashable, Sendable {
    case pending
    case inProgress
    case completed
  }

  var text: String
  var status: Status
}

/// What a tool call does, read from its name and arguments the way the Codex CLI names it: a
/// command it ran, a file it read, a search, a plan it updated, or a call to some other tool.
nonisolated enum CLIToolCall: Hashable, Sendable {
  /// A shell command: its script, one line or several.
  case command(String)
  case read(String)
  case list(String)
  case search(query: String, path: String?)
  case plan(note: String?, steps: [CLIPlanStep])
  /// A file edit and the path its arguments name; its change is read apart (``ToolEditDiff``).
  case edit(String?)
  /// Any other tool: `server.tool` and its arguments on one line.
  case other(name: String, arguments: String)

  /// The longest one-line arguments a call shows.
  static let argumentCharacters = 160
  private static let pathKeys = [
    "file_path", "path", "filePath", "file", "filename", "notebook_path",
  ]
  private static let queryKeys = ["pattern", "query", "regex"]
  private static let scopeKeys = ["path", "glob", "directory"]

  init(tool: String, arguments: String) {
    let arguments = CLIToolArguments(arguments)
    // Arguments with no fields (a bare command or path) are the subject themselves.
    let firstLine = arguments.bare.split(separator: "\n").first.map(String.init)
    let (server, base) = ToolTitle.split(tool)
    let name = base.isEmpty ? "tool" : base
    let steps = Self.steps(arguments.items("plan") + arguments.items("todos"))
    if !steps.isEmpty {
      self = .plan(note: arguments.value(["explanation"]), steps: steps)
      return
    }
    switch server == nil ? ToolRunSummary.category(of: name) : nil {
    case .shell:
      let script = arguments.value(["command", "cmd", "script"]).map(Self.script)
      self = .command(script ?? (arguments.bare.isEmpty ? name : arguments.bare))
    case .read: self = .read(arguments.value(Self.pathKeys) ?? firstLine ?? name)
    case .list: self = .list(arguments.value(["pattern"] + Self.scopeKeys) ?? firstLine ?? ".")
    case .search:
      self = .search(
        query: arguments.value(Self.queryKeys) ?? firstLine ?? name,
        path: arguments.value(Self.scopeKeys))
    case .edit: self = .edit(arguments.value(Self.pathKeys))
    case nil:
      let fields = arguments.fields.map { "\($0.key): \($0.value)" }.joined(separator: ", ")
      self = .other(
        name: server.map { "\($0).\(name)" } ?? name,
        arguments: Self.oneLine(fields.isEmpty ? arguments.bare : fields))
    }
  }

  /// The line an "Explored" cell shows for a call that only looks around: its verb and what
  /// it looked at.
  var explored: (title: String, target: String)? {
    switch self {
    case .read(let path): ("Read", DecisionPath(path).name)
    case .list(let path): ("List", path)
    case .search(let query, _): ("Search", query)
    case .command, .plan, .edit, .other: nil
    }
  }

  /// A call whose output may be the diff it made: an edit, or a tool this app does not know.
  var reportsChanges: Bool {
    switch self {
    case .edit, .other: true
    case .command, .read, .list, .search, .plan: false
    }
  }

  /// The script a shell call runs, without the login shell some harnesses wrap around it.
  static func script(_ command: String) -> String {
    let words = command.split(separator: "\n", maxSplits: 2, omittingEmptySubsequences: false)
    // An argument list reads one word a line: the shell, `-lc`, then the script.
    if words.count == 3, ["-lc", "-c"].contains(words[1]) { return String(words[2]) }
    return ToolTitle.unwrappedShellCommand(command)
  }

  /// The steps of a plan update or a todo list, from its listed objects.
  private static func steps(_ items: [[String: String]]) -> [CLIPlanStep] {
    items.compactMap { item in
      guard let text = item["step"] ?? item["content"] ?? item["title"] else { return nil }
      let status: CLIPlanStep.Status =
        switch item["status"]?.lowercased() {
        case "completed", "done": .completed
        case "in_progress", "active": .inProgress
        default: .pending
        }
      return CLIPlanStep(text: text, status: status)
    }
  }

  /// Arguments on one line, cut at ``argumentCharacters``.
  static func oneLine(_ arguments: String) -> String {
    let line = arguments.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    return line.count > argumentCharacters
      ? String(line.prefix(argumentCharacters)) + "\u{2026}" : line
  }
}

/// A tool call as the CLI draws it: what it does, the change it made and its output.
nonisolated struct CLIToolStep: Hashable, Sendable, Identifiable {
  let entry: ToolEntry
  let call: CLIToolCall
  /// The edit the call's arguments describe, else a diff in its output.
  let diff: DiffSummary?

  var id: String { entry.id }

  init(_ entry: ToolEntry) {
    self.entry = entry
    let activity = entry.call?.activity
    let arguments = activity.map { $0.detail("arguments") ?? $0.summary } ?? ""
    call = CLIToolCall(tool: entry.primary?.activity?.title ?? "", arguments: arguments)
    let output = entry.result?.activity?.detail("output")
    let edit = activity.flatMap {
      ToolEditDiff.diff(tool: $0.title, arguments: arguments, output: output)
    }
    diff = edit ?? (call.reportsChanges ? output.flatMap(DiffSummary.find(in:)) : nil)
  }

  /// The result's output section, else its text; `nil` when there is none.
  var output: String? {
    let text = entry.result?.activity?.detail("output") ?? entry.result?.text ?? ""
    let trimmed = text.trimmingCharacters(in: .newlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  /// What Copy input copies: the command itself, else the arguments as recorded.
  var input: String {
    let recorded = entry.call?.activity?.summary ?? ""
    if case .command(let script) = call, !recorded.isEmpty { return script }
    return recorded
  }
}

/// A run of tool calls as the cells a terminal draws: calls that only look around share one
/// "Explored" cell, every other call has its own.
nonisolated enum CLIToolCell: Hashable, Sendable, Identifiable {
  case explored([CLIToolStep])
  case call(CLIToolStep)

  var id: String {
    switch self {
    case .explored(let steps): "explored:\(steps.first?.id ?? "")"
    case .call(let step): step.id
    }
  }

  static func cells(for entries: [ToolEntry]) -> [Self] {
    var cells: [Self] = []
    for step in entries.map(CLIToolStep.init) {
      if step.call.explored != nil, case .explored(let run) = cells.last {
        cells[cells.count - 1] = .explored(run + [step])
      } else if step.call.explored != nil {
        cells.append(.explored([step]))
      } else {
        cells.append(.call(step))
      }
    }
    return cells
  }
}

/// One line under "Explored": a search, a listing, or the files read one after another.
nonisolated struct CLIExploredLine: Hashable, Sendable, Identifiable {
  var steps: [CLIToolStep]

  var id: String { steps.first?.id ?? "" }

  /// Reads that worked, which the next read joins.
  private var isReads: Bool {
    steps.allSatisfy { step in
      if case .read = step.call { return !step.entry.isFailure }
      return false
    }
  }

  static func lines(for steps: [CLIToolStep]) -> [Self] {
    var lines: [Self] = []
    for step in steps {
      let line = Self(steps: [step])
      if line.isReads, lines.last?.isReads == true {
        lines[lines.count - 1].steps.append(step)
      } else {
        lines.append(line)
      }
    }
    return lines
  }

  /// "Read", "List" or "Search".
  var title: String { steps.first?.call.explored?.title ?? "" }

  /// The files' names, each once, or the listing's path or the search's query.
  var targets: [String] {
    var seen: Set<String> = []
    return steps.compactMap(\.call.explored?.target).filter { seen.insert($0).inserted }
  }

  /// Where a search looked.
  var scope: String? {
    if case .search(_, let path) = steps.first?.call { return path }
    return nil
  }
}
