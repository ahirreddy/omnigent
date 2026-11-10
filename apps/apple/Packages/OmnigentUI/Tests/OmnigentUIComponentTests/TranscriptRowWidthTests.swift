import Foundation
import SwiftUI
import Testing

@testable import OmnigentUIComponents

/// The rows take a new width at the scroll view's top, and the reader is put back after.
@MainActor
@Suite("Transcript row width", .serialized)
struct TranscriptRowWidthTests {
  private static let top = "\(TranscriptView.topID) 0.0"
  private static let end = "\(TranscriptView.bottomID) 1.0"

  private final class Scrolls {
    var all: [String] = []
  }

  /// A transcript's state with rows at 500 points, and the scrolls it made.
  private func state() -> (TranscriptScrollState, Scrolls) {
    let state = TranscriptScrollState()
    let scrolls = Scrolls()
    state.scrollToRow = { id, anchor in scrolls.all.append("\(id) \(anchor.y)") }
    state.rowWidthOffered(500)
    return (state, scrolls)
  }

  /// A state whose reader went to an earlier message and has row `m` under the middle.
  private func readingState() -> (TranscriptScrollState, Scrolls) {
    let (state, scrolls) = state()
    state.follow.readEarlier()
    state.follow.geometryChanged(isNearBottom: false)
    state.endReached(false)
    state.record(anchor("m"))
    return (state, scrolls)
  }

  /// A row as tall as the viewport, which a scroll puts back by its fraction alone.
  private func anchor(_ id: String, _ fraction: Double = 0.4, row: CGFloat = 1_000)
    -> TranscriptReadingAnchor
  {
    TranscriptReadingAnchor(
      id: id, fraction: fraction, rowHeight: row, viewportWidth: 500, viewportHeight: 1_000)
  }

  /// Lets blocks waiting on the main run loop run.
  private func returnToRunLoop() {
    CFRunLoopRunInMode(.defaultMode, 0.02, false)
  }

  /// Takes the state through a passage to `width`, as one layout pass does.
  private func pass(_ state: TranscriptScrollState, to width: CGFloat) {
    state.rowWidthOffered(width)
    state.topReached(true)
    state.rowsResized()
    state.topReached(false)
  }

  @Test("The rows keep their width until the viewport's is given to them")
  func heldWidth() {
    let width = TranscriptRowWidth()
    #expect(width.held == nil && !width.isBehind)
    #expect(!width.offer(500))
    #expect(width.held == 500)
    #expect(width.offer(900))
    #expect(width.held == 500 && width.isBehind)
    width.catchUp()
    #expect(width.held == 900 && !width.isBehind)
    width.catchUp()
    #expect(width.held == 900)
  }

  @Test("A passage short of the top is sent there twice more, and not once it has its width")
  func topScrolls() {
    var passage = TranscriptRowWidth.Passage(anchor: nil)
    let taken = [passage.takesTopScroll(), passage.takesTopScroll(), passage.takesTopScroll()]
    #expect(taken == [true, true, false])
    var arrived = TranscriptRowWidth.Passage(anchor: nil)
    arrived.hasWidth = true
    let afterWidth = arrived.takesTopScroll()
    #expect(!afterWidth)
  }

  @Test("A reader mid-conversation is taken to the top for the new width, then back to their row")
  func passageForAReader() {
    let (state, scrolls) = readingState()
    state.rowWidthOffered(900)
    #expect(scrolls.all == [Self.top])
    #expect(state.rowWidth.held == 500, "the rows wait for the top")
    state.topReached(true)
    #expect(state.rowWidth.held == 900)
    #expect(scrolls.all == [Self.top])
    state.rowsResized()
    #expect(scrolls.all == [Self.top, "m 0.4"])
    // Rows laid out again with no passage change nothing.
    state.rowsResized()
    // The first row under the middle on the way is not where the reader is.
    state.record(anchor("first"))
    state.topReached(false)
    state.record(anchor("m"))
    returnToRunLoop()
    #expect(scrolls.all == [Self.top, "m 0.4"])
  }

