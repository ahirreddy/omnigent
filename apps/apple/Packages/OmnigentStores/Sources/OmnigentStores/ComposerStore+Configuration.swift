public import OmnigentCoreFFI

/// A harness the session may switch to, and why it cannot when it cannot.
public struct HarnessOption: Hashable, Sendable, Identifiable {
  /// The built-in agent.
  public let choice: HarnessChoice
  /// Why it cannot be selected now, or `nil` (the core's rule).
  public let unavailableReason: String?
  /// The session runs on it now.
  public let isCurrent: Bool

  /// The agent id.
  public var id: String { choice.id }
}

extension ComposerStore {
  /// The models to offer: the runner's, or the host's preview when the runner reported none.
  /// Hidden rows are excluded.
  public var modelChoices: [ModelChoice] {
    guard let configuration = effectiveConfiguration else { return [] }
    return configuration.models.filter { $0.hidden != true }
  }

  /// Efforts selectable with `model` (`nil`: the runner's default model). Empty when the
  /// session's wrapper does not forward effort changes.
  /// - Parameter model: The model's value, or `nil`.
  /// - Returns: The efforts, in the runner's order.
  public func efforts(for model: String?) -> [String] {
    guard let configuration = effectiveConfiguration else { return [] }
    return configurationEfforts(configuration: configuration, model: model)
  }

  /// The harnesses the session may switch to, each with the core's availability verdict.
  public var harnessOptions: [HarnessOption] {
    guard let catalog = configurationCatalog, let current = configuration else { return [] }
    return catalog.agents.map { choice in
      HarnessOption(
        choice: choice,
        unavailableReason: harnessSwitchUnavailableReason(
          catalog: catalog, target: choice, current: current),
        isCurrent: choice.id == current.agentId)
    }
  }

  /// Whether the harness has a runner-owned model picker.
  public var supportsModelChoice: Bool {
    configuration.map { configurationSupportsModels(configuration: $0) } ?? false
  }

  /// Whether the wrapper forwards reasoning-effort changes.
  public var supportsEffortChoice: Bool {
    configuration.map { configurationSupportsEffort(configuration: $0) } ?? false
  }

  /// The configuration with the host's model preview merged in when the runner reported none.
  var effectiveConfiguration: SessionConfiguration? {
    guard let configuration else { return nil }
    guard let catalog = configurationCatalog else { return configuration }
    return configurationWithCatalogModels(catalog: catalog, current: configuration)
  }

  /// Reads the session's configuration and what it may switch to. Failures are kept in
  /// ``configurationError``; a failed host model preview is in the catalog's
  /// `modelOptionsError` and does not hide the harness list.
  public func loadConfiguration() async {
    do {
      let summary = try await core.configurationSnapshot(sessionId: sessionID)
      adopt(summary)
      configurationCatalog = try await core.configurationCatalog(sessionId: sessionID)
      configurationError = nil
    } catch {
      configurationError = coreError(error)
    }
  }

  /// Chooses `model` (`nil`: the harness default). The effort is kept when the new model
  /// supports it. Never retried; an uncertain outcome is in ``configurationError``.
  /// - Parameter model: The model's value.
  public func selectModel(_ model: String?) async {
    guard let baseline = effectiveConfiguration else {
      configurationError = .InvalidState(message: "Settings have not loaded yet.")
      return
    }
    let edit = configurationSelectModel(edit: configurationEdit(baseline: baseline), model: model)
    await apply(edit)
  }

  /// Chooses `effort` (`nil`: the harness default).
  /// - Parameter effort: The effort value.
  public func selectEffort(_ effort: String?) async {
    guard let baseline = effectiveConfiguration else {
      configurationError = .InvalidState(message: "Settings have not loaded yet.")
      return
    }
    var edit = configurationEdit(baseline: baseline)
    edit.effort = effort
    await apply(edit)
  }

  /// Switches the session in place to the built-in agent `agentID`, keeping its history.
  /// - Parameter agentID: The target agent.
  public func switchHarness(to agentID: String) async {
    guard let baseline = configuration else {
      configurationError = .InvalidState(message: "Settings have not loaded yet.")
      return
    }
    isApplyingConfiguration = true
    defer { isApplyingConfiguration = false }
    do {
      let summary = try await core.switchHarness(
        sessionId: sessionID, targetId: agentID, baseline: baseline)
      adopt(summary)
      configurationCatalog = try await core.configurationCatalog(sessionId: sessionID)
      configurationError = nil
    } catch {
      configurationError = coreError(error)
    }
  }

  /// Clears ``configurationError`` after the user has seen it.
  public func dismissConfigurationError() {
    configurationError = nil
  }

  private func apply(_ edit: ConfigurationEdit) async {
    isApplyingConfiguration = true
    defer { isApplyingConfiguration = false }
    do {
      let summary = try await core.applyConfiguration(sessionId: sessionID, edit: edit)
      adopt(summary)
      configurationError = nil
    } catch {
      configurationError = coreError(error)
    }
  }

  private func adopt(_ summary: SessionSummary) {
    configuration = summary.configuration
    configurationLabels = summary.configuration.map {
      OmnigentCoreFFI.configurationLabels(configuration: $0)
    }
  }
}
