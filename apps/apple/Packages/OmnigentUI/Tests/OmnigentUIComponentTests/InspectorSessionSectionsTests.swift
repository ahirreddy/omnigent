#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  @Suite("Inspector: the session panel's lists", .serialized)
  @MainActor
  struct InspectorSessionSectionsTests {
    private let files = EventSection(
      id: "files-a", title: "Files", summary: "4 files in repo",
      details: [
        DetailSection(id: "1", title: "src/new.swift", text: "added"),
        DetailSection(id: "2", title: "src/gone.swift", text: "deleted"),
        DetailSection(id: "3", title: "src/moved.swift", text: "renamed"),
        DetailSection(id: "4", title: "src/edit.swift", text: "modified"),
      ])

    @Test("Changed files show name, letter, folder and the section's summary")
    func changedFiles() throws {
      let screen = inspectorPanel([files])
      defer { screen.close() }
      #expect(try screen.shows("Changed Files"))
      #expect(try screen.shows("new.swift"))
      #expect(try screen.shows("src"))
      #expect(try screen.shows("A"))
      #expect(try screen.shows("D"))
      #expect(try screen.shows("R"))
      #expect(try screen.shows("M"))
      #expect(try screen.shows("4 files in repo"))
    }

    @Test("A changed files section with no list shows its summary alone")
    func changedFilesSummaryOnly() throws {
      let screen = inspectorPanel([EventSection(id: "files-a", title: "", summary: "Nothing yet")])
      defer { screen.close() }
      #expect(try screen.shows("Nothing yet"))
    }

    @Test("A changed file's menu copies its path")
    func copyPath() throws {
      let screen = inspectorPanel([files])
      defer { screen.close() }
      // The form isn't a table, so the first row with the menu is found by walking down it.
      var chosen = false
      for height in stride(from: CGFloat(0), to: 1_100, by: 8) where !chosen {
        if let menu = try screen.contextMenu(at: CGPoint(x: 60, y: height)),
          menu.item(named: "Copy Path") != nil
        {
          try screen.choose("Copy Path", in: menu)
          chosen = true
        }
      }
      #expect(chosen)
      #expect(SystemSideEffects.pasteboard.string(forType: .string) == "src/new.swift")
    }

    @Test("A subagent's row opens its session")
    func subagent() throws {
      var opened: [String] = []
      var actions = ConversationActions()
      actions.openSession = { opened.append($0) }
      let screen = inspectorPanel(
        [EventSection(id: "child-a", title: "Tester", summary: "Running", sessionId: "child-1")],
        actions: actions)
      defer { screen.close() }
      #expect(try screen.shows("Subagents"))
      #expect(try screen.shows("Tester"))
      #expect(try screen.shows("Running"))
      // The copy button, then the subagent.
      #expect(screen.controlFrames.count == 2)
      let row = try #require(screen.controlFrames.last)
      try screen.click(CGPoint(x: row.minX + 4, y: row.midY))
      #expect(opened == ["child-1"])
    }

    @Test("A subagent with no session opens nothing")
    func subagentWithoutSession() throws {
      var opened: [String] = []
      var actions = ConversationActions()
      actions.openSession = { opened.append($0) }
      let screen = inspectorPanel(
        [EventSection(id: "child-a", title: "Tester", summary: "Starting")], actions: actions)
      defer { screen.close() }
      let row = try #require(screen.controlFrames.last)
      try screen.click(CGPoint(x: row.minX + 4, y: row.midY))
      #expect(opened.isEmpty)
    }

    @Test("Without a way to open sessions the subagent button is disabled")
    func subagentDisabled() throws {
      let screen = inspectorPanel([
        EventSection(id: "child-a", title: "Tester", summary: "Running", sessionId: "child-1")
      ])
      defer { screen.close() }
      #expect(try screen.shows("Tester"))
      // Only the copy button.
      #expect(screen.controlFrames.count == 1)
    }

    @Test("Environment sections list sandbox, MCP, terminals and resources")
    func environment() throws {
      let screen = inspectorPanel([
        EventSection(id: "sandbox", title: "Sandbox", summary: "Read only"),
        EventSection(id: "mcp", title: "MCP", summary: "2 servers"),
        EventSection(id: "terminal-pending", title: "Terminal", summary: "Waiting"),
        EventSection(id: "resource-1", title: "Data", summary: "1 file"),
      ])
      defer { screen.close() }
      #expect(try screen.shows("Environment"))
      #expect(try screen.shows("Read only"))
      #expect(try screen.shows("2 servers"))
      #expect(try screen.shows("Waiting"))
      #expect(try screen.shows("1 file"))
      #expect(try !screen.shows("Other"))
    }

    @Test("Unknown sections go under Other, and a section with details expands to show them")
    func other() throws {
      let screen = inspectorPanel([
        EventSection(id: "custom", title: "Custom", summary: "Value"),
        EventSection(
          id: "details", title: "Detailed", summary: "More",
          details: [DetailSection(id: "d", title: "Inner", text: "Inner text")]),
      ])
      defer { screen.close() }
      #expect(try screen.shows("Other"))
      #expect(try screen.shows("Custom"))
      #expect(try screen.shows("More"))
      #expect(try !screen.shows("Inner text"))
      try screen.clickControl(at: screen.controlFrames.count - 1)
      screen.settle(0.1)
      #expect(try screen.shows("Inner text"))
    }

    @Test("Lifecycle history counts its rows and opens to show them")
    func lifecycle() throws {
      let screen = inspectorPanel(rows: [
        Row(
          id: "a", role: .tool, activity: Activity(kind: .command, title: "Started"),
          isActivityOnly: true),
        Row(
          id: "b", role: .tool, activity: Activity(kind: .command, title: "Stopped"),
          isActivityOnly: true),
        Row(id: "c", role: .user, text: "Hi"),
      ])
      defer { screen.close() }
      #expect(try screen.shows("Lifecycle history (2)"))
      #expect(try !screen.shows("Started"))
      try screen.clickControl(at: screen.controlFrames.count - 1)
      screen.settle(0.1)
      #expect(try screen.shows("Started"))
    }
  }
#endif
