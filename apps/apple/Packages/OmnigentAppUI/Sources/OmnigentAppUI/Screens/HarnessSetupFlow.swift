import OmnigentCoreFFI
public import OmnigentStores
import OmnigentUIComponents
public import SwiftUI

/// What the setup sheet is for: one harness on one host.
struct HarnessSetupTarget: Identifiable, Hashable {
  let harness: String
  let hostID: String
  var id: String { "\(hostID)/\(harness)" }
}

/// The harness setup sheet over a ``HarnessSetupStore``: reads the catalog, then installs or
/// writes a credential and shows the refreshed readiness in place.
struct HarnessSetupContainer: View {
  let store: HarnessSetupStore
  let target: HarnessSetupTarget
  let close: @MainActor () -> Void

  var body: some View {
    HarnessSetupSheet(state: state, actions: actions)
      .task { if store.catalog.value == nil { await store.load() } }
      .onDisappear { store.dismissMessages() }
  }

  private var plan: HarnessSetupPlan? {
    store.plan(harness: target.harness, hostID: target.hostID)
  }

  private var state: HarnessSetupSheetState {
    HarnessSetupAdapter.sheet(
      plan,
      progress: HarnessSetupAdapter.Progress(
        catalog: store.catalog, detected: store.detected[target.hostID]?.value ?? [],
        isInstalling: store.isInstalling(harness: target.harness, hostID: target.hostID),
        isSaving: store.isSavingCredential, notice: store.notice, error: store.error?.message))
  }

  private var actions: HarnessSetupActions {
    let label = plan?.label ?? target.harness
    return HarnessSetupActions(
      install: {
        Task { await store.install(harness: target.harness, label: label, hostID: target.hostID) }
      },
      saveCredential: { choice in
        guard
          let input = HarnessSetupAdapter.credential(
            choice, harness: target.harness,
            detected: store.detected[target.hostID]?.value ?? [])
        else { return }
        Task {
          await store.storeCredential(
            input, harness: target.harness, label: label, hostID: target.hostID)
        }
      },
      credentialFormOpened: { Task { await store.loadDetected(hostID: target.hostID) } },
      close: close)
  }
}

/// Settings > Harnesses for one server: the host picker, each harness's readiness and Set Up.
/// Self-contained: give it the server's connection.
public struct HarnessesSettingsView: View {
  private let connection: ConnectionStore
  @State private var store: HarnessSetupStore?
  @State private var hostID: String?
  @State private var target: HarnessSetupTarget?

  /// Creates the section.
  /// - Parameter connection: The server whose hosts show.
  public init(connection: ConnectionStore) {
    self.connection = connection
  }

  /// The section, as a grouped form.
  public var body: some View {
    Form {
      if let store {
        HarnessesSettingsSection(state: state(store), actions: actions(store))
      } else {
        Text("Connect to this server to manage its harnesses.").foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .task(id: ObjectIdentifier(connection)) {
      guard let store = connection.harnessSetup() else { return }
      self.store = store
      await store.load()
    }
    .sheet(item: $target) { target in
      if let store {
        HarnessSetupContainer(store: store, target: target) { self.target = nil }
      }
    }
  }

  private func selectedHost(_ store: HarnessSetupStore) -> String? {
    let hosts = store.catalog.value?.hosts ?? []
    if let hostID, hosts.contains(where: { $0.hostId == hostID }) { return hostID }
    return hosts.first?.hostId
  }

  private func state(_ store: HarnessSetupStore) -> HarnessesSettingsState {
    let host = selectedHost(store)
    return HarnessesSettingsState(
      hosts: (store.catalog.value?.hosts ?? []).map {
        HarnessesSettingsHost(id: $0.hostId, name: $0.name, isOnline: $0.status == "online")
      },
      selectedHostID: host,
      rows: host.map { HarnessSetupAdapter.rows(store.inventory(hostID: $0)) } ?? [],
      isLoading: store.catalog == .loading,
      errorMessage: {
        if case .failed(let error) = store.catalog { return error.message }
        return nil
      }())
  }

  private func actions(_ store: HarnessSetupStore) -> HarnessesSettingsActions {
    HarnessesSettingsActions(
      selectHost: { hostID = $0 },
      setUp: { row in
        guard let host = selectedHost(store) else { return }
        target = HarnessSetupTarget(harness: row.id, hostID: host)
      },
      refresh: { Task { await store.load() } })
  }
}