  @Test("A reader at the end is taken to the top for the new width, then back to the end")
  func passageForAFollower() {
    let (state, scrolls) = state()
    state.rowWidthOffered(900)
    state.endReached(false)
    state.topReached(true)
    state.rowsResized()
    #expect(scrolls.all == [Self.top, Self.end])
    state.endReached(true)
    // Rows measured after the scroll move the end away.
    state.endReached(false)
    #expect(scrolls.all == [Self.top, Self.end, Self.end])
    state.endReached(true)
    returnToRunLoop()
    #expect(scrolls.all.count == 3)
  }

  @Test("A reader the scrolls never bring to the end is scrolled there eight times, then left")
  func endNeverReached() {
    let (state, scrolls) = state()
    state.rowWidthOffered(900)
    state.endReached(false)
    state.topReached(true)
    state.rowsResized()
    for _ in 0..<5 { returnToRunLoop() }
    #expect(scrolls.all == [Self.top] + Array(repeating: Self.end, count: 9))
  }

  @Test("A reader near the end who does not follow yet ends at the end as well")
  func framedReaderEndsAtTheEnd() {
    let (state, scrolls) = state()
    state.follow.frameLatest()
    state.record(anchor("m"))
    pass(state, to: 900)
    #expect(scrolls.all == [Self.top, Self.end])
    returnToRunLoop()
  }

  @Test("At the top, or with no row to come back to, the rows take the width where they are")
  func widthInPlace() {
    let (atTop, topScrolls) = readingState()
    atTop.topReached(true)
    atTop.rowWidthOffered(900)
    #expect(atTop.rowWidth.held == 900)
    #expect(topScrolls.all.isEmpty)

    let (unread, unreadScrolls) = state()
    unread.follow.readEarlier()
    unread.follow.geometryChanged(isNearBottom: false)
    unread.rowWidthOffered(900)
    #expect(unread.rowWidth.held == 900)
    #expect(unreadScrolls.all.isEmpty)
  }

  @Test("With the turn's scrolls spent, the rows take the width in place and the end is owed")
  func refusedPassage() {
    TranscriptScrollState.layoutScrollLimits = .init(perCause: 8, perTurn: 1)
    let (state, scrolls) = state()
    TranscriptScrollState.layoutScrollLimits = .init()
    #expect(state.allowsScroll("content height", keepsBottom: true))
    state.rowWidthOffered(900)
    #expect(state.rowWidth.held == 900)
    #expect(scrolls.all.isEmpty)
    returnToRunLoop()
    #expect(scrolls.all == [Self.end])
  }

  @Test("A width offered on the way to the top, or at it, is the one the rows take")
  func newerWidthDuringAPassage() {
    let (onTheWay, wayScrolls) = readingState()
    onTheWay.rowWidthOffered(900)
    onTheWay.rowWidthOffered(700)
    onTheWay.topReached(true)
    #expect(onTheWay.rowWidth.held == 700)
    onTheWay.rowsResized()
    #expect(wayScrolls.all == [Self.top, "m 0.4"])
    onTheWay.topReached(false)
    onTheWay.record(anchor("m"))
    returnToRunLoop()

    let (atTop, topScrolls) = readingState()
    atTop.rowWidthOffered(900)
    atTop.topReached(true)
    atTop.rowWidthOffered(700)
    #expect(atTop.rowWidth.held == 900)
    atTop.rowsResized()
    #expect(atTop.rowWidth.held == 700)
    #expect(topScrolls.all == [Self.top])
    atTop.rowsResized()
    #expect(topScrolls.all == [Self.top, "m 0.4"])
    atTop.topReached(false)
    atTop.record(anchor("m"))
    returnToRunLoop()
  }

