#if os(macOS)
  import Foundation
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  @Suite("Custom agent screens with hostile data", .serialized)
  struct CustomAgentScreensRenderTests {
    private static let actions = CustomAgentsSettingsActions(
      create: {}, edit: { _ in }, save: { _ in }, remove: { _, _ in }, closeEditor: {})
    private static let harnesses = [
      AgentHarnessOption(id: "claude", label: "Claude Code"),
      AgentHarnessOption(id: "codex", label: "Codex"),
    ]

    private static var realisticAgents: [CustomAgentRow] {
      [
        CustomAgentRow(
          id: "a1", name: "reviewer", description: "Reviews pull requests", harness: "Claude Code",
          created: Date(timeIntervalSince1970: 1_793_880_000), edited: nil)
      ]
    }

    private static var hostileAgents: [CustomAgentRow] {
      (0..<HostileData.formRowCount).map { index in
        CustomAgentRow(
          id: "\(index)", name: HostileData.text(index),
          description: index.isMultiple(of: 2) ? nil : HostileData.text(index + 1),
          harness: HostileData.text(index + 2), created: HostileData.date(index),
          edited: HostileData.date(index + 1))
      }
    }

    private static func editing(text: String, servers: [CustomAgentMCPServer] = [])
      -> CustomAgentConfigForm
    {
      CustomAgentConfigForm(
        id: "a1", name: text, description: text, instructions: text, model: text,
        harness: "missing-harness", mcpServers: servers)
    }

    private static var hostileServers: [CustomAgentMCPServer] {
      (0..<HostileData.formRowCount).map { index in
        CustomAgentMCPServer(
          id: "\(index)\(HostileData.text(index))", summary: HostileData.text(index + 1),
          isEditable: index.isMultiple(of: 2),
          edit: index.isMultiple(of: 2)
            ? MCPServerEdit(name: HostileData.text(index), isNew: false) : nil)
      }
    }

    private static var hostileHarnesses: [AgentHarnessOption] {
      (0..<HostileData.formRowCount).map {
        AgentHarnessOption(id: "\($0)", label: HostileData.text($0))
      }
    }

    private static func serverEdit(transport: String, text: String) -> MCPServerEdit {
      MCPServerEdit(
        name: text, originalName: text, isNew: text.isEmpty, transport: transport,
        description: text, url: text, command: text, arguments: text,
        credentials: (0..<HostileData.samples.count).map { index in
          MCPCredentialEdit(
            name: HostileData.text(index), value: HostileData.text(index + 1),
            action: [.keep, .replace, .remove][index % 3], existing: index.isMultiple(of: 2))
        })
    }

    nonisolated static let screens: [ScreenCase] = [
      ScreenCase("custom-agents-realistic", realistic: true) {
        GroupedFormHost {
          CustomAgentsSettingsSection(
            state: CustomAgentsSettingsState(
              serverAgents: realisticAgents, myAgents: realisticAgents), actions: actions)
        }
      },
      ScreenCase("custom-agents-empty", realistic: true, narrowOnly: true) {
        GroupedFormHost {
          CustomAgentsSettingsSection(state: CustomAgentsSettingsState(), actions: actions)
        }
      },
      ScreenCase("custom-agents-loading", narrowOnly: true) {
        GroupedFormHost {
          CustomAgentsSettingsSection(
            state: CustomAgentsSettingsState(isLoading: true), actions: actions)
        }
      },
      ScreenCase("custom-agents-hostile") {
        GroupedFormHost {
          CustomAgentsSettingsSection(
            state: CustomAgentsSettingsState(
              serverAgents: hostileAgents, myAgents: hostileAgents,
              errorMessage: HostileData.bidirectional, inUseMessage: HostileData.unbroken),
            actions: actions)
        }
      },
      ScreenCase("custom-agent-editor-loading", narrowOnly: true) {
        GroupedFormHost {
          CustomAgentsSettingsSection(
            state: CustomAgentsSettingsState(isLoadingConfig: true), actions: actions)
        }
      },
      ScreenCase("custom-agent-editor-realistic", realistic: true, narrowOnly: true) {
        GroupedFormHost {
          CustomAgentsSettingsSection(
            state: CustomAgentsSettingsState(
              editing: editing(text: "reviewer"), harnesses: harnesses), actions: actions)
        }
      },
      ScreenCase("custom-agent-editor-hostile") {
        GroupedFormHost {
          CustomAgentsSettingsSection(
            state: CustomAgentsSettingsState(
              editing: editing(text: HostileData.bidirectional, servers: hostileServers),
              harnesses: hostileHarnesses, isSaving: true, errorMessage: HostileData.bidirectional),
            actions: actions)
        }
      },
      ScreenCase("custom-agent-editor-long-text", narrowOnly: true) {
        GroupedFormHost {
          CustomAgentsSettingsSection(
            state: CustomAgentsSettingsState(
              editing: editing(text: HostileData.unbroken), harnesses: [],
              errorMessage: HostileData.unbroken), actions: actions)
        }
      },
      ScreenCase("mcp-editor-realistic", realistic: true) {
        MCPServerEditorSheet(
          server: MCPServerEdit(
            name: "docs", originalName: "docs", isNew: false, url: "https://example.com/mcp"),
          taken: ["other"], save: { _ in }, cancel: {})
      },
      ScreenCase("mcp-editor-new-blank", narrowOnly: true) {
        MCPServerEditorSheet(
          server: MCPServerEdit(isNew: true), taken: [], save: { _ in }, cancel: {})
      },
      ScreenCase("mcp-editor-unknown-transport-hostile") {
        MCPServerEditorSheet(
          server: serverEdit(transport: HostileData.controlCharacters, text: HostileData.unbroken),
          taken: [HostileData.unbroken], save: { _ in }, cancel: {})
      },
      ScreenCase("mcp-editor-stdio-hostile", narrowOnly: true) {
        MCPServerEditorSheet(
          server: serverEdit(transport: "stdio", text: HostileData.bidirectional), taken: [],
          save: { _ in }, cancel: {})
      },
      ScreenCase("create-agent-realistic", realistic: true) {
        CreateAgentSheet(
          harnesses: harnesses, notice: "Agents are saved on this server.",
          problem: { _ in "Name the agent." }, save: { _ in }, importBundle: {}, cancel: {})
      },
      ScreenCase("create-agent-no-harnesses", narrowOnly: true) {
        CreateAgentSheet(harnesses: [], problem: { _ in nil }, save: { _ in }, cancel: {})
      },
      ScreenCase("create-agent-hostile") {
        CreateAgentSheet(
          harnesses: hostileHarnesses, title: HostileData.unbroken,
          saveLabel: HostileData.bidirectional, notice: HostileData.bidirectional, isSaving: true,
          errorMessage: HostileData.bidirectional, problem: { _ in HostileData.controlCharacters },
          save: { _ in }, cancel: {})
      },
      ScreenCase("create-agent-long-text", narrowOnly: true) {
        CreateAgentSheet(
          harnesses: harnesses, notice: HostileData.unbroken, errorMessage: HostileData.unbroken,
          problem: { _ in HostileData.unbroken }, save: { _ in }, cancel: {})
      },
    ]

    @Test("renders without crashing or hanging", arguments: screens)
    func render(screen: ScreenCase) throws {
      try ScreenRenderer.check(screen)
    }
  }

  @Suite("MCP server edits")
  struct MCPServerEditTests {
    @Test("a stored server keeps its identity while renamed; a new one follows its typed name")
    func identity() {
      var stored = MCPServerEdit(name: "docs", originalName: "docs", isNew: false)
      stored.name = "renamed"
      #expect(stored.id == "docs")
      var new = MCPServerEdit(name: "first", isNew: true)
      #expect(new.id == "new:first")
      new.name = ""
      #expect(new.id == "new:")
    }

    @Test("credential rows stay distinct, even with the same name and value")
    func credentialIdentity() {
      let first = MCPCredentialEdit(name: "TOKEN", existing: true)
      let second = MCPCredentialEdit(name: "TOKEN", existing: true)
      #expect(first.id != second.id)
    }
  }
#endif
