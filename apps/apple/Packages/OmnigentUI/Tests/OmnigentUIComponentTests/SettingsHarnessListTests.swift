#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  @Suite("Harness list and details, clicked", .serialized)
  @MainActor
  struct SettingsHarnessListTests {
    private let log = ActionLog()
    private let store: UserDefaults

    init() throws {
      store = try #require(UserDefaults(suiteName: "settings-harness-\(UUID())"))
    }

    private var actions: HarnessesSettingsActions {
      let log = log
      return HarnessesSettingsActions(
        selectHost: { log.record("host \($0)") }, setUp: { log.record("setup \($0.id)") },
        refresh: { log.record("refresh") }, open: { log.record("open \($0.id)") })
    }

    private var state: HarnessesSettingsState {
      HarnessesSettingsState(
        hosts: [
          HarnessesSettingsHost(id: "mac", name: "Mac", isOnline: true),
          HarnessesSettingsHost(id: "old", name: "Old", isOnline: false),
        ],
        selectedHostID: "mac",
        rows: [
          HarnessesSettingsRow(
            id: "codex", name: "Codex", description: "From OpenAI", status: "Configured",
            isReady: true, needsSetup: false),
          HarnessesSettingsRow(
            id: "claude", name: "Claude Code", description: "From Anthropic",
            status: "Needs sign-in", isReady: false, needsSetup: true),
          HarnessesSettingsRow(
            id: "unknown", name: "Unknown", description: "Unreported", status: nil, isReady: false,
            needsSetup: false),
        ])
    }

    private func list(
      _ state: HarnessesSettingsState? = nil, actions: HarnessesSettingsActions? = nil
    ) -> OffscreenWindow<some View> {
      let state = state ?? self.state
      let actions = actions ?? self.actions
      return settingsForm(store: store) {
        HarnessesSettingsSection(state: state, actions: actions)
      }
    }

    @Test("the host picker marks offline machines and chooses by id")
    func hostPicker() throws {
      let screen = list()
      defer { screen.close() }
      let picker = try #require(screen.popUps.first)
      #expect(try screen.titles(inPopUp: picker) == ["Mac", "Old (offline)"])
      try screen.choose("Old (offline)", inPopUp: picker)
      #expect(log.entries == ["host old"])
    }

    @Test("no hosts says what to do, unless they're still loading")
    func noHosts() throws {
      let empty = list(HarnessesSettingsState())
      defer { empty.close() }
      #expect(try empty.shows("Connect a host to see and set up its harnesses."))
      let loading = list(HarnessesSettingsState(isLoading: true))
      defer { loading.close() }
      #expect(try !loading.shows("Connect a host"))
    }

    @Test("Refresh, Set Up and Details each act on their own row")
    func rowButtons() throws {
      let screen = list()
      defer { screen.close() }
      #expect(try screen.shows("Needs sign-in"))
      // Refresh, Codex's Details, Claude's Set Up and Details; Unknown reports nothing to open.
      let buttons = screen.buttonFrames
      try #require(buttons.count == 4)
      for button in buttons { try screen.click(CGPoint(x: button.midX, y: button.midY)) }
      #expect(log.entries == ["refresh", "open codex", "setup claude", "open claude"])
    }

    @Test("without a details action, rows only offer Set Up")
    func noDetails() throws {
      let log = log
      let actions = HarnessesSettingsActions(
        selectHost: { _ in }, setUp: { log.record("setup \($0.id)") }, refresh: {})
      let screen = list(actions: actions)
      defer { screen.close() }
      #expect(screen.buttonFrames.count == 2)
    }

    @Test("Configured hides what isn't ready, and says so when nothing is")
    func configuredFilter() throws {
      let screen = list()
      defer { screen.close() }
      let filter = try #require(screen.segmentedControls.first)
      try screen.click(segment: 1, of: filter)
      #expect(try screen.shows("Codex"))
      #expect(try !screen.shows("Claude Code"))
      var none = state
      none.rows = [none.rows[1]]
      let empty = list(none)
      defer { empty.close() }
      try empty.click(segment: 1, of: try #require(empty.segmentedControls.first))
      #expect(try empty.shows("No configured harnesses."))
    }

    @Test("search matches names and descriptions, and names what found nothing")
    func search() throws {
      let screen = list()
      defer { screen.close() }
      let field = try #require(screen.textFields.first)
      try screen.replaceText(in: field, with: "anthropic")
      #expect(try screen.shows("Claude Code"))
      #expect(try !screen.shows("Codex"))
      try screen.replaceText(in: field, with: "OPENAI")
      #expect(try screen.shows("Codex"))
      #expect(try !screen.shows("Claude Code"))
      try screen.replaceText(in: field, with: "zzz")
      #expect(try screen.shows("No harnesses match \u{201C}zzz\u{201D}."))
    }

    @Test("a failed load says why")
    func failure() throws {
      var failed = state
      failed.errorMessage = "The host stopped answering"
      let screen = list(failed)
      defer { screen.close() }
      #expect(try screen.shows("The host stopped answering"))
    }

    private var detailActions: HarnessDetailActions {
      let log = log
      return HarnessDetailActions(
        back: { log.record("back") }, fixWarning: { log.record("warning") },
        fixCredential: { log.record("credential") })
    }

    private func detail(_ state: HarnessDetailState) -> OffscreenWindow<some View> {
      let actions = detailActions
      return settingsForm(store: store) { HarnessDetailView(state: state, actions: actions) }
    }

    @Test("Back, the warning's fix and the credential's fix each do their own thing")
    func detailButtons() throws {
      let state = HarnessDetailState(
        harness: "codex", name: "Codex", hostName: "Mac", status: "Needs sign-in",
        warning: .init(message: "Out of date", action: "Update"), credentialLabel: "ChatGPT",
        credentialDescription: "Signed out", credentialWarning: true,
        credentialAction: "Sign In Again", notice: "Updated to 1.2")
      let screen = detail(state)
      defer { screen.close() }
      for text in ["Needs sign-in", "Out of date", "Signed out", "Updated to 1.2", "Mac"] {
        #expect(try screen.shows(text), "\(text)")
      }
      let buttons = screen.buttonFrames
      try #require(buttons.count == 3)
      for button in buttons { try screen.click(CGPoint(x: button.midX, y: button.midY)) }
      #expect(log.entries == ["back", "warning", "credential"])
    }

    @Test("a ready harness with nothing to fix reads Configured, and offers no fix")
    func detailReady() throws {
      let state = HarnessDetailState(
        harness: "codex", name: "Codex", hostName: "Mac", isReady: true,
        warning: .init(message: "Can't fix here", action: nil), credentialLabel: "Key",
        credentialDescription: "Stored")
      let screen = detail(state)
      defer { screen.close() }
      #expect(try screen.shows("Configured"))
      #expect(screen.buttonFrames.count == 1, "only Back")
    }

    private func startup(_ startup: HarnessDetailState.Startup) -> OffscreenWindow<some View> {
      detail(
        HarnessDetailState(
          harness: "codex", name: "Codex", hostName: "Mac", credentialLabel: "Key",
          credentialDescription: "Stored", startup: startup))
    }

    @Test("startup reports each state it can be in")
    func startupStates() throws {
      let hidden = startup(.hidden)
      defer { hidden.close() }
      #expect(try !hidden.shows("Startup Configuration"))
      let loading = startup(.loading)
      defer { loading.close() }
      #expect(try loading.shows("Startup Configuration"))
      let unavailable = startup(.unavailable("Update Mac to see launch settings."))
      defer { unavailable.close() }
      #expect(try unavailable.shows("Update Mac to see launch settings."))
    }

    @Test("a loaded startup lists its command, environment and arguments, blank ones visibly")
    func startupLoaded() throws {
      let loaded = HarnessStartupState(
        command: "/bin/codex", found: false, source: "From the host.", listsEnvironment: true,
        environment: [.init(name: "TOKEN", value: "abc"), .init(name: "BLANK", value: "")],
        environmentNote: "Inherited", arguments: ["--flag", ""], argumentsNote: "unused")
      let screen = startup(.loaded(loaded))
      defer { screen.close() }
      for text in [
        "/bin/codex", "Executable not found.", "TOKEN", "abc", "BLANK", "\"\"", "Inherited",
        "--flag", "From the host.",
      ] {
        #expect(try screen.shows(text), "\(text)")
      }
      #expect(try !screen.shows("unused"))
    }

    @Test("a startup with nothing listed says so, or leaves it to the note")
    func startupEmpty() throws {
      var empty = HarnessStartupState(
        command: "codex", found: true, source: "Default.", listsEnvironment: true, environment: [],
        environmentNote: "", arguments: [], argumentsNote: "3 arguments")
      let listed = startup(.loaded(empty))
      defer { listed.close() }
      #expect(try listed.shows("None configured"))
      #expect(try listed.shows("3 arguments"))
      #expect(try !listed.shows("Executable not found."))
      empty.listsEnvironment = false
      let unlisted = startup(.loaded(empty))
      defer { unlisted.close() }
      #expect(try !unlisted.shows("None configured"))
    }
  }
#endif
