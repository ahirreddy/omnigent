import Foundation

/// One block of the transcript after turn folding, as the web renders it: user messages, a
/// per-turn "Worked for …" fold holding the turn's tool work, and the items that stay visible
/// (the turn's final answer, errors and side questions).
nonisolated enum TurnSegment: Hashable, Sendable, Identifiable {
  case item(TranscriptItem)
  case worked(id: String, responseID: String?, items: [TranscriptItem], isLive: Bool)

  var id: String {
    switch self {
    case .item(let item): item.id
    case .worked(let id, _, _, _): "worked:\(id)"
    }
  }
}

nonisolated enum TurnLayout {
  /// Folds each assistant turn (everything between user messages) into one Worked group, except
  /// its final answer, errors and side questions. The live turn's fold stays open.
  static func segments(_ items: [TranscriptItem], isRunning: Bool) -> [TurnSegment] {
    var result: [TurnSegment] = []
    var turn: [TranscriptItem] = []

    func flush(isLast: Bool) {
      guard !turn.isEmpty else { return }
      let isLive = isLast && (isRunning || turn.contains(where: \.isStreaming))
      let finalIndex = isLive ? nil : turn.lastIndex(where: \.isFinalAnswerCandidate)
      var worked: [TranscriptItem] = []
      var foldPosition: Int?
      var outside: [(Int, TranscriptItem)] = []
      for (index, item) in turn.enumerated() {
        if index == finalIndex || item.staysVisible || (isLive && item.isStreamingAnswer) {
          outside.append((index, item))
        } else {
          if foldPosition == nil { foldPosition = index }
          worked.append(item)
        }
      }
      var ordered: [(Int, TurnSegment)] = outside.map { ($0.0, .item($0.1)) }
      if let foldPosition, let first = worked.first {
        let fold = TurnSegment.worked(
          id: first.id, responseID: first.responseID, items: worked, isLive: isLive)
        ordered.append((foldPosition, fold))
      }
      result += ordered.sorted { $0.0 < $1.0 }.map(\.1)
      turn.removeAll(keepingCapacity: true)
    }

    for item in items {
      if item.isUserMessage {
        flush(isLast: false)
        result.append(.item(item))
      } else {
        turn.append(item)
      }
    }
    flush(isLast: true)
    return result
  }

  /// "8s", "1m 46s", "1m", "1h 2m".
  static func duration(_ seconds: TimeInterval) -> String {
    let total = Int(seconds.rounded())
    let hours = total / 3_600
    let minutes = (total % 3_600) / 60
    let secs = total % 60
    if hours > 0 { return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h" }
    if minutes > 0 { return secs > 0 ? "\(minutes)m \(secs)s" : "\(minutes)m" }
    return "\(secs)s"
  }
}

/// The web's tool-run summary ("Ran 3 shell commands, read 2 files"). Order: shell, list, read,
/// edit, search, then "called N other tools"; "Called N tools" when none are known.
nonisolated enum ToolRunSummary {
  enum Category: CaseIterable {
    case shell
    case list
    case read
    case edit
    case search
  }

  static func category(of title: String) -> Category? {
    let name = title.lowercased()
    let shell = ["bash", "shell", "exec", "sys_os_shell", "run_command", "terminal"]
    let list = ["ls", "list", "glob", "list_dir", "list_files"]
    let read = ["read", "view", "cat", "read_file", "sys_os_read", "open"]
    let edit = [
      "edit", "write", "apply_patch", "multiedit", "str_replace", "sys_os_edit", "sys_os_write",
      "update",
    ]
    let search = ["grep", "search", "find", "web_search", "websearch", "rg", "codebase_search"]
    if shell.contains(where: { name == $0 || name.hasPrefix("\($0)(") }) { return .shell }
    if list.contains(name) { return .list }
    if read.contains(name) { return .read }
    if edit.contains(name) { return .edit }
    if search.contains(name) { return .search }
    return nil
  }

  static func text(for titles: [String]) -> String {
    var counts: [Category: Int] = [:]
    var other = 0
    for title in titles {
      if let category = category(of: title) {
        counts[category, default: 0] += 1
      } else {
        other += 1
      }
    }
    var phrases: [String] = []
    for category in Category.allCases {
      guard let count = counts[category] else { continue }
      phrases.append(phrase(category, count))
    }
    if phrases.isEmpty { return other == 1 ? "Called 1 tool" : "Called \(other) tools" }
    if other > 0 {
      phrases.append(other == 1 ? "called 1 other tool" : "called \(other) other tools")
    }
    let joined = phrases.joined(separator: ", ")
    return joined.prefix(1).uppercased() + joined.dropFirst()
  }

  private static func phrase(_ category: Category, _ count: Int) -> String {
    let plural = count != 1
    switch category {
    case .shell: return "ran \(count) shell command\(plural ? "s" : "")"
    case .list: return "listed \(count) director\(plural ? "ies" : "y")"
    case .read: return "read \(count) file\(plural ? "s" : "")"
    case .edit: return "edited \(count) file\(plural ? "s" : "")"
    case .search: return "ran \(count) search\(plural ? "es" : "")"
    }
  }
}

extension TranscriptItem {
  nonisolated var isUserMessage: Bool {
    if case .message(let row) = self { return row.role == .user }
    return false
  }

  nonisolated var isFinalAnswerCandidate: Bool {
    if case .message(let row) = self {
      return row.role == .assistant && !row.text.isEmpty && !row.isStreaming
    }
    return false
  }

  nonisolated var isStreamingAnswer: Bool {
    if case .message(let row) = self { return row.role == .assistant && row.isStreaming }
    return false
  }

  nonisolated var isStreaming: Bool {
    switch self {
    case .message(let row), .activity(let row): row.isStreaming
    case .tools(_, let entries): entries.contains(where: \.isRunning)
    }
  }

  /// Errors and side questions stay outside the fold so they are never hidden.
  nonisolated var staysVisible: Bool {
    if case .activity(let row) = self {
      return row.activity?.kind == .error || row.activity?.kind == .sidechat
    }
    return false
  }

  nonisolated var responseID: String? {
    switch self {
    case .message(let row), .activity(let row): row.responseId
    case .tools(_, let entries): entries.first?.primary?.responseId
    }
  }
}
