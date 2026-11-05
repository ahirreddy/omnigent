import Foundation

/// One block of the transcript after turn folding, as the web renders it: messages, a Worked
/// fold for each run of tool work, and the items that stay visible (errors and side questions).
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
  /// Folds each run of tool work and reasoning between assistant messages into its own Worked
  /// group, as the web does: every message, error and side question stays visible. A settled
  /// turn with no message stays unfolded; trailing reasoning joins the turn's last run. The live
  /// turn's folds stay open.
  static func segments(_ items: [TranscriptItem], isRunning: Bool) -> [TurnSegment] {
    var result: [TurnSegment] = []
    var turn: [TranscriptItem] = []

    func flush(isLast: Bool) {
      guard !turn.isEmpty else { return }
      let isLive = isLast && (isRunning || turn.contains(where: \.isStreaming))
      result += fold(turn, isLive: isLive)
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

  private enum Piece {
    case visible(TranscriptItem)
    case work([TranscriptItem])
  }

  private static func fold(_ turn: [TranscriptItem], isLive: Bool) -> [TurnSegment] {
    let hasMessage = turn.contains(where: \.isVisibleMessage)
    guard isLive || hasMessage else { return turn.map(TurnSegment.item) }
    var pieces: [Piece] = []
    for item in turn {
      if item.isVisibleMessage || item.staysVisible {
        pieces.append(.visible(item))
      } else if case .work(let run) = pieces.last {
        pieces[pieces.count - 1] = .work(run + [item])
      } else {
        pieces.append(.work([item]))
      }
    }
    mergeTrailingReasoning(&pieces)
    return pieces.map { piece in
      switch piece {
      case .visible(let item): .item(item)
      case .work(let run):
        .worked(id: run[0].id, responseID: run[0].responseID, items: run, isLive: isLive)
      }
    }
  }

  /// Reasoning after the last message joins the previous run, so live and reloaded turns agree.
  private static func mergeTrailingReasoning(_ pieces: inout [Piece]) {
    guard case .work(let trailing) = pieces.last, trailing.allSatisfy(\.isReasoning),
      let earlier = pieces.dropLast().lastIndex(where: {
        if case .work = $0 { true } else { false }
      }),
      case .work(let run) = pieces[earlier]
    else { return }
    pieces[earlier] = .work(run + trailing)
    pieces.removeLast()
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

  /// An assistant message with text, or one still streaming: it never folds.
  nonisolated var isVisibleMessage: Bool {
    if case .message(let row) = self {
      return row.role == .assistant && (!row.text.isEmpty || row.isStreaming)
    }
    return false
  }

  nonisolated var isReasoning: Bool {
    if case .activity(let row) = self { return row.activity?.kind == .reasoning }
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
