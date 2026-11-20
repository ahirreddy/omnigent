import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents

/// The `/btw` answer over the composer, from the session's `quick-answer` section.
extension ComposerAdapter {
  /// The answer, until it is closed here.
  /// - Parameter store: The conversation.
  /// - Returns: The answer, or `nil`.
  static func quickAnswer(_ store: ConversationStore) -> ComposerQuickAnswer? {
    guard let section = store.sections.first(where: { $0.id == "quick-answer" }) else {
      return nil
    }
    func detail(_ id: String) -> String? { section.details.first { $0.id == id }?.text }
    let question = detail("question") ?? section.summary
    let answer = detail("answer") ?? ""
    let key = ComposerStore.quickAnswerKey(question: question, answer: answer)
    guard key != store.composer.dismissedQuickAnswer else { return nil }
    return ComposerQuickAnswer(
      question: question, answer: answer, isTruncated: detail("truncated") != nil)
  }

  /// Closes the answer shown now.
  /// - Parameter store: The conversation.
  /// - Returns: The action.
  static func dismissQuickAnswer(_ store: ConversationStore) -> @MainActor () -> Void {
    {
      guard let answer = quickAnswer(store) else { return }
      store.composer.dismissQuickAnswer(
        ComposerStore.quickAnswerKey(question: answer.question, answer: answer.answer))
    }
  }
}

/// A leading `!` in a native Claude Code or Codex session: the hint, and why a send is refused.
extension ComposerAdapter {
  /// The draft's shell hint, or `nil` when the draft is not a shell command.
  /// - Parameter store: The conversation.
  /// - Returns: The hint.
  static func shellHint(_ store: ConversationStore) -> ComposerShellHint? {
    store.composer.shellInput(permissionLevel: store.header?.permissionLevel).map {
      ComposerShellHint(refusal: $0.refusal)
    }
  }
}
