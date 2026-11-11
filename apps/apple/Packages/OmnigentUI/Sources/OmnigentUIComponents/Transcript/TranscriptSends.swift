/// What the user has sent from here into one session, as the transcript compares it between
/// renders. Rows cannot say this: the user's own message and one that arrived from elsewhere
/// (another device, an agent's forward) look alike, and an echo replaces the row that was sent.
nonisolated struct TranscriptSends: Equatable {
  var sessionID: String
  var count: Int

  /// The sends of `state`'s session.
  init(_ state: ConversationViewState) {
    self.init(sessionID: state.header.id, count: state.sendCount)
  }

  init(sessionID: String, count: Int) {
    self.sessionID = sessionID
    self.count = count
  }

  /// Whether the user sent something since `previous`. Another session's count is not a send,
  /// nor is a count that fell (a conversation opened again).
  func hasNewSend(since previous: Self) -> Bool {
    sessionID == previous.sessionID && count > previous.count
  }
}

extension TranscriptScrollState {
  /// The user sent a message: the transcript follows its newest row again, wherever they were
  /// reading, until they scroll away from it.
  /// - Returns: Whether to scroll there now. A hidden tab's follower is put there as it shows.
  func userSent() -> Bool {
    follow.jumpToLatest()
    return !isHidden
  }
}
