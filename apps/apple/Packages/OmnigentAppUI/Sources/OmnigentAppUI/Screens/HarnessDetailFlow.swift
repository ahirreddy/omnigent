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
  @State private var openSkill: HarnessCatalogState.Skill?

  var body: some View {
    Group {
      if let detail {
        HarnessDetailView(state: state(detail), actions: actions(detail))
      } else {
        Section {
          Button("Harnesses", systemImage: "chevron.left", action: back)
            .buttonStyle(.borderless)
          Text("This host is no longer connected.").foregroundStyle(.secondary)
        }
      }
    }
    .task(id: "\(hostID)/\(harness)") {
      openSkill = nil
      guard let detail else { return }
      await fix.loadStartup(harness: harness, hostID: hostID, hostName: detail.hostName)
      if HarnessCatalogAdapter.offersCatalog(detail) {
        await setup.loadCatalog(harness: harness, hostID: hostID)
      }
    }
    .sheet(item: $fixTarget, onDismiss: fix.cancel) { target in
      fixSheet(target)
    }
  }

  private var detail: HarnessDetail? {
    setup.detail(harness: harness, name: name, hostID: hostID)
  }

  private func state(_ detail: HarnessDetail) -> HarnessDetailState {
    var state = HarnessFixAdapter.detail(
      detail, startup: fix.startup["\(hostID)/\(harness)"], notice: notice)
    state.catalog = HarnessCatalogAdapter.catalog(
      setup.catalogs["\(hostID)/\(harness)"], detail: detail)
    state.catalog = state.catalog.map {
      HarnessCatalogAdapter.probing(
        $0, tools: setup.mcpTools, prefix: HarnessSetupStore.mcpToolsKey(hostID, harness, ""),
        harness: harness, host: detail.hostName)
    }
    if let openSkill {
      let key = HarnessSetupStore.skillKey(hostID, harness, openSkill.name)
      state.skillPage = HarnessCatalogAdapter.skillPage(
        openSkill, load: setup.skillContents[key], host: detail.hostName)
    }
    return state
  }

  private func actions(_ detail: HarnessDetail) -> HarnessDetailActions {
    var actions = HarnessDetailActions(
      back: back,
      fixWarning: { open(detail.warning?.mode ?? detail.mode, detail: detail) },
      fixCredential: {
        guard let action = detail.credentialAction else { return }
        open(HarnessFixAdapter.mode(for: action, detail: detail), detail: detail)
      })
    let (setup, harness, hostID) = (setup, harness, hostID)
    actions.openSkill = { skill in
      openSkill = skill
      Task {
        await setup.loadSkill(
          skill.name, sourceID: skill.sourceID, harness: harness, hostID: hostID)
      }
    }
    actions.closeSkill = { openSkill = nil }
    let servers = setup.catalogs["\(hostID)/\(harness)"]?.value?.mcpServers ?? []
    actions.probeServer = { id in
      guard let server = servers.first(where: { $0.id == id }) else { return }
      Task { await setup.loadMcpTools(server, harness: harness, hostID: hostID) }
    }
    return actions
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
