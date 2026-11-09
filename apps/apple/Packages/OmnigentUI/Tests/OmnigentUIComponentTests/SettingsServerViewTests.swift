#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  @Suite("Server settings window, clicked", .serialized)
  @MainActor
  struct SettingsServerViewTests {
    private let log = ActionLog()
    private let server = EditedValue<String?>("one")
    private let pane = EditedValue<ServerSettingsPane?>(nil)

    private var actions: ServerSettingsActions {
      var actions = ServerSettingsActions()
      let log = log
      actions.load = { log.record("load \($0.rawValue)") }
      actions.setHarnessEnabled = { log.record("harness \($0.id) \($1)") }
      return actions
    }

    private func state(
      panes: [ServerSettingsPane] = ServerSettingsPane.allCases
    ) -> ServerSettingsViewState {
      var state = ServerSettingsViewState(
        servers: [
          ServerChoice(id: "one", name: "One", url: "https://one.test"),
          ServerChoice(id: "two", name: "Two", url: "https://two.test"),
        ],
        panes: panes)
      state.harnesses = [
        ServerHarness(id: "codex", name: "Codex", harness: "codex", isEnabled: true, note: "Set up")
      ]
      return state
    }

    private func screen(
      _ state: ServerSettingsViewState, actions: ServerSettingsActions? = nil,
      hosted: @escaping (ServerSettingsPane) -> AnyView? = { _ in nil }
    ) -> OffscreenWindow<some View> {
      SystemSideEffects.reset()
      let server = server
      let pane = pane
      return OffscreenWindow(
        ServerSettingsView(
          state: state, selectedServer: server.binding, selectedPane: pane.binding,
          actions: actions ?? self.actions, hostedPane: hosted), width: 900, height: 700)
    }

    @Test(
      "each pane shows when selected, and loads when shown",
      arguments: [
        (ServerSettingsPane.account, "Change password"),
        (.harnesses, "Codex"),
        (.customAgents, "Custom agents are not available here."),
        (.mcp, "No MCP services."),
        (.integrations, "No integrations."),
        (.git, "Worktrees"),
        (.importSessions, "No machine is online."),
        (.members, "No members."),
        (.policies, "No default policies."),
        (.archived, "No archived sessions."),
      ])
    func panes(pane selected: ServerSettingsPane, text: String) async throws {
      pane.value = selected
      let screen = screen(state())
      defer { screen.close() }
      try await screen.letTasksRun()
      #expect(try screen.shows(text))
      #expect(log.entries == ["load \(selected.rawValue)"])
    }

    @Test("the sidebar's sections keep Admin and Archived apart, each pane once")
    func sidebar() throws {
      let screen = screen(state())
      defer { screen.close() }
      let shown = try screen.shownText()
      #expect(shown.contains("Admin"))
      for pane in ServerSettingsPane.allCases {
        #expect(shown.contains(pane.title), "\(pane)")
      }
    }

    @Test("a pane this server doesn't offer falls back to its first")
    func unavailablePane() async throws {
      pane.value = .members
      let screen = screen(state(panes: [.git, .mcp]))
      defer { screen.close() }
      try await screen.letTasksRun()
      #expect(log.entries == ["load git"])
      #expect(try !screen.shows("Admin"))
    }

    @Test("no panes at all asks to sign in, and loads nothing")
    func noPanes() async throws {
      let screen = screen(state(panes: []))
      defer { screen.close() }
      try await screen.letTasksRun()
      #expect(try screen.shows("Sign in to a server to see its settings."))
      #expect(log.entries.isEmpty)
    }

    @Test("an error shows over the pane, which stays usable")
    func errorOverPane() throws {
      var state = state(panes: [.git])
      state.errorMessage = "The server is unreachable"
      state.isLoading = true
      let screen = screen(state)
      defer { screen.close() }
      #expect(try screen.shows("The server is unreachable"))
      #expect(try screen.shows("Worktrees"))
    }

    @Test("a save in progress disables the pane's controls")
    func saving() throws {
      var state = state(panes: [.harnesses])
      state.isSaving = true
      let screen = screen(state)
      defer { screen.close() }
      let toggle = try #require(screen.switches.first)
      try screen.click(toggle)
      #expect(!log.entries.contains { $0.hasPrefix("harness") })
    }

    @Test("a harness switch sends that harness, and shows its note")
    func harnessToggle() throws {
      pane.value = .harnesses
      let screen = screen(state())
      defer { screen.close() }
      #expect(try screen.shows("Set up"))
      try screen.click(try #require(screen.switches.first))
      #expect(log.entries.contains("harness codex false"))
    }

    @Test("without the action, a harness switch can't change")
    func harnessWithoutAction() throws {
      pane.value = .harnesses
      let screen = screen(state(), actions: ServerSettingsActions())
      defer { screen.close() }
      #expect(screen.switches.first?.isEnabled == false)
    }

    @Test("a pane the host draws replaces the built-in one, and only that pane")
    func hostedPane() throws {
      pane.value = .git
      let screen = screen(state()) { pane in
        pane == .git ? AnyView(Text("Host's own Git")) : nil
      }
      defer { screen.close() }
      #expect(try screen.shows("Host's own Git"))
      #expect(try !screen.shows("Worktrees"))
    }

    @Test("the server picker chooses the server, and the pane reloads for it")
    func serverPicker() async throws {
      pane.value = .git
      let screen = screen(state())
      defer { screen.close() }
      try await screen.letTasksRun()
      #expect(log.entries == ["load git"])
      try screen.choose("Two", inPopUp: try #require(screen.popUps.first { $0.title == "One" }))
      #expect(server.value == "two")
    }

    @Test("without a binding the view keeps its own pane")
    func localPane() async throws {
      SystemSideEffects.reset()
      let server = server
      let screen = OffscreenWindow(
        ServerSettingsView(state: state(), selectedServer: server.binding, actions: actions),
        width: 900, height: 700)
      defer { screen.close() }
      try await screen.letTasksRun()
      #expect(log.entries == ["load account"])
    }
  }
#endif
