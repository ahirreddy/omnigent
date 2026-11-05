import Foundation
import OmnigentCoreFFI
import OmnigentUIComponents
import Testing

@testable import OmnigentAppUI

@MainActor
struct CustomAgentsAdapterTests {
  @Test func harnessesStartWithTheDefault() {
    #expect(
      CustomAgentsAdapter.harnesses.first
        == AgentHarnessOption(id: "claude-sdk", label: "Claude SDK"))
  }

  @Test func formValidationIsTheCoresRule() {
    var form = AgentForm(harness: "codex")
    #expect(CustomAgentsAdapter.problem(form) == "Name the agent.")
    form.name = "bad name"
    #expect(CustomAgentsAdapter.problem(form) != nil)
    form.name = "reviewer"
    form.model = "gpt-5"
    #expect(CustomAgentsAdapter.problem(form) == nil)
  }

  @Test func mcpRowsKeepTheirTransport() {
    var form = AgentForm(harness: "codex")
    var server = AgentMCPServerForm()
    server.name = "docs"
    server.transport = .http
    server.url = "https://example.com/mcp"
    form.mcpServers = [server]
    let draft = CustomAgentsAdapter.draft(form)
    #expect(draft.mcpServers.first?.transport == .http)
    #expect(draft.mcpServers.first?.url == "https://example.com/mcp")
  }

  @Test func configRoundTripsToAnEdit() {
    let config = AgentConfig(
      id: "a1", name: "reviewer", version: 2, description: nil, instructions: "Be terse.",
      model: "m", harness: "codex",
      mcpServers: [
        AgentMcpServer(
          name: "fs", transport: "stdio", url: nil, command: "npx", args: ["-y", "fs"],
          editable: true)
      ], etag: "\"e\"")
    var form = CustomAgentsAdapter.form(config)
    #expect(form.mcpServers.first?.summary == "stdio \u{00B7} npx -y fs")
    form.removedMCPServers = ["fs"]
    form.model = "m2"
    let edit = CustomAgentsAdapter.edit(form)
    #expect(edit.removedMcpServers == ["fs"])
    #expect(edit.model == "m2")
    #expect(edit.description.isEmpty)
  }

  @Test func addedAndChangedServersBecomeCoreEdits() throws {
    let config = AgentConfig(
      id: "a1", name: "reviewer", version: 2, description: nil, instructions: nil,
      model: "m", harness: "codex",
      mcpServers: [
        AgentMcpServer(
          name: "docs", transport: "http", url: "https://d/mcp", command: nil, args: [],
          editable: true, description: "Docs", credentialNames: ["Authorization"])
      ], etag: nil)
    var form = CustomAgentsAdapter.form(config)
    var docs = try #require(form.mcpServers.first?.edit)
    #expect(docs.credentials.map(\.name) == ["Authorization"])
    #expect(docs.credentials.first?.existing == true)
    docs.url = "https://d/v2"
    docs.credentials[0].action = .remove
    form.mcpEdits["docs"] = docs
    form.mcpEdits["fs"] = MCPServerEdit(
      name: "fs", originalName: "fs", isNew: true, transport: "stdio", command: "npx",
      arguments: "-y  fs")
    let edits = CustomAgentsAdapter.edit(form).mcpServers
    #expect(edits.map(\.name) == ["docs", "fs"])
    #expect(edits[0].credentials.first?.action == .remove)
    #expect(edits[1].args == ["-y", "fs"])
    form.removedMCPServers = ["docs"]
    #expect(CustomAgentsAdapter.edit(form).mcpServers.map(\.name) == ["fs"])
  }

  @Test func rowsCarryDates() {
    let rows = CustomAgentsAdapter.rows([
      ManagedAgent(
        id: "a1", name: "reviewer", description: nil, harness: "codex", harnessLabel: "Codex",
        createdAt: 86_400, updatedAt: nil, builtin: false)
    ])
    #expect(rows.first?.created == Date(timeIntervalSince1970: 86_400))
    #expect(rows.first?.harness == "Codex")
  }
}
