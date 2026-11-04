import Foundation
import OmnigentCoreFFI
import OmnigentUIComponents

/// Maps the core's custom agents to the create sheet and Settings, and the forms back.
enum CustomAgentsAdapter {
  /// The harnesses a custom agent can run on, the default first.
  static var harnesses: [AgentHarnessOption] {
    agentHarnessChoices().map { AgentHarnessOption(id: $0.id, label: $0.label) }
  }

  /// The core's draft for the form.
  static func draft(_ form: AgentForm) -> AgentDraft {
    AgentDraft(
      name: form.name, description: form.description, instructions: form.instructions,
      harness: form.harness, model: form.model,
      mcpServers: form.mcpServers.map {
        McpServerForm(
          name: $0.name, transport: $0.transport == .http ? .http : .stdio, command: $0.command,
          arguments: $0.arguments, environment: $0.environment, url: $0.url, headers: $0.headers)
      })
  }

  /// Why the form cannot be saved yet.
  static func problem(_ form: AgentForm) -> String? {
    agentDraftProblem(draft: draft(form))
  }

  static func rows(_ agents: [ManagedAgent]) -> [CustomAgentRow] {
    agents.map {
      CustomAgentRow(
        id: $0.id, name: $0.name, description: $0.description, harness: $0.harnessLabel,
        created: $0.createdAt.map(date), edited: $0.updatedAt.map(date))
    }
  }

  static func form(_ config: AgentConfig) -> CustomAgentConfigForm {
    CustomAgentConfigForm(
      id: config.id, name: config.name, description: config.description ?? "",
      instructions: config.instructions ?? "", model: config.model ?? "",
      harness: config.harness ?? "",
      mcpServers: config.mcpServers.map {
        let target = $0.url ?? ([$0.command ?? ""] + $0.args).joined(separator: " ")
        return CustomAgentMCPServer(
          id: $0.name, summary: "\($0.transport) \u{00B7} \(target)", isEditable: $0.editable)
      })
  }

  static func edit(_ form: CustomAgentConfigForm) -> AgentConfigEdit {
    AgentConfigEdit(
      description: form.description, instructions: form.instructions, model: form.model,
      harness: form.harness, removedMcpServers: form.removedMCPServers.sorted())
  }

  private static func date(_ seconds: UInt64) -> Date {
    Date(timeIntervalSince1970: TimeInterval(seconds))
  }
}
