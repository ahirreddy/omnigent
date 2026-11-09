#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  @Suite("Inspector: the agents tree", .serialized)
  @MainActor
  struct InspectorAgentTreeTests {
    /// Root, one working child with a grandchild, and a settled child with a routed model.
    private let tree = AgentTreeState(
      nodes: [
        AgentTreeNode(
          id: "root", name: "Main", activity: .working, statusLabel: "Working", childCount: 2),
        AgentTreeNode(
          id: "child", parentID: "root", depth: 1, name: "Explorer", role: .explore,
          activity: .working, statusLabel: "Working", preview: "reading files", childCount: 1),
        AgentTreeNode(
          id: "grandchild", parentID: "child", depth: 2, name: "Reader", role: .docs,
          activity: .needsYou, statusLabel: "Needs you"),
        AgentTreeNode(
          id: "settled", parentID: "root", depth: 1, name: "Tester", role: .test, activity: .failed,
          statusLabel: "Failed", statusDetail: "tunnel closed", isSettled: true,
          routedModel: "fast-model"),
      ],
      currentID: "settled")

    private final class Log {
      var opened: [String] = []
      var refreshes = 0
    }

    private func panel(
      _ state: AgentTreeState, log: Log = Log(), canOpen: Bool = true, canRefresh: Bool = true
    ) -> OffscreenWindow<AnyView> {
      var actions = AgentTreeActions()
      if canOpen { actions.open = { log.opened.append($0) } }
      if canRefresh { actions.refresh = { log.refreshes += 1 } }
      return OffscreenWindow(
        AnyView(AgentTreePanel(state: state, actions: actions)), width: 500, height: 500)
    }

    /// The controls in order: Refresh, the view picker, then Main, Explorer's fold control,
    /// Explorer, Reader and Tester.
    private enum Control {
      static let refresh = 0
      static let main = 2
      static let fold = 3
      static let explorer = 4
      static let reader = 5
      static let tester = 6
    }

    @Test("Choosing an agent opens its chat; choosing the one on screen does nothing")
    func opensAgents() throws {
      let log = Log()
      let screen = panel(tree, log: log)
      defer { screen.close() }
      try screen.clickControl(at: Control.explorer)
      try screen.clickControl(at: Control.reader)
      try screen.clickControl(at: Control.main)
      #expect(log.opened == ["child", "grandchild", "root"])
      try screen.clickControl(at: Control.tester)
      #expect(log.opened == ["child", "grandchild", "root"])
    }

    @Test("The rows read as names, latest messages and routed models")
    func rowContent() throws {
      let screen = panel(tree)
      defer { screen.close() }
      for line in ["Main", "Explorer", "reading files", "Reader", "Tester", "fast-model"] {
        #expect(try screen.shows(line))
      }
      #expect(try !screen.shows("Sub-agents this session starts appear here."))
    }

    @Test("Folding an agent hides what's under it, and unfolding brings it back")
    func folding() throws {
      let screen = panel(tree)
      defer { screen.close() }
      try screen.clickControl(at: Control.fold)
      #expect(try !screen.shows("Reader"))
      #expect(try screen.shows("Tester"))
      try screen.clickControl(at: Control.fold)
      #expect(try screen.shows("Reader"))
    }

    @Test("Refresh reads the tree again, and only shows when the app can")
    func refresh() throws {
      let log = Log()
      let screen = panel(tree, log: log)
      defer { screen.close() }
      try screen.clickControl(at: Control.refresh)
      #expect(log.refreshes == 1)

      let without = panel(tree, canRefresh: false)
      defer { without.close() }
      #expect(without.controlFrames.count == screen.controlFrames.count - 1)
    }

    @Test("Agents can't be chosen when the app can't open them, but can still be folded")
    func cannotOpen() throws {
      let screen = panel(tree, canOpen: false, canRefresh: false)
      defer { screen.close() }
      // The view picker and Explorer's fold control.
      #expect(screen.controlFrames.count == 2)
      try screen.clickControl(at: 1)
      #expect(try !screen.shows("Reader"))
    }

    @Test("Before the first read there's a spinner, and a failed read says why")
    func emptyTree() throws {
      let loading = panel(AgentTreeState(nodes: [], currentID: "s", isLoading: true))
      defer { loading.close() }
      #expect(try !loading.shows("Couldn't load"))
      #expect(loading.allViews.contains { $0 is NSProgressIndicator })

      let failed = panel(AgentTreeState(nodes: [], currentID: "s", errorMessage: "boom"))
      defer { failed.close() }
      #expect(try failed.shows("Couldn't load the agents: boom"))
      #expect(!failed.allViews.contains { $0 is NSProgressIndicator })
    }

    @Test("A failed refresh keeps the list and says so above it")
    func failedRefresh() throws {
      var state = tree
      state.errorMessage = "boom"
      let screen = panel(state)
      defer { screen.close() }
      #expect(try screen.shows("Couldn't refresh: boom"))
      #expect(try screen.shows("Explorer"))
    }

    @Test("A session with no sub-agents says where they'd appear")
    func onlyRoot() throws {
      let screen = panel(AgentTreeState(nodes: [tree.nodes[0]], currentID: "root"))
      defer { screen.close() }
      #expect(try screen.shows("Sub-agents this session starts appear here."))
    }

    @Test("The main agent spins while it works")
    func rootSpinner() throws {
      var idle = tree.nodes[0]
      idle.activity = .idle
      let working = panel(AgentTreeState(nodes: [tree.nodes[0]], currentID: "root"))
      defer { working.close() }
      #expect(working.allViews.contains { $0 is NSProgressIndicator })
      let resting = panel(AgentTreeState(nodes: [idle], currentID: "root"))
      defer { resting.close() }
      #expect(!resting.allViews.contains { $0 is NSProgressIndicator })
    }

    @Test("Node help names the reason behind a failure, and each role has its own symbol")
    func nodeFacts() {
      #expect(tree.nodes[3].statusHelp == "Failed: tunnel closed")
      #expect(tree.nodes[1].statusHelp == "Working")
      let symbols = Set(AgentTreeRole.allCases.map(\.systemImage))
      #expect(symbols.count == AgentTreeRole.allCases.count)
    }
  }

  @Suite("Inspector: the agents graph", .serialized)
  @MainActor
  struct InspectorAgentGraphTests {
    private let tree = AgentTreeState(
      nodes: [
        AgentTreeNode(
          id: "root", name: "Main", activity: .working, statusLabel: "Working", childCount: 1),
        AgentTreeNode(
          id: "child", parentID: "root", depth: 1, name: "Explorer", activity: .working,
          statusLabel: "Working", preview: "reading files"),
        AgentTreeNode(
          id: "done", parentID: "root", depth: 1, name: "Finished", activity: .done,
          statusLabel: "Done", isSettled: true),
      ],
      currentID: "root")

    private final class Opened { var ids: [String] = [] }

    private func panelOnGraph(_ opened: Opened? = nil) throws -> OffscreenWindow<AnyView> {
      var actions = AgentTreeActions()
      if let opened { actions.open = { opened.ids.append($0) } }
      let screen = OffscreenWindow(
        AnyView(AgentTreePanel(state: tree, actions: actions)), width: 700, height: 500)
      let picker = try #require(screen.controlFrames.first)
      try screen.click(CGPoint(x: picker.maxX - 6, y: picker.midY))
      return screen
    }

    /// The picker comes first, the three cards next and the three zoom buttons last.
    private func zoomButton(_ screen: OffscreenWindow<AnyView>, fromLast offset: Int) throws {
      try screen.clickControl(at: screen.controlFrames.count - 1 - offset)
    }

    @Test("The picker swaps the list for cards, and back")
    func swapsViews() throws {
      let screen = try panelOnGraph()
      defer { screen.close() }
      #expect(screen.list == nil)
      #expect(try screen.shows("reading files"))
      // A settled card keeps its status to itself; a running one states it.
      #expect(try screen.shows("Working"))
      #expect(try !screen.shows("Done"))
      let picker = try #require(screen.controlFrames.first)
      try screen.click(CGPoint(x: picker.minX + 6, y: picker.midY))
      #expect(screen.list != nil)
    }

    @Test("A card opens its agent's chat, except the one on screen")
    func cardsOpen() throws {
      let opened = Opened()
      let screen = try panelOnGraph(opened)
      defer { screen.close() }
      // Reading order: the picker, Main on top, then its two children.
      try screen.clickControl(at: 2)
      try screen.clickControl(at: 3)
      #expect(opened.ids.count == 2)
      #expect(Set(opened.ids) == ["child", "done"])
      try screen.clickControl(at: 1)
      #expect(opened.ids.count == 2)
    }

    @Test("Zoom grows and shrinks the cards within limits, and Actual Size restores them")
    func zoom() throws {
      let screen = try panelOnGraph()
      defer { screen.close() }
      let document = try #require(screen.allViews.lazy.compactMap { $0 as? NSScrollView }.first)
      let width = { document.documentView?.frame.width ?? 0 }
      let actualSize = width()
      try zoomButton(screen, fromLast: 2)
      let bigger = width()
      #expect(bigger > actualSize)
      for _ in 0..<6 { try zoomButton(screen, fromLast: 2) }
      #expect(width() <= actualSize * 2)
      try zoomButton(screen, fromLast: 0)
      #expect(width() == actualSize)
      for _ in 0..<8 { try zoomButton(screen, fromLast: 1) }
      let smallest = width()
      #expect(smallest < actualSize)
      #expect(smallest >= actualSize * 0.4)
    }

    @Test("Without a way to open agents, cards can't be chosen")
    func cardsDisabled() throws {
      let screen = try panelOnGraph()
      defer { screen.close() }
      // The picker and the three zoom buttons.
      #expect(screen.controlFrames.count == 4)
    }

    @Test("Each state draws its own tile and card")
    func tilesAndCards() throws {
      let activities: [AgentTreeActivity] = [
        .needsYou, .failed, .disconnected, .done, .idle, .other,
      ]
      let tiles = try activities.map {
        try RenderSupport.picture(AgentStatusTile(activity: $0), width: 40, height: 40)
      }
      #expect(Set(tiles).count == activities.count)
      let spinner = try RenderSupport.picture(
        AgentStatusTile(activity: .working), width: 40, height: 40)
      #expect(!tiles.contains(spinner))
      _ = try RenderSupport.picture(AgentStatusTile(activity: .launching), width: 40, height: 40)

      let cards = try AgentTreeActivity.allCases.map { activity in
        let state = AgentTreeState(
          nodes: [
            AgentTreeNode(id: "root", name: "Main"),
            AgentTreeNode(id: "c", parentID: "root", depth: 1, name: "C", activity: activity),
          ],
          currentID: "root")
        return try RenderSupport.picture(
          AgentTreeGraph(state: state, open: nil), width: 300, height: 300)
      }
      #expect(Set(cards).count > 4)
    }
  }
#endif
