import Foundation
import SwiftUI

/// One block of the CLI transcript: the folded segments, plus a "Worked for" footer under each
/// settled turn, where the Codex CLI puts it.
nonisolated enum CLIBlock: Hashable, Sendable, Identifiable {
  case segment(TurnSegment)
  case footer(id: String, text: String)

  var id: String {
    switch self {
    case .segment(let segment): segment.id
    case .footer(let id, _): "footer:\(id)"
    }
  }
}

nonisolated enum CLILayout {
  /// Adds a footer after each settled turn (the segments between user messages) that reports a
  /// duration or a time. The live turn has none; its working line shows instead.
  /// `closesLastTurn` settles the last turn too: the segments end before a user message.
  static func blocks(
    _ segments: [TurnSegment], durations: [String: TimeInterval], timestamps: [String: Date],
    isRunning: Bool, closesLastTurn: Bool = false, now: Date = Date()
  ) -> [CLIBlock] {
    var blocks: [CLIBlock] = []
    var turn: [TurnSegment] = []

    func flush(isLast: Bool) {
      guard !turn.isEmpty else { return }
      blocks += turn.map(CLIBlock.segment)
      let isLive = isLast && (isRunning || turn.contains(where: \.isStreaming))
      if !isLive, let last = turn.last,
        let text = footer(turn, durations: durations, timestamps: timestamps, now: now)
      {
        blocks.append(.footer(id: last.id, text: text))
      }
      turn.removeAll(keepingCapacity: true)
    }

    for segment in segments {
      if segment.isUserMessage {
        flush(isLast: false)
        blocks.append(.segment(segment))
      } else {
        turn.append(segment)
      }
    }
    flush(isLast: !closesLastTurn)
    return blocks
  }

  /// "Worked for 12s • 9:47 PM", "Worked for 12s" or the time alone.
  static func footer(
    _ turn: [TurnSegment], durations: [String: TimeInterval], timestamps: [String: Date],
    now: Date
  ) -> String? {
    let items = turn.flatMap(\.items)
    let duration = items.lazy.compactMap(\.responseID).compactMap { durations[$0] }.first
    let finished = items.flatMap(\.rows).reversed().lazy.compactMap {
      timestamps[$0.id] ?? $0.createdAt
    }
    .first
    let parts = [
      duration.map { "Worked for \(TurnLayout.duration($0))" },
      finished.map { MessageTimestamp.format($0, now: now) },
    ].compactMap(\.self)
    return parts.isEmpty ? nil : parts.joined(separator: " \u{2022} ")
  }
}

extension TurnSegment {
  nonisolated var isUserMessage: Bool {
    if case .item(let item) = self { return item.isUserMessage }
    return false
  }

  nonisolated var isStreaming: Bool {
    switch self {
    case .item(let item): item.isStreaming
    case .worked(_, _, let items, let isLive): isLive || items.contains(where: \.isStreaming)
    }
  }

  nonisolated var items: [TranscriptItem] {
    switch self {
    case .item(let item): [item]
    case .worked(_, _, let items, _): items
    }
  }
}

/// The CLI transcript's rows, laid out inside ``TranscriptView``'s lazy stack so the reading
/// position rules and Jump to latest are shared with chat style. Text blocks are terminal-like;
/// plans, decisions, the live sub-agent group and banners stay native.
struct CLITranscriptRows<Header: View>: View {
  let state: ConversationViewState
  let actions: ConversationActions
  /// The folded blocks, from ``TranscriptLayoutMemo``.
  let blocks: [CLIBlockEntry]
  let header: Header
  @Environment(\.transcriptFocus) private var focus

  var body: some View {
    header
    if let todos = state.section("todos"), !todos.details.isEmpty {
      PlanCard(section: todos).transcriptColumn()
    }
    if let superseded = state.section("superseded"), let target = superseded.sessionId,
      target != state.header.id
    {
      SupersededBanner(section: superseded, target: target).transcriptColumn()
    }
    if blocks.isEmpty {
      EmptyTranscriptView(state: state).transcriptColumn()
    }
    ForEach(blocks) { entry in
      CLIBlockView(block: entry.block, decorations: entry.decorations)
        .equatable()
        .id(entry.id)
        // Over the row, since a user message's band is opaque.
        .overlay { if focus?.flashedRowID == entry.id { MessageFlash(isBand: true) } }
    }
    InlineDecisions(state: state, actions: actions).transcriptColumn()
    CLISubagentLines(state: state, actions: actions)
    if state.header.status == .running, !(state.rows.last?.isStreaming ?? false) {
      CLIWorkingLine(
        isBlocked: !state.pendingDecisions.isEmpty, startedAt: TurnElapsed.start(in: state))
    }
    if let failure = state.header.failureMessage, !hasErrorRow(matching: failure) {
      FailureBanner(message: failure, resume: actions.resume).transcriptColumn()
    }
    if let error = state.errorMessage {
      ErrorBanner(message: error, dismiss: actions.dismissError, retry: actions.retry)
        .transcriptColumn()
    }
  }

  private func hasErrorRow(matching failure: String) -> Bool {
    state.rows.suffix(20).contains {
      $0.activity?.isFailure == true && $0.activity?.summary == failure
    }
  }
}

/// One CLI block; equatable so unchanged rows skip re-rendering while output streams.
private struct CLIBlockView: View, Equatable {
  let block: CLIBlock
  let decorations: [String: MessageDecoration]

  var body: some View {
    switch block {
    case .segment(.item(let item)):
      CLIItemView(item: item, decorations: decorations)
    case .segment(.worked(let id, _, let items, let isLive)):
      CLIWorkGroup(id: id, items: items, isLive: isLive, decorations: decorations)
    case .footer(_, let text):
      CLIFooterLine(text: text)
    }
  }
}
