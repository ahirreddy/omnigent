import Foundation
import OmnigentPlatform
import SwiftUI
import os

/// One folded segment with what its row needs: message decorations and the turn's duration.
nonisolated struct SegmentEntry: Hashable, Sendable, Identifiable {
  let segment: TurnSegment
  let decorations: [String: MessageDecoration]
  let duration: TimeInterval?

  var id: String { segment.id }
}

/// One CLI block with its message decorations.
nonisolated struct CLIBlockEntry: Hashable, Sendable, Identifiable {
  let block: CLIBlock
  let decorations: [String: MessageDecoration]

  var id: String { block.id }
}

/// The transcript's folded layout, computed once per change of the rows and the values the
/// decorations read, not on every body pass. Between changes the same arrays are returned, so
/// SwiftUI's comparison of the row lists is an identity check instead of a deep one.
@MainActor
final class TranscriptLayoutMemo {
  private struct Inputs: Equatable {
    var rows: [Row]
    var isRunning: Bool
    var timestamps: [String: Date]
    var turnDurations: [String: TimeInterval]
    var isShared: Bool
    var viewerName: String?

    init(_ state: ConversationViewState) {
      rows = state.rows
      isRunning = state.header.status == .running
      timestamps = state.timestamps
      turnDurations = state.turnDurations
      isShared = state.isShared
      viewerName = state.viewerName
    }
  }

  /// What message decorations read besides the rows.
  private struct DecorationInputs: Equatable {
    var lastAnswerID: String?
    var timestamps: [String: Date]
    var turnDurations: [String: TimeInterval]
    var isShared: Bool
    var viewerName: String?
  }

  /// The rows before the last user message, folded and decorated. While they and their
  /// decorations are unchanged, a streamed delta folds only the open turn instead of the whole
  /// transcript.
  private struct Prefix {
    var rows: [Row]
    var decorations: DecorationInputs
    var responseIDs: Set<String>
    var entries: [SegmentEntry]
    var turns: [TranscriptTurn]
    /// The CLI blocks of ``entries``, made the first time the CLI style asks (never empty
    /// once made: the prefix holds at least one turn).
    var blocks: [CLIBlockEntry] = []
  }

  private var inputs: Inputs?
  private var prefix: Prefix?
  /// ``cachedEntries`` start with the prefix's entries.
  private var entriesUsePrefix = false
  private var cachedEntries: [SegmentEntry] = []
  private var cachedBlocks: [CLIBlockEntry] = []
  private var hasBlocks = false
  /// The user turns; kept (the same array) while a delta changes only the open answer.
  private var cachedTurns: [TranscriptTurn] = []
  /// The turns after the prefix's, and whether ``cachedTurns`` start with the prefix's.
  private var tailTurns: [TranscriptTurn] = []
  private var turnsUsePrefix = false
  /// How many times the layout was computed, for tests.
  private(set) var computations = 0
  /// How many of those reused the folded prefix, for tests.
  private(set) var prefixReuses = 0

  /// The chat transcript's segments for `state`.
  /// - Parameter state: The conversation.
  /// - Returns: The segments, the same array while the inputs are unchanged.
  func entries(for state: ConversationViewState) -> [SegmentEntry] {
    refresh(state)
    return cachedEntries
  }

  /// The CLI transcript's blocks for `state`.
  /// - Parameter state: The conversation.
  /// - Returns: The blocks, the same array while the inputs are unchanged.
  func blocks(for state: ConversationViewState) -> [CLIBlockEntry] {
    refresh(state)
    if hasBlocks { return cachedBlocks }
    // A streamed delta changes only the open turn: the settled turns' blocks (each with a
    // formatted footer) are kept with the prefix, which resets when the last answer moves.
    let lastAnswerID =
      state.header.status == .running ? nil : TranscriptView.lastAnswerID(state.rows)
    if entriesUsePrefix, var prefix {
      if prefix.blocks.isEmpty {
        prefix.blocks = Self.cliBlocks(
          prefix.entries[...], state: state, lastAnswerID: lastAnswerID, closesLastTurn: true)
        self.prefix = prefix
      }
      let tail = cachedEntries[prefix.entries.count...]
      cachedBlocks =
        prefix.blocks + Self.cliBlocks(tail, state: state, lastAnswerID: lastAnswerID)
    } else {
      cachedBlocks = Self.cliBlocks(cachedEntries[...], state: state, lastAnswerID: lastAnswerID)
    }
    hasBlocks = true
    return cachedBlocks
  }

  private static func cliBlocks(
    _ entries: ArraySlice<SegmentEntry>, state: ConversationViewState, lastAnswerID: String?,
    closesLastTurn: Bool = false
  ) -> [CLIBlockEntry] {
    CLILayout.blocks(
      entries.map(\.segment), durations: state.turnDurations, timestamps: state.timestamps,
      isRunning: state.header.status == .running, closesLastTurn: closesLastTurn
    )
    .map { block in
      CLIBlockEntry(
        block: block,
        decorations: Self.cliDecorations(for: block, state: state, lastAnswerID: lastAnswerID))
    }
  }

