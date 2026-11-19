import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents

/// The models an automation's harness can pick where it runs: its host's list, or a new
/// sandbox's preview (the catalog half of the web's `useScheduledHarnessSettings`).
struct AutomationModelCatalog: Equatable {
  /// The rows to offer.
  var listed: [ModelChoice] = []
  /// The harness takes a model where the automation runs.
  var takesModel: Bool
  /// The harness whose effort ladder applies; a gateway catalog's models carry their own.
  var effortHarness: String
  /// Claude Code's aliases stand in for an empty list.
  var offersClaudeAliases = false
  /// The list is being read.
  var isLoading = false
  /// The list could not be read.
  var failed = false
  /// The host is offline, so it can't list models.
  var hostOffline = false
  /// Why the harness can't run there at all; it blocks Save.
  var blockedReason: String?

  /// What `agent` can pick on `hostID`, or on a new sandbox of the server's default provider.
  static func resolve(
    pages: PagesStore, agent: OmnigentCoreFFI.CreationAgent, hostID: String, inSandbox: Bool
  )
    -> Self
  {
    let harness = agent.harnessId
    let native = AutomationEditorMapping.modelHarnesses.contains(harness)
    guard inSandbox else {
      let load = pages.automationModels[PagesStore.modelsKey(agentID: agent.id, hostID: hostID)]
      let host = pages.automationCatalog.value?.hosts.first { $0.hostId == hostID }
      var catalog = Self(takesModel: native, effortHarness: harness)
      catalog.listed = (load?.value ?? []).filter { $0.hidden != true }
      catalog.offersClaudeAliases = harness == "claude-native"
      catalog.isLoading = load == .loading
      catalog.failed = load?.error != nil
      catalog.hostOffline = host?.status == "offline"
      return catalog
    }
    let server = pages.automationCatalog.value
    guard let provider = previewingProvider(server) else {
      // A provider without a catalog leaves the agent's own models.
      var catalog = Self(takesModel: native, effortHarness: harness)
      catalog.offersClaudeAliases = harness == "claude-native"
      return catalog
    }
    let load = pages.automationSandboxModels[
      PagesStore.sandboxModelsKey(agentID: agent.id, provider: provider)]
    let preview = load?.value
    // An unavailable preview says nothing about what the sandbox takes.
    let authoritative = preview.map { $0.status != .unavailable } ?? false
    let gatewayDefaults =
      server?.defaultModelProviders.contains(provider) == true
      && !(authoritative && preview?.status == .unconfigured)
    let configured = authoritative && preview?.configured == true
    var catalog = Self(
      takesModel: native || gatewayDefaults || configured,
      effortHarness: gatewayDefaults ? "codex-native" : harness)
    catalog.listed = authoritative && preview?.status == .ready ? preview?.models ?? [] : []
    catalog.isLoading = load == .loading
    catalog.failed = load?.error != nil || preview?.status == .unavailable
    if preview?.status == .unsupported {
      catalog.blockedReason =
        preview?.error
        ?? "No models are available for \(agent.name) in this sandbox. Choose another harness."
    }
    return catalog
  }

  /// The provider of a new sandbox, when it previews a model catalog.
  static func previewingProvider(_ server: OmnigentCoreFFI.CreationCatalog?) -> String? {
    guard let provider = server?.defaultSandboxProvider,
      server?.modelPreviewProviders.contains(provider) == true
    else { return nil }
    return provider
  }

  /// Shown when the harness takes a model but none is listed.
  var emptyMessage: String {
    if hostOffline { return "Connect your host to load models." }
    if isLoading { return "Loading models\u{2026}" }
    if failed { return "Could not load models. Default uses the agent\u{2019}s configuration." }
    return "No model choices are available. Default uses the agent\u{2019}s configuration."
  }
}

/// Where an automation's models are read from: its host, or a new sandbox's provider.
struct AutomationModelSource: Hashable {
  /// The agent.
  let agentID: String
  /// Its harness.
  let harness: String
  /// The host; empty for a sandbox.
  let hostID: String
  /// The sandbox provider; `nil` for a host.
  let provider: String?

  /// What `draft`'s Advanced section lists models from, when its harness can take one there.
  static func of(_ draft: AutomationDraftState, pages: PagesStore) -> Self? {
    let server = pages.automationCatalog.value
    guard let agent = server?.agents.first(where: { $0.id == draft.agentID }) else { return nil }
    if draft.runsInSandbox {
      return AutomationModelCatalog.previewingProvider(server).map {
        Self(agentID: agent.id, harness: agent.harnessId, hostID: "", provider: $0)
      }
    }
    guard !draft.hostID.isEmpty, AutomationEditorMapping.takesModel(server, agentID: agent.id)
    else { return nil }
    return Self(agentID: agent.id, harness: agent.harnessId, hostID: draft.hostID, provider: nil)
  }

  /// Reads the models, unless they are loaded or loading.
  func load(_ pages: PagesStore) async {
    if let provider {
      await pages.loadAutomationSandboxModels(
        agentID: agentID, harness: harness, provider: provider)
    } else {
      await pages.loadAutomationModels(agentID: agentID, hostID: hostID)
    }
  }
}
