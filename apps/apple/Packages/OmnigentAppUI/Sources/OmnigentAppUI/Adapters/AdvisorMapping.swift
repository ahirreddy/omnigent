import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents

/// Omni Advisor's Settings state and actions over the connection's ``AdvisorStore``.
enum AdvisorMapping {
  /// The state; `nil` where the server doesn't offer the advisor.
  /// - Parameters:
  ///   - store: The connection's advisor.
  ///   - info: What the server offers and the caller may manage.
  /// - Returns: The state.
  static func state(_ store: AdvisorStore?, info: ServerSettingsInfo?) -> AdvisorViewState? {
    guard let store, let info, info.advisor else { return nil }
    let settings: AdvisorViewState.Settings =
      switch store.settings {
      case .loaded(let loaded):
        .ready(
          AdvisorSwitches(
            userOn: loaded.showsOn, workspaceEnabled: loaded.workspaceEnabled,
            canManageWorkspace: loaded.canManageWorkspace))
      case .failed: .failed
      case .idle, .loading: .loading
      }
    var prompt: AdvisorViewState.Prompt?
    if info.isAdmin || info.singleUser {
      prompt =
        switch store.prompt {
        case .loaded(let loaded): .ready(prompt: loaded.prompt, overridden: loaded.overridden)
        case .failed(let error): .failed(error.message)
        case .idle, .loading: .loading
        }
    }
    return AdvisorViewState(
      settings: settings, isSavingSwitch: store.isSavingSwitch,
      switchError: store.switchError?.message, prompt: prompt,
      isSavingPrompt: store.isSavingPrompt, promptError: store.promptError?.message,
      isRunning: store.isRunning, runSummary: store.runs?.summary,
      runError: store.runError?.message)
  }

  /// The actions over `store`.
  static func actions(_ store: AdvisorStore?) -> AdvisorActions {
    var actions = AdvisorActions()
    guard let store else { return actions }
    actions.setEnabled = { scope, enabled in
      Task { await store.setEnabled(scope == .user ? .me : .workspace, enabled) }
    }
    actions.retry = { Task { await store.loadSettings() } }
    actions.retryPrompt = { Task { await store.loadPrompt() } }
    actions.savePrompt = { text in await store.savePrompt(text)?.prompt }
    actions.run = { users in Task { await store.run(users) } }
    return actions
  }

  /// Reads what the advisor's panes show: the settings, and the prompt for those who manage it.
  /// - Parameters:
  ///   - store: The connection's advisor.
  ///   - info: What the server offers and the caller may manage.
  ///   - admin: Admin › General is showing, which holds the prompt.
  static func load(_ store: AdvisorStore?, info: ServerSettingsInfo?, admin: Bool) async {
    guard let store, let info, info.advisor else { return }
    await store.loadSettings()
    if admin, info.isAdmin || info.singleUser { await store.loadPrompt() }
  }
}
