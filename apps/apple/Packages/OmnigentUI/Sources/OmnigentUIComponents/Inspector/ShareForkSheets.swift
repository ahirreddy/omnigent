import OmnigentPlatform
public import SwiftUI

/// "Share this session": general access, workspace files, people with Read or Edit, Copy link,
/// the system share menu, and Done.
public struct ShareSheet: View {
  private let state: ShareViewState
  private let actions: ShareActions
  private let done: @MainActor () -> Void

  @State private var newPrincipal = ""
  @State private var newRole: ShareGrant.Role = .read
  @State private var copied = false

  /// Creates the sheet.
  /// - Parameters:
  ///   - state: Access and grants.
  ///   - actions: Changes.
  ///   - done: Close.
  public init(state: ShareViewState, actions: ShareActions, done: @escaping @MainActor () -> Void) {
    self.state = state
    self.actions = actions
    self.done = done
  }

  /// The sheet.
  public var body: some View {
    NavigationStack {
      Form {
        Section {
          Text("Invite others to view or collaborate on this session.")
            .foregroundStyle(.secondary)
          Picker(
            "General access",
            selection: Binding(
              get: { state.generalAccess }, set: { actions.setGeneralAccess?($0) })
          ) {
            ForEach(state.generalAccessOptions, id: \.self) { Text($0).tag($0) }
          }
          .disabled(actions.setGeneralAccess == nil)
          .accessibilityIdentifier("share-general-access")
          Toggle(
            isOn: Binding(get: { state.workspaceFiles }, set: { actions.setWorkspaceFiles?($0) })
          ) {
            VStack(alignment: .leading, spacing: Theme.Spacing.tiny) {
              Text("Workspace files")
              Text("Let people with view access browse this session's files")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
          .disabled(actions.setWorkspaceFiles == nil)
          .accessibilityIdentifier("share-workspace-files")
        }
        Section("People") {
          if state.grants.isEmpty {
            Text("No grants yet.").foregroundStyle(.secondary)
          }
          ForEach(state.grants) { grant in
            HStack {
              AuthorAvatar(name: grant.principal)
              Text(grant.principal)
              Spacer()
              Picker(
                "Role",
                selection: Binding(get: { grant.role }, set: { actions.setRole?(grant, $0) })
              ) {
                ForEach(ShareGrant.Role.allCases, id: \.self) { Text($0.title).tag($0) }
              }
              .labelsHidden()
              .fixedSize()
              .accessibilityIdentifier("share-role-\(grant.id)")
              if let remove = actions.removeGrant {
                Button("Remove", systemImage: "xmark.circle") { remove(grant) }
                  .labelStyle(.iconOnly)
                  .buttonStyle(.borderless)
                  .help("Remove access")
                  .accessibilityLabel("Remove access")
                  .accessibilityIdentifier("share-remove-\(grant.id)")
              }
            }
          }
          HStack {
            TextField("Add people", text: $newPrincipal, prompt: Text("alice@example.com"))
              .textContentType(.emailAddress)
              .onSubmit(add)
              .accessibilityIdentifier("share-add-principal")
            Picker("Role", selection: $newRole) {
              ForEach(ShareGrant.Role.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            .accessibilityIdentifier("share-add-role")
            Button("Add", action: add)
              .disabled(newPrincipal.trimmingCharacters(in: .whitespaces).isEmpty)
              .accessibilityIdentifier("share-add")
          }
          .disabled(actions.addGrant == nil)
        }
        if let error = state.errorMessage {
          Section {
            Label(error, systemImage: "exclamationmark.triangle.fill")
              .foregroundStyle(Theme.failure)
              .textSelection(.enabled)
          }
        }
      }
      .formStyle(.grouped)
      .navigationTitle("Share this session")
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done", action: done)
            .accessibilityIdentifier("share-done")
        }
        ToolbarItemGroup(placement: .cancellationAction) {
          if let link = state.link {
            Button(copied ? "Copied!" : "Copy link", systemImage: "link") {
              Pasteboard.copy(link.absoluteString)
              copied = true
            }
            .accessibilityIdentifier("share-copy-link")
            .task(id: copied) {
              guard copied else { return }
              do {
                try await Task.sleep(for: .seconds(2))
              } catch {
                // Cancelled because the sheet closed; nothing to reset.
                return
              }
              copied = false
            }
            ShareLink(item: link)
              .accessibilityIdentifier("share-link")
          }
        }
      }
    }
    #if os(macOS)
      .frame(width: 520, height: 520)
    #endif
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("share-sheet")
  }

  private func add() {
    let principal = newPrincipal.trimmingCharacters(in: .whitespaces)
    guard !principal.isEmpty, let addGrant = actions.addGrant else { return }
    addGrant(principal, newRole)
    newPrincipal = ""
  }
}

/// The Fork dialog: "Clone session", "Fork from this response" or "Continue in another
/// directory", with the agent and directory, then Clone, Clone & start, or Continue.
public struct ForkSheet: View {
  private let state: ForkViewState
  private let actions: ForkActions
  @State private var agentID: String
  @State private var directory: String

  /// Creates the dialog.
  /// - Parameters:
  ///   - state: Choices.
  ///   - actions: Fork and cancel.
  public init(state: ForkViewState, actions: ForkActions) {
    self.state = state
    self.actions = actions
    _agentID = State(initialValue: state.agentID)
    _directory = State(initialValue: state.directory)
  }

  /// The dialog.
  public var body: some View {
    NavigationStack {
      Form {
        Picker("Agent", selection: $agentID) {
          // Menu pickers on macOS show text labels only; the harness reads from the name.
          ForEach(state.agents) { agent in
            Text(agent.name).tag(agent.id)
          }
        }
        .accessibilityIdentifier("fork-agent")
        // The directory is where "Clone & start" runs, so it shows only when that can.
        if startsInDirectory {
          directoryField
        }
        if let error = state.errorMessage {
          Label(error, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(Theme.failure)
            .accessibilityIdentifier("fork-error")
        }
        if let reason = state.startUnavailableReason, state.kind != .anotherDirectory {
          Text("Clone copies the conversation without starting it. \(reason)")
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("fork-start-unavailable")
        }
      }
      .formStyle(.grouped)
      .disabled(state.isForking)
      .navigationTitle(state.title)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel", action: actions.cancel)
            .accessibilityIdentifier("fork-cancel")
        }
        ToolbarItemGroup(placement: .confirmationAction) {
          if state.isForking {
            ProgressView().controlSize(.small)
          }
          if case .anotherDirectory = state.kind {
            Button("Continue") { actions.fork(agentID, directory, true) }
              .primaryActionStyle()
              .disabled(state.isForking)
              .accessibilityIdentifier("fork-continue")
          } else if !startsInDirectory {
            Button("Clone") { actions.fork(agentID, directory, false) }
              .primaryActionStyle()
              .disabled(state.isForking)
              .accessibilityIdentifier("fork-clone")
          } else {
            Button("Clone") { actions.fork(agentID, directory, false) }
              .disabled(state.isForking)
              .accessibilityIdentifier("fork-clone")
            Button("Clone & start") { actions.fork(agentID, directory, true) }
              .primaryActionStyle()
              .disabled(state.isForking)
              .accessibilityIdentifier("fork-clone-start")
          }
        }
      }
    }
    #if os(macOS)
      .frame(width: 480, height: startsInDirectory ? 280 : 210)
    #endif
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("fork-sheet")
  }

  /// Continue always runs in the directory; a fork can when its start is available.
  private var startsInDirectory: Bool {
    if case .anotherDirectory = state.kind { return true }
    return state.startUnavailableReason == nil
  }

  private var directoryField: some View {
    LabeledContent("Directory") {
      HStack {
        TextField("Directory", text: $directory)
          .labelsHidden()
          .font(Theme.codeFont)
          .accessibilityIdentifier("fork-directory")
        if !state.recentDirectories.isEmpty {
          Menu {
            ForEach(state.recentDirectories, id: \.self) { path in
              Button(path) { directory = path }
            }
          } label: {
            Label("Recent directories", systemImage: "clock")
          }
          .labelStyle(.iconOnly)
          .fixedSize()
          .help("Recent directories")
          .accessibilityIdentifier("fork-recent-directories")
        }
      }
    }
  }
}

/// The Fork sheet's presentation key: the dialog's id alone, so its state updates in place.
/// Keying the sheet on the whole state made iOS re-render the conversation without end.
struct ForkSheetID: Identifiable, Hashable {
  let id: String

  /// The key for `fork`; clearing it closes the dialog.
  static func binding(_ fork: Binding<ForkViewState?>) -> Binding<Self?> {
    Binding(
      get: { fork.wrappedValue.map { Self(id: $0.id) } },
      set: { if $0 == nil { fork.wrappedValue = nil } })
  }
}
