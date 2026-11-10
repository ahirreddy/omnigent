import Foundation
import SwiftUI
import Testing

@testable import OmnigentUIComponents

/// A transcript whose tab is hidden holds its rows' width, and takes the viewport's when shown.
extension TranscriptRowWidthTests {
  @Test("Hidden, a follower's rows hold their width; shown, they take it and end at the end")
  func hiddenFollowerTakesTheWidthWhenShown() {
    let (state, scrolls) = state()
    state.tabContent(isHidden: true)
    state.rowWidthOffered(900)
    state.rowWidthOffered(700)
    returnToRunLoop()
    #expect(state.rowWidth.held == 500)
    #expect(scrolls.all.isEmpty)

    state.tabContent(isHidden: false)
    #expect(scrolls.all == [Self.top])
    state.topReached(true)
    #expect(state.rowWidth.held == 700)
    state.rowsResized()
    #expect(scrolls.all == [Self.top, Self.edge])
    // Shown already: told again, nothing more happens.
    state.tabContent(isHidden: false)
    #expect(scrolls.all == [Self.top, Self.edge])
    returnToRunLoop()
  }

  @Test("A hidden reader mid-conversation comes back to the row they were on when it hid")
  func hiddenReaderComesBackToTheirRow() {
    let (state, scrolls) = readingState()
    state.tabContent(isHidden: true)
    state.rowWidthOffered(900)
    // The viewport's new size puts another row under its middle, and its bottom near the end.
    state.record(anchor("x"))
    bottom(state, near: true)
    #expect(!state.end.isNearBottom)

    state.tabContent(isHidden: false)
    state.topReached(true)
    state.rowsResized()
    #expect(scrolls.all == [Self.top, "m 0.4"])
    returnToRunLoop()
  }

  @Test("A width that came back while the tab was hidden costs no scroll when it shows")
  func widthBackWhileHidden() {
    let (follower, followerScrolls) = state()
    follower.tabContent(isHidden: true)
    follower.rowWidthOffered(900)
    follower.rowWidthOffered(500)
    follower.tabContent(isHidden: false)
    returnToRunLoop()
    #expect(follower.rowWidth.held == 500)
    #expect(followerScrolls.all.isEmpty)

    // A reader away from the end stays where the scroll view kept them.
    let (reader, readerScrolls) = readingState()
    reader.tabContent(isHidden: true)
    reader.tabContent(isHidden: false)
    returnToRunLoop()
    #expect(readerScrolls.all.isEmpty)
  }

  @Test("Hidden, growing content and a growing dock scroll nothing; shown, a follower is put back")
  func hiddenFollowerIsPutBackWhenShown() {
    let (state, scrolls) = state()
    state.tabContent(isHidden: true)
    #expect(!state.contentHeightChanged(1_100, from: 1_000))
    #expect(!state.dockChanged(200, from: 100))
    end(state, reached: false)
    returnToRunLoop()
    #expect(scrolls.all.isEmpty)

    state.tabContent(isHidden: false)
    #expect(scrolls.all == [Self.end])
    end(state, reached: true)
    returnToRunLoop()
    #expect(scrolls.all == [Self.end])
  }

  @Test("A follower at the content's edge is at the end, and not scrolled when its tab shows")
  func followerAtTheEdgeShown() {
    let (state, scrolls) = state()
    state.tabContent(isHidden: true)
    _ = state.sees(end: .edge)
    state.tabContent(isHidden: false)
    returnToRunLoop()
    #expect(scrolls.all.isEmpty)
  }

  @Test("A hidden transcript ends no turn for the geometry it sees")
  func hiddenGeometryEndsNoTurn() {
    let (state, scrolls) = state()
    state.tabContent(isHidden: true)
    // A turn's end would rest this return on the bottom row.
    state.end.returnsByEdge = true
    _ = state.sees(end: .edge)
    _ = state.sees(
      TranscriptViewport(width: 900, visibleBottom: 0, contentHeight: 1_000))
    returnToRunLoop()
    #expect(scrolls.all.isEmpty)
    #expect(state.end.isNearBottom)
  }

  @Test("A turn that ends after the tab hid leaves the rows' width for when it shows")
  func turnEndingWhileHidden() {
    let (state, scrolls) = state()
    // Seen while shown: this turn's end is on its way.
    _ = state.sees(end: .away)
    state.tabContent(isHidden: true)
    state.rowWidthOffered(900)
    returnToRunLoop()
    #expect(state.rowWidth.held == 500)
    #expect(scrolls.all.isEmpty)
  }
}
