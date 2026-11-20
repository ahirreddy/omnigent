import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents

/// A new side chat's model and effort, chosen before its first message (web `SideChatSettings`
/// on a pending tab): the menus of the session it forks, with the tab's choice over them.
extension PendingSideChatTab {
  /// The settings; `nil` where the session's own agent forks the side chat, or the session
  /// offers no model menu.
  /// - Parameters:
  ///   - parent: The session the side chat forks.
  ///   - draft: The tab's draft, which holds the choice.
  ///   - update: Changes the draft.
  /// - Returns: The settings.
  static func settings(
    parent: ConversationStore, draft: SideChatDrafts.Draft,
    update: @escaping @MainActor ((inout SideChatDrafts.Draft) -> Void) -> Void
  ) -> PendingSideChatSettings? {
    let harness = parent.header?.settings?.harness
    guard sideChatStart(harness: harness, quote: nil).delivery == .forkThenSend else { return nil }
    let inherited =
      parent.composer.configuration == nil
      ? parent.header?.settings.map(ComposerAdapter.configuration)
      : ComposerAdapter.configuration(parent.composer)
    guard var configuration = inherited, !configuration.modelOptions.isEmpty else { return nil }
    configuration = choice(over: configuration, draft: draft)
    let options = configuration.modelOptions
    return PendingSideChatSettings(
      configuration: configuration,
      selectModel: { model in
        update { draft in
          draft.model = model
          // An effort the new model doesn't take goes back to the model's own.
          let efforts = options.first { $0.id == model }?.supportedReasoningEfforts ?? []
          if let effort = draft.effort, !efforts.contains(effort) { draft.effort = nil }
        }
      },
      selectEffort: { effort in update { $0.effort = effort } })
  }

  /// `configuration` with the tab's model and effort over the session's, and no harness or
  /// Smart Routing choice: the side chat runs the session's agent.
  static func choice(over configuration: ComposerConfiguration, draft: SideChatDrafts.Draft)
    -> ComposerConfiguration
  {
    var configuration = configuration
    configuration.harnessChoices = []
    configuration.smartRouting = .unavailable
    configuration.errorMessage = nil
    configuration.busyReason = nil
    configuration.isApplying = draft.isStarting
    if let model = draft.model { configuration.selectedModelId = model }
    if let effort = draft.effort { configuration.selectedEffort = effort }
    return configuration
  }
}
