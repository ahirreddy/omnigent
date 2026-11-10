import Foundation
import SwiftUI
import Testing

@testable import OmnigentUIComponents

/// The transcript's end as its scroll geometry was last seen, and a follower's return to it.
extension TranscriptRowWidthTests {
  /// A follower's state after a passage to 900 points: sent from the top to the end by its edge.
  private func returningState() -> (TranscriptScrollState, Scrolls) {
    let (state, scrolls) = state()
    state.rowWidthOffered(900)
    end(state, reached: false)
    state.topReached(true)
    state.rowsResized()
    state.topReached(false)
    return (state, scrolls)
  }

  private func viewport(near: Bool) -> TranscriptViewport {
    TranscriptViewport(width: 500, visibleBottom: near ? 1_000 : 0, contentHeight: 1_000)
  }

  @Test("The end is the bottom row around the rows' padding short of it, and the edge past that")
  func places() {
    func place(short: CGFloat) -> TranscriptEnd.Place {
      TranscriptEnd.Place(visibleBottom: 1_000 - short, contentHeight: 1_000)
    }
    #expect(place(short: 27) == .away)
    #expect(place(short: 26) == .bottomRow)
    #expect(place(short: 24) == .bottomRow)
    #expect(place(short: 22) == .bottomRow)
    #expect(place(short: 21) == .edge)
    #expect(place(short: 0) == .edge)
    // Past the end, as a bounce is.
    #expect(place(short: -30) == .edge)
  }

  @Test("A reader at the end goes to the top for the new width, then by edge to the bottom row")
  func passageForAFollower() {
    let (state, scrolls) = returningState()
    #expect(scrolls.all == [Self.top, Self.edge])
    // A row under the middle on the way is not the end.
    state.record(anchor("x"))
    #expect(scrolls.all == [Self.top, Self.edge])
    end(state, at: .edge)
    #expect(scrolls.all == [Self.top, Self.edge, Self.released, Self.end])
    end(state, reached: true)
    // Rows measured after the scroll move the end away.
    end(state, reached: false)
    #expect(scrolls.all.dropFirst(4) == [Self.end])
    end(state, reached: true)
    returnToRunLoop()
    #expect(scrolls.all.count == 5)
  }

  @Test("A scroll to the bottom row is not made again before a geometry shows where it landed")
  func oneScrollALanding() {
    let (state, scrolls) = returningState()
    end(state, at: .edge)
    // The action runs again, and a row comes under the middle, with the scroll still to land.
    state.endChanged()
    state.record(anchor("x"))
    #expect(scrolls.all == [Self.top, Self.edge, Self.released, Self.end])
    // It landed short of the bottom row: another, and again none before that one lands.
    end(state, reached: false)
    state.endChanged()
    #expect(scrolls.all.dropFirst(4) == [Self.end])
    // A scroll no geometry answers is made again when the turn ends.
    returnToRunLoop()
    #expect(scrolls.all.dropFirst(5).first == Self.end)
  }

  @Test("A reader the scrolls never bring to the end is scrolled there eight times, then left")
  func endNeverReached() {
    let (state, scrolls) = returningState()
    for _ in 0..<8 { returnToRunLoop() }
    #expect(state.rowWidth.held == 900)
    let ends = Array(repeating: Self.end, count: 9)
    #expect(scrolls.all == [Self.top, Self.edge, Self.released] + ends)
  }

  @Test("A reader near the end who does not follow yet ends at the end as well")
  func framedReaderEndsAtTheEnd() {
    let (state, scrolls) = state()
    state.follow.frameLatest()
    state.record(anchor("m"))
    pass(state, to: 900)
    #expect(scrolls.all == [Self.top, Self.edge])
    // No geometry at the end is seen: the turn's end rests the return on the bottom row.
    returnToRunLoop()
    #expect(scrolls.all == [Self.top, Self.edge, Self.released, Self.end])
  }

  @Test("A reader who scrolls, jumps or opens another session lets go of the edge and stays put")
  func readerLeavesTheEdge() {
    let moves: [(TranscriptScrollState) -> Void] = [
      { $0.readerMoved() }, { $0.jumped(to: "u7") }, { $0.sessionOpened() },
    ]
    for move in moves {
      let (state, scrolls) = returningState()
      move(state)
      #expect(scrolls.all == [Self.top, Self.edge, Self.released])
      // Reaching the end now is the reader's doing.
      end(state, at: .edge)
      returnToRunLoop()
      #expect(scrolls.all == [Self.top, Self.edge, Self.released])
    }
  }

  @Test("An end left in a pass whose action did not run is scrolled back to when the turn ends")
  func endLeftUnreported() {
    let (state, scrolls) = returningState()
    end(state, at: .edge)
    end(state, reached: true)
    returnToRunLoop()
    #expect(scrolls.all.count == 4)
    // SwiftUI computes a geometry away from the end, and runs no action for it.
    _ = state.sees(end: .away)
    #expect(scrolls.all.count == 4)
    returnToRunLoop()
    #expect(scrolls.all.dropFirst(4).first == Self.end)
  }

  @Test("A bottom seen left or reached with no action reaches the follow rules at the turn's end")
  func followSettlesWithTheTurn() {
    let (state, _) = state()
    var pills: [Bool] = []
    state.showPill = { pills.append($0.isShown) }
    _ = state.follow.scrollPhaseChanged(isUserScrolling: true)
    _ = state.sees(viewport(near: false))
    #expect(state.follow.isNearBottom)
    returnToRunLoop()
    #expect(!state.follow.isNearBottom && !state.follow.follows)
    #expect(pills == [true])
    _ = state.sees(viewport(near: true))
    returnToRunLoop()
    #expect(state.follow.follows)
    #expect(pills == [true, false])
  }

  @Test("A width change takes its reader where the bottom was last seen, whatever an action said")
  func widthGoesByWhatWasSeen() {
    // Left and reached again in one pass: the action said away, and the bottom was seen near.
    let (back, backScrolls) = readingState()
    _ = back.sees(viewport(near: true))
    pass(back, to: 900)
    #expect(backScrolls.all == [Self.top, Self.edge])
    returnToRunLoop()

    // Seen away with no action: the reader has a row to come back to.
    let (away, awayScrolls) = state()
    away.follow.readEarlier()
    away.record(anchor("m"))
    _ = away.sees(viewport(near: false))
    pass(away, to: 900)
    #expect(awayScrolls.all == [Self.top, "m 0.4"])
    returnToRunLoop()
  }

  @Test("Follow rules started again with the bottom seen away are told so before they are asked")
  func followResetAwayFromTheBottom() {
    let (state, _) = state()
    bottom(state, near: false)
    state.follow.reset()
    #expect(state.follow.isNearBottom)
    state.settleFollow()
    #expect(!state.follow.isNearBottom)
  }

  @Test("Content and the dock growing do not scroll a follower while a passage puts them back")
  func passageKeepsOtherScrollsOut() {
    let (state, scrolls) = state()
    state.rowWidthOffered(900)
    #expect(!state.contentHeightChanged(500, from: 400))
    #expect(!state.dockChanged(120, from: 100))
    state.topReached(true)
    state.rowsResized()
    #expect(!state.contentHeightChanged(600, from: 500))
    #expect(scrolls.all == [Self.top, Self.edge])
    returnToRunLoop()
    #expect(state.contentHeightChanged(700, from: 600))
    #expect(state.dockChanged(140, from: 120))
    returnToRunLoop()
  }
}
