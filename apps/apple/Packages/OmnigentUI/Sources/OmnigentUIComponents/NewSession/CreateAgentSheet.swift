public import SwiftUI

/// One MCP server row in the create-agent form.
nonisolated public struct AgentMCPServerForm: Hashable, Sendable, Identifiable {
  /// How the server runs.
  public enum Transport: String, Hashable, Sendable, CaseIterable { case stdio, http }

  /// Row id.
  public var id = UUID()
  /// Tool name.
  public var name = ""
  /// Transport.
  public var transport = Transport.stdio
  /// Executable (stdio).
  public var command = ""
  /// Space-separated arguments (stdio).
  public var arguments = ""
  /// `KEY=VALUE` lines (stdio).
  public var environment = ""
  /// Endpoint (http).
  public var url = ""
  /// `Name: value` lines (http).
  public var headers = ""

  /// An empty row.
  public init() {}
}

/// The create-agent form, as typed.
nonisolated public struct AgentForm: Hashable, Sendable {
  /// Name: letters, numbers, hyphens and underscores.
  public var name = ""
  /// Description.
  public var description = ""
  /// Instructions (`AGENTS.md`).
  public var instructions = ""
  /// Harness id.
  public var harness: String
  /// Model.
  public var model = ""
  /// MCP servers.
  public var mcpServers: [AgentMCPServerForm] = []

  /// An empty form on `harness`.
  public init(harness: String) {
    self.harness = harness
  }
}

/// A harness a custom agent can run on.
nonisolated public struct AgentHarnessOption: Hashable, Sendable, Identifiable {
  /// Harness id.
  public let id: String
  /// Label.
  public let label: String

  /// Creates an option.
  public init(id: String, label: String) {
    self.id = id
    self.label = label
  }
}

/// The web's "Create custom agent" dialog: name, description, instructions, harness, model and
/// MCP servers, with "Import Bundle…" for a `.tar.gz` made elsewhere. Settings reuses the form
/// with its own title and save label.
public struct CreateAgentSheet: View {
  private let harnesses: [AgentHarnessOption]
  private let title: String
  private let saveLabel: String
  private let notice: String?
  private let isSaving: Bool
  private let errorMessage: String?
  private let problem: @MainActor (AgentForm) -> String?
  private let save: @MainActor (AgentForm) -> Void
  private let importBundle: (@MainActor () -> Void)?
  private let cancel: @MainActor () -> Void
  @State private var form: AgentForm

  /// Creates the sheet.
  /// - Parameters:
  ///   - harnesses: Harness choices, the default first.
  ///   - title: The title.
  ///   - saveLabel: The save button.
  ///   - notice: A note above the form.
  ///   - isSaving: A save is in flight.
  ///   - errorMessage: Why the last save failed.
  ///   - problem: Why the form cannot be saved yet (the core's rule), or `nil`.
  ///   - save: Saves the form.
  ///   - importBundle: Picks a `.tar.gz` bundle instead; `nil` hides it.
  ///   - cancel: Closes the sheet.
  public init(
    harnesses: [AgentHarnessOption], title: String = "Create Custom Agent",
    saveLabel: String = "Create", notice: String? = nil, isSaving: Bool = false,
    errorMessage: String? = nil, problem: @escaping @MainActor (AgentForm) -> String?,
    save: @escaping @MainActor (AgentForm) -> Void,
    importBundle: (@MainActor () -> Void)? = nil, cancel: @escaping @MainActor () -> Void
  ) {
    self.harnesses = harnesses
    self.title = title
    self.saveLabel = saveLabel
    self.notice = notice
    self.isSaving = isSaving
    self.errorMessage = errorMessage
    self.problem = problem
    self.save = save
    self.importBundle = importBundle
    self.cancel = cancel
    _form = State(initialValue: AgentForm(harness: harnesses.first?.id ?? ""))
  }

