public import Foundation
import SwiftUI

/// A stored header or environment variable in the MCP server editor. Values are never read
/// back: an existing one is kept, replaced or removed.
nonisolated public struct MCPCredentialEdit: Identifiable, Hashable, Sendable {
  /// What to do with it.
  public enum Action: Hashable, Sendable {
    /// Keep the stored value.
    case keep
    /// Store `value`.
    case replace
    /// Remove it.
    case remove
  }

  /// Stable within the editor.
  public let id = UUID()
  /// Name.
  public var name: String
  /// The new value, for `replace`.
  public var value: String
  /// What to do.
  public var action: Action
  /// The server already stores it.
  public var existing: Bool

  /// Creates a credential row.
  public init(name: String, value: String = "", action: Action = .keep, existing: Bool) {
    self.name = name
    self.value = value
    self.action = action
    self.existing = existing
  }
}

/// An MCP server being added to or changed in an agent (the web's `MCPDraft`).
nonisolated public struct MCPServerEdit: Identifiable, Hashable, Sendable {
  /// Tool name.
  public var name: String
  /// The name it was stored or last saved under; empty for one never saved.
  public var originalName: String
  /// Not yet on the server.
  public var isNew: Bool
  /// `http` or `stdio`.
  public var transport: String
  /// Description.
  public var description: String
  /// Endpoint, for `http`.
  public var url: String
  /// Executable, for `stdio`.
  public var command: String
  /// Arguments, space separated, for `stdio`.
  public var arguments: String
  /// Headers (`http`) or environment variables (`stdio`).
  public var credentials: [MCPCredentialEdit]

  /// The editor's identity: the stored name, or the typed one for a new server.
  public var id: String { originalName.isEmpty ? "new:\(name)" : originalName }

  /// Creates an edit.
  public init(
    name: String = "", originalName: String = "", isNew: Bool, transport: String = "http",
    description: String = "", url: String = "", command: String = "", arguments: String = "",
    credentials: [MCPCredentialEdit] = []
  ) {
    self.name = name
    self.originalName = originalName
    self.isNew = isNew
    self.transport = transport
    self.description = description
    self.url = url
    self.command = command
    self.arguments = arguments
    self.credentials = credentials
  }
}

/// Adds or changes one MCP server: its transport (new servers only), URL or command and
/// arguments, description, and its headers or environment variables.
struct MCPServerEditorSheet: View {
  let server: MCPServerEdit
  /// Names other servers use.
  let taken: Set<String>
  let save: @MainActor (MCPServerEdit) -> Void
  let cancel: @MainActor () -> Void

  @State private var edit = MCPServerEdit(isNew: true)

  var body: some View {
    NavigationStack {
      Form {
        Section {
          TextField("Name", text: $edit.name, prompt: Text("docs"))
            .disabled(!server.isNew)
          Picker("Transport", selection: $edit.transport) {
            Text("HTTP").tag("http")
            Text("Command").tag("stdio")
          }
          .disabled(!server.isNew)
          if edit.transport == "http" {
            TextField("URL", text: $edit.url, prompt: Text("https://example.com/mcp"))
          } else {
            TextField("Command", text: $edit.command, prompt: Text("npx"))
            TextField("Arguments", text: $edit.arguments, prompt: Text("-y @scope/server"))
          }
          TextField("Description", text: $edit.description)
        }
        credentialSection
        if let problem {
          Text(problem).font(.caption).foregroundStyle(Theme.failure)
        }
      }
      .formStyle(.grouped)
      .navigationTitle(server.isNew ? "Add MCP Server" : "Edit \(server.name)")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: cancel) }
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") {
            var saved = edit
            saved.name = saved.name.trimmingCharacters(in: .whitespaces)
            if saved.isNew { saved.originalName = saved.name }
            save(saved)
          }
          .disabled(problem != nil)
          .accessibilityIdentifier("mcp-server-done")
        }
      }
    }
    #if os(macOS)
      .frame(width: 460, height: 460)
    #endif
    .onAppear { edit = server }
  }

  private var credentialTitle: String { edit.transport == "http" ? "Headers" : "Environment" }

  private var credentialSection: some View {
    Section {
      ForEach($edit.credentials) { $credential in
        HStack {
          TextField("Name", text: $credential.name).disabled(credential.existing)
          if credential.action == .replace || !credential.existing {
            SecureField("Value", text: $credential.value)
          } else {
            Text(credential.action == .remove ? "Removed" : "Stored")
              .foregroundStyle(.secondary)
          }
          Menu("Change") {
            if credential.existing { Button("Keep") { credential.action = .keep } }
            Button("Replace") { credential.action = .replace }
            Button("Remove") {
              if credential.existing {
                credential.action = .remove
              } else {
                edit.credentials.removeAll { $0.id == credential.id }
              }
            }
          }
          .fixedSize()
        }
      }
    } header: {
      HStack {
        Text(credentialTitle)
        Spacer()
        Button("Add", systemImage: "plus") {
          edit.credentials.append(MCPCredentialEdit(name: "", action: .replace, existing: false))
        }
      }
    } footer: {
      Text("Stored values are never shown. Keep them, replace them or remove them.")
        .font(.caption)
    }
  }

  /// Why the server cannot be saved yet.
  private var problem: String? {
    let name = edit.name.trimmingCharacters(in: .whitespaces)
    if name.isEmpty { return "Name the server." }
    if taken.contains(name) { return "Another MCP server has this name." }
    if edit.transport == "http" {
      let url = edit.url.trimmingCharacters(in: .whitespaces)
      if !(url.hasPrefix("http://") || url.hasPrefix("https://")) {
        return "Use an HTTP or HTTPS URL."
      }
    } else if edit.command.trimmingCharacters(in: .whitespaces).isEmpty {
      return "Enter the command."
    }
    if edit.credentials.contains(where: { $0.name.trimmingCharacters(in: .whitespaces).isEmpty }) {
      return "Name each \(edit.transport == "http" ? "header" : "variable")."
    }
    return nil
  }
}
