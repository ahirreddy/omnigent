#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  /// The create-agent sheet: the form as typed, its problems, and each way out.
  @Suite("New session: create agent", .serialized)
  @MainActor
  struct NewSessionCreateAgentTests {
    @MainActor
    private final class Log {
      var saved: [AgentForm] = []
      var imports = 0
      var cancels = 0
    }

    private let log = Log()
    private static let harnesses = [
      AgentHarnessOption(id: "claude", label: "Claude Code"),
      AgentHarnessOption(id: "codex", label: "Codex"),
    ]

    private func open(
      title: String = "Create Custom Agent", saveLabel: String = "Create", notice: String? = nil,
      isSaving: Bool = false, errorMessage: String? = nil, imports: Bool = true,
      problem: @escaping @MainActor (AgentForm) -> String? = { _ in nil }
    ) -> OffscreenWindow<some View> {
      let log = log
      var importBundle: (@MainActor () -> Void)?
      if imports { importBundle = { log.imports += 1 } }
      let screen = OffscreenWindow(
        ComposerSheetHost(
          sheet: CreateAgentSheet(
            harnesses: Self.harnesses, title: title, saveLabel: saveLabel, notice: notice,
            isSaving: isSaving, errorMessage: errorMessage, problem: problem,
            save: { log.saved.append($0) }, importBundle: importBundle,
            cancel: { log.cancels += 1 })))
      screen.settle(0.5)
      return screen
    }

    @Test("What's typed is what's saved, on the harness picked")
    func save() throws {
      let screen = open()
      defer { screen.close() }
      #expect(try screen.shows("Create Custom Agent"))
      try screen.type("my-agent", intoField: 0)
      try screen.type("Helps out", intoField: 1)
      try screen.type("fast", intoField: 2)
      let instructions = try #require(
        screen.allViews.lazy.compactMap { $0 as? NSTextView }.first { !$0.isFieldEditor })
      _ = screen.activeWindow.makeFirstResponder(instructions)
      try screen.type("Be brief")
      let harness = try screen.menu(at: 0)
      #expect(harness.items.map(\.title) == ["Claude Code", "Codex"])
      try screen.choose("Codex", in: harness)
      try screen.tapButton(fromEnd: 0)
      let form = try #require(log.saved.first)
      #expect(form.name == "my-agent")
      #expect(form.description == "Helps out")
      #expect(form.model == "fast")
      #expect(form.harness == "codex")
      #expect(form.instructions == "Be brief")
      #expect(form.mcpServers.isEmpty)
    }

    @Test("The rule shows only once a name is typed, and always blocks saving")
    func problem() throws {
      let screen = open(problem: { _ in "Names need letters" })
      defer { screen.close() }
      #expect(try !screen.shows("Names need letters"))
      try screen.type("!", intoField: 0)
      screen.settle(0.05)
      #expect(try screen.shows("Names need letters"))
      // The disabled save isn't listed, so the last button is Cancel.
      try screen.tapButton(fromEnd: 0)
      #expect(log.saved.isEmpty)
      #expect(log.cancels == 1)
    }

    @Test("A failed save says why, over the rule")
    func errorMessage() throws {
      let screen = open(errorMessage: "Name taken", problem: { _ in "Rule" })
      defer { screen.close() }
      #expect(try screen.shows("Name taken"))
      #expect(try !screen.shows("Rule"))
    }

    @Test("While saving only Cancel still works")
    func saving() throws {
      let screen = open(isSaving: true)
      defer { screen.close() }
      #expect(screen.allViews.contains { $0 is NSProgressIndicator })
      try screen.clickEveryButton()
      #expect(log.saved.isEmpty)
      #expect(log.imports == 0)
      #expect(log.cancels == 1)
    }

    @Test("A notice, title and save label can be the caller's")
    func customWords() throws {
      let screen = open(title: "Edit Agent", saveLabel: "Save", notice: "Changes apply next run")
      defer { screen.close() }
      #expect(try screen.shows("Edit Agent"))
      #expect(try screen.shows("Save"))
      #expect(try screen.shows("Changes apply next run"))
    }

    @Test("Import Bundle imports; without a handler it isn't there")
    func importBundle() throws {
      let screen = open()
      defer { screen.close() }
      let controls = screen.buttons.count
      #expect(try screen.shows("Import Bundle\u{2026}"))
      try screen.tapButton(fromEnd: 2)
      #expect(log.imports == 1)

      let bare = open(imports: false)
      defer { bare.close() }
      #expect(bare.buttons.count == controls - 1)
    }

    @Test("An MCP server is added, filled in for its transport, and removed")
    func mcpServers() throws {
      let screen = open()
      defer { screen.close() }
      #expect(try screen.shows("Add MCP Server"))
      #expect(try !screen.shows("Server name"))
      let before = screen.fields.count
      // Add sits just before the toolbar's Import, Cancel and Create.
      let add = try #require(screen.buttons.dropLast(3).last)
      try screen.click(screen.clickPoint(add))
      screen.scrollToEnd()
      #expect(screen.fields.count == before + 4)
      #expect(try screen.shows("Server name"))
      #expect(try screen.shows("KEY=value, one per line"))
      try screen.type("files", intoField: before)
      try screen.type("npx", intoField: before + 1)
      try screen.type("-y server", intoField: before + 2)
      try screen.type("A=1", intoField: before + 3)
      screen.settle(0.05)
      try screen.tapButton(fromEnd: 0)
      let stdio = try #require(log.saved.last?.mcpServers.first)
      #expect(stdio.name == "files")
      #expect(stdio.transport == .stdio)
      #expect(stdio.command == "npx")
      #expect(stdio.arguments == "-y server")
      #expect(stdio.environment == "A=1")

      // The harness picker comes first, then this row's transport.
      let transport = try screen.menu(at: 1)
      #expect(transport.items.map(\.title) == ["Local (stdio)", "HTTP"])
      try screen.choose("HTTP", in: transport)
      screen.scrollToEnd()
      #expect(try screen.shows("https://example.com/mcp"))
      try screen.type("https://a.test/mcp", intoField: before + 1)
      try screen.type("Authorization: x", intoField: before + 2)
      screen.settle(0.05)
      try screen.tapButton(fromEnd: 0)
      let http = try #require(log.saved.last?.mcpServers.first)
      #expect(http.transport == .http)
      #expect(http.url == "https://a.test/mcp")
      #expect(http.headers == "Authorization: x")
    }

    @Test("Remove takes the server's row away")
    func mcpRemove() throws {
      let screen = open()
      defer { screen.close() }
      let before = screen.fields.count
      // Add sits just before the toolbar's Import, Cancel and Create.
      let add = try #require(screen.buttons.dropLast(3).last)
      try screen.click(screen.clickPoint(add))
      screen.scrollToEnd()
      // The trash is the row's one icon-sized control, at the end of the name's line.
      let name = try #require(screen.fields.dropFirst(before).first)
      let row = name.convert(name.bounds, to: screen.activeWindow.contentView)
      let remove = try #require(
        screen.buttons.last { abs($0.midY - row.midY) < 16 && $0.minX > row.maxX })
      try screen.click(screen.clickPoint(remove))
      // The form animates the row out.
      screen.settle(0.3)
      #expect(screen.fields.count == before)
      #expect(try !screen.shows("Server name"))
      try screen.tapButton(fromEnd: 0)
      #expect(log.saved.last?.mcpServers.isEmpty == true)
    }
  }
#endif