  private func refresh(_ state: ConversationViewState) {
    let current = Inputs(state)
    guard current != inputs else { return }
    let signpost = PerformanceSignposts.transcript.beginInterval("layout")
    defer { PerformanceSignposts.transcript.endInterval("layout", signpost) }
    inputs = current
    computations += 1
    cachedBlocks = []
    hasBlocks = false
    entriesUsePrefix = false
    let reusedPrefix = layOut(state, isRunning: current.isRunning)
    updateTurns(reusedPrefix: reusedPrefix)
  }

  /// Folds and decorates the rows into ``cachedEntries``.
  /// - Returns: Whether the folded prefix was reused.
  private func layOut(_ state: ConversationViewState, isRunning: Bool) -> Bool {
    let decorations = DecorationInputs(
      lastAnswerID: isRunning ? nil : TranscriptView.lastAnswerID(state.rows),
      timestamps: state.timestamps, turnDurations: state.turnDurations,
      isShared: state.isShared, viewerName: state.viewerName)
    guard let split = state.rows.lastIndex(where: { $0.role == .user && !$0.isActivityOnly }),
      split > 0
    else {
      prefix = nil
      cachedEntries = Self.entries(TranscriptView.segments(for: state), state, decorations)
      return false
    }
    let tailRows = state.rows[split...]
    let tail = TurnLayout.segments(
      TranscriptLayout.items(for: Array(tailRows)), isRunning: isRunning)
    let tailResponses = Set(tailRows.compactMap(\.responseId))
    if let prefix, prefix.decorations == decorations, prefix.rows.count == split,
      prefix.responseIDs.isDisjoint(with: tailResponses),
      state.rows[..<split].elementsEqual(prefix.rows)
    {
      prefixReuses += 1
      entriesUsePrefix = true
      cachedEntries = prefix.entries + Self.entries(tail, state, decorations)
      return true
    }
    let prefixRows = Array(state.rows[..<split])
    let head = TurnLayout.segments(
      TranscriptLayout.items(for: prefixRows), isRunning: isRunning, closesLastTurn: true)
    let responses = Set(prefixRows.compactMap(\.responseId))
    guard responses.isDisjoint(with: tailResponses) else {
      // A response continues past the user's message (a steer): its "Worked for" belongs to the
      // answer after it, so the turns are decorated together and nothing is kept.
      self.prefix = nil
      cachedEntries = Self.entries(head + tail, state, decorations)
      return false
    }
    let headEntries = Self.entries(head, state, decorations)
    self.prefix = Prefix(
      rows: prefixRows, decorations: decorations, responseIDs: responses, entries: headEntries,
      turns: Self.turns(headEntries[...]))
    entriesUsePrefix = true
    cachedEntries = headEntries + Self.entries(tail, state, decorations)
    return false
  }

  /// The turn rail's turns for `state`.
  /// - Parameter state: The conversation.
  /// - Returns: The user turns, the same array while a delta changes only the open answer.
  func turns(for state: ConversationViewState) -> [TranscriptTurn] {
    refresh(state)
    return cachedTurns
  }

  /// Keeps ``cachedTurns`` when the reused prefix is the one they were built from and the tail's
  /// turns are unchanged, so a streamed delta allocates nothing.
  private func updateTurns(reusedPrefix: Bool) {
    guard entriesUsePrefix, let prefix else {
      cachedTurns = Self.turns(cachedEntries[...])
      turnsUsePrefix = false
      return
    }
    let tail = Self.turns(cachedEntries[prefix.entries.count...])
    if reusedPrefix, turnsUsePrefix, tail == tailTurns { return }
    cachedTurns = prefix.turns + tail
    tailTurns = tail
    turnsUsePrefix = true
  }

  /// The user messages among `entries`, in order.
  private static func turns(_ entries: ArraySlice<SegmentEntry>) -> [TranscriptTurn] {
    entries.compactMap { entry in
      guard case .item(.message(let row)) = entry.segment, row.role == .user else { return nil }
      return TranscriptTurn(id: entry.id, text: row.text)
    }
  }

  /// `segments` with their message decorations and turn durations.
  private static func entries(
    _ segments: [TurnSegment], _ state: ConversationViewState, _ inputs: DecorationInputs
  ) -> [SegmentEntry] {
    let turnAnswers = lastAnswerIDs(segments)
    return segments.map { segment in
      var duration: TimeInterval?
      if case .worked(_, let responseID?, _, _) = segment {
        duration = inputs.turnDurations[responseID]
      }
      var decorations = Self.decorations(
        for: segment.items, state: state, lastAnswerID: inputs.lastAnswerID)
      // A turn's last settled answer carries its "Worked for".
      if case .item(.message(let row)) = segment, row.role == .assistant, !row.isStreaming,
        let responseID = row.responseId, turnAnswers[responseID] == row.id
      {
        decorations[row.id]?.workedFor = inputs.turnDurations[responseID]
      }
      return SegmentEntry(segment: segment, decorations: decorations, duration: duration)
    }
  }

