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
  /// turn with no message stays unfolded; trailing reasoning joins the turn's last run. In the
  /// live turn only the run still growing is open: one the turn has moved past is done, and
  /// closes. `closesLastTurn` folds items that end before a user message (a transcript's settled
  /// prefix), whose last turn is never the live one.
  static func segments(
    _ items: [TranscriptItem], isRunning: Bool, closesLastTurn: Bool = false
  ) -> [TurnSegment] {
    var result: [TurnSegment] = []
    var turn: [TranscriptItem] = []

    func flush(isLast: Bool) {
      guard !turn.isEmpty else { return }
      let isLive = isLast && (isRunning || turn.contains(where: \.isStreaming))
      result += fold(turn, isLive: isLive)
      turn.removeAll(keepingCapacity: true)
    }

    for item in items {
      if item.isTurnBoundary {
        flush(isLast: false)
        result.append(.item(item))
      } else {
        turn.append(item)
      }
    }
    flush(isLast: !closesLastTurn)
    return result
  }

  private enum Piece {
    case visible(TranscriptItem)
    case work([TranscriptItem])
  }

  private static func fold(_ turn: [TranscriptItem], isLive: Bool) -> [TurnSegment] {
    let hasMessage = turn.contains(where: \.isVisibleMessage)
    guard isLive || hasMessage else { return turn.map(TurnSegment.item) }
    let latest = latestNewsStart(turn)
    var pieces: [Piece] = []
    for item in turn[..<latest] {
      if item.isVisibleMessage || item.staysVisible {
        pieces.append(.visible(item))
      } else if case .work(let run) = pieces.last {
        pieces[pieces.count - 1] = .work(run + [item])
      } else {
        pieces.append(.work([item]))
      }
    }
    var wrapUp: [TranscriptItem] = []
    if case .work(let trailing) = pieces.last, trailing.allSatisfy(\.isTrailingWrapUp) {
      wrapUp = trailing
      pieces.removeLast()
    }
    foldMarkerRuns(&pieces)
    mergeWrapUp(wrapUp, into: &pieces)
    let last = pieces.count - 1
    let folded: [TurnSegment] = pieces.enumerated().map { index, piece in
      switch piece {
      case .visible(let item): .item(item)
      case .work(let run):
        .worked(
          id: run[0].id, responseID: run[0].responseID, items: run,
          isLive: isLive && index == last && latest == turn.count)
      }
    }
    return folded + turn[latest...].map(TurnSegment.item)
  }

  /// Where the turn's latest news starts, as the web's `latestNewsStart`: its trailing markers
  /// and the uncommitted output after them stay visible after the fold until committed work
  /// follows them.
  private static func latestNewsStart(_ turn: [TranscriptItem]) -> Int {
    var start = turn.count
    while start > 0, turn[start - 1].isMarkerOrUncommitted { start -= 1 }
    return turn[start...].firstIndex(where: \.isActivityMarker) ?? turn.count
  }

  /// A run of only markers folds with the nearest work, the earlier first (the web's
  /// `foldNoticeRuns`). With no other work in the turn there is nothing to fold into, so the
  /// markers stay visible.
  private static func foldMarkerRuns(_ pieces: inout [Piece]) {
    func isMarkerRun(_ piece: Piece) -> Bool {
      if case .work(let run) = piece { return run.allSatisfy(\.isActivityMarker) }
      return false
    }
    func isWork(_ piece: Piece) -> Bool {
      if case .work = piece { return !isMarkerRun(piece) }
      return false
    }
    guard pieces.contains(where: isMarkerRun) else { return }
    var index = 0
    while index < pieces.count {
      guard isMarkerRun(pieces[index]), case .work(let markers) = pieces[index] else {
        index += 1
        continue
      }
      pieces.remove(at: index)
      if let earlier = pieces[..<index].lastIndex(where: isWork),
        case .work(let run) = pieces[earlier]
      {
        pieces[earlier] = .work(run + markers)
      } else if let later = pieces.firstIndex(where: isWork), case .work(let run) = pieces[later] {
        pieces[later] = .work(markers + run)
      } else {
        pieces.insert(contentsOf: markers.map(Piece.visible), at: index)
        index += markers.count
      }
    }
  }

  /// Reasoning and bookkeeping tools after the last message join the previous run, so live and
  /// reloaded turns agree and the answer ends the turn.
  private static func mergeWrapUp(_ wrapUp: [TranscriptItem], into pieces: inout [Piece]) {
    guard !wrapUp.isEmpty else { return }
    if let earlier = pieces.lastIndex(where: { if case .work = $0 { true } else { false } }),
      case .work(let run) = pieces[earlier]
    {
      pieces[earlier] = .work(run + wrapUp)
    } else {
      pieces.append(.work(wrapUp))
    }
  }

  /// "8s", "1m 46s", "1m", "1h 2m".
  static func duration(_ seconds: TimeInterval) -> String {
    // Built from server timestamps, so it needn't be a sensible span.
    let total = seconds.isFinite ? Int(min(max(seconds.rounded(), 0), 0x1p53)) : 0
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

  /// A runtime `[System: …]` notice: like a user message, it starts a new turn.
  nonisolated var isSystemNotice: Bool {
    if case .activity(let row) = self { return row.activity?.kind == .systemNotice }
    return false
  }

  /// Where one turn ends and the next starts: a user message or a notice.
  nonisolated var isTurnBoundary: Bool { isUserMessage || isSystemNotice }

  /// A sub-agent's or a task's start or end, or a plan change: it folds with the turn's work.
  nonisolated var isActivityMarker: Bool {
    if case .activity(let row) = self {
      return row.activity?.kind == .subagentMarker || row.activity?.kind == .taskMarker
    }
    return false
  }

  /// A marker, or output no server item stands for yet (a live preview) that has not failed.
  nonisolated var isMarkerOrUncommitted: Bool {
    if isActivityMarker { return true }
    let rows = rows
    return !rows.isEmpty && rows.allSatisfy(\.isEphemeral)
      && !rows.contains { $0.activity?.isFailure == true }
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

  /// Work after the last message that says nothing new: reasoning, or Codex's `turn_diff` mirror.
  nonisolated var isTrailingWrapUp: Bool {
    if case .tools(_, let entries) = self {
      return !entries.isEmpty && entries.allSatisfy { $0.primary?.activity?.title == "turn_diff" }
    }
    return isReasoning
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
