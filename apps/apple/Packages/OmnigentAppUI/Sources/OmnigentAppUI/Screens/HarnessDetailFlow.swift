import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents
import SwiftUI

/// What a fix sheet is for: one harness on one host, in one mode.
struct HarnessFixTarget: Identifiable, Equatable {
  let harness: String
  let name: String
  let hostID: String
  let mode: HarnessFixMode
  var id: String { "\(hostID)/\(harness)/\(mode)" }
}

/// Settings > Harnesses > a harness: its details on the selected host, with the fix sheet
/// (switch account, device sign-in, update) and, for steps the app cannot do itself, the setup
/// sheet. The host is captured when a fix opens, so changing hosts cannot redirect it.
struct HarnessDetailContainer: View {
  let setup: HarnessSetupStore
  let fix: HarnessFixStore
  let harness: String
  let name: String
  let hostID: String
  let back: @MainActor () -> Void
  @Binding var setupTarget: HarnessSetupTarget?
  @State private var fixTarget: HarnessFixTarget?
  @State private var notice: String?

  var body: some View {
    Group {
      if let detail {
        HarnessDetailView(
          state: HarnessFixAdapter.detail(
            detail, startup: fix.startup["\(hostID)/\(harness)"], notice: notice),
          actions: actions(detail))
      } else {
        Section {
          Button("Harnesses", systemImage: "chevron.left", action: back)
            .buttonStyle(.borderless)
          Text("This host is no longer connected.").foregroundStyle(.secondary)
        }
      }
    }
    .task(id: "\(hostID)/\(harness)") {
      guard let hostName = detail?.hostName else { return }
      await fix.loadStartup(harness: harness, hostID: hostID, hostName: hostName)
    }
    .sheet(item: $fixTarget, onDismiss: fix.cancel) { target in
      fixSheet(target)
    }
  }

  private var detail: HarnessDetail? {
    setup.detail(harness: harness, name: name, hostID: hostID)
  }

  private func actions(_ detail: HarnessDetail) -> HarnessDetailActions {
    HarnessDetailActions(
      back: back,
      fixWarning: { open(detail.warning?.mode ?? detail.mode, detail: detail) },
      fixCredential: {
        guard let action = detail.credentialAction else { return }
        open(HarnessFixAdapter.mode(for: action, detail: detail), detail: detail)
      })
  }

  /// Runs `mode` in the fix sheet, or opens the setup sheet for steps only it can do: an
  /// install or a credential with no account sign-in, as the web's setup dialog does.
  private func open(_ mode: HarnessFixMode, detail: HarnessDetail) {
    notice = nil
    let signsIn = detail.supportsDeviceLogin || detail.personalLoginCommand != nil
    if mode == .install || (mode == .reconfigure && !signsIn) {
      setupTarget = HarnessSetupTarget(harness: harness, hostID: hostID)
      return
    }
    fixTarget = HarnessFixTarget(harness: harness, name: name, hostID: hostID, mode: mode)
    Task { await fix.begin(mode, detail: detail, hostID: hostID) }
  }

  @ViewBuilder private func fixSheet(_ target: HarnessFixTarget) -> some View {
    let current = setup.detail(harness: target.harness, name: target.name, hostID: target.hostID)
    if let current,
      let state = HarnessFixAdapter.sheet(
        fix.phase, mode: target.mode, detail: current, isChecking: fix.isChecking)
    {
      HarnessFixSheet(state: state, actions: fixActions(target, detail: current))
    } else {
      ProgressView().padding()
    }
  }

  private func fixActions(_ target: HarnessFixTarget, detail: HarnessDetail) -> HarnessFixActions {
    HarnessFixActions(
      confirmSwitch: { email in
        Task { await fix.confirmSwitch(detail: detail, hostID: target.hostID, email: email) }
      },
      checkAgain: { Task { await fix.checkAgain(detail: detail, hostID: target.hostID) } },
      retry: { Task { await fix.begin(target.mode, detail: detail, hostID: target.hostID) } },
      continueSetup: {
        fixTarget = nil
        setupTarget = HarnessSetupTarget(harness: target.harness, hostID: target.hostID)
      },
      close: {
        if case .done(let message) = fix.phase { notice = message }
        fixTarget = nil
      })
  }
}
