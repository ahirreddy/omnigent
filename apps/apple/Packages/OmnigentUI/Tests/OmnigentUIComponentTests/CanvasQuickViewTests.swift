import CoreGraphics
import Foundation
import Testing

@testable import OmnigentUIComponents

#if os(macOS)
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI

  @testable import OmnigentUITestSupport
#endif

/// The Canvas's parity with the web's: a card's session beside the board, the PR on its card,
/// only the cards in view drawn, and zoom around the middle.
@Suite("Canvas quick view and cards", .serialized)
@MainActor
struct CanvasQuickViewTests {
  private func card(_ id: String, left: Int = 0, top: Int = 0) -> CanvasCard {
    CanvasCard(
      id: id, title: "Title \(id)", state: .idle, workspace: "/repo/\(id)", left: left, top: top)
  }

  @Test("only cards in or near the view are drawn, and every card before the view is known")
  func culling() {
    let near = card("near", left: 0, top: 0)
    let far = card("far", left: 20_000, top: 0)
    let geometry = CanvasGeometry(cards: [near, far])
    let view = CGRect(x: 0, y: 0, width: 800, height: 600)
    #expect(geometry.isVisible(near, zoom: 1, in: view))
    #expect(!geometry.isVisible(far, zoom: 1, in: view))
    #expect(geometry.isVisible(far, zoom: 1, in: .zero))
    #expect(geometry.isVisible(far, zoom: 0.03, in: view), "zoomed out, it comes into view")
  }

  @Test("zooming keeps the middle of the view where it was")
  func centeredZoom() {
    let view = CGRect(x: 100, y: 50, width: 400, height: 300)
    let point = CanvasGeometry.scrolled(view, from: 1, to: 2)
    #expect(point == CGPoint(x: 600 - 200, y: 400 - 150))
    #expect(CanvasGeometry.scrolled(view, from: 1, to: 0.1) == .zero)
  }

  @Test("the PR tooltip names its state, and its age once stale")
  func tooltip() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let fresh = SessionRowPullRequest(number: 7, status: "Merged", checkedAt: now)
    #expect(CanvasPullRequest.tooltip(title: "Ship it", fresh, now: now) == "Ship it (merged)")
    let stale = SessionRowPullRequest(
      number: 7, status: "Open", checkedAt: now.addingTimeInterval(-7_200))
    #expect(
      CanvasPullRequest.tooltip(title: "Ship it", stale, now: now) == "Ship it (open, as of 2h ago)"
    )
    #expect(
      CanvasPullRequest.tooltip(title: "#7", SessionRowPullRequest(number: 7), now: now) == "#7")
  }

  #if os(macOS)
    private final class Log {
      var opened: [String] = []
      var quickViews: [String?] = []
    }

    private func page(_ state: CanvasViewState, _ actions: CanvasActions)
      -> OffscreenWindow<AnyView>
    {
      transcriptScreen(
        CanvasView(
          state: state, actions: actions,
          quickView: { id in AnyView(Text("Chat of \(id)")) }),
        width: 1100, height: 700)
    }

    @Test("with a quick view, the session shows beside the board and the board stays")
    func quickView() throws {
      let log = Log()
      var actions = CanvasActions { log.opened.append($0) }
      actions.quickView = { log.quickViews.append($0) }
      var state = CanvasViewState(
        boards: [CanvasBoard(id: "main", name: "Main")], activeBoard: "main",
        cards: [card("a"), card("b", left: 320)])
      state.quickViewID = "a"
      let screen = page(state, actions)
      defer { screen.close() }
      #expect(try screen.shows("Chat of a"))
      #expect(try screen.shows("Title b"), "the board stays beside it")
      try screen.clickElement("project-board-quick-view-open")
      #expect(log.opened == ["a"])
      try screen.clickElement("project-board-quick-view-close")
      #expect(log.quickViews == [nil])
    }

    @Test("a card's PR links to its page with the web's text")
    func pullRequestLine() throws {
      var withPR = card("a")
      withPR.pullRequest = CanvasPullRequest(
        text: "#212 Ship the upload retry",
        url: try #require(URL(string: "https://example.com/pr/212")),
        tooltip: "Ship the upload retry (merged)", accessibilityLabel: "Open pull request #212")
      let screen = page(
        CanvasViewState(
          boards: [CanvasBoard(id: "main", name: "Main")], activeBoard: "main", cards: [withPR]),
        CanvasActions())
      defer { screen.close() }
      #expect(try screen.shows("#212 Ship the upload retry"))
    }
  #endif
}
