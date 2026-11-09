#if os(macOS)
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  @Suite("Canvas page", .serialized)
  @MainActor
  struct CanvasViewTests {
    private let boards = [
      CanvasBoard(id: "main", name: "Main"), CanvasBoard(id: "p", name: "Project", icon: "🚀"),
    ]

    private func card(
      _ id: String, state: CanvasCard.State = .idle, branch: String? = nil, left: Int = 0,
      top: Int = 0
    ) -> CanvasCard {
      CanvasCard(
        id: id, title: "Title \(id)", state: state, workspace: "/repo/\(id)", branch: branch,
        left: left, top: top)
    }

    private func page(_ state: CanvasViewState, _ actions: CanvasActions = CanvasActions())
      -> OffscreenWindow<AnyView>
    {
      transcriptScreen(CanvasView(state: state, actions: actions), width: 900, height: 700)
    }

    /// The zoom in, zoom out, fit, reset and new session controls come after one tab per board.
    private func controlIndex(_ position: Int) -> Int { boards.count + position }

    @Test("Counts its sessions, singular and plural, and draws each card's facts")
    func header() throws {
      let one = page(
        CanvasViewState(
          boards: boards, activeBoard: "main",
          cards: [card("a", state: .running, branch: "feature/x")]))
      defer { one.close() }
      for text in ["1 session", "Title a", "Running", "/repo/a", "feature/x", "Main", "Project"] {
        #expect(try one.shows(text), "\(text)")
      }

      let two = page(
        CanvasViewState(
          boards: boards, activeBoard: "main", cards: [card("a"), card("b", left: 320)]))
      defer { two.close() }
      #expect(try two.shows("2 sessions"))
    }

    @Test("Every card state has its label on the card")
    func states() throws {
      let states: [CanvasCard.State] = [.needsYou, .running, .unread, .failed, .idle]
      #expect(Set(states.map(\.label)).count == states.count)
      let cards = states.enumerated().map { index, state in
        card("c\(index)", state: state, left: index * 320)
      }
      let screen = page(CanvasViewState(boards: boards, activeBoard: "main", cards: cards))
      defer { screen.close() }
      for state in states { #expect(try screen.shows(state.label), "\(state)") }
    }

    @Test("Clicking a board's tab selects that board")
    func selectBoard() throws {
      var selected: [String] = []
      var actions = CanvasActions()
      actions.selectBoard = { selected.append($0) }
      let screen = page(
        CanvasViewState(boards: boards, activeBoard: "main", cards: [card("a")]), actions)
      defer { screen.close() }
      try screen.clickControl(at: 1)
      try screen.clickControl(at: 0)
      #expect(selected == ["p", "main"])
    }

    @Test("New session and Reset layout reach the host, and hide without one")
    func hostActions() throws {
      let log = HostLog()
      var actions = CanvasActions()
      actions.newSession = { log.add("new") }
      actions.resetLayout = { log.add("reset") }
      let state = CanvasViewState(boards: boards, activeBoard: "main", cards: [card("a")])
      let screen = page(state, actions)
      defer { screen.close() }
      let bare = page(state)
      defer { bare.close() }
      #expect(screen.controlFrames.count == bare.controlFrames.count + 2)
      let count = screen.controlFrames.count
      try screen.clickControl(at: count - 2)
      try screen.clickControl(at: count - 1)
      #expect(Set(log.entries) == ["new", "reset"])
    }

    @Test("A first load failure offers Retry; loading draws no board")
    func loadStates() throws {
      let log = HostLog()
      var state = CanvasViewState(boards: boards, activeBoard: "main", cards: [])
      state.loadError = "The server is down"
      var actions = CanvasActions()
      actions.retry = { log.add("retry") }
      let failed = page(state, actions)
      defer { failed.close() }
      #expect(try failed.shows("Canvas could not load"))
      #expect(try failed.shows("The server is down"))
      try failed.clickControl(at: failed.controlFrames.count - 1)
      #expect(log.entries == ["retry"])

      state.loadError = nil
      state.isLoading = true
      let loading = page(state)
      defer { loading.close() }
      #expect(try !loading.shows("No sessions"))
    }

    @Test("A failed reload keeps the cards and says so; an empty board says its title")
    func refreshStates() throws {
      var state = CanvasViewState(boards: boards, activeBoard: "main", cards: [card("a")])
      state.refreshError = "Timed out"
      state.isRefreshing = true
      let stale = page(state)
      defer { stale.close() }
      #expect(try stale.shows("Refresh failed: Timed out"))
      #expect(try stale.shows("Title a"))

      var empty = CanvasViewState(boards: boards, activeBoard: "main", cards: [])
      empty.emptyTitle = "Nothing in this project"
      let bare = page(empty)
      defer { bare.close() }
      #expect(try bare.shows("Nothing in this project"))
    }

    @Test("Zoom controls leave the board usable, at both ends of the range")
    func zoomControls() throws {
      let state = CanvasViewState(
        boards: boards, activeBoard: "main", cards: [card("a"), card("b", left: 6_400, top: 3_200)])
      let screen = page(state)
      defer { screen.close() }
      let zoomIn = controlIndex(0)
      let zoomOut = controlIndex(1)
      let fit = controlIndex(2)
      for _ in 0..<3 { try screen.clickControl(at: zoomIn) }
      for _ in 0..<6 { try screen.clickControl(at: zoomOut) }
      try screen.clickControl(at: fit)
      #expect(try screen.shows("Title b"))
    }

    @Test("Switching boards follows the fit again")
    func boardSwitchRefits() throws {
      struct Host: View {
        let boards: [CanvasBoard]
        let cards: [CanvasCard]
        @State private var active = "main"

        var body: some View {
          var actions = CanvasActions()
          actions.selectBoard = { active = $0 }
          return CanvasView(
            state: CanvasViewState(boards: boards, activeBoard: active, cards: cards),
            actions: actions)
        }
      }
      let screen = transcriptScreen(
        Host(boards: boards, cards: [card("a")]), width: 900, height: 700)
      defer { screen.close() }
      try screen.clickControl(at: 1)
      #expect(try screen.shows("Title a"))
    }

    @Test("Card positions from a corrupted store neither trap nor hang the board")
    func hostilePositions() throws {
      let hostile: [[CanvasCard]] = [
        [card("a", left: .max, top: .max), card("b", left: .min, top: .min)],
        [card("a", left: .max, top: 0)],
        [card("a", left: 0, top: 0), card("b", left: 1 << 62, top: 1 << 62)],
        [card("a", left: 40_000_000, top: 40_000_000), card("b")],
      ]
      for cards in hostile {
        let geometry = CanvasGeometry(cards: cards)
        #expect(geometry.size.width.isFinite && geometry.size.height.isFinite)
        let fit = geometry.fitZoom(CGSize(width: 800, height: 600))
        #expect(fit >= CanvasGeometry.minZoom && fit <= 1)
        let screen = page(CanvasViewState(boards: boards, activeBoard: "main", cards: cards))
        defer { screen.close() }
        #expect(try screen.shows("\(cards.count) session"))
      }
    }

    @Test("A drag from any stored position lands on a position, whatever the gesture reports")
    func dragLanding() {
      #expect(CanvasGeometry.moved(10, by: 4.6) == 15)
      #expect(CanvasGeometry.moved(10, by: -20) == -10)
      #expect(CanvasGeometry.moved(.max, by: 1) == .max)
      #expect(CanvasGeometry.moved(.min, by: -1) == .min)
      #expect(CanvasGeometry.moved(10, by: .nan) == 10)
      #expect(CanvasGeometry.moved(10, by: .infinity) == 10)
      #expect(CanvasGeometry.moved(10, by: 1e300) == .max)
      #expect(CanvasGeometry.moved(10, by: -1e300) == .min + 10)
      #expect(CanvasGeometry.moved(-10, by: -1e300) == .min)
    }

    @Test("The dot lattice is drawn up to its limit and left out past it")
    func dotLattice() {
      let small = CanvasGeometry.dotLattice(in: CGSize(width: 64, height: 32))
      #expect(small?.columns == 3)
      #expect(small?.rows == 2)
      let huge = CGSize(width: 1.8e19, height: 1.8e19)
      #expect(CanvasGeometry.dotLattice(in: huge) == nil)
      #expect(CanvasGeometry.dotLattice(in: CGSize(width: 100_000, height: 100_000)) == nil)
      #expect(CanvasGeometry.dotLattice(in: CGSize(width: CGFloat.nan, height: 10)) == nil)
      #expect(CanvasGeometry.dotLattice(in: CGSize(width: CGFloat.infinity, height: 0)) == nil)
      #expect(CanvasGeometry.dotLattice(in: CGSize(width: -100, height: -100)) == nil)
    }

    @Test("Hostile titles and an unbroken workspace stay on their card")
    func hostileText() throws {
      for text in HostileData.samples {
        let state = CanvasViewState(
          boards: [CanvasBoard(id: "main", name: text, icon: text)], activeBoard: "main",
          cards: [
            CanvasCard(
              id: "a", title: text, state: .failed, workspace: text, branch: text, left: 0, top: 0)
          ])
        let screen = page(state)
        defer { screen.close() }
        #expect(try screen.shows("1 session"))
      }
    }

    @Test("Zoom clamps to its range, whatever it is given")
    func clamp() {
      #expect(CanvasGeometry.clamp(0) == CanvasGeometry.minZoom)
      #expect(CanvasGeometry.clamp(-1) == CanvasGeometry.minZoom)
      #expect(CanvasGeometry.clamp(100) == CanvasGeometry.maxZoom)
      #expect(CanvasGeometry.clamp(1) == 1)
      #expect(CanvasGeometry(cards: []).size == CGSize(width: 128, height: 128))
    }
  }
#endif