  /// The last visible assistant message of each response.
  static func lastAnswerIDs(_ segments: [TurnSegment]) -> [String: String] {
    var result: [String: String] = [:]
    for segment in segments {
      if case .item(.message(let row)) = segment, row.role == .assistant,
        let responseID = row.responseId
      {
        result[responseID] = row.id
      }
    }
    return result
  }

  private static func decorations(
    for items: [TranscriptItem], state: ConversationViewState, lastAnswerID: String?
  ) -> [String: MessageDecoration] {
    var result: [String: MessageDecoration] = [:]
    for item in items {
      guard case .message(let row) = item else { continue }
      result[row.id] = MessageDecoration(
        timestamp: state.timestamps[row.id] ?? row.createdAt, showsActions: row.id == lastAnswerID,
        showsAvatar: isOtherAuthor(row, state: state))
    }
    return result
  }

  /// Timestamps for the hover action row, the shared-session author, and the latest answer
  /// whose actions stay shown on touch, as in chat.
  static func cliDecorations(
    for block: CLIBlock, state: ConversationViewState, lastAnswerID: String?
  ) -> [String: MessageDecoration] {
    guard case .segment(let segment) = block else { return [:] }
    var result: [String: MessageDecoration] = [:]
    for item in segment.items {
      guard case .message(let row) = item else { continue }
      result[row.id] = MessageDecoration(
        timestamp: state.timestamps[row.id] ?? row.createdAt, showsActions: row.id == lastAnswerID,
        showsAvatar: isOtherAuthor(row, state: state))
    }
    return result
  }

  private static func isOtherAuthor(_ row: Row, state: ConversationViewState) -> Bool {
    state.isShared && row.role == .user && row.author != nil && row.author != state.viewerName
  }
}

/// Keeps the transcript's environment values stable across updates, as ``FocusedActionsRelay``
/// does for focused values: a new `ConversationActions` or `OpenURLAction` in the environment
/// would re-render every row that reads it on every streamed delta.
@MainActor
final class TranscriptEnvironmentRelay {
  private let relay = FocusedActionsRelay<ConversationActions>()
  private var openLink: (@MainActor (URL) -> Void)?

  /// Opens links through the latest actions' `openURL`, or the system when there is none.
  private(set) lazy var openURL = OpenURLAction { [weak self] url in
    guard let open = self?.openLink else { return .systemAction }
    open(url)
    return .handled
  }

  /// How many times new actions were published, for tests.
  var publications: Int { relay.publications }

  /// The actions to put in the environment: the last value while the same actions exist, with
  /// closures that call `actions`'.
  /// - Parameter actions: The current actions.
  /// - Returns: The stable actions.
  func publish(_ actions: ConversationActions) -> ConversationActions {
    openLink = actions.openURL
    return relay.publish(actions) ?? actions
  }
}

extension ConversationActions: FocusedActions {
  /// Which actions exist; rows show or hide controls by it.
  public var menuSignature: [Bool] {
    [
      loadOlder != nil, openSession != nil, openAttachment != nil, openURL != nil,
      respond != nil, validateForm != nil, dismissError != nil, retry != nil, forkFrom != nil,
      messageURL != nil, resume != nil, share != nil, openSideChat != nil, openChild != nil,
      retryFailedTurn != nil, replyWithSelection != nil, askInSideChat != nil,
    ]
  }

  /// A copy whose actions call `latest`'s.
  /// - Parameter latest: The newest actions.
  /// - Returns: The forwarding copy.
  public func forwarding(to latest: @escaping @MainActor () -> Self?) -> Self {
    var copy = Self(
      loadOlder: Self.forward(loadOlder, \.loadOlder, to: latest),
      dismissError: Self.forward(dismissError, \.dismissError, to: latest),
      retry: Self.forward(retry, \.retry, to: latest),
      resume: Self.forward(resume, \.resume, to: latest),
      share: Self.forward(share, \.share, to: latest))
    if openSession != nil { copy.openSession = { latest()?.openSession?($0) } }
    if openAttachment != nil { copy.openAttachment = { latest()?.openAttachment?($0) } }
    if openURL != nil { copy.openURL = { latest()?.openURL?($0) } }
    if respond != nil { copy.respond = { latest()?.respond?($0, $1) } }
    if validateForm != nil { copy.validateForm = { latest()?.validateForm?($0, $1) } }
    if forkFrom != nil { copy.forkFrom = { latest()?.forkFrom?($0) } }
    if messageURL != nil { copy.messageURL = { latest()?.messageURL?($0) } }
    if openSideChat != nil { copy.openSideChat = { latest()?.openSideChat?($0) } }
    if openChild != nil { copy.openChild = { latest()?.openChild?($0) } }
    if retryFailedTurn != nil { copy.retryFailedTurn = { latest()?.retryFailedTurn?($0) } }
    forwardQuotes(into: &copy, to: latest)
    return copy
  }

  /// Reply and Ask in side chat, which quote text from the transcript.
  private func forwardQuotes(into copy: inout Self, to latest: @escaping @MainActor () -> Self?) {
    if replyWithSelection != nil {
      copy.replyWithSelection = { latest()?.replyWithSelection?($0) }
    }
    if askInSideChat != nil { copy.askInSideChat = { latest()?.askInSideChat?($0) } }
  }
}