  /// The sheet.
  public var body: some View {
    NavigationStack {
      Form {
        if let notice { Text(notice).font(.callout).foregroundStyle(.secondary) }
        Section {
          TextField("Name", text: $form.name, prompt: Text("my-agent"))
            .accessibilityIdentifier("create-agent-name")
          TextField("Description", text: $form.description, prompt: Text("Optional"))
          Picker("Harness", selection: $form.harness) {
            ForEach(harnesses) { Text($0.label).tag($0.id) }
          }
          .accessibilityIdentifier("create-agent-harness")
          TextField("Model", text: $form.model, prompt: Text("claude-sonnet-4-5"))
            .accessibilityIdentifier("create-agent-model")
        }
        Section("Instructions") {
          TextEditor(text: $form.instructions)
            .font(.body)
            .frame(minHeight: 80)
            .accessibilityIdentifier("create-agent-instructions")
        }
        Section {
          ForEach($form.mcpServers) { $server in
            mcpRow($server)
          }
          Button("Add MCP Server", systemImage: "plus") {
            form.mcpServers.append(AgentMCPServerForm())
          }
          .accessibilityIdentifier("create-agent-add-mcp")
        } header: {
          Text("MCP Servers")
        }
        if let message = errorMessage ?? visibleProblem {
          Label(message, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(errorMessage == nil ? Theme.warning : Theme.failure)
            .textSelection(.enabled)
            .accessibilityIdentifier("create-agent-error")
        }
      }
      .formStyle(.grouped)
      .disabled(isSaving)
      .navigationTitle(title)
      .toolbar { toolbar }
    }
    #if os(macOS)
      .frame(width: 520, height: 560)
    #endif
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("create-agent-sheet")
  }

  @ToolbarContentBuilder private var toolbar: some ToolbarContent {
    if let importBundle {
      ToolbarItem(placement: Self.importPlacement) {
        Button("Import Bundle\u{2026}", systemImage: "square.and.arrow.down", action: importBundle)
          .disabled(isSaving)
          .accessibilityIdentifier("create-agent-import")
      }
    }
    ToolbarItem(placement: .cancellationAction) {
      Button("Cancel", action: cancel)
    }
    ToolbarItem(placement: .confirmationAction) {
      HStack {
        if isSaving { ProgressView().controlSize(.small) }
        Button(saveLabel) { save(form) }
          .primaryActionStyle()
          .disabled(isSaving || problem(form) != nil)
          .accessibilityIdentifier("create-agent-submit")
      }
    }
  }

  /// A Mac sheet doesn't draw a secondary action at all, so it would have no way to import.
  private static var importPlacement: ToolbarItemPlacement {
    #if os(macOS)
      .automatic
    #else
      .secondaryAction
    #endif
  }

  /// The rule only once the user typed a name, so an empty form is not an error.
  private var visibleProblem: String? {
    form.name.isEmpty ? nil : problem(form)
  }

  private func mcpRow(_ server: Binding<AgentMCPServerForm>) -> some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.small) {
      HStack {
        TextField("Name", text: server.name, prompt: Text("Server name"))
        Picker("Transport", selection: server.transport) {
          Text("Local (stdio)").tag(AgentMCPServerForm.Transport.stdio)
          Text("HTTP").tag(AgentMCPServerForm.Transport.http)
        }
        .labelsHidden()
        .fixedSize()
        Button("Remove", systemImage: "trash") {
          form.mcpServers.removeAll { $0.id == server.wrappedValue.id }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
      }
      switch server.wrappedValue.transport {
      case .stdio:
        TextField("Command", text: server.command, prompt: Text("npx"))
        TextField(
          "Arguments", text: server.arguments, prompt: Text("-y @modelcontextprotocol/server"))
        TextField(
          "Environment", text: server.environment, prompt: Text("KEY=value, one per line"),
          axis: .vertical)
      case .http:
        TextField("URL", text: server.url, prompt: Text("https://example.com/mcp"))
        TextField(
          "Headers", text: server.headers, prompt: Text("Authorization: Bearer …, one per line"),
          axis: .vertical)
      }
    }
    .textFieldStyle(.roundedBorder)
    .labelsHidden()
  }
}
