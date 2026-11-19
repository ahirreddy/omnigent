import Foundation
import OmnigentCoreFFI

/// The models an automation's harness can pick: a host's, or a new sandbox's preview.
extension PagesStore {
  /// The ``automationModels`` key of an agent on a host.
  public static func modelsKey(agentID: String, hostID: String) -> String {
    "\(agentID)\n\(hostID)"
  }

  /// The ``automationSandboxModels`` key of an agent on a new sandbox of `provider`.
  public static func sandboxModelsKey(agentID: String, provider: String) -> String {
    "\(agentID)\n\(provider)"
  }

  /// Reads the models `hostID` offers `agentID`, unless they are loaded or loading.
  public func loadAutomationModels(agentID: String, hostID: String) async {
    let key = Self.modelsKey(agentID: agentID, hostID: hostID)
    switch automationModels[key] {
    case .loading, .loaded: return
    case .idle, .failed, nil: break
    }
    automationModels[key] = .loading
    do {
      automationModels[key] = .loaded(
        try await core.creationModels(agentId: agentID, hostId: hostID))
    } catch {
      automationModels[key] = .failed(coreError(error))
    }
  }

  /// Reads what a new sandbox of `provider` offers `agentID`'s `harness`, unless it is loaded
  /// or loading.
  public func loadAutomationSandboxModels(agentID: String, harness: String, provider: String)
    async
  {
    let key = Self.sandboxModelsKey(agentID: agentID, provider: provider)
    switch automationSandboxModels[key] {
    case .loading, .loaded: return
    case .idle, .failed, nil: break
    }
    automationSandboxModels[key] = .loading
    do {
      automationSandboxModels[key] = .loaded(
        try await core.sandboxModelPreview(provider: provider, harness: harness, agentId: agentID))
    } catch {
      automationSandboxModels[key] = .failed(coreError(error))
    }
  }
}
