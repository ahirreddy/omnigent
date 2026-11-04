import Foundation
import SwiftUI

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

  private var inputs: Inputs?
  private var cachedEntries: [SegmentEntry] = []
  private var cachedBlocks: [CLIBlockEntry] = []
  private var hasBlocks = false
  /// How many times the layout was computed, for tests.
  private(set) var computations = 0

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
    let blocks = CLILayout.blocks(
      cachedEntries.map(\.segment), durations: state.turnDurations, timestamps: state.timestamps,
      isRunning: state.header.status == .running
    )
    .map { block in
      CLIBlockEntry(block: block, decorations: Self.cliDecorations(for: block, state: state))
    }
    cachedBlocks = blocks
    hasBlocks = true
    return blocks
  }

  private func refresh(_ state: ConversationViewState) {
    let current = Inputs(state)
    guard current != inputs else { return }
    inputs = current
    computations += 1
    let lastAnswerID = current.isRunning ? nil : TranscriptView.lastAnswerID(state.rows)
    cachedEntries = TranscriptView.segments(for: state).map { segment in
      var duration: TimeInterval?
      if case .worked(_, let responseID?, _, _) = segment {
        duration = state.turnDurations[responseID]
      }
      var decorations = Self.decorations(
        for: segment.items, state: state, lastAnswerID: lastAnswerID)
      // A settled answer outside the fold carries its turn's "Worked for".
      if case .item(.message(let row)) = segment, row.role == .assistant, !row.isStreaming,
        let responseID = row.responseId
      {
        decorations[row.id]?.workedFor = state.turnDurations[responseID]
      }
      return SegmentEntry(segment: segment, decorations: decorations, duration: duration)
    }
    cachedBlocks = []
    hasBlocks = false
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

  /// Timestamps for the hover action row and the shared-session author.
  private static func cliDecorations(for block: CLIBlock, state: ConversationViewState)
    -> [String: MessageDecoration]
  {
    guard case .segment(let segment) = block else { return [:] }
    var result: [String: MessageDecoration] = [:]
    for item in segment.items {
      guard case .message(let row) = item else { continue }
      result[row.id] = MessageDecoration(
        timestamp: state.timestamps[row.id] ?? row.createdAt, showsActions: false,
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
      retryFailedTurn != nil,
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
    return copy
  }
}
