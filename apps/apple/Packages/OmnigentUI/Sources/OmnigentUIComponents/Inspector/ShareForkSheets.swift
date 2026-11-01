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
          Toggle(
            isOn: Binding(get: { state.workspaceFiles }, set: { actions.setWorkspaceFiles?($0) })
          ) {
            VStack(alignment: .leading, spacing: 2) {
              Text("Workspace files")
              Text("Let people with view access browse this session's files")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
          .disabled(actions.setWorkspaceFiles == nil)
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
              if let remove = actions.removeGrant {
                Button("Remove", systemImage: "xmark.circle") { remove(grant) }
                  .labelStyle(.iconOnly)
                  .buttonStyle(.borderless)
              }
            }
          }
          HStack {
            TextField("Add people", text: $newPrincipal, prompt: Text("alice@example.com"))
              .textContentType(.emailAddress)
              .onSubmit(add)
            Picker("Role", selection: $newRole) {
              ForEach(ShareGrant.Role.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            Button("Add", action: add)
              .disabled(newPrincipal.trimmingCharacters(in: .whitespaces).isEmpty)
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
        }
        ToolbarItemGroup(placement: .cancellationAction) {
          if let link = state.link {
            Button(copied ? "Copied!" : "Copy link", systemImage: "link") {
              Pasteboard.copy(link.absoluteString)
              copied = true
            }
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
          }
        }
      }
    }
    #if os(macOS)
      .frame(width: 520, height: 520)
    #endif
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
          ForEach(state.agents) { agent in
            HStack {
              HarnessGlyph(harness: agent.harness, size: 16)
              Text(agent.name)
            }
            .tag(agent.id)
          }
        }
        LabeledContent("Directory") {
          HStack {
            TextField("Directory", text: $directory)
              .labelsHidden()
              .font(Theme.codeFont)
            if !state.recentDirectories.isEmpty {
              Menu {
                ForEach(state.recentDirectories, id: \.self) { path in
                  Button(path) { directory = path }
                }
              } label: {
                Label("Recents", systemImage: "clock")
              }
              .labelStyle(.iconOnly)
              .fixedSize()
            }
          }
        }
        if let error = state.errorMessage {
          Label(error, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(Theme.failure)
        }
      }
      .formStyle(.grouped)
      .disabled(state.isForking)
      .navigationTitle(state.title)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel", action: actions.cancel)
        }
        ToolbarItemGroup(placement: .confirmationAction) {
          if state.isForking {
            ProgressView().controlSize(.small)
          }
          if case .anotherDirectory = state.kind {
            Button("Continue") { actions.fork(agentID, directory, true) }
              .buttonStyle(.borderedProminent)
          } else {
            Button("Clone") { actions.fork(agentID, directory, false) }
            Button("Clone & start") { actions.fork(agentID, directory, true) }
              .buttonStyle(.borderedProminent)
          }
        }
      }
    }
    #if os(macOS)
      .frame(width: 480, height: 260)
    #endif
    .accessibilityIdentifier("fork-sheet")
  }
}
