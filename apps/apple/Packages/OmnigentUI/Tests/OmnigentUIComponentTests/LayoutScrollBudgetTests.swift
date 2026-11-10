import Foundation
import SwiftUI
import Testing

@testable import OmnigentUIComponents

/// Layout answering its own scrolls runs out of them; something happening pays for more.
@MainActor
@Suite("Layout scroll budget", .serialized)
struct LayoutScrollBudgetTests {
  private let limits = LayoutScrollBudget.Limits()

  /// The content falls back and grows again every frame, never to a height or from a start it
  /// had before, so the memory of recent heights lets every growth through.
  @Test("Content that shrinks and grows on its own is followed only as far as the budget")
  func estimatesBouncingToNewHeights() {
    var heights = FollowedHeights()
    var budget = LayoutScrollBudget()
    let begin = Date()
    var followed = 0
    func grow(_ step: Int) {
      let now = begin.addingTimeInterval(Double(step) * 0.016)
      let start = 5000 + CGFloat(step) * 7
      let height = 9000 + CGFloat(step) * 11
      budget.layoutChanged(at: now)
      if heights.follows(height, from: start, at: now), budget.spend(keepsBottom: true, at: now) {
        followed += 1
      }
      _ = budget.turnEnded()
    }
    for step in 0..<200 { grow(step) }
    #expect(followed == limits.perCause)
    #expect("\(budget)" == "0 left, 0 this turn, awaits rest")

    // The bottom waits for layout to rest, which a loop never lets it.
    let last = begin.addingTimeInterval(199 * 0.016)
    #expect(LayoutScrollBudget().untilRest(at: last) == 0)
    let wait = budget.untilRest(at: last.addingTimeInterval(limits.quiet / 4))
    #expect(abs(wait - limits.quiet * 0.75) < 0.001)
    #expect(budget.untilRest(at: last.addingTimeInterval(limits.quiet * 2)) == 0)
    let early = budget.rested(at: last.addingTimeInterval(limits.quiet / 2))
    let rested = budget.rested(at: last.addingTimeInterval(limits.quiet + 0.1))
    let again = budget.rested(at: last.addingTimeInterval(limits.quiet + 0.2))
    #expect(!early && rested && !again)

    budget.contentChanged()
    grow(200)
    #expect(followed == limits.perCause + 1)
  }

  /// A budget an expectation can spend from, which it cannot do to a value.
  private final class Spending {
    var budget: LayoutScrollBudget
    /// The time of the next scroll or change.
    private var now = Date()

    init(_ limits: LayoutScrollBudget.Limits = .init()) {
      budget = LayoutScrollBudget(limits)
    }

    func spend(keepsBottom: Bool) -> Bool { budget.spend(keepsBottom: keepsBottom, at: now) }

    func turnEnded() -> Bool { budget.turnEnded() }

    /// Spends until the budget refuses, a turn per scroll.
    func scrollsLeft() -> Int {
      var count = 0
      while spend(keepsBottom: false) {
        count += 1
        _ = budget.turnEnded()
      }
      return count
    }

    /// A side of the viewport changes size `seconds` after the last change.
    func viewport(_ side: LayoutScrollBudget.Side, _ size: CGFloat, after seconds: TimeInterval) {
      now = now.addingTimeInterval(seconds)
      budget.viewportChanged(side, to: size, at: now)
    }
  }

