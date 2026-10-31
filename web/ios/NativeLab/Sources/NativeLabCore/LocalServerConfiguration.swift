import Foundation

extension LocalServerSessionClient {
  public func configurationSnapshot(_ id: String) async throws -> SessionSummary {
    try requireConnection()
    try validateIdentifier(id)
    let epoch = configurationEpochs[id, default: 0]
    let generation = streamGeneration
    let wire: SessionWire = try await get(
      path: "/v1/sessions/\(id)",
      query: [URLQueryItem(name: "include_items", value: "false")])
    guard wire.id == id else { throw LocalServerClientError.malformedResponse }
    guard epoch == configurationEpochs[id, default: 0] else {
      throw ConfigurationError.changedElsewhere
    }
    guard generation == streamGeneration else { throw LocalServerClientError.streamNotReady }
    let summary = try wire.summary(previous: summaries[id])
    return acceptConfigurationSummary(summary)
  }

  public func configurationCatalog(sessionID: String) async throws -> ConfigurationCatalog {
    let summary = try await configurationSnapshot(sessionID)
    struct Hosts: Decodable { let hosts: [ConfigurationHost] }
    let hosts: Hosts = try await get(path: "/v1/hosts")
    var agents: [HarnessChoice] = []
    var after: String?
    var cursors = Set<String>()
    repeat {
      let page: PageWire<HarnessChoice> = try await get(
        path: "/v1/agents", query: pageQuery(after: after, limit: 1000))
      agents += page.data
      after = try page.nextCursor(after: after)
      if let after, !cursors.insert(after).inserted {
        throw LocalServerClientError.invalidPagination
      }
    } while after != nil
    var seen = Set<String>()
    var catalog = ConfigurationCatalog(
      agents: agents.filter { $0.builtin == true && seen.insert($0.id).inserted },
      host: hosts.hosts.first { $0.hostID == summary.configuration?.hostID })
    if let current = summary.configuration, current.models.isEmpty,
      current.supportsModels, catalog.host?.status == "online"
    {
      do {
        catalog.modelOptions = try await hostModelOptions(for: current)
        catalog.modelOptionsIdentity = current
      } catch {
        if error as? LocalServerClientError == .unauthorized { throw error }
        catalog.modelOptionsError = error.localizedDescription
      }
    }
    return catalog
  }

  public func applyConfiguration(_ edit: ConfigurationEdit, sessionID: String) async throws
    -> SessionSummary
  {
    guard configurationMutations.insert(sessionID).inserted else { throw SessionClientError.busy }
    defer { configurationMutations.remove(sessionID) }
    var summary = try await configurationSnapshot(sessionID)
    try configurationMutationAllowed(summary)
    guard var current = summary.configuration else {
      throw ConfigurationError.unavailable("Settings are unavailable.")
    }
    if current.models.isEmpty && edit.hasChanges && current.supportsModels {
      let epoch = configurationEpochs[sessionID, default: 0]
      current.models = try await hostModelOptions(for: current)
      guard epoch == configurationEpochs[sessionID, default: 0] else {
        throw ConfigurationError.changedElsewhere
      }
      try configurationMutationAllowed(summary)
    }
    try edit.validate(against: current)
    var savedModel = false
    var attemptedMutation = false
    defer { if attemptedMutation { rehydrateAfterMutation(sessionID: sessionID) } }
    do {
      // Serialize native slash-command forwarding: model first, then effort.
      if edit.model != current.modelOverride {
        attemptedMutation = true
        summary = try await patchConfiguration(
          sessionID, field: "model_override", value: edit.model)
        savedModel = true
      }
      if edit.effort != current.effort {
        let latest = try await configurationSnapshot(sessionID)
        try configurationMutationAllowed(latest)
        guard let actual = latest.configuration, let acknowledged = summary.configuration,
          actual.sameSelection(as: acknowledged)
        else { throw ConfigurationError.changedElsewhere }
        attemptedMutation = true
        summary = try await patchConfiguration(
          sessionID, field: "reasoning_effort", value: edit.effort)
      }
    } catch {
      // A later rejection must not make an already-saved model look rolled back.
      if savedModel { throw LocalServerClientError.deliveryUncertain }
      throw error
    }
    return summary
  }

