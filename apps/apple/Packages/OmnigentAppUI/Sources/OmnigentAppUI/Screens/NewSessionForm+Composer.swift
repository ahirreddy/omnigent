import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents

extension NewSessionForm {
  /// The composer in start mode: the agent grouped as on the web, the model and effort, the
  /// host (or a new sandbox), the approval mode, attachments and where it will run.
  func composerState(
    _ creation: CreationStore, connection: ConnectionStore,
    launch: LaunchCompletionsStore? = nil, submitWithCommandReturn: Bool = false
  ) -> ComposerViewState {
    let catalog = creation.catalog.value
    let hostID =
      isSandbox
      ? NewSessionAdapter.sandboxHostID(sandbox.option(catalog)?.provider) : selection.hostId
    let agents = catalog.map {
      NewSessionAdapter.agents(
        $0, hostID: hostID,
        hidingUnconfigured: InterfacePreferences.read(
          InterfacePreferences.hideUnconfiguredHarnessesKey)
          ? selection.agentId : nil)
    }
    let agent = selectedAgent(creation)
    var configuration = ComposerConfiguration(
      harness: agent?.harness, agentName: agent?.name,
      harnessChoices: PickerVisibility.shown(
        agents?.choices ?? [], name: \.name, id: \.id, selectedID: selection.agentId,
        hidden: PickerVisibility.hidden()) + (pendingChoice.map { [$0] } ?? []),
      selectedAgentId: selection.agentId,
      modelOptions: startsPendingAgent
        ? [] : NewSessionAdapter.models(creation.models.value ?? []),
      selectedModelId: selection.model, selectedEffort: selection.reasoningEffort)
    configuration.agentGroups = agents?.groups ?? [:]
    configuration.smartRouting = smartRouting(catalog)
    if pendingChoice != nil { configuration.agentGroups[Self.pendingAgentID] = .custom }
    var state = ComposerViewState(
      availability: availability(creation), delivery: delivery(creation.phase),
      attachments: attachmentChips(creation), acceptsAttachments: !isSandbox,
      configuration: configuration,
      placeholder: placeholder,
      hosts: ComposerHosts(hosts: hostRows(creation), selectedID: hostID),
      approvalModes: NewSessionAdapter.approvalModes(agent, selected: selection.approvalMode),
      purpose: .start, context: context(creation, connection: connection))
    state.submitWithCommandReturn = submitWithCommandReturn
    state.sendsWithoutText = sendsWorkflowWithoutText
    applyCompletions(launch, to: &state)
    return state
  }

  /// The composer's prompt: a nested agent's, the project's, else the web's.
  private var placeholder: String {
    if nested != nil { return NestedComposer.placeholder }
    if let workflowPlaceholder { return workflowPlaceholder }
    return project.map { "Start a new session in \($0.name)" }
      ?? "Describe a task to start a new session\u{2026}"
  }

  /// The Host menu: what the server's policy offers a nested agent, else every row.
  private func hostRows(_ creation: CreationStore) -> [ComposerHost] {
    guard let choices = nestedChoices(creation) else {
      return NewSessionAdapter.hosts(creation.catalog.value).filter { row in
        NewSessionAdapter.sandboxProvider(hostID: row.id) != nil || offersMachine(row.id)
      }
    }
    return NewSessionAdapter.nestedHosts(creation.catalog.value, choices: choices)
  }

  /// Why the selected agent can't run on the selected host; a nested agent may reuse its
  /// source's sandbox host.
  private func hostProblem(_ catalog: OmnigentCoreFFI.CreationCatalog) -> String? {
    guard let nested else {
      return creationUnavailableReason(
        catalog: catalog, agentId: selection.agentId, hostId: selection.hostId)
    }
    return nestedUnavailableReason(
      catalog: catalog, agentId: selection.agentId, hostId: selection.hostId,
      sourceHostId: nested.sourceHostID)
  }

  /// Smart Routing's toggle, where the server routes the chosen agent's native pane (the web's
  /// per-harness eligibility). A new sandbox or an agent not yet registered has none.
  func smartRouting(_ catalog: OmnigentCoreFFI.CreationCatalog?) -> SmartRoutingState {
    guard !isSandbox, !startsPendingAgent, let catalog,
      creationOffersSmartRouting(catalog: catalog, agentId: selection.agentId)
    else { return .unavailable }
    return selection.smartRouting ? .enabled : .disabled
  }

  /// Where the session will run, and why it cannot, before the first send.
  private func context(_ creation: CreationStore, connection: ConnectionStore) -> ExecutionContext {
    let catalog = creation.catalog.value
    let host = catalog?.hosts.first { $0.hostId == selection.hostId }
    let agent = selectedAgent(creation)
    let server = connection.connectedServer
    return ExecutionContext(
      agent: nil, harness: agent?.harness,
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
      unavailableReason: isSandbox || startsPendingAgent ? nil : catalog.flatMap(hostProblem))
  }

  private func availability(_ creation: CreationStore) -> ComposerAvailability {
    switch creation.catalog {
    case .idle, .loading: return .unavailable(reason: "Loading hosts and agents\u{2026}")
    case .failed(let error): return .unavailable(reason: error.message)
    case .loaded:
      // Chosen MCP services wait for the registry, as the web's launch does.
      if nested == nil, let problem = mcpProblem(creation) {
        return .unavailable(reason: problem)
      }
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
      if needsHost(creation) {
        return .unavailable(reason: "Connect a host to run agents on.")
      }
      if selection.workspace.isEmpty {
        return .unavailable(reason: "Choose the folder the session works in.")
      }
      let problem =
        nested.map { creation.nestedUnavailableReason(selection, sourceHostID: $0.sourceHostID) }
        ?? creation.unavailableReason(selection)
      return problem.map { .unavailable(reason: $0) } ?? .available
    }
  }

  private func delivery(_ phase: OmnigentStores.CreationPhase) -> DeliveryState {
    if let error = attachmentError ?? projectError, phase == .editing {
      return .failed(message: error)
    }
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