  @Test("A turn of the main thread gets a few scrolls, and the bottom is owed when it ends")
  func scrollsWithinOneTurn() {
    let spending = Spending()
    let allowed = (0..<10).count { _ in spending.spend(keepsBottom: true) }
    #expect(allowed == limits.perTurn)
    #expect(
      "\(spending.budget)"
        == "\(limits.perCause - limits.perTurn) left, \(limits.perTurn) this turn, owes the bottom")
    #expect(spending.turnEnded())
    #expect(spending.spend(keepsBottom: true))
    #expect(!spending.turnEnded())
  }

  @Test("A refused scroll that does not keep the bottom is not owed, nor one the reader left")
  func nothingOwed() {
    let spending = Spending(.init(perCause: 8, perTurn: 1))
    #expect(spending.spend(keepsBottom: false))
    #expect(!spending.spend(keepsBottom: false))
    #expect(!spending.turnEnded())

    #expect(spending.spend(keepsBottom: true))
    #expect(!spending.spend(keepsBottom: true))
    spending.budget.readerMoved()
    #expect(!spending.turnEnded())
    #expect("\(spending.budget)" == "8 left, 0 this turn")
  }

  @Test("An empty budget owes nothing, and the reader moving fills it")
  func emptyBudget() {
    let spending = Spending(.init(perCause: 2, perTurn: 1))
    #expect(spending.scrollsLeft() == 2)
    #expect(!spending.spend(keepsBottom: true))
    #expect(!spending.turnEnded())
    #expect(spending.budget.awaitsRest)
    spending.budget.readerMoved()
    #expect(!spending.budget.awaitsRest)
    #expect(spending.spend(keepsBottom: true))
  }

  @Test("Layout that was still for a while pays for scrolls when it next changes")
  func quietLayout() {
    var budget = LayoutScrollBudget(.init(perCause: 2, perTurn: 10))
    let begin = Date()
    var allowed = 0
    // A change every half second never leaves layout still long enough.
    for step in 0..<10 {
      let now = begin.addingTimeInterval(Double(step) * 0.5)
      budget.layoutChanged(at: now)
      if budget.spend(keepsBottom: true, at: now) { allowed += 1 }
    }
    #expect(allowed == 2)
    let later = begin.addingTimeInterval(4.5 + limits.quiet + 0.1)
    budget.layoutChanged(at: later)
    let paid = budget.spend(keepsBottom: true, at: later)
    #expect(paid)
  }

  @Test("A new viewport size pays for scrolls; one that keeps coming back stops paying")
  func viewportSizes() {
    let spending = Spending(.init(perCause: 3, perTurn: 1))
    #expect(spending.scrollsLeft() == 3)
    // A resize passes each width once: every one pays.
    for step in 0..<5 {
      spending.viewport(.width, 800 + CGFloat(step), after: 0.016)
      #expect(spending.scrollsLeft() == 3)
    }
    // A width flipping between two values pays while it could still be a resize.
    var paid = 0
    for step in 0..<40 {
      spending.viewport(.width, step.isMultiple(of: 2) ? 600 : 620.4, after: 0.016)
      paid += spending.scrollsLeft()
    }
    #expect(paid == 2 * LayoutScrollBudget.repeats * 3)
    // The dock is another side, and its changes keep layout from being still.
    for step in 0..<3 {
      spending.viewport(.dock, 600 + CGFloat(step) * 10, after: 0.9)
      #expect(spending.scrollsLeft() == 3)
    }
    // A width pays again once it has been away a while.
    spending.viewport(.width, 600, after: 0.9)
    #expect(spending.scrollsLeft() == 3)
  }

  @Test("Without limits nothing is refused")
  func noLimits() {
    let spending = Spending(.none)
    #expect((0..<1000).allSatisfy { _ in spending.spend(keepsBottom: true) })
  }

  /// A transcript's state with small limits, and the scrolls it made.
  private func state(
    perCause: Int, perTurn: Int, quiet: TimeInterval = 1
  ) -> (TranscriptScrollState, () -> [String]) {
    TranscriptScrollState.layoutScrollLimits = .init(
      perCause: perCause, perTurn: perTurn, quiet: quiet)
    defer { TranscriptScrollState.layoutScrollLimits = .init() }
    let state = TranscriptScrollState()
    let scrolls = Scrolls()
    state.scrollToRow = { id, anchor in scrolls.all.append("\(id) \(anchor.y)") }
    return (state, { scrolls.all })
  }

  private final class Scrolls {
    var all: [String] = []
  }

  /// Lets blocks waiting on the main run loop run, and timers due within `seconds`.
  private func returnToRunLoop(_ seconds: TimeInterval = 0.02) {
    CFRunLoopRunInMode(.defaultMode, seconds, false)
  }

  @Test("A scroll to the bottom refused within a turn runs when the main thread is back")
  func owedBottomAtTurnEnd() {
    let (state, scrolls) = state(perCause: 8, perTurn: 2)
    let allowed = (0..<5).count { _ in state.allowsScroll("content height", keepsBottom: true) }
    #expect(allowed == 2)
    #expect(scrolls().isEmpty)
    returnToRunLoop()
    #expect(scrolls() == ["\(TranscriptView.bottomID) 1.0"])
    // The next turn starts with its own scrolls.
    #expect(state.allowsScroll("content height", keepsBottom: true))
    returnToRunLoop()
    #expect(scrolls().count == 1)
  }

  @Test("A scroll to the bottom refused with the budget spent runs once layout has rested")
  func bottomAfterRest() {
    let (state, scrolls) = state(perCause: 1, perTurn: 10, quiet: 0.3)
    #expect(state.allowsScroll("content height", keepsBottom: true))
    #expect(!state.allowsScroll("content height", keepsBottom: true))
    // Layout that keeps changing keeps the scroll waiting.
    for _ in 0..<10 {
      #expect(!state.contentHeightChanged(400, from: 400))
      returnToRunLoop(0.05)
    }
    #expect(scrolls().isEmpty)
    for _ in 0..<100 where scrolls().isEmpty { returnToRunLoop(0.05) }
    #expect(scrolls() == ["\(TranscriptView.bottomID) 1.0"])
  }

  @Test("The scroll that waits for rest is dropped once the reader moves or is scrolling")
  func restWithoutScroll() {
    let (state, scrolls) = state(perCause: 1, perTurn: 10, quiet: 0.05)
    #expect(state.allowsScroll("content height", keepsBottom: true))
    #expect(!state.allowsScroll("content height", keepsBottom: true))
    state.readerMoved()
    returnToRunLoop(0.2)

    #expect(state.allowsScroll("dock inset", keepsBottom: true))
    #expect(!state.allowsScroll("dock inset", keepsBottom: true))
    _ = state.follow.scrollPhaseChanged(isUserScrolling: true)
    returnToRunLoop(0.2)
    #expect(scrolls().isEmpty)
  }

  @Test("The owed scroll does not run under the reader's own scrolling")
  func owedBottomWhileScrolling() {
    let (state, scrolls) = state(perCause: 8, perTurn: 1)
    #expect(state.allowsScroll("dock inset", keepsBottom: true))
    #expect(!state.allowsScroll("dock inset", keepsBottom: true))
    _ = state.follow.scrollPhaseChanged(isUserScrolling: true)
    returnToRunLoop()
    #expect(scrolls().isEmpty)
  }

  @Test("Content, the reader and a new viewport size each pay for more scrolls")
  func causes() {
    let (state, _) = state(perCause: 1, perTurn: 10)
    #expect(state.allowsScroll("content height", keepsBottom: true))
    #expect(!state.allowsScroll("content height", keepsBottom: true))
    state.contentChanged()
    #expect(state.allowsScroll("content height", keepsBottom: true))
    state.readerMoved()
    #expect(state.allowsScroll("content height", keepsBottom: true))
    state.widthChanged(to: 640)
    #expect(state.allowsScroll("keeps bottom", keepsBottom: true))
    #expect(!state.allowsScroll("keeps bottom", keepsBottom: true))
    returnToRunLoop()
  }

  @Test("Content and the dock growing scroll a following reader; shrinking and repeats do not")
  func growth() {
    let (state, _) = state(perCause: 8, perTurn: 10)
    #expect(state.contentHeightChanged(500, from: 400))
    #expect(!state.contentHeightChanged(400, from: 500))
    // Growth back to a height just reached is the lazy rows' estimates bouncing.
    #expect(!state.contentHeightChanged(500, from: 400))
    #expect(state.dockChanged(120, from: 100))
    #expect(!state.dockChanged(100, from: 120))
    state.follow.readEarlier()
    #expect(!state.contentHeightChanged(900, from: 800))
    #expect(!state.dockChanged(140, from: 100))
    returnToRunLoop()
  }

  private func anchor(_ id: String, width: CGFloat) -> TranscriptReadingAnchor {
    TranscriptReadingAnchor(
      id: id, fraction: 0.5, rowHeight: 100, viewportWidth: width, viewportHeight: 300)
  }

  @Test("A width change with the budget spent leaves the reading position alone")
  func restoreRefused() {
    let (state, scrolls) = state(perCause: 2, perTurn: 10)
    state.record(anchor("row", width: 900))
    state.restoreReading(from: 900, to: 400)
    #expect(scrolls() == ["row 0.5"])
    // The row's height at the new width finishes the restore with the last scroll paid for.
    state.record(anchor("row", width: 400))
    #expect(scrolls().count == 2)

    state.restoreReading(from: 400, to: 900)
    #expect(scrolls().count == 2)
    state.contentChanged()
    state.restoreReading(from: 400, to: 900)
    #expect(state.allowsScroll("content height", keepsBottom: false))
    // The restore still waits for the row, and finds the budget spent.
    state.record(anchor("row", width: 900))
    #expect(scrolls().count == 3)
    returnToRunLoop()
  }
}