  public func switchHarness(
    to targetID: String, baseline: SessionConfiguration, sessionID: String
  ) async throws -> SessionSummary {
    guard configurationMutations.insert(sessionID).inserted else { throw SessionClientError.busy }
    defer { configurationMutations.remove(sessionID) }
    try validateIdentifier(targetID)
    let catalog = try await configurationCatalog(sessionID: sessionID)
    let summary = try await configurationSnapshot(sessionID)
    try configurationMutationAllowed(summary)
    guard let current = summary.configuration, baseline.sameSelection(as: current) else {
      throw ConfigurationError.changedElsewhere
    }
    guard let target = catalog.agents.first(where: { $0.id == targetID }) else {
      throw ConfigurationError.unavailable("This harness is no longer in the server catalog.")
    }
    if let reason = catalog.unavailableReason(for: target, current: current) {
      throw ConfigurationError.unavailable(reason)
    }
    defer { rehydrateAfterMutation(sessionID: sessionID) }
    let epoch = configurationEpochs[sessionID, default: 0]
    let wire: SessionWire = try await mutation(
      path: "/v1/sessions/\(sessionID)/switch-agent",
      body: .object(["agent_id": .string(targetID)]))
    guard wire.id == sessionID else { throw LocalServerClientError.deliveryUncertain }
    let updated: SessionSummary
    do {
      updated =
        epoch == configurationEpochs[sessionID, default: 0]
        ? try wire.summary(previous: nil) : try await configurationSnapshot(sessionID)
    } catch { throw LocalServerClientError.deliveryUncertain }
    guard let actual = updated.configuration,
      actual.agentID != nil, actual.agentID != baseline.agentID,
      SessionConfiguration.canonicalHarness(actual.harness)
        == SessionConfiguration.canonicalHarness(target.harness)
    else { throw LocalServerClientError.deliveryUncertain }
    return acceptConfigurationSummary(updated)
  }

  private func configurationMutationAllowed(_ summary: SessionSummary) throws {
    if summary.isReadOnly { throw SessionClientError.readOnly }
    if summary.isArchived { throw SessionClientError.archived }
    if summary.status != .idle { throw SessionClientError.busy }
    guard watchedSessionID == summary.id, streamReady else {
      throw LocalServerClientError.streamNotReady
    }
    let config = summary.configuration
    guard config?.hostOnline == true || config?.runnerOnline == true else {
      throw ConfigurationError.unavailable("Reconnect the session's host before changing settings.")
    }
  }

  private func patchConfiguration(_ id: String, field: String, value: String?) async throws
    -> SessionSummary
  {
    let epoch = configurationEpochs[id, default: 0]
    let wire: SessionWire = try await mutation(
      path: "/v1/sessions/\(id)", method: "PATCH",
      body: .object([field: .string(value ?? "default")]))
    guard wire.id == id else { throw LocalServerClientError.deliveryUncertain }
    let summary: SessionSummary
    do {
      summary =
        epoch == configurationEpochs[id, default: 0]
        ? try wire.summary(previous: summaries[id]) : try await configurationSnapshot(id)
    } catch { throw LocalServerClientError.deliveryUncertain }
    guard let actual = summary.configuration,
      field == "model_override" ? modelAcknowledged(value, by: actual) : actual.effort == value
    else { throw LocalServerClientError.deliveryUncertain }
    return acceptConfigurationSummary(summary)
  }

  private func modelAcknowledged(_ expected: String?, by actual: SessionConfiguration) -> Bool {
    actual.modelOverride == expected
      || (expected != nil && actual.modelOverride != nil
        && actual.models.contains { $0.matches(expected) && $0.matches(actual.modelOverride) })
  }

  private func hostModelOptions(for configuration: SessionConfiguration) async throws
    -> [ModelChoice]
  {
    guard configuration.hostOnline == true, let hostID = configuration.hostID,
      configuration.supportsModels
    else {
      throw ConfigurationError.unavailable("The host must be online to preview model choices.")
    }
    let harness = SessionConfiguration.canonicalHarness(configuration.harness)
    try validateIdentifier(hostID)
    try validateIdentifier(harness)
    struct Response: Decodable { let models: [ModelChoice] }
    let response: Response = try await get(
      path: "/v1/hosts/\(hostID)/harnesses/\(harness)/model-options")
    var seen = Set<String>()
    return response.models.filter { !$0.id.isEmpty && seen.insert($0.id).inserted }
  }

  private func acceptConfigurationSummary(_ value: SessionSummary) -> SessionSummary {
    let summary = recordConfigurationSummary(value)
    if watchedSessionID == summary.id {
      // A stable snapshot supersedes setting events buffered before its read.
      bufferedEvents.removeAll {
        [
          "session.model", "session.reasoning_effort", "session.model_options",
          "session.agent_changed",
        ]
        .contains($0["type"]?.string ?? "")
      }
    }
    cacheSummary(summary)
    if reducer?.snapshot.id == summary.id {
      publishSnapshot()
    }
    emit(.sessionsChanged([summary]))
    return summary
  }
}
