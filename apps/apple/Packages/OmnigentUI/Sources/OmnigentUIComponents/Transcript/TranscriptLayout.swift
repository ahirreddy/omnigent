import Foundation

/// One tool call and its result, paired by `callId`.
nonisolated struct ToolEntry: Hashable, Sendable, Identifiable {
  var call: Row?
  var result: Row?

  var id: String { call?.id ?? result?.id ?? "" }

  var primary: Row? { call ?? result }

  var isRunning: Bool {
    if call?.isStreaming == true || result?.isStreaming == true { return true }
    let status = (result?.activity?.status ?? call?.activity?.status)?.lowercased()
    if result == nil, call?.activity?.kind == .toolCall {
      return status == nil || status == "in_progress" || status == "running"
    }
    return status == "in_progress" || status == "running"
  }

  var isFailure: Bool {
    call?.activity?.isFailure == true || result?.activity?.isFailure == true
  }
}

/// What the transcript renders, in order. Ids are the underlying row ids, so they are stable
/// across updates and `LazyVStack` keeps cell identity.
nonisolated enum TranscriptItem: Hashable, Sendable, Identifiable {
  case message(Row)
  case tools(id: String, entries: [ToolEntry])
  case activity(Row)

  var id: String {
    switch self {
    case .message(let row), .activity(let row): row.id
    case .tools(let id, _): "tools:\(id)"
    }
  }

  var rowIDs: [String] { rows.map(\.id) }

  /// The rows the item shows, in order.
  var rows: [Row] {
    switch self {
    case .message(let row), .activity(let row): [row]
    case .tools(_, let entries):
      entries.flatMap { [$0.call, $0.result].compactMap(\.self) }
    }
  }
}

/// Folds rows into transcript items in one pass: consecutive tool calls, tool results and
/// native tools become one group, with each result attached to its call.
nonisolated enum TranscriptLayout {
  static let toolKinds: Set<ActivityKind> = [.toolCall, .toolResult, .nativeTool]

  static func items(for rows: [Row]) -> [TranscriptItem] {
    var items: [TranscriptItem] = []
    items.reserveCapacity(rows.count)
    var group: [ToolEntry] = []
    var callIndex: [String: Int] = [:]

    func flush() {
      // A journal write the chat marks with a task or plan line gets no row of its own.
      let shown = group.filter { !JournalWrite.repeatsMarker($0) }
      if let first = shown.first { items.append(.tools(id: first.id, entries: shown)) }
      group.removeAll(keepingCapacity: true)
      callIndex.removeAll(keepingCapacity: true)
    }

    for row in rows where !row.isActivityOnly {
      guard row.role == .tool, let activity = row.activity else {
        flush()
        items.append(row.role == .tool ? .activity(row) : .message(row))
        continue
      }
      guard toolKinds.contains(activity.kind) else {
        flush()
        items.append(.activity(row))
        continue
      }
      if activity.kind == .toolResult, let callID = row.callId, let index = callIndex[callID],
        group[index].result == nil
      {
        group[index].result = row
        continue
      }
      if activity.kind == .toolResult {
        group.append(ToolEntry(call: nil, result: row))
      } else {
        if let callID = row.callId { callIndex[callID] = group.count }
        group.append(ToolEntry(call: row, result: nil))
      }
    }
    flush()
    return items
  }
}

