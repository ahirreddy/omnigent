/// The `/btw` answer over the composer: closed here, it stays closed until another arrives,
/// and the session's terminal is told to close its own.
extension ComposerStore {
  /// What tells one answer from the next.
  /// - Parameters:
  ///   - question: The question.
  ///   - answer: The answer.
  /// - Returns: The key.
  public static func quickAnswerKey(question: String, answer: String) -> String {
    "\(question)\u{0}\(answer)"
  }

  /// Closes the answer `key` names and tells the terminal; its overlay also closes on the next
  /// message, so a failed post changes nothing the user sees.
  /// - Parameter key: The answer's ``quickAnswerKey(question:answer:)``.
  public func dismissQuickAnswer(_ key: String) {
    dismissedQuickAnswer = key
    let core = core
    let sessionID = sessionID
    Task { try? await core.dismissQuickAnswer(sessionId: sessionID) }
  }
}
