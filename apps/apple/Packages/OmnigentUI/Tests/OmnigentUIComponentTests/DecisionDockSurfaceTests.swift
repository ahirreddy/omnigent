#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  /// What the dock leaves to the transcript, and who answers Command-Return.
  @Suite("Decision dock: inline cards and the shortcut", .serialized)
  @MainActor
  struct DecisionDockSurfaceTests {
    private let log = DecisionDockLog()

    private func open(
      _ state: ConversationViewState, startsExpanded: Bool = false,
      surfaces: DecisionSurfaces? = nil, owner: CommandReturnOwner? = nil
    ) -> (OffscreenWindow<DecisionDockScreen>, DecisionDockModelHost) {
      openDock(
        state, log: log, startsExpanded: startsExpanded, surfaces: surfaces, owner: owner)
    }

    private func request(_ id: String) -> DecisionCard {
      .sample(id: id, detail: "Do \(id)")
    }

    // MARK: Inline cards

    private func onScreen(_ ids: String...) -> DecisionSurfaces {
      let surfaces = DecisionSurfaces()
      for id in ids {
        surfaces.report(
          id,
          placement: InlineDecisionPlacement(
            card: CGRect(x: 0, y: 0, width: 100, height: 100),
            viewport: CGRect(x: 0, y: 0, width: 100, height: 400), showsApprove: true))
      }
      return surfaces
    }

    @Test("A request on screen inline is only named by the dock")
    func summaryOne() throws {
      let (screen, _) = open(.requests([request("one")]), surfaces: onScreen("one"))
      defer { screen.close() }
      #expect(try screen.shows("1 request needs you \u{00B7} Answer it above"))
      #expect(screen.buttons.isEmpty)
    }

    @Test("Several on screen inline are named together")
    func summaryMany() throws {
      let (screen, _) = open(
        .requests([request("one"), request("two")]), surfaces: onScreen("one", "two"))
      defer { screen.close() }
      #expect(try screen.shows("2 requests need you \u{00B7} Answer them above"))
    }

    @Test("With one inline and one not, the dock lists the other and counts the first as above")
    func partlyInline() throws {
      let (screen, _) = open(
        .requests([request("one"), request("two")]), surfaces: onScreen("one"))
      defer { screen.close() }
      #expect(try screen.shows("2 requests need you \u{00B7} 1 above"))
      #expect(try screen.shows("Do two"))
      #expect(try !screen.shows("Do one"))
      #expect(screen.buttons.count == 4)
      try screen.tapButton(0)
      #expect(try screen.shows("2 requests need you \u{00B7} 1 above"))
      #expect(try screen.shows("Collapse"))
    }

    @Test("A card scrolled into view reports itself, and the dock leaves it to the transcript")
    func reporterDrivesDock() throws {
      let surfaces = DecisionSurfaces()
      let card = request("one")
      let root = VStack(spacing: 0) {
        ScrollView {
          Color.clear.frame(height: 200).reportsInlineDecision("one", showsApprove: true)
        }
        DecisionDock(state: .requests([card]), actions: log.actions)
          .decisionBottomBar(surfaces)
      }
      .environment(surfaces)
      .frame(width: 800, height: 600)
      let screen = OffscreenWindow(root)
      defer { screen.close() }
      screen.settle()
      #expect(surfaces.visibility.onScreen == ["one"])
      #expect(surfaces.visibility.approvable == ["one"])
      #expect(try screen.shows("Answer it above"))
    }

    @Test("Without a tracker a card just draws, and leaving the screen clears its report")
    func reporterEdges() throws {
      let bare = OffscreenWindow(Text("Bare").reportsInlineDecision("one", showsApprove: true))
      defer { bare.close() }
      bare.settle()
      #expect(try bare.shows("Bare"))

      let surfaces = DecisionSurfaces()
      let toggle = DecisionDockModelHost(.requests([request("one")]))
      let root = ScrollView {
        DecisionDockReporter(host: toggle)
      }
      .environment(surfaces)
      .frame(width: 800, height: 600)
      let screen = OffscreenWindow(root)
      defer { screen.close() }
      screen.settle()
      #expect(surfaces.visibility.onScreen == ["one"])
      toggle.state = .requests([])
      screen.settle()
      #expect(surfaces.visibility.onScreen.isEmpty)
    }

    // MARK: Command-Return

    private func pressCommandReturn(_ screen: OffscreenWindow<DecisionDockScreen>) throws {
      _ = try screen.pressShortcut(
        keyCode: ComposerKey.returnKey, characters: "\r", modifiers: .command)
    }

    @Test("Command-Return approves the first row that can answer")
    func shortcutRow() throws {
      let (screen, _) = open(.requests([.command("a\nb", id: "long"), request("short")]))
      defer { screen.close() }
      try pressCommandReturn(screen)
      #expect(log.responses == ["short:Approved"])
    }

    @Test("Command-Return approves the selected request when expanded")
    func shortcutExpanded() throws {
      let (screen, _) = open(.requests([request("one"), request("two")]), startsExpanded: true)
      defer { screen.close() }
      try screen.tapButton(2)
      try pressCommandReturn(screen)
      #expect(log.responses == ["two:Approved"])
    }

    @Test("Command-Return is the draft's when the draft owns it")
    func shortcutOwnedBySend() throws {
      let (screen, _) = open(.requests([request("one")]), owner: .send)
      defer { screen.close() }
      try pressCommandReturn(screen)
      #expect(log.responses.isEmpty)
    }
  }
  /// A card row that leaves the transcript when its request does.
  private struct DecisionDockReporter: View {
    @Bindable var host: DecisionDockModelHost

    var body: some View {
      if !host.state.decisions.isEmpty {
        Color.clear.frame(height: 200).reportsInlineDecision("one", showsApprove: false)
      }
    }
  }
#endif
