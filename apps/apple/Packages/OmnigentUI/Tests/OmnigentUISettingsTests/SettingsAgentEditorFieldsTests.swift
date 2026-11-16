#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents
  @testable import OmnigentUITestSupport

  @Suite("Custom agent editor, typed into", .serialized)
  @MainActor
  struct SettingsAgentEditorFieldsTests {
    private let saved = EditedValue<[CustomAgentConfigForm]>([])
    private let store: UserDefaults

    init() throws {
      store = try #require(UserDefaults(suiteName: "settings-agent-fields-\(UUID())"))
    }

    @Test("typed instructions turn Save on, and Save sends them with the rest unchanged")
    func instructions() throws {
      let form = CustomAgentConfigForm(
        id: "mine", name: "Mine", description: "Old", instructions: "Do", model: "m1",
        harness: "codex", mcpServers: [])
      let saved = saved
      let actions = CustomAgentsSettingsActions(
        create: {}, edit: nil, save: { saved.value.append($0) }, remove: { _, _ in },
        closeEditor: {})
      let screen = settingsForm(store: store, height: 1_000) {
        CustomAgentsSettingsSection(
          state: CustomAgentsSettingsState(editing: form), actions: actions)
      }
      defer { screen.close() }
      let before = screen.buttonFrames.count
      let editor = try #require(
        screen.allViews.lazy.compactMap { $0 as? NSTextView }.first { $0.isEditable })
      #expect(editor.string == "Do")
      try screen.click(editor)
      editor.selectAll(nil)
      try screen.type("Review the diff")
      #expect(screen.buttonFrames.count == before + 1, "Save joined the controls")
      try screen.click(try #require(screen.buttonFrames.last).center)
      #expect(saved.value.map(\.instructions) == ["Review the diff"])
      var expected = form
      expected.instructions = "Review the diff"
      #expect(saved.value == [expected])
    }
  }

  @Suite("MCP server editor, typed into", .serialized)
  @MainActor
  struct SettingsMCPEditorFieldsTests {
    private let saved = EditedValue<[MCPServerEdit]>([])

    private func screen(_ server: MCPServerEdit) -> OffscreenWindow<some View> {
      let saved = saved
      return sheetScreen {
        MCPServerEditorSheet(
          server: server, taken: [], save: { saved.value.append($0) }, cancel: {})
      }
    }

    private func field(
      _ placeholder: String, in screen: OffscreenWindow<some View>
    ) throws -> NSTextField {
      try #require(
        screen.textFields.first { $0.placeholderString == placeholder },
        "no field with the placeholder \(placeholder)")
    }

    @Test("a command server's command, arguments and description are saved as typed")
    func commandFields() throws {
      let screen = screen(MCPServerEdit(name: "tool", isNew: true))
      defer { screen.close() }
      try screen.choose("Command", inPopUp: try #require(screen.popUps.first))
      try screen.replaceText(in: try field("npx", in: screen), with: "uvx")
      try screen.replaceText(in: try field("-y @scope/server", in: screen), with: "-q docs-mcp")
      // Name, Command, Arguments, Description.
      try #require(screen.textFields.count == 4)
      try screen.replaceText(in: screen.textFields[3], with: "Reads the docs")
      try screen.click(try #require(screen.sheetButtons.last).center)
      let edit = try #require(saved.value.first)
      #expect(saved.value.count == 1)
      #expect(edit.transport == "stdio")
      #expect(edit.command == "uvx")
      #expect(edit.arguments == "-q docs-mcp")
      #expect(edit.description == "Reads the docs")
    }

    @Test("an added header's name and value are saved as typed, to replace what's stored")
    func credentialFields() throws {
      let screen = screen(MCPServerEdit(name: "wiki", isNew: true, url: "https://w.test"))
      defer { screen.close() }
      // The section's Add sits above the toolbar's Cancel and Done.
      try screen.clickSheetButton(at: screen.sheetButtons.count - 3)
      #expect(try screen.shows("Name each header."))
      // The header's name sits on its value's row.
      let value = try #require(screen.secureFields.first)
      let root = screen.activeWindow.contentView
      let row = value.convert(value.bounds, to: root).midY
      let name = try #require(
        screen.textFields.first { abs($0.convert($0.bounds, to: root).midY - row) < 8 },
        "no field beside the value")
      try screen.replaceText(in: name, with: "Authorization")
      #expect(try !screen.shows("Name each header."), "\(screen.textFields.map(\.stringValue))")
      try screen.replaceText(in: value, with: "Bearer abc")
      try screen.click(try #require(screen.sheetButtons.last).center)
      let edit = try #require(saved.value.first)
      #expect(edit.credentials.map(\.name) == ["Authorization"])
      #expect(edit.credentials.map(\.value) == ["Bearer abc"])
      #expect(edit.credentials.map(\.action) == [.replace])
      #expect(edit.credentials.map(\.existing) == [false])
    }
  }
#endif
