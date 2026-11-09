import SwiftUI

/// The transcript's latest rows, kept for the scroll actions of ``TranscriptView`` (paging,
/// previous and next message), which run outside a body. Not observed: storing it redraws nothing.
@MainActor
final class TranscriptCurrentState {
  var state: ConversationViewState

  init(_ state: ConversationViewState) {
    self.state = state
  }
}

/// What the row list reports to ``TranscriptView`` when its rows change.
struct TranscriptRowEvents {
  /// The rows' revision changed.
  var revisionChanged: () -> Void = {}
  /// The first row changed (older history landed above).
  var firstRowChanged: () -> Void = {}
  /// The viewer's newest message changed, from the old id to the new one.
  var ownMessageChanged: (String?, String?) -> Void = { _, _ in }
  /// Whether any user message is loaded, for the previous and next message buttons.
  var hasUserMessagesChanged: (Bool) -> Void = { _ in }
  /// The user turns changed, for the turn rail.
  var turnsChanged: ([TranscriptTurn]) -> Void = { _ in }
}

/// The transcript's scrolling content. It reads the rows in its own body (paced, see
/// ``TranscriptRowsPacer``), so a row change re-renders this list and not the scroll view's
/// modifiers and overlays in ``TranscriptView``.
struct TranscriptRowsContent<Header: View>: View {
  let state: ConversationViewState
  let liveRows: LiveTranscriptRows?
  let pacer: TranscriptRowsPacer
  let actions: ConversationActions
  let layout: TranscriptLayoutMemo
  let current: TranscriptCurrentState
  let events: TranscriptRowEvents
  let header: Header

  @Environment(\.isTabContentHidden) private var isHidden
  @Environment(\.transcriptAppearance) private var appearance
  @Environment(\.transcriptFocus) private var focus

  var body: some View {
    let state = rowsState
    current.state = state
    pacer.warmup.warm(state.rows)
    return list(state)
  }

  private func list(_ state: ConversationViewState) -> some View {
    LazyVStack(
      alignment: .leading, spacing: appearance.isCLI ? CLIMetrics.blockGap : Theme.Spacing.row
    ) {
      Color.clear.frame(height: 1).id(TranscriptView.topID)
      if appearance.isCLI {
        CLITranscriptRows(
          state: state, actions: actions, blocks: layout.blocks(for: state), header: header)
      } else {
        rows(state)
      }
      Color.clear.frame(height: 1).id(TranscriptView.bottomID)
    }
    .scrollTargetLayout()
    .padding(.vertical, Theme.Spacing.extraLarge)
    // CLI rows set their own column, so user bands reach the edges.
    .transcriptStackColumn()
    .onChange(of: state.revision) { _, _ in events.revisionChanged() }
    .onChange(of: state.rows.first?.id) { _, _ in events.firstRowChanged() }
    .onChange(of: TranscriptView.ownMessageID(state)) { previous, latest in
      events.ownMessageChanged(previous, latest)
    }
    // Previous and next need a second message to move between.
    .onChange(of: state.rows.count { $0.role == .user } > 1, initial: true) { _, hasSeveral in
      events.hasUserMessagesChanged(hasSeveral)
    }
    // The memo returns the same array while a delta changes only the open answer, so this
    // comparison is an identity check while streaming.
    .onChange(of: layout.turns(for: state), initial: true) { _, turns in
      events.turnsChanged(turns)
    }
  }

  /// The state with the live rows, when the transcript reads them itself.
  private var rowsState: ConversationViewState {
    guard let liveRows else { return state }
    var state = state
    let live = pacer.rows(from: liveRows, isShown: !isHidden)
    state.rows = live.rows
    state.revision = live.revision
    if pacer.isPreparing { state.isHydrating = true }
    return state
  }

  @ViewBuilder private func rows(_ state: ConversationViewState) -> some View {
    header
    if let superseded = state.section("superseded"), let target = superseded.sessionId,
      target != state.header.id
    {
      SupersededBanner(section: superseded, target: target)
    }
    let entries = layout.entries(for: state)
    if entries.isEmpty {
      EmptyTranscriptView(state: state)
    }
    ForEach(entries) { entry in
      TurnSegmentView(entry: entry)
        .equatable()
        .id(entry.id)
        .reportsReadingAnchor(entry.id)
        .probesRowHeight(entry.id)
        .background { if focus?.flashedRowID == entry.id { MessageFlash() } }
    }
    InlineDecisions(state: state, actions: actions)
    SubagentGroupView(state: state, actions: actions)
    if let startup = state.section("startup") {
      StartupLine(section: startup)
    }
    if state.header.status == .running, !(state.rows.last?.isStreaming ?? false) {
      WorkingIndicator(
        isBlocked: !state.pendingDecisions.isEmpty, startedAt: TurnElapsed.start(in: state))
    }
    if let failure = state.header.failureMessage, !Self.hasErrorRow(in: state, matching: failure) {
      FailureBanner(message: failure, resume: actions.resume)
    }
    if let error = state.errorMessage {
      ErrorBanner(message: error, dismiss: actions.dismissError, retry: actions.retry)
    }
  }

  private static func hasErrorRow(in state: ConversationViewState, matching failure: String)
    -> Bool
  {
    state.rows.suffix(20).contains {
      $0.activity?.isFailure == true && $0.activity?.summary == failure
    }
  }
}

/// One folded segment: a plain item, or a Worked fold.
struct TurnSegmentView: View, Equatable {
  let entry: SegmentEntry

  var body: some View {
    segment.countsRenders("row")
  }

  @ViewBuilder private var segment: some View {
    switch entry.segment {
    case .item(let item):
      TranscriptItemView(item: item, decorations: entry.decorations)
    case .worked(_, _, let items, let isLive):
      WorkedFold(
        items: items, isLive: isLive, duration: entry.duration, decorations: entry.decorations)
    }
  }
}
