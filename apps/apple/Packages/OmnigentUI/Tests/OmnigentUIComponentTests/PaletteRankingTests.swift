#if os(macOS)
  import Foundation
  import Testing

  @testable import OmnigentUIComponents

  @Suite("Command palette: ranking and catalog")
  struct PaletteRankingTests {
    private func entry(_ title: String, keywords: [String] = []) -> PaletteEntry {
      PaletteEntry(
        id: title, title: title, detail: "", symbol: "x", keywords: keywords,
        target: .session(title))
    }

    @Test("exact and prefix matches lead, then contains, then scattered letters")
    func ranking() {
      let entries = [
        entry("Go to Settings"), entry("settings"), entry("My settings page"),
        entry("sxextxtxinxgs"),
      ]
      let results = PaletteSearch.results(entries, query: "settings").map(\.title)
      #expect(results.first == "settings")
      #expect(results.last == "sxextxtxinxgs")
    }

    @Test("case and accents don't matter; spaces inside a query don't stop it")
    func folding() {
      let entries = [entry("Caf\u{E9} Ol\u{E9}")]
      #expect(!PaletteSearch.results(entries, query: "cafe").isEmpty)
      #expect(!PaletteSearch.results(entries, query: "CAF\u{C9}").isEmpty)
      #expect(!PaletteSearch.results(entries, query: "c o").isEmpty)
      #expect(PaletteSearch.results(entries, query: "zebra").isEmpty)
    }

    @Test("a blank query lists everything; titles-only skips keywords")
    func blankAndTitles() {
      let entries = [entry("One", keywords: ["needle"])]
      #expect(PaletteSearch.results(entries, query: "  \n").count == 1)
      #expect(PaletteSearch.results(entries, query: "needle").count == 1)
      #expect(PaletteSearch.results(entries, query: "needle", titlesOnly: true).isEmpty)
    }

    @Test("hostile queries don't crash")
    func hostile() {
      let entries = [
        entry("\u{1F680} rocket"), entry(""), entry(String(repeating: "x", count: 5_000)),
      ]
      for query in [
        "\u{0}", "\u{1F680}\u{200D}\u{1F680}", "[.*", String(repeating: "x", count: 6_000),
      ] {
        _ = PaletteSearch.results(entries, query: query)
        _ = PaletteSearch.highlighted("\u{1F680} rocket", query: query)
      }
    }

    @Test("the title's first match is bold, ignoring case and accents")
    func highlighted() {
      let text = PaletteSearch.highlighted("Caf\u{E9} bar", query: " CAFE ")
      let bold = text.runs.filter { $0.inlinePresentationIntent == .stronglyEmphasized }
      #expect(bold.count == 1)
      let boldText = bold.map { String(text[$0.range].characters) }
      #expect(boldText == ["Caf\u{E9}"])
      let none = PaletteSearch.highlighted("Bar", query: "zebra")
      let noneBold = none.runs.filter { $0.inlinePresentationIntent != nil }
      #expect(noneBold.isEmpty)
      #expect(PaletteSearch.highlighted("Bar", query: "").runs.count == 1)
    }

    @MainActor
    @Test("the catalog enables session actions only with a session, and pages with the server")
    func catalog() {
      var state = PaletteViewState(scope: "S", sessions: [], servers: [], hasNextRequest: false)
      func ids(_ entries: [PaletteEntry]) -> [String] { entries.map(\.id) }
      let bare = PaletteCatalog.entries(state: state, commands: SessionCommandActions())
      #expect(!ids(bare).contains("automations") && !ids(bare).contains("usage"))
      let off = bare.filter { !$0.isEnabled }.map(\.id)
      #expect(Set(off) == ["inspector", "next", "changes", "composer", "terminal"])

      state.showsAutomations = true
      state.showsUsage = true
      state.hasNextRequest = true
      var commands = SessionCommandActions()
      commands.toggleInspector = {}
      commands.openChanges = {}
      commands.focusComposer = {}
      commands.toggleViewMode = {}
      let full = PaletteCatalog.entries(state: state, commands: commands)
      let fullOff = full.filter { !$0.isEnabled }
      #expect(fullOff.isEmpty)
      #expect(ids(full).prefix(4) == ["new", "inbox", "automations", "usage"])
    }

    @Test("results group as the web's, without repeats")
    func sections() {
      let state = PaletteViewState(
        scope: "S", sessions: (0..<8).map { entry("Session \($0)") },
        servers: [entry("Server one")], hasNextRequest: false)
      let commands = [entry("Do session thing")]
      let idle = PaletteResults.sections(
        scope: .all, query: "", commands: commands, state: state, found: .init())
      #expect(idle.map(\.title) == ["Sessions", "Actions"])
      #expect(idle[0].entries.count == PaletteResults.idleSessionLimit)
      let found = PaletteSearchResults(
        titles: [entry("Session 1"), entry("Far")], messages: [entry("Far"), entry("Note")])
      let typed = PaletteResults.sections(
        scope: .all, query: "session", commands: commands, state: state, found: found)
      #expect(typed.map(\.title) == ["Sessions", "In messages", "Actions"])
      let sessionOne = typed[0].entries.filter { $0.title == "Session 1" }
      #expect(sessionOne.count == 1)
      #expect(typed[1].entries.map(\.title) == ["Note"])
      let servers = PaletteResults.sections(
        scope: .servers, query: "", commands: commands, state: state, found: found)
      #expect(servers.map(\.title) == ["Servers"])
      let sessionsOnly = PaletteResults.sections(
        scope: .sessions, query: "Far", commands: commands, state: state, found: found)
      #expect(sessionsOnly.first?.entries.map(\.title) == ["Session 1", "Far"])
      let none = PaletteResults.sections(
        scope: .servers, query: "zzz", commands: commands, state: state, found: found)
      #expect(none.isEmpty)
    }
  }
#endif
