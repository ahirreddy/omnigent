import Foundation
import OmnigentCoreFFI
public import OmnigentStores
import OmnigentUIComponents
public import SwiftUI
import UniformTypeIdentifiers

/// The create-agent sheet over a ``CustomAgentsStore``: saves the form as the caller's agent,
/// or installs a picked `.tar.gz` bundle, then hands the new agent back.
struct CreateAgentContainer: View {
  let store: CustomAgentsStore
  var title = "Create Custom Agent"
  var saveLabel = "Create"
  var notice: String?
  let allowsImport: Bool
  let created: @MainActor (ManagedAgent) -> Void
  /// When set, Create hands the form back unsaved (it uploads with the new session, as on the
  /// web) instead of installing it.
  var drafted: (@MainActor (AgentDraft) -> Void)?
  let cancel: @MainActor () -> Void

  @State private var isImporting = false

  var body: some View {
    CreateAgentSheet(
      harnesses: CustomAgentsAdapter.harnesses, title: title, saveLabel: saveLabel,
      notice: notice, isSaving: store.isSaving, errorMessage: store.error?.message,
      problem: CustomAgentsAdapter.problem,
      save: { form in
        if let drafted {
          drafted(CustomAgentsAdapter.draft(form))
          return
        }
        Task {
          if let agent = await store.create(CustomAgentsAdapter.draft(form)) { created(agent) }
        }
      },
      importBundle: importBundle,
      cancel: cancel
    )
    .onDisappear { store.dismissMessages() }
    .agentBundleImporter(isPresented: $isImporting, store: store, imported: created)
  }

  private var importBundle: (@MainActor () -> Void)? {
    guard allowsImport else { return nil }
    return { isImporting = true }
  }
}

extension View {
  /// A file importer for a `.tar.gz` agent bundle that installs the picked file.
  func agentBundleImporter(
    isPresented: Binding<Bool>, store: CustomAgentsStore?,
    imported: @escaping @MainActor (ManagedAgent) -> Void
  ) -> some View {
    fileImporter(isPresented: isPresented, allowedContentTypes: [.gzip]) { result in
      Task { await bundlePicked(result, store: store, imported: imported) }
    }
  }
}

/// Installs the bundle picked in the file importer, or records why the importer failed.
func bundlePicked(
  _ result: Result<URL, any Error>, store: CustomAgentsStore?,
  imported: @MainActor (ManagedAgent) -> Void
) async {
  guard let store else { return }
  switch result {
  case .success(let url):
    if let agent = await CustomAgentsBundle.install(url, store: store) { imported(agent) }
  case .failure(let error):
    store.recordImportFailure(error.localizedDescription)
  }
}

/// Reads a picked bundle and installs it.
enum CustomAgentsBundle {
  static func install(_ url: URL, store: CustomAgentsStore) async -> ManagedAgent? {
    let accessing = url.startAccessingSecurityScopedResource()
    defer { if accessing { url.stopAccessingSecurityScopedResource() } }
    let data: Data
    do {
      data = try Data(contentsOf: url)
    } catch {
      store.recordImportFailure(
        "Could not read \(url.lastPathComponent): \(error.localizedDescription)")
      return nil
    }
    return await store.importBundle(data, filename: url.lastPathComponent)
  }
}

/// Settings > Custom agents for one server: the server's agents, yours with Create, and an
/// editor with Delete. Self-contained: give it the server's connection.
public struct CustomAgentsSettingsView: View {
  private let connection: ConnectionStore
  private let canEdit: Bool
  @State private var store: CustomAgentsStore?
  @State private var editingID: String?
  @State private var isCreating = false

  /// Creates the section.
  /// - Parameters:
  ///   - connection: The server whose agents show.
  ///   - canEdit: The server reads and changes an agent's configuration (`agent_detail`).
  public init(connection: ConnectionStore, canEdit: Bool = true) {
    self.connection = connection
    self.canEdit = canEdit
  }

  /// The section, as a grouped form.
  public var body: some View {
    Form {
      if let store {
        CustomAgentsSettingsSection(state: state(store), actions: actions(store))
      } else {
        Text("Connect to this server to manage its custom agents.").foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .task(id: ObjectIdentifier(connection)) {
      guard let store = connection.customAgents() else { return }
      self.store = store
      editingID = nil
      await store.load()
    }
    .sheet(isPresented: $isCreating) {
      if let store {
        CreateAgentContainer(
          store: store, title: "Create Custom Agent", saveLabel: "Save Agent",
          notice: "Saving an agent with an existing name replaces its whole configuration. "
            + "Sessions using that agent get the update. Use a new name to keep both.",
          allowsImport: true,
          created: { agent in
            isCreating = false
            Task {
              await store.load()
              if canEdit { edit(agent.id, store: store) }
            }
          },
          cancel: { isCreating = false })
      }
    }
  }

  private func edit(_ agentID: String, store: CustomAgentsStore) {
    editingID = agentID
    Task { await store.loadConfig(agentID) }
  }

  private func state(_ store: CustomAgentsStore) -> CustomAgentsSettingsState {
    var errors: [String] = []
    for load in [store.serverAgents, store.myAgents] {
      if case .failed(let error) = load { errors.append(error.message) }
    }
    if editingID != nil, case .failed(let error) = store.config { errors.append(error.message) }
    if let error = store.error { errors.append(error.message) }
    let editing = editingID == nil ? nil : store.config.value.map(CustomAgentsAdapter.form)
    return CustomAgentsSettingsState(
      serverAgents: CustomAgentsAdapter.rows(store.serverAgents.value ?? []),
      myAgents: CustomAgentsAdapter.rows(store.myAgents.value ?? []),
      isLoading: store.serverAgents == .loading || store.myAgents == .loading,
      editing: editing, isLoadingConfig: editingID != nil && store.config == .loading,
      harnesses: CustomAgentsAdapter.harnesses, isSaving: store.isSaving,
      errorMessage: errors.isEmpty ? nil : errors.joined(separator: "\n"),
      inUseMessage: store.inUseMessage)
  }

  private func actions(_ store: CustomAgentsStore) -> CustomAgentsSettingsActions {
    var openEditor: (@MainActor (CustomAgentRow) -> Void)?
    if canEdit { openEditor = { row in edit(row.id, store: store) } }
    return CustomAgentsSettingsActions(
      create: {
        store.dismissMessages()
        isCreating = true
      },
      edit: openEditor,
      save: { form in
        Task {
          if await store.save(CustomAgentsAdapter.edit(form)) { await store.load() }
        }
      },
      remove: { agentID, force in
        Task {
          if await store.remove(agentID, force: force) {
            editingID = nil
            await store.load()
          }
        }
      },
      closeEditor: {
        store.dismissMessages()
        editingID = nil
      })
  }
}
