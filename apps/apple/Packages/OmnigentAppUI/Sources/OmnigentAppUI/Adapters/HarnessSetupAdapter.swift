import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents

/// Maps the core's harness setup plan and inventory to the setup sheet and the Settings rows.
enum HarnessSetupAdapter {
  /// The setup sheet for `plan`, or a loading or failed sheet before it exists.
  static func sheet(
    _ plan: HarnessSetupPlan?, catalog: CreationLoad<HarnessSetupCatalog>,
    detected: [DetectedCredential]?, isInstalling: Bool, isSaving: Bool, notice: String?,
    error: String?
  ) -> HarnessSetupSheetState {
    guard let plan else {
      var loadError: String?
      if case .failed(let failure) = catalog { loadError = failure.message }
      return HarnessSetupSheetState(
        name: "Harness", hostName: "Host", isLoading: loadError == nil,
        errorMessage: loadError ?? error)
    }
    return HarnessSetupSheetState(
      name: plan.label, hostName: plan.hostName ?? "the host",
      steps: plan.steps.map(step), allDone: plan.allDone, needsOmniSetup: plan.needsOmniSetup,
      isInstalling: isInstalling, isSavingCredential: isSaving,
      adoptableSource: adoptableHarnessCredential(harness: plan.harness, detected: detected ?? [])?
        .source,
      notice: notice, errorMessage: error)
  }

  static func step(_ step: ResolvedSetupStep) -> HarnessSetupStepState {
    let status: HarnessSetupStepState.Status =
      switch step.status {
      case .done: .done
      case .todo: .todo
      case .unknown: .unknown
      }
    let control: HarnessSetupStepState.Control =
      switch step.control {
      case .none: .none
      case .install: .install
      case .credential(let enabled): .credential(enabled: enabled)
      case .command(let command): .command(command)
      }
    return HarnessSetupStepState(
      id: step.kind, title: step.title, detail: step.detail, status: status, control: control,
      loginCommand: step.command)
  }

  /// The credential to write for `choice`; `nil` for adopting when nothing adoptable was found.
  static func credential(
    _ choice: HarnessCredentialChoice, harness: String, detected: [DetectedCredential]
  ) -> HarnessCredentialInput? {
    switch choice {
    case .apiKey(let key):
      return .key(secret: key)
    case .gateway(let url, let key):
      return .gateway(baseUrl: url, secret: key)
    case .adopt:
      guard
        let variable = adoptableHarnessCredential(harness: harness, detected: detected)?.envVar
      else { return nil }
      return .adopt(envVar: variable)
    }
  }

  /// The Settings rows.
  static func rows(_ inventory: [HarnessInventoryRow]) -> [HarnessesSettingsRow] {
    inventory.map {
      HarnessesSettingsRow(
        id: $0.harness, name: $0.name, description: $0.description, status: $0.status,
        isReady: $0.ready, needsSetup: $0.needsSetup)
    }
  }
}
