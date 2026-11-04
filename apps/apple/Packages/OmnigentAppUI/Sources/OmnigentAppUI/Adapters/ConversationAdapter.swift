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
    let header =
      store.header.map(OmnigentUIComponents.SessionHeader.init)
      ?? OmnigentUIComponents.SessionHeader(
        id: store.sessionID, title: summary?.title ?? "Loading\u{2026}")
    return ConversationViewState(
      revision: store.revision, header: header,
      rows: store.rows.map(OmnigentUIComponents.Row.init),
      decisions: store.decisions.cards.map(OmnigentUIComponents.DecisionCard.init),
      decisionPhases: decisionPhases(store.decisions),
      sections: store.sections.map(OmnigentUIComponents.EventSection.init),
      isLoadingHistory: !store.isHydrated && !store.isClosed,
      errorMessage: errorMessage(store),
      connectionStatus: connectionStatus(store),
      turnDurations: store.turnTimer.durations,
      summary: summary.map(OmnigentUIComponents.SessionSummary.init),
      turnStartedAt: store.turnTimer.startedAt)
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
    let header =
      store.header.map(OmnigentUIComponents.SessionHeader.init)
      ?? OmnigentUIComponents.SessionHeader(
        id: store.sessionID, title: summary?.title ?? "Loading\u{2026}")
    var state = ConversationViewState(
      header: header,
      decisions: store.decisions.cards.map(OmnigentUIComponents.DecisionCard.init),
      decisionPhases: decisionPhases(store.decisions),
      sections: store.sections.map(OmnigentUIComponents.EventSection.init),
      isLoadingHistory: !store.isHydrated && !store.isClosed,
      errorMessage: errorMessage(store),
      connectionStatus: connectionStatus(store),
      turnDurations: store.turnTimer.durations,
      summary: summary.map(OmnigentUIComponents.SessionSummary.init),
      turnStartedAt: store.turnTimer.startedAt)
    let digest = store.transcriptDigest
    state.transcriptStatus = TranscriptStatus(
      isEmpty: digest.isEmpty, lastInterrupted: digest.lastInterrupted,
      activityTitle: digest.activityTitle)
    return state
  }

  /// Reads the store's rows inside the transcript's body.
  /// - Parameter store: The conversation.
  /// - Returns: The reader.
  static func liveRows(_ store: ConversationStore) -> LiveTranscriptRows {
    LiveTranscriptRows { (store.rows.map(OmnigentUIComponents.Row.init), store.revision) }
  }

  /// The newest failure to show. Stream and transport failures describe a connection problem,
  /// which the connection line covers while it lasts; once the stream is live again they are
  /// history, not a current error. Every other failure stays until dismissed.
  static func errorMessage(_ store: ConversationStore) -> String? {
    let live = store.link == .live
    let current = store.errors.last { error in
      switch error {
      case .Link, .Transport: !live
      default: true
      }
    }
    return current?.message ?? store.lastFailure
  }

  /// Answers in flight show as resolving and failed answers keep their message, so a pending
  /// card is never hidden behind a stale state.
  static func decisionPhases(_ decisions: DecisionStore) -> [String: DecisionPhase] {
    var phases: [String: DecisionPhase] = [:]
    for (id, error) in decisions.errors {
      phases[id] = .failed(message: error.message)
    }
    for id in decisions.resolving {
      phases[id] = .resolving
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
