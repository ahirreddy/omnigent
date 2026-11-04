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
      guard let first = group.first else { return }
      items.append(.tools(id: first.id, entries: group))
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

  private static func filePath(_ line: String) -> String? {
    for prefix in ["*** Update File: ", "*** Add File: ", "*** Delete File: ", "+++ b/"]
    where line.hasPrefix(prefix) {
      return String(line.dropFirst(prefix.count))
    }
    return nil
  }
}
