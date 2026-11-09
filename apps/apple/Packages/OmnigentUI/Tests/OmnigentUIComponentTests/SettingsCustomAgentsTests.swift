#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  @Suite("Custom agents, clicked", .serialized)
  @MainActor
  struct SettingsCustomAgentsTests {
    private let log = ActionLog()
    private let store: UserDefaults

    init() throws {
      store = try #require(UserDefaults(suiteName: "settings-agents-\(UUID())"))
    }

    private func row(_ id: String, description: String? = nil) -> CustomAgentRow {
      CustomAgentRow(
        id: id, name: "Agent \(id)", description: description, harness: "codex",
        created: Date(timeIntervalSince1970: 0), edited: Date(timeIntervalSince1970: 86_400))
    }

    private var actions: CustomAgentsSettingsActions {
      let log = log
      return CustomAgentsSettingsActions(
        create: { log.record("create") }, edit: { log.record("edit \($0.id)") },
        save: { form in
          let edits = form.mcpEdits.keys.sorted()
          log.record(
            "save \(form.description) \(form.model) \(form.harness)"
              + " removed=\(form.removedMCPServers.sorted()) edits=\(edits)")
        },
        remove: { log.record("remove \($0) \($1)") }, closeEditor: { log.record("close") })
    }

    private func screen(
      _ state: CustomAgentsSettingsState, actions: CustomAgentsSettingsActions? = nil
    ) -> OffscreenWindow<some View> {
      let actions = actions ?? self.actions
      return settingsForm(store: store, height: 1_000) {
        CustomAgentsSettingsSection(state: state, actions: actions)
      }
    }

    private var form: CustomAgentConfigForm {
      CustomAgentConfigForm(
        id: "mine", name: "Mine", description: "Old", instructions: "Do", model: "m1",
        harness: "codex",
        mcpServers: [
          CustomAgentMCPServer(
            id: "docs", summary: "http \u{00B7} https://docs.test", isEditable: true,
            edit: MCPServerEdit(
              name: "docs", originalName: "docs", isNew: false, url: "https://docs.test")),
          CustomAgentMCPServer(id: "managed", summary: "stdio", isEditable: false),
        ])
    }

    private func editorState(
      _ form: CustomAgentConfigForm? = nil, harnesses: [AgentHarnessOption] = []
    ) -> CustomAgentsSettingsState {
      CustomAgentsSettingsState(editing: form ?? self.form, harnesses: harnesses)
    }

    @Test("the lists show who made what, and Create and Edit act")
    func lists() throws {
      let state = CustomAgentsSettingsState(
        serverAgents: [row("server", description: "Built in")], myAgents: [row("mine")])
      let screen = screen(state)
      defer { screen.close() }
      for text in ["Agent mine", "Agent server", "Built in", "codex \u{00B7} Created"] {
        #expect(try screen.shows(text), "\(text)")
      }
      // Create, then this row's Edit.
      try screen.clickButton(at: 0)
      try screen.clickButton(at: 1)
      #expect(log.entries == ["create", "edit mine"])
    }

    @Test("a server that can't read configurations offers no Edit")
    func withoutEdit() throws {
      let actions = CustomAgentsSettingsActions(
        create: {}, edit: nil, save: { _ in }, remove: { _, _ in }, closeEditor: {})
      let screen = screen(CustomAgentsSettingsState(myAgents: [row("mine")]), actions: actions)
      defer { screen.close() }
      #expect(screen.buttonFrames.count == 1, "only Create")
    }

    @Test("empty lists say so, but not while loading")
    func empty() throws {
      let empty = screen(CustomAgentsSettingsState())
      defer { empty.close() }
      #expect(try empty.shows("No custom agents yet."))
      #expect(try empty.shows("No server agents."))
      let loading = screen(CustomAgentsSettingsState(isLoading: true))
      defer { loading.close() }
      #expect(try !loading.shows("No custom agents yet."))
    }

    @Test("search narrows both lists by name or description")
    func search() throws {
      let state = CustomAgentsSettingsState(
        serverAgents: [row("server", description: "Finds bugs")], myAgents: [row("mine")])
      let screen = screen(state)
      defer { screen.close() }
      let field = try #require(screen.textFields.first)
      try screen.replaceText(in: field, with: "bugs")
      #expect(try screen.shows("Agent server"))
      #expect(try !screen.shows("Agent mine"))
      try screen.replaceText(in: field, with: " MINE ")
      #expect(try screen.shows("Agent mine"))
      #expect(try !screen.shows("Agent server"))
    }

    @Test("a right click deletes after asking")
    func contextMenuDelete() throws {
      let screen = screen(CustomAgentsSettingsState(myAgents: [row("mine")]))
      defer { screen.close() }
      let edit = try #require(screen.buttonFrames.last)
      let menu = try #require(try screen.contextMenu(at: CGPoint(x: 60, y: edit.midY - 6)))
      SystemSideEffects.answer(alert: .alertSecondButtonReturn)
      try screen.choose("Delete\u{2026}", in: menu)
      #expect(SystemSideEffects.record.alertMessages == ["Delete Agent mine?"])
      #expect(log.entries.isEmpty)
      SystemSideEffects.answer(alert: .alertFirstButtonReturn)
      try screen.choose("Delete\u{2026}", in: menu)
      #expect(log.entries == ["remove mine false"])
    }

    @Test("errors show on both the list and the editor")
    func errors() throws {
      let list = screen(CustomAgentsSettingsState(errorMessage: "Refused"))
      defer { list.close() }
      #expect(try list.shows("Refused"))
      var state = editorState()
      state.errorMessage = "Refused too"
      let editor = screen(state)
      defer { editor.close() }
      #expect(try editor.shows("Refused too"))
    }

    @Test("the editor waits for the configuration")
    func loadingConfig() throws {
      let screen = screen(CustomAgentsSettingsState(isLoadingConfig: true))
      defer { screen.close() }
      #expect(try screen.shows("Custom Agents"))
      #expect(screen.textFields.isEmpty)
      try screen.clickButton(at: 0)
      #expect(log.entries == ["close"])
    }

    @Test("Save stays off until something changed, then sends every edit")
    func save() throws {
      let harnesses = [
        AgentHarnessOption(id: "codex", label: "Codex"),
        AgentHarnessOption(id: "claude", label: "Claude"),
      ]
      let screen = screen(editorState(harnesses: harnesses))
      defer { screen.close() }
      let before = screen.buttonFrames.count
      try screen.replaceText(in: try #require(screen.textFields.first), with: "New")
      try screen.replaceText(in: try #require(screen.textFields.last), with: "m2")
      try screen.choose("Claude", inPopUp: try #require(screen.popUps.first))
      #expect(screen.buttonFrames.count == before + 1, "Save joined the controls")
      let save = try #require(screen.buttonFrames.last)
      try screen.click(CGPoint(x: save.midX, y: save.midY))
      #expect(log.entries == [#"save New m2 claude removed=[] edits=[]"#])
    }

    @Test("a harness this server no longer offers still shows as chosen")
    func unknownHarness() throws {
      let screen = screen(editorState())
      defer { screen.close() }
      #expect(screen.popUps.first?.title == "codex")
    }

    @Test("Remove marks a server, and Keep takes it back; a managed one can't change")
    func removeAndKeep() throws {
      let screen = screen(editorState())
      defer { screen.close() }
      // Back, Add, docs' Edit and Remove; Delete Agent is destructive, Save is off.
      #expect(try screen.shows("Remove"))
      try screen.clickButton(at: 3)
      #expect(try screen.shows("Keep"))
      let save = try #require(screen.buttonFrames.last)
      try screen.click(CGPoint(x: save.midX, y: save.midY))
      #expect(log.entries.last?.contains(#"removed=["docs"]"#) == true, "\(log.entries)")
      // With docs removed its Edit is gone, so Keep is now third.
      try screen.clickButton(at: 2)
      #expect(try !screen.shows("Keep"))
    }

    @Test("Add opens the server editor, and what's added is listed as new until removed")
    func addServer() throws {
      var empty = form
      empty.mcpServers = []
      let screen = screen(editorState(empty))
      defer { screen.close() }
      #expect(try screen.shows("None"))
      // Back, Add.
      try screen.clickButton(at: 1)
      screen.settle(0.3)
      #expect(try screen.shows("Add MCP Server"))
      try screen.replaceText(in: try #require(screen.textFields.first), with: "wiki")
      try screen.replaceText(
        in: try #require(screen.textFields.dropFirst().first), with: "https://w.test")
      let done = try #require(screen.sheetButtons.last)
      try screen.click(CGPoint(x: done.midX, y: done.midY))
      screen.settle(0.3)
      #expect(screen.window.attachedSheet == nil)
      #expect(try screen.shows("wiki"))
      #expect(try screen.shows("New"))
      #expect(try !screen.shows("None"))
      // Back, Add, Edit, Remove.
      try screen.clickButton(at: 3)
      #expect(try !screen.shows("wiki"))
    }

    @Test("renaming a server just added replaces it instead of leaving both")
    func renameAdded() throws {
      var empty = form
      empty.mcpServers = []
      let screen = screen(editorState(empty))
      defer { screen.close() }
      try screen.clickButton(at: 1)
      screen.settle(0.3)
      try screen.replaceText(in: try #require(screen.textFields.first), with: "wiki")
      try screen.replaceText(
        in: try #require(screen.textFields.dropFirst().first), with: "https://w.test")
      try screen.click(try #require(screen.sheetButtons.last).center)
      screen.settle(0.3)
      // Back, Add, then the added row's Edit.
      try screen.clickButton(at: 2)
      screen.settle(0.3)
      try screen.replaceText(in: try #require(screen.textFields.first), with: "docs2")
      try screen.click(try #require(screen.sheetButtons.last).center)
      screen.settle(0.3)
      #expect(try screen.shows("docs2"))
      #expect(try !screen.shows("wiki"))
      let save = try #require(screen.buttonFrames.last)
      try screen.click(save.center)
      #expect(log.entries.last?.contains(#"edits=["docs2"]"#) == true, "\(log.entries)")
    }

    @Test("Edit opens the stored server, whose name can't change")
    func editServer() throws {
      let screen = screen(editorState())
      defer { screen.close() }
      try screen.clickButton(at: 2)
      screen.settle(0.3)
      #expect(try screen.shows("Edit docs"))
      #expect(screen.textFields.first?.isEnabled == false)
      // The toolbar ends Cancel, Done.
      let cancel = try #require(screen.sheetButtons.suffix(2).first)
      try screen.click(CGPoint(x: cancel.midX, y: cancel.midY))
      screen.settle(0.3)
      #expect(screen.window.attachedSheet == nil)
      #expect(log.entries.isEmpty)
    }

    @Test("Delete Agent asks first, and an agent in use can still be removed on purpose")
    func deleteInUse() throws {
      var state = editorState()
      state.inUseMessage = "2 sessions use it"
      let screen = screen(state)
      defer { screen.close() }
      #expect(try !screen.shows("2 sessions use it"), "nothing was deleted yet")
      // Back, Add, docs' Edit and Remove, Delete Agent.
      SystemSideEffects.answer(alert: .alertSecondButtonReturn)
      try screen.clickButton(at: 4)
      #expect(SystemSideEffects.record.alertMessages == ["Delete Mine?"])
      #expect(log.entries.isEmpty, "declined")
      SystemSideEffects.answer(alert: .alertFirstButtonReturn)
      try screen.clickButton(at: 4)
      #expect(log.entries == ["remove mine false"])
      #expect(try screen.shows("2 sessions use it"))
      // Remove Anyway joins right after Back.
      try screen.clickButton(at: 1)
      #expect(log.entries == ["remove mine false", "remove mine true"])
    }
  }

  @Suite("MCP server editor, clicked", .serialized)
  @MainActor
  struct SettingsMCPEditorTests {
    private let log = ActionLog()

    private func screen(
      _ server: MCPServerEdit, taken: Set<String> = []
    ) -> OffscreenWindow<some View> {
      let log = log
      return sheetScreen {
        MCPServerEditorSheet(
          server: server, taken: taken,
          save: { edit in
            log.record(
              "save \(edit.name) \(edit.transport) \(edit.url) \(edit.command) "
                + "\(edit.credentials.map { "\($0.name)=\($0.action)" })")
          }, cancel: { log.record("cancel") })
      }
    }

    private var existing: MCPServerEdit {
      MCPServerEdit(
        name: "docs", originalName: "docs", isNew: false, url: "https://docs.test",
        credentials: [MCPCredentialEdit(name: "AUTH", existing: true)])
    }

    @Test("a new server starts with what's wrong, and Done stays off until it's right")
    func problems() throws {
      let screen = screen(MCPServerEdit(isNew: true), taken: ["docs"])
      defer { screen.close() }
      #expect(try screen.shows("Name the server."))
      let name = try #require(screen.textFields.first)
      try screen.replaceText(in: name, with: "docs")
      #expect(try screen.shows("Another MCP server has this name."))
      try screen.replaceText(in: name, with: "wiki")
      #expect(try screen.shows("Use an HTTP or HTTPS URL."))
      try screen.replaceText(
        in: try #require(screen.textFields.dropFirst().first), with: " https://w.test ")
      #expect(try !screen.shows("Use an HTTP"))
      let done = try #require(screen.sheetButtons.last)
      try screen.click(CGPoint(x: done.midX, y: done.midY))
      #expect(log.entries == ["save wiki http https://w.test  []"])
    }

    @Test("the Command transport asks for a command and arguments instead")
    func commandTransport() throws {
      let screen = screen(MCPServerEdit(name: "tool", isNew: true))
      defer { screen.close() }
      try screen.choose("Command", inPopUp: try #require(screen.popUps.first))
      #expect(try screen.shows("Enter the command."))
      #expect(try screen.shows("Environment"))
      try screen.replaceText(in: try #require(screen.textFields.dropFirst().first), with: "npx")
      #expect(try !screen.shows("Enter the command."))
    }

    @Test("a stored server's name and transport can't change, and Cancel saves nothing")
    func stored() throws {
      let screen = screen(existing)
      defer { screen.close() }
      #expect(try screen.shows("Edit docs"))
      #expect(screen.textFields.first?.isEnabled == false)
      #expect(screen.popUps.first?.isEnabled == false)
      try screen.clickSheetButton(at: screen.sheetButtons.count - 2)
      #expect(log.entries == ["cancel"])
    }

    @Test("a stored credential is kept, replaced or removed, never shown")
    func storedCredential() throws {
      let screen = screen(existing)
      defer { screen.close() }
      #expect(try screen.shows("Stored"))
      #expect(screen.secureFields.isEmpty)
      let change = try #require(screen.popUps.last)
      try screen.choose("Replace", inPopUp: change)
      #expect(screen.secureFields.count == 1)
      try screen.choose("Remove", inPopUp: try #require(screen.popUps.last))
      #expect(try screen.shows("Removed"))
      try screen.choose("Keep", inPopUp: try #require(screen.popUps.last))
      #expect(try screen.shows("Stored"))
    }

    @Test("an added credential needs a name, and removing it drops the row")
    func addedCredential() throws {
      let screen = screen(MCPServerEdit(name: "w", isNew: true, url: "https://w.test"))
      defer { screen.close() }
      #expect(try !screen.shows("Name each header."))
      // The section's Add sits above the toolbar's Cancel and Done.
      try screen.clickSheetButton(at: screen.sheetButtons.count - 3)
      #expect(try screen.shows("Name each header."))
      #expect(screen.secureFields.count == 1)
      // A menu's blank first item is its own title; Keep is only for what's stored.
      let change = try #require(screen.popUps.first { $0.title == "Change" })
      #expect(try screen.titles(inPopUp: change) == ["", "Replace", "Remove"])
      try screen.choose("Remove", inPopUp: change)
      #expect(try !screen.shows("Name each header."))
      #expect(screen.secureFields.isEmpty)
    }
  }
#endif
