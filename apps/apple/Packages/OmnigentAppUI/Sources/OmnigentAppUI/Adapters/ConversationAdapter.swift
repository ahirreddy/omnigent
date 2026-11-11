import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents

/// Builds the conversation screen's view state from one ``ConversationStore``. Reading the
/// store's properties inside a view body registers them with Observation, so the screen updates
/// as the core patches rows.
enum ConversationAdapter {
  /// The conversation's view state.
  /// - Parameters:
  ///   - store: The conversation.
  ///   - summary: Its session-list row, for the title before the header arrives.
  /// - Returns: The state.
  static func state(
    _ store: ConversationStore, summary: OmnigentCoreFFI.SessionSummary?
  ) -> ConversationViewState {
    let header = Self.header(store, summary: summary)
    var state = ConversationViewState(
      revision: store.displayRevision, header: header,
      rows: store.displayRows.map(OmnigentUIComponents.Row.init),
      decisions: store.decisions.cards.map(OmnigentUIComponents.DecisionCard.init),
      decisionPhases: decisionPhases(store.decisions),
      sections: store.sections.map(OmnigentUIComponents.EventSection.init),
      hasMoreHistory: store.hasOlderHistory, isLoadingHistory: isLoadingHistory(store),
      errorMessage: errorMessage(store),
      connectionStatus: connectionStatus(store),
      turnDurations: store.turnTimer.durations,
      summary: summary.map(OmnigentUIComponents.SessionSummary.init),
      turnStartedAt: store.turnTimer.startedAt)
    state.isHydrating = isHydrating(store)
    state.approvalModeTitle = approvalModeTitle(store)
    state.effortTitle = ComposerAdapter.configuration(store.composer).effortTitle
    return state
  }

  /// The conversation's state without its rows, for the screen around the transcript. It reads
  /// no rows or revision, so streamed deltas don't re-render the header, composer or panels;
  /// the transcript reads them through ``liveRows(_:)``.
  /// - Parameters:
  ///   - store: The conversation.
  ///   - summary: Its session-list row, for the title before the header arrives.
  /// - Returns: The state, with ``ConversationViewState/transcriptStatus`` in place of rows.
  static func screenState(
    _ store: ConversationStore, summary: OmnigentCoreFFI.SessionSummary?
  ) -> ConversationViewState {
    let header = Self.header(store, summary: summary)
    var state = ConversationViewState(
      header: header,
      decisions: store.decisions.cards.map(OmnigentUIComponents.DecisionCard.init),
      decisionPhases: decisionPhases(store.decisions),
      sections: store.sections.map(OmnigentUIComponents.EventSection.init),
      hasMoreHistory: store.hasOlderHistory, isLoadingHistory: isLoadingHistory(store),
      errorMessage: errorMessage(store),
      connectionStatus: connectionStatus(store),
      turnDurations: store.turnTimer.durations,
      summary: summary.map(OmnigentUIComponents.SessionSummary.init),
      turnStartedAt: store.turnTimer.startedAt)
    let digest = store.transcriptDigest
    state.transcriptStatus = TranscriptStatus(
      isEmpty: digest.isEmpty, lastInterrupted: digest.lastInterrupted,
      activityTitle: digest.activityTitle)
    state.isHydrating = isHydrating(store)
    state.approvalModeTitle = approvalModeTitle(store)
    state.effortTitle = ComposerAdapter.configuration(store.composer).effortTitle
    return state
  }

