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

/// The core's verdicts on a composer's configuration, recomputed only when the configuration,
/// catalog or skills change.
struct ConfigurationRules {
  var effective: SessionConfiguration?
  var modelChoices: [ModelChoice] = []
  var effortsByModel: [String?: [String]] = [:]
  var harnessOptions: [HarnessOption] = []
  var supportsModelChoice = false
  var supportsEffortChoice = false
  var supportsSteering = false
  var approvalModeMenu: ApprovalModeMenu?
  var executionUnavailableReason: String?
  var slashCommands: [SlashCommand] = []
  var offersSmartRouting = false

  init() {}

  init(
    configuration: SessionConfiguration?, catalog: ConfigurationCatalog?, skills: [Skill],
    options: SlashOptions
  ) {
    guard let configuration else { return }
    let effective =
      catalog.map { configurationWithCatalogModels(catalog: $0, current: configuration) }
      ?? configuration
    self.effective = effective
    modelChoices = effective.models.filter { $0.hidden != true }
    effortsByModel[nil] = configurationEfforts(configuration: effective, model: nil)
    for choice in modelChoices {
      effortsByModel[choice.value] = configurationEfforts(
        configuration: effective, model: choice.value)
    }
    if let catalog {
      harnessOptions = catalog.agents.map { choice in
        HarnessOption(
          choice: choice,
          unavailableReason: harnessSwitchUnavailableReason(
            catalog: catalog, target: choice, current: configuration),
          isCurrent: choice.id == configuration.agentId)
      }
    }
    supportsModelChoice = configurationSupportsModels(configuration: configuration)
    supportsEffortChoice = configurationSupportsEffort(configuration: configuration)
    supportsSteering = configurationSupportsSteering(configuration: configuration)
    approvalModeMenu = OmnigentCoreFFI.approvalModeMenu(configuration: configuration)
    executionUnavailableReason = OmnigentCoreFFI.executionUnavailableReason(
      configuration: configuration)
    slashCommands = OmnigentCoreFFI.slashCommands(
      configuration: configuration, skills: skills, options: options)
    offersSmartRouting = OmnigentCoreFFI.offersSmartRouting(
      configuration: configuration, options: options)
  }
}

extension ComposerStore {
  /// The models to offer: the runner's, or the host's preview when the runner reported none.
  /// Hidden rows are excluded.
  public var modelChoices: [ModelChoice] { rules.modelChoices }

  /// Efforts selectable with `model` (`nil`: the runner's default model). Empty when the
  /// session's wrapper does not forward effort changes.
  /// - Parameter model: The model's value, or `nil`.
  /// - Returns: The efforts, in the runner's order.
  public func efforts(for model: String?) -> [String] {
    if let cached = rules.effortsByModel[model] { return cached }
    guard let configuration = rules.effective else { return [] }
    return configurationEfforts(configuration: configuration, model: model)
  }

  /// The harnesses the session may switch to, each with the core's availability verdict.
  public var harnessOptions: [HarnessOption] { rules.harnessOptions }

  /// Whether the harness has a runner-owned model picker.
  public var supportsModelChoice: Bool { rules.supportsModelChoice }

  /// The session's approval modes and the current one; `nil` when its harness has no live
  /// switch.
  public var approvalModeMenu: ApprovalModeMenu? { rules.approvalModeMenu }

  /// Whether a message sent mid-turn steers the running turn.
  public var supportsSteering: Bool { rules.supportsSteering }

  /// Why nothing can run in this session now, or `nil` (the core's rule).
  public var executionUnavailableReason: String? { rules.executionUnavailableReason }

  /// Whether the wrapper forwards reasoning-effort changes.
  public var supportsEffortChoice: Bool { rules.supportsEffortChoice }

  /// The `/` menu: the built-ins this harness supports, then the session's skills.
  public var slashCommands: [SlashCommand] { rules.slashCommands }

  /// Whether the model picker offers Smart Routing for this session (the core's rule).
  public var offersSmartRouting: Bool { rules.offersSmartRouting }

  /// Smart Routing is on: the router picks the model and effort each turn.
  public var isSmartRoutingOn: Bool { configuration?.routingMode == "on" }

  /// The configuration with the host's model preview merged in when the runner reported none.
  var effectiveConfiguration: SessionConfiguration? { rules.effective }

  func refreshRules() {
    rules = ConfigurationRules(
      configuration: configuration, catalog: configurationCatalog, skills: skills,
      options: slashOptions)
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
    guard await stopRoutingForChoice() else { return }
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
    guard await stopRoutingForChoice() else { return }
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

  /// Switches the live approval mode to `value`, also while a turn runs. When the harness lands
  /// on another mode, that mode is read back and ``configurationError`` says so.
  /// - Parameter value: The mode's wire value.
  public func selectApprovalMode(_ value: String) async {
    isApplyingConfiguration = true
    defer { isApplyingConfiguration = false }
    do {
      adopt(try await core.setApprovalMode(sessionId: sessionID, value: value))
      configurationError = nil
    } catch {
      let failure = coreError(error)
      do {
        adopt(try await core.configurationSnapshot(sessionId: sessionID))
        configurationError = failure
      } catch {
        configurationError = .InvalidState(
          message:
            "\(failure.message) The current mode could not be read: \(coreError(error).message)")
      }
    }
  }

  /// Turns Smart Routing on or off. Never retried; an uncertain outcome is in
  /// ``configurationError``.
  /// - Parameter enabled: Whether the router picks the model and effort.
  public func setSmartRouting(_ enabled: Bool) async {
    isApplyingConfiguration = true
    defer { isApplyingConfiguration = false }
    do {
      adopt(try await core.setSmartRouting(sessionId: sessionID, enabled: enabled))
      configurationError = nil
    } catch {
      configurationError = coreError(error)
    }
  }

  /// A model or effort chosen while Smart Routing is on pins it, as on the web: routing turns
  /// off first. Returns whether the choice can go ahead.
  private func stopRoutingForChoice() async -> Bool {
    guard isSmartRoutingOn else { return true }
    await setSmartRouting(false)
    return configurationError == nil
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
    workspace = summary.workspace
    configurationLabels = summary.configuration.map {
      OmnigentCoreFFI.configurationLabels(configuration: $0)
    }
  }
}