  @Test("A viewport back at the rows' width before the top sends the reader straight back")
  func widthCameBack() {
    let (state, scrolls) = readingState()
    state.rowWidthOffered(900)
    state.rowWidthOffered(500)
    state.topReached(true)
    #expect(state.rowWidth.held == 500)
    #expect(scrolls.all == [Self.top, "m 0.4"])
    state.topReached(false)
    state.record(anchor("m"))
    returnToRunLoop()
  }

  @Test("A passage that never reaches the top ends when the main thread is back")
  func passageEndsWithTheTurn() {
    let (state, scrolls) = readingState()
    state.rowWidthOffered(900)
    // A row under the middle short of the top sends the scroll view there again, twice.
    for _ in 0..<3 { state.record(anchor("other")) }
    #expect(scrolls.all == [Self.top, Self.top, Self.top])
    returnToRunLoop()
    #expect(state.rowWidth.held == 900)
    #expect(scrolls.all == [Self.top, Self.top, Self.top, "m 0.4"])
  }

  @Test("A second width in one turn waits for the turn's end, and has its own passage")
  func onePassageATurn() {
    let (state, scrolls) = readingState()
    pass(state, to: 900)
    state.rowWidthOffered(700)
    #expect(state.rowWidth.held == 900)
    #expect(scrolls.all == [Self.top, "m 0.4"])
    returnToRunLoop()
    returnToRunLoop()
    #expect(state.rowWidth.held == 700)
    #expect(scrolls.all == [Self.top, "m 0.4", Self.top, "m 0.4"])
  }
}

/// Putting the reader back after the rows took their width.
extension TranscriptRowWidthTests {
  @Test("A width change while a reader is being put back returns them to the same row")
  func widthDuringARestore() {
    let (state, scrolls) = readingState()
    pass(state, to: 900)
    state.record(anchor("m"))
    returnToRunLoop()
    // The scroll back landed on another row, and the next width comes before it is corrected.
    state.record(anchor("x"))
    #expect(scrolls.all == [Self.top, "m 0.4", "m 0.4"])
    pass(state, to: 700)
    #expect(scrolls.all == [Self.top, "m 0.4", "m 0.4", Self.top, "m 0.4"])
    state.record(anchor("m"))
    returnToRunLoop()
    #expect(scrolls.all.count == 5)
  }

  @Test("A scroll back that keeps landing on another row goes by way of the row opposite")
  func stalledRestore() {
    let (state, scrolls) = readingState()
    state.rowOrder = { ["a", "b", "m", "x", "y"] }
    pass(state, to: 900)
    state.record(anchor("x"))
    state.record(anchor("x"))
    state.record(anchor("y"))
    state.record(anchor("y"))
    #expect(scrolls.all.dropFirst(2) == ["m 0.4", "b 0.4", "m 0.4", "a 0.4"])
    // In view the row is scrolled by its new height, which is exact; then nothing more.
    state.record(anchor("m", 0.7, row: 2_000))
    #expect(scrolls.all.last == "m 0.3")
    state.record(anchor("m", 0.4, row: 2_000))
    returnToRunLoop()
    #expect(scrolls.all.count == 7)
  }

  @Test("The row opposite is as far from the wanted one, within the rows there are")
  func counterTarget() {
    let order = ["a", "b", "c"]
    func target(_ wanted: String, _ landed: String) -> String? {
      TranscriptReadingAnchor.counterTarget(wanted: wanted, landed: landed, in: order)
    }
    #expect(target("b", "c") == "a")
    #expect(target("b", "a") == "c")
    #expect(target("a", "c") == "a")
    #expect(target("c", "a") == "c")
    #expect(target("b", "b") == nil)
    #expect(target("b", "gone") == nil)
    #expect(target("gone", "b") == nil)
  }