  /// The session's status line (``SessionStatusLine``). It reads only the header, decisions,
  /// sections and transcript digest, so a view showing it (the tab strip's tooltip) does not
  /// redraw for the turn timer, the link or history paging.
  /// - Parameters:
  ///   - store: The conversation.
  ///   - summary: Its session-list row, for the title before the header arrives.
  /// - Returns: The line.
  static func statusLine(
    _ store: ConversationStore, summary: OmnigentCoreFFI.SessionSummary?
  ) -> SessionStatusLine {
    let header = Self.header(store, summary: summary)
    var state = ConversationViewState(
      header: header,
      decisions: store.decisions.cards.map(OmnigentUIComponents.DecisionCard.init),
      decisionPhases: decisionPhases(store.decisions),
      sections: store.sections.map(OmnigentUIComponents.EventSection.init))
    let digest = store.transcriptDigest
    state.transcriptStatus = TranscriptStatus(
      isEmpty: digest.isEmpty, lastInterrupted: digest.lastInterrupted,
      activityTitle: digest.activityTitle)
    return SessionStatusLine(state)
  }

  /// The store's header, or a placeholder titled from the session-list row until it arrives.
  private static func header(
    _ store: ConversationStore, summary: OmnigentCoreFFI.SessionSummary?
  ) -> OmnigentUIComponents.SessionHeader {
    store.header.map(OmnigentUIComponents.SessionHeader.init)
      ?? OmnigentUIComponents.SessionHeader(
        id: store.sessionID, title: summary?.title ?? "Loading\u{2026}")
  }

  /// A page of older history is in flight.
  static func isLoadingHistory(_ store: ConversationStore) -> Bool {
    store.isLoadingOlderHistory
  }

  /// The first read is in flight and no row has arrived: the transcript says it is loading
  /// rather than offering an empty session.
  static func isHydrating(_ store: ConversationStore) -> Bool {
    !store.isHydrated && !store.isClosed && store.transcriptDigest.isEmpty
  }

  /// What the composer's chip calls the session's approval mode.
  static func approvalModeTitle(_ store: ConversationStore) -> String? {
    store.composer.approvalModeMenu.flatMap { ComposerAdapter.approvalModes($0).selected?.label }
  }

  /// Reads the store's rows inside the transcript's body.
  /// - Parameter store: The conversation.
  /// - Returns: The reader.
  static func liveRows(_ store: ConversationStore) -> LiveTranscriptRows {
    LiveTranscriptRows {
      (store.displayRows.map(OmnigentUIComponents.Row.init), store.displayRevision)
    }
  }

  /// The newest failure to show. Stream and transport failures describe a connection problem,
  /// which the connection line under the composer shows while it lasts and which is history once
  /// the stream is live, so neither is a card. Every other failure stays until dismissed.
  static func errorMessage(_ store: ConversationStore) -> String? {
    let current = store.errors.last { error in
      switch error {
      case .Link, .Transport: false
      default: true
      }
    }
    return current?.message ?? store.lastFailure
  }

  /// An answer given here shows on its card from the tap until the server retires the card, and
  /// a failed answer keeps its message, so a card never reads as pending while its answer is out.
  static func decisionPhases(_ decisions: DecisionStore) -> [String: DecisionPhase] {
    var phases: [String: DecisionPhase] = [:]
    for (id, error) in decisions.errors {
      phases[id] = .failed(message: error.message)
    }
    for (id, answer) in decisions.answers {
      phases[id] = .answered(summary: OmnigentUIComponents.DecisionResponse(answer).summary)
    }
    return phases
  }

  /// A line for the stream's state when it is not live, `nil` while live.
  static func connectionStatus(_ store: ConversationStore) -> String? {
    if store.isClosed { return "This session is no longer available." }
    if let target = store.supersededBy { return "This conversation continues in \(target)." }
    switch store.link {
    case .live: return nil
    case .idle, .connecting: return "Connecting\u{2026}"
    case .reconnecting(let reason, let failures, let delayMs):
      let seconds = max(1, Int((Double(delayMs) / 1_000).rounded()))
      let attempt = failures > 1 ? " (attempt \(failures))" : ""
      return "Reconnecting in \(seconds)s\(attempt): \(reason.message)"
    case .closed: return "The stream closed."
    case .stopped: return "Disconnected."
    case .failed(let error): return "The stream failed: \(error.message)"
    }
  }
}
