import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents

extension NewSessionForm {
  /// The composer in start mode: the agent grouped as on the web, the model and effort, the
  /// host (or a new sandbox), the approval mode, attachments and where it will run.
  func composerState(
    _ creation: CreationStore, connection: ConnectionStore, submitWithCommandReturn: Bool = false
  ) -> ComposerViewState {
    let catalog = creation.catalog.value
    let hostID =
      isSandbox
      ? NewSessionAdapter.sandboxHostID(sandbox.option(catalog)?.provider) : selection.hostId
    let agents = catalog.map { NewSessionAdapter.agents($0, hostID: hostID) }
    let agent = selectedAgent(creation)
    var configuration = ComposerConfiguration(
      harness: agent?.harness, agentName: agent?.name,
      harnessChoices: (agents?.choices ?? []) + (pendingChoice.map { [$0] } ?? []),
      selectedAgentId: selection.agentId,
      modelOptions: isSandbox || startsPendingAgent
        ? [] : NewSessionAdapter.models(creation.models.value ?? []),
      selectedModelId: selection.model, selectedEffort: selection.reasoningEffort)
    configuration.agentGroups = agents?.groups ?? [:]
    if pendingChoice != nil { configuration.agentGroups[Self.pendingAgentID] = .custom }
    var state = ComposerViewState(
      availability: availability(creation), delivery: delivery(creation.phase),
      attachments: attachmentChips(creation), acceptsAttachments: !isSandbox,
      configuration: configuration,
      placeholder: "Describe what to build\u{2026}",
      hosts: ComposerHosts(hosts: NewSessionAdapter.hosts(catalog), selectedID: hostID),
      approvalModes: NewSessionAdapter.approvalModes(agent, selected: selection.approvalMode),
      purpose: .start, context: context(creation, connection: connection))
    state.submitWithCommandReturn = submitWithCommandReturn
    return state
  }

  /// Where the session will run, and why it cannot, before the first send.
  private func context(_ creation: CreationStore, connection: ConnectionStore) -> ExecutionContext {
    let catalog = creation.catalog.value
    let host = catalog?.hosts.first { $0.hostId == selection.hostId }
    let agent = selectedAgent(creation)
    let server = connection.connectedServer
    return ExecutionContext(
      agent: agent?.name, harness: agent?.harness,
      host: isSandbox
        ? sandbox.option(catalog)?.label ?? "New Sandbox"
        : ExecutionContext.hostDisplayName(host?.name),
      hostKind: isSandbox || host?.sandboxProvider != nil ? .cloud : .machine,
      isHostOnline: isSandbox ? true : host.map { $0.status == "online" },
      server: ExecutionContext.serverDisplayName(
        name: server?.serverName, baseURL: server?.baseUrl),
      directory: isSandbox || selection.workspace.isEmpty ? nil : selection.workspace,
      sandbox: isSandbox
        ? "Managed sandbox \u{00B7} \(sandbox.option(catalog)?.provider ?? "server default")"
        : host.map {
          $0.sandboxProvider.map { "Managed sandbox \u{00B7} \($0)" } ?? "None (runs on the host)"
        },
      unavailableReason: isSandbox || startsPendingAgent
        ? nil
        : catalog.flatMap {
          creationUnavailableReason(
            catalog: $0, agentId: selection.agentId, hostId: selection.hostId)
        })
  }

  private func availability(_ creation: CreationStore) -> ComposerAvailability {
    switch creation.catalog {
    case .idle, .loading: return .unavailable(reason: "Loading hosts and agents\u{2026}")
    case .failed(let error): return .unavailable(reason: error.message)
    case .loaded:
      if isSandbox {
        if selectedAgent(creation) == nil || startsPendingAgent {
          return .unavailable(reason: "Choose an agent.")
        }
        let problem = sandbox.problem(creation.catalog.value, sandboxes: sandboxes)
        return problem.map { .unavailable(reason: $0) } ?? .available
      }
      if startsPendingAgent {
        return pendingAgentProblem(creation).map { .unavailable(reason: $0) } ?? .available
      }
      if selection.workspace.isEmpty {
        return .unavailable(reason: "Choose the folder the session works in.")
      }
      return creation.unavailableReason(selection).map { .unavailable(reason: $0) } ?? .available
    }
  }

  private func delivery(_ phase: OmnigentStores.CreationPhase) -> DeliveryState {
    if let attachmentError, phase == .editing { return .failed(message: attachmentError) }
    return switch phase {
    case .editing: .idle
    case .creating: .sending
    case .failed(let error): .failed(message: error.message)
    case .uncertain(let error):
      .uncertain(
        message: "The session may have been created: \(error.message) Check Sessions first.")
    case .created(_, nil): .idle
    case .created(_, .some(let error)):
      .failed(message: "The session was created, but the first message failed: \(error.message)")
    }
  }
}
