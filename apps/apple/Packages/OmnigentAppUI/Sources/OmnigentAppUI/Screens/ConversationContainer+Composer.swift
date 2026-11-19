import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents

/// The composer's session tools: side chats, goals, PR review comments and the liveness row.
extension ConversationContainer {
  var extras: ComposerExtraActions {
    let conversation = conversation
    var extras = ComposerAdapter.extras(
      conversation.composer, isRunning: { conversation.isRunning }, reconnect: retry,
      prompts: { ComposerAdapter.prompts(conversation) })
    SessionToolsAdapter.add(to: &extras, store: conversation, summary: summary, routes: toolRoutes)
    if let panel {
      let composer = conversation.composer
      let showPullRequests = toolRoutes.showPullRequests
      extras.openReviewComment = { id in
        guard let comment = composer.reviewComments.first(where: { $0.id == id }) else { return }
        showPullRequests()
        Task { await panel.revealLocalComment(comment) }
      }
      extras.deleteReviewComment = { id in Task { await panel.deleteLocalComment(id) } }
    }
    extras.liveness.fork = forkSession
    addHostMoves(to: &extras.liveness, sheets: livenessSheets)
    return extras
  }
}
