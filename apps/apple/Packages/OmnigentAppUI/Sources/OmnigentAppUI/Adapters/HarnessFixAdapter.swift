import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents

/// Maps the core's harness details and the fix store to Settings > Harnesses > a harness and
/// the fix sheet.
enum HarnessFixAdapter {
  /// The details page.
  static func detail(
    _ detail: HarnessDetail, startup: CreationLoad<HarnessStartupRead>?, notice: String?
  ) -> HarnessDetailState {
    HarnessDetailState(
      harness: detail.harness, name: detail.name, hostName: detail.hostName,
      status: detail.status, isReady: detail.ready,
      warning: detail.warning.map {
        HarnessDetailState.Warning(
          message: $0.message, action: detail.canFix ? $0.actionLabel : nil)
      },
      credentialLabel: detail.credentialLabel, credentialDescription: detail.credentialDescription,
      credentialWarning: detail.credentialWarning,
      credentialAction: detail.credentialAction.map(actionLabel), notice: notice,
      startup: startupSection(startup, hostName: detail.hostName))
  }

  static func actionLabel(_ action: HarnessCredentialAction) -> String {
    switch action {
    case .switchAccount: "Switch Account"
    case .signInAgain: "Sign In Again"
    case .reconfigure: "Reconfigure"
    }
  }

  /// The fix the credential row's button runs.
  static func mode(for action: HarnessCredentialAction, detail: HarnessDetail) -> HarnessFixMode {
    action == .switchAccount ? .switch : detail.mode
  }

  static func startupSection(_ load: CreationLoad<HarnessStartupRead>?, hostName: String)
    -> HarnessDetailState.Startup
  {
    switch load {
    case nil, .idle, .loading: .loading
    case .failed: .unavailable("Couldn\u{2019}t load launch settings from \(hostName).")
    case .loaded(.notReported): .hidden
    case .loaded(.hostOutdated): .unavailable("Update \(hostName) to see launch settings.")
    case .loaded(.loaded(let startup)): .loaded(startupState(startup, hostName: hostName))
    }
  }

  static func startupState(_ startup: HarnessStartup, hostName: String) -> HarnessStartupState {
    var environmentNote: String
    if startup.environment == nil {
      environmentNote =
        startup.hostOutdated
        ? "Update \(hostName) to see environment settings."
        : "Cannot separate environment values for this env wrapper. Command and arguments are shown unchanged."
    } else {
      environmentNote =
        startup.inheritsEnvironment
        ? "Inherited values are not listed." : "Inherited environment cleared."
      if !startup.unset.isEmpty {
        environmentNote +=
          " Removed before applying overrides: \(startup.unset.joined(separator: ", "))."
      }
    }
    let count = startup.argCount
    let argumentsNote =
      startup.args == nil && count > 0
      ? "\(count) configured argument\(count == 1 ? "" : "s"). Update \(hostName) to view values."
      : "None configured"
    return HarnessStartupState(
      command: startup.command, found: startup.found, source: startup.source,
      listsEnvironment: startup.environment != nil,
      environment: (startup.environment ?? []).map {
        HarnessStartupState.Variable(name: $0.name, value: $0.value)
      },
      environmentNote: environmentNote, arguments: startup.args ?? [],
      argumentsNote: argumentsNote)
  }

  /// The fix sheet for `phase`; `nil` while idle.
  static func sheet(
    _ phase: HarnessFixPhase, mode: HarnessFixMode, detail: HarnessDetail, isChecking: Bool
  ) -> HarnessFixSheetState? {
    let name = detail.name
    let host = detail.hostName
    let isClaude = detail.harness.contains("claude")
    let sheetPhase: HarnessFixSheetState.Phase
    switch phase {
    case .idle: return nil
    case .confirmSwitch(let account):
      sheetPhase = .confirmSwitch(account: account, asksForEmail: isClaude)
    case .working(let message): sheetPhase = .working(message)
    case .deviceCode(let login):
      sheetPhase = .deviceCode(
        link: secureLink(login.verificationUrl), code: login.userCode,
        expiresAt: Date(timeIntervalSince1970: TimeInterval(login.expiresAt)))
    case .waitingForOtherSignIn: sheetPhase = .waitingForOtherSignIn
    case .runCommand(let command, let stillNotReady):
      let hint =
        isClaude
        ? "Open the link it prints, then paste the code from your browser back into the terminal."
        : "Open the link it prints and enter the one-time code."
      sheetPhase = .runCommand(command: command, hint: hint, stillNotReady: stillNotReady)
    case .needsSetup(let message): sheetPhase = .needsSetup(message)
    case .failed(let message): sheetPhase = .failed(message)
    case .done(let message): sheetPhase = .done(message)
    }
    return HarnessFixSheetState(
      title: title(phase, mode: mode, name: name, host: host), hostName: host, phase: sheetPhase,
      isChecking: isChecking)
  }

  /// The web's `dialogTitle`.
  static func title(_ phase: HarnessFixPhase, mode: HarnessFixMode, name: String, host: String)
    -> String
  {
    switch phase {
    case .confirmSwitch: "Switch \(name) Account?"
    case .deviceCode, .waitingForOtherSignIn, .runCommand: "Sign In to \(name) on \(host)"
    case .failed: failureTitle(mode, name: name)
    case .working: workingTitle(mode, name: name)
    case .idle, .needsSetup, .done: "Set Up \(name) on \(host)"
    }
  }

  private static func failureTitle(_ mode: HarnessFixMode, name: String) -> String {
    switch mode {
    case .update: "Couldn\u{2019}t Update \(name)"
    case .install: "Couldn\u{2019}t Install \(name)"
    case .reconfigure, .switch: "Couldn\u{2019}t Reconfigure \(name)"
    }
  }

  private static func workingTitle(_ mode: HarnessFixMode, name: String) -> String {
    switch mode {
    case .switch: "Switching \(name) Account\u{2026}"
    case .update: "Updating \(name)\u{2026}"
    case .install: "Installing \(name)\u{2026}"
    case .reconfigure: "Reconfiguring \(name)\u{2026}"
    }
  }

  /// `text` as a URL only when it is `https` with a host; the core already checked.
  static func secureLink(_ text: String) -> URL? {
    guard let url = URL(string: text), url.scheme == "https", url.host() != nil else { return nil }
    return url
  }
}