  @Test("A reader is put back for eight scrolls or a second, whichever ends first")
  func restoreEnds() {
    let (scrolled, scrolls) = readingState()
    pass(scrolled, to: 900)
    for _ in 0..<12 { scrolled.record(anchor("x")) }
    returnToRunLoop()
    #expect(scrolls.all == [Self.top] + Array(repeating: "m 0.4", count: 9))

    let (late, lateScrolls) = readingState()
    pass(late, to: 900)
    late.record(
      anchor("x"), at: Date().addingTimeInterval(TranscriptScrollState.restoreWindow + 1))
    #expect(lateScrolls.all == [Self.top, "m 0.4"])
    returnToRunLoop()
  }

  @Test("A reader whose scroll begins or ends during a passage is still put back at their row")
  func readerScrollsDuringAPassage() {
    let (state, scrolls) = readingState()
    state.rowWidthOffered(900)
    state.readerMoved()
    // The rows wait for the top: at the reader's place every row above would be built.
    #expect(state.rowWidth.held == 500)
    state.topReached(true)
    #expect(state.rowWidth.held == 900)
    state.rowsResized()
    #expect(scrolls.all == [Self.top, "m 0.4"])
    returnToRunLoop()
  }

  @Test("A jump during a passage ends it at the row jumped to, or at the end as a follower's")
  func jumpDuringAPassage() {
    let (state, scrolls) = readingState()
    state.rowWidthOffered(900)
    state.jumped(to: "u7")
    #expect(state.rowWidth.held == 500)
    state.topReached(true)
    state.rowsResized()
    #expect(scrolls.all == [Self.top, "u7 0.0"])
    returnToRunLoop()
    // The reader is where they jumped, not being put back anywhere.
    state.record(anchor("x"))
    #expect(scrolls.all == [Self.top, "u7 0.0"])

    let (latest, latestScrolls) = readingState()
    latest.rowWidthOffered(900)
    latest.jumped(to: TranscriptView.bottomID)
    latest.topReached(true)
    latest.rowsResized()
    latest.endReached(false)
    #expect(latestScrolls.all == [Self.top, Self.end, Self.end])
    returnToRunLoop()
  }

  @Test("A width owed after a passage is not taken where a reader scrolls, but at the turn's end")
  func owedWidthWaitsForTheTurn() {
    let (state, scrolls) = readingState()
    pass(state, to: 900)
    state.rowWidthOffered(700)
    state.readerMoved()
    #expect(state.rowWidth.held == 900)
    #expect(scrolls.all == [Self.top, "m 0.4"])
    returnToRunLoop()
    #expect(scrolls.all.dropFirst(2).first == Self.top)
    #expect(state.rowWidth.held == 700)
  }

  @Test("A passage begun at a turn's end is left to the display's layout, not ended before it")
  func owedPassageWaitsForTheDisplay() {
    let (state, scrolls) = readingState()
    pass(state, to: 900)
    state.rowWidthOffered(700)
    // A pass with no time to wait: the turn ends, and the loop's blocks run again before layout.
    CFRunLoopRunInMode(.defaultMode, 0, false)
    #expect(scrolls.all.last == Self.top)
    #expect(state.rowWidth.held == 900)
    state.topReached(true)
    state.rowsResized()
    #expect(state.rowWidth.held == 700)
    #expect(scrolls.all.last == "m 0.4")
    returnToRunLoop()
  }

  @Test("Another session opening during a passage ends it, its rows at the viewport's width")
  func sessionOpensDuringAPassage() {
    let (state, scrolls) = readingState()
    state.rowWidthOffered(900)
    state.sessionOpened()
    #expect(state.rowWidth.held == 900)
    #expect(state.rowWidth.passage == nil)
    state.topReached(true)
    state.rowsResized()
    returnToRunLoop()
    #expect(scrolls.all == [Self.top])
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
    #expect(scrolls.all == [Self.top, Self.end])
    returnToRunLoop()
    #expect(state.contentHeightChanged(700, from: 600))
    #expect(state.dockChanged(140, from: 120))
    returnToRunLoop()
  }
}