/// The journal writes whose accepted calls the chat marks with a task marker or a plan line
/// (the web's `repeatsTaskMarker`): such a call's row would repeat the marker, so it shows none.
/// A rejected write gets no marker, so its row stays and shows the error.
nonisolated enum JournalWrite {
  static let marked: Set<String> = ["sys_journal_write_status", "sys_journal_write_plan"]

  /// Whether `entry` is a status or plan write the journal accepted, or one still running,
  /// whose marker lands once it is accepted.
  static func repeatsMarker(_ entry: ToolEntry) -> Bool {
    guard let call = entry.call, call.activity?.kind == .toolCall,
      let name = call.activity?.title, let tool = ownTool(name), marked.contains(tool)
    else { return false }
    guard let result = entry.result else { return entry.isRunning }
    if entry.isFailure { return false }
    return !reportsError(result.activity?.detail("output") ?? result.text)
  }

  /// The tool an Omnigent tool name names: `mcp__omnigent__x` and `x` are `x`; another
  /// server's tool is `nil`.
  static func ownTool(_ name: String) -> String? {
    let bare = name.hasPrefix("mcp__") ? String(name.dropFirst("mcp__".count)) : name
    guard let separator = bare.range(of: "__"), separator.lowerBound > bare.startIndex else {
      return name
    }
    let server = bare[..<separator.lowerBound]
    guard server.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) else {
      return name
    }
    return server == "omnigent" ? ownTool(String(bare[separator.upperBound...])) : nil
  }

  /// Whether a tool's output reports a failure (the web's `toolErrorMessage`).
  static func reportsError(_ output: String) -> Bool {
    let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
    // Output that does not parse as a JSON object is read as text.
    if text.first == "{", let data = text.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    {
      // A JSON result reports a failure only through its fields.
      if let error = object["error"] as? String { return !error.isEmpty }
      if object["error"] is [String: Any] { return true }
      return object["error"] as? Bool == true || object["isError"] as? Bool == true
    }
    if text.hasPrefix("<tool_use_error>") { return true }
    let errorLead = /^(?:(?:error|fatal)\s*:|mcp error\b|error (?:executing|calling|running)\b)/
    return text.lowercased().firstMatch(of: errorLead) != nil
  }
}

/// The role of one line in a diff.
nonisolated enum DiffLineKind: Hashable, Sendable {
  case added
  case removed
  case context
  case header
}

/// Added and removed line counts of a unified diff or a Codex patch, found in tool text.
nonisolated struct DiffSummary: Hashable, Sendable {
  struct Line: Hashable, Sendable {
    let kind: DiffLineKind
    let text: String
  }

  var files: [String]
  var added: Int
  var removed: Int
  var lines: [Line]

  /// Finds a diff in `text`, or in a JSON string value inside it (tool arguments).
  static func find(in text: String) -> Self? {
    if let summary = parse(text) { return summary }
    guard text.first == "{" || text.first == "[", let data = text.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data)
    else {
      // Not JSON: there is no embedded patch to look for.
      return nil
    }
    return strings(in: object).lazy.compactMap(parse).first
  }

  private static func strings(in value: Any) -> [String] {
    switch value {
    case let string as String: [string]
    case let array as [Any]: array.flatMap(strings)
    case let dictionary as [String: Any]:
      dictionary.keys.sorted().flatMap { key in
        dictionary[key].map(strings) ?? []
      }
    default: []
    }
  }

  static func parse(_ text: String) -> Self? {
    let isPatch = text.contains("*** Begin Patch")
    let isUnified =
      text.hasPrefix("diff --git") || text.hasPrefix("--- ") || text.contains("\n@@ ")
      || text.hasPrefix("@@ ")
    guard isPatch || isUnified else { return nil }
    var files: [String] = []
    var added = 0
    var removed = 0
    var lines: [Line] = []
    for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
      let line = String(raw)
      if let path = filePath(line) {
        files.append(path)
        lines.append(Line(kind: .header, text: line))
      } else if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("diff --git")
        || line.hasPrefix("index ") || line.hasPrefix("*** ")
      {
        lines.append(Line(kind: .header, text: line))
      } else if line.hasPrefix("@@") {
        lines.append(Line(kind: .header, text: line))
      } else if line.hasPrefix("+") {
        added += 1
        lines.append(Line(kind: .added, text: line))
      } else if line.hasPrefix("-") {
        removed += 1
        lines.append(Line(kind: .removed, text: line))
      } else {
        lines.append(Line(kind: .context, text: line))
      }
    }
    guard added + removed > 0 else { return nil }
    return Self(files: files, added: added, removed: removed, lines: lines)
  }

  /// The path a file header line names (a patch's `*** Update File:` or a diff's `+++ b/`).
  static func filePath(_ line: String) -> String? {
    for prefix in ["*** Update File: ", "*** Add File: ", "*** Delete File: ", "+++ b/"]
    where line.hasPrefix(prefix) {
      return String(line.dropFirst(prefix.count))
    }
    return nil
  }
}
