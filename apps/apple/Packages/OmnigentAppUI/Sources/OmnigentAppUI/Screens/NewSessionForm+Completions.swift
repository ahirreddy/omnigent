import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents

/// Where the new-session composer discovers skills, and why it cannot yet (the web's words).
struct LaunchSkillsRequest: Hashable {
  var target: LaunchCompletionsStore.Target?
  var unavailable: String?
}

extension NewSessionForm {
  /// The skills to discover for the chosen host, folder and harness, as on the web's launcher.
  func skillsRequest(_ creation: CreationStore) -> LaunchSkillsRequest {
    if isSandbox {
      return LaunchSkillsRequest(
        unavailable: "Host skills will be available after the sandbox starts.")
    }
    if startsPendingAgent {
      return LaunchSkillsRequest(
        unavailable: "Skills will be available after this session starts.")
    }
    let host = creation.catalog.value?.hosts.first { $0.hostId == selection.hostId }
    guard let host else {
      return LaunchSkillsRequest(unavailable: "Choose a host to discover skills.")
    }
    guard host.status == "online" else {
      return LaunchSkillsRequest(unavailable: "Skills unavailable while the host is offline.")
    }
    guard selection.workspace.hasPrefix("/") else {
      return LaunchSkillsRequest(unavailable: "Choose a working directory to discover skills.")
    }
    guard let harness = setupHarness(creation) else {
      return LaunchSkillsRequest(unavailable: "Choose a harness to discover host skills.")
    }
    return LaunchSkillsRequest(
      target: LaunchCompletionsStore.Target(
        hostID: host.hostId, harness: harness, agentID: selection.agentId,
        folder: selection.workspace))
  }

  /// The folder the `@` menu browses: native coding agents on a host with an absolute folder,
  /// as on the web; `nil` turns mentions off.
  func mentionTarget(_ creation: CreationStore) -> LaunchCompletionsStore.Target? {
    guard let target = skillsRequest(creation).target,
      let harness = target.harness, harness.hasSuffix("-native") || harness.hasPrefix("native-")
    else { return nil }
    return target
  }

  /// The composer's `/` skills, `@` rows and tagged paths from `launch`.
  func applyCompletions(_ launch: LaunchCompletionsStore?, to state: inout ComposerViewState) {
    guard let launch else { return }
    state.slashCommands = launch.skills.map(ComposerAdapter.slashCommand)
    state.slashCommandsNote = launch.skillsNote
    state.mentionCandidates = launch.mentionCandidates
    state.mentionsNote = launch.mentionProblem
    state.mentions = launch.mentions
  }
}
