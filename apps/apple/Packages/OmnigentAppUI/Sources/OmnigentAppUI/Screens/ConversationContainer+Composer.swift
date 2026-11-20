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
    if !ComposerAdapter.isReadOnly(conversation), let workflows {
      extras.runWorkflow = WorkflowComposerAdapter.runSource(
        composer: conversation.composer, store: workflows.store, sharing: workflows.sharing,
        blockedReason: { TasksAdapter.blockedReason(conversation) })
    }
    extras.liveness.fork = forkSession
    addHostMoves(to: &extras.liveness, sheets: livenessSheets)
    let signInOpener = signInOpener
    let serverURL = server?.baseUrl
    var openSettings: (@MainActor (ServerSettingsPane) -> Void)?
    var openHarness: (@MainActor (HarnessSettingsFocus) -> Void)?
    if let openSettingsAt {
      openSettings = { pane in openSettingsAt(.server(url: serverURL, pane: pane)) }
      openHarness = { focus in openSettingsAt(.harness(url: serverURL, focus: focus)) }
    }
    extras.dismissQuickAnswer = ComposerAdapter.dismissQuickAnswer(conversation)
    extras.mcp = ComposerAdapter.mcpActions(
      conversation.composer.mcp, signIn: { url in Task { _ = await signInOpener.open(url) } },
      openSettings: openSettings, openHarness: openHarness)
    return extras
  }

  /// The session menu's Fork copies the whole session.
  func forkable(_ actions: SessionListActions) -> SessionListActions {
    var actions = actions
    if let fork = forkSession { actions.fork = { _ in fork() } }
    return actions
  }
}
