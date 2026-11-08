import CoreFoundation
import Testing

@testable import OmnigentUIComponents

@Suite("Message navigation")
struct TranscriptNavigationTests {
  private let order = ["u1", "a1", "u2", "a2", "u3", "a3"]
  private let users: Set = ["u1", "u2", "u3"]

  private func target(_ direction: TranscriptNavigation.Direction, visible: Set<String>)
    -> String?
  {
    TranscriptNavigation.target(direction, order: order, userMessages: users, visible: visible)
  }

  @Test("previous and next move from the top row on screen, in transcript order")
  func steps() {
    // Visibility comes in any order; the top row is the first in transcript order.
    #expect(target(.previous, visible: ["a3", "a2", "u3"]) == "u2")
    #expect(target(.next, visible: ["a3", "a2", "u3"]) == "u3")
    #expect(target(.previous, visible: ["u2", "a2"]) == "u1")
    #expect(target(.next, visible: ["u2", "a2"]) == "u3")
  }

  @Test("the ends of the loaded transcript have nothing further")
  func ends() {
    #expect(target(.previous, visible: ["u1", "a1"]) == nil)
    #expect(target(.next, visible: ["a3"]) == nil)
  }

  @Test("with nothing known on screen, previous goes to the newest user message")
  func unknownPosition() {
    #expect(target(.previous, visible: []) == "u3")
    #expect(target(.next, visible: ["transcript-bottom"]) == nil)
  }

  @Test("navigating to an earlier message stops following new output")
  func readEarlier() {
    var follow = TranscriptFollow()
    follow.readEarlier()
    #expect(follow.showsJumpToLatest)
    #expect(!follow.layoutGrew())
    let scrolls = follow.contentChanged()
    #expect(!scrolls)
    #expect(follow.hasUnseenOutput)
  }

  @Test("on touch the message pill shows only in the margin beside the column")
  func pillMargin() {
    // A phone's column is the full width.
    #expect(!TranscriptNavigator.fitsBesideColumn(width: 390, column: .infinity))
    // An iPad mini beside the sidebar: the reading column reaches the pill.
    #expect(!TranscriptNavigator.fitsBesideColumn(width: 520, column: 720))
    #expect(!TranscriptNavigator.fitsBesideColumn(width: 740, column: 720))
    // A wide iPad leaves room on either side.
    #expect(TranscriptNavigator.fitsBesideColumn(width: 1_000, column: 720))
  }
}

/// The "Jump to top" pill's response to the reader's scrolling.
struct ScrollTopRevealTests {
  @Test("scrolling up away from the top reveals the pill; scrolling down hides it")
  func scrollingUpRevealsAndDownHides() {
    #expect(ScrollTopReveal.change(delta: -20, isAtTop: false, isRevealed: false) == .reveal)
    #expect(ScrollTopReveal.change(delta: 20, isAtTop: false, isRevealed: true) == .hide)
    #expect(ScrollTopReveal.change(delta: 20, isAtTop: false, isRevealed: false) == .unchanged)
  }

  @Test("at the top, or for a sub-point jitter, nothing changes")
  func topAndJitterLeaveThePill() {
    #expect(ScrollTopReveal.change(delta: -20, isAtTop: true, isRevealed: false) == .unchanged)
    #expect(ScrollTopReveal.change(delta: -0.5, isAtTop: false, isRevealed: false) == .unchanged)
    #expect(ScrollTopReveal.change(delta: 0.5, isAtTop: false, isRevealed: true) == .unchanged)
  }

  @Test("a few points of re-measured rows at the top do not leave it")
  func theTopHasHysteresis() {
    #expect(ScrollTopReveal.isAtTop(0, wasAtTop: false))
    #expect(!ScrollTopReveal.isAtTop(4, wasAtTop: false))
    #expect(ScrollTopReveal.isAtTop(4, wasAtTop: true))
    #expect(!ScrollTopReveal.isAtTop(9, wasAtTop: true))
    // Rows re-measured back and forth across the edge settle instead of flipping each pass.
    var atTop = true
    for offset: CGFloat in [0, 6, 0, 7, 2, 5] {
      atTop = ScrollTopReveal.isAtTop(offset, wasAtTop: atTop)
      #expect(atTop)
    }
  }
}

/// Width measurers whose answer changes the width they measure settle instead of flipping on
/// every layout pass.
struct LayoutThresholdHysteresisTests {
  @Test("a fitting pill keeps fitting until it loses more than a scroll bar")
  func thePillFitsWithSlack() {
    let pill = TranscriptNavigator.pillWidth
    let edge = 720 + pill
    #expect(TranscriptNavigator.fits(width: edge, column: 720, pill: pill))
    #expect(!TranscriptNavigator.fits(width: edge - 15, column: 720, pill: pill))
    #expect(TranscriptNavigator.fits(width: edge - 15, column: 720, pill: pill, wasFitting: true))
    #expect(
      !TranscriptNavigator.fits(
        width: edge - TranscriptNavigator.fitSlack - 1, column: 720, pill: pill, wasFitting: true))
  }

  @Test("a compact layout grows past the threshold by the slack before it is regular")
  func theWidthClassHasSlack() {
    #expect(LayoutWidth.measuring(559, compactBelow: 560, previous: .regular) == .compact)
    #expect(LayoutWidth.measuring(560, compactBelow: 560, previous: .regular) == .regular)
    #expect(LayoutWidth.measuring(570, compactBelow: 560, previous: .compact) == .compact)
    #expect(
      LayoutWidth.measuring(560 + LayoutWidth.regularSlack, compactBelow: 560, previous: .compact)
        == .regular)
    // A scroll bar showing and hiding across the threshold settles on one class.
    var width = LayoutWidth.regular
    for measured: CGFloat in [559, 574, 559, 574] {
      width = LayoutWidth.measuring(measured, compactBelow: 560, previous: width)
      #expect(width == .compact)
    }
  }
}
