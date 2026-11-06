import CoreGraphics
import SwiftUI
import Testing

@testable import OmnigentUIComponents

@Suite("Transcript scroll state")
struct TranscriptScrollStateTests {
  @Test("geometry that moves the bottom while following leaves the pill alone")
  func pillIgnoresGeometryWhileFollowing() {
    var follow = TranscriptFollow()
    let pill = follow.pill
    // The keyboard or a resize moving the bottom is not the reader scrolling.
    follow.geometryChanged(isNearBottom: false)
    follow.geometryChanged(isNearBottom: true)
    _ = follow.contentChanged()
    #expect(follow.pill == pill)
    #expect(!pill.isShown)
  }

  @Test("the pill changes only when following stops or unseen output arrives")
  func pillChangesWithFollowing() {
    var follow = TranscriptFollow()
    follow.readEarlier()
    #expect(follow.pill == TranscriptFollow.Pill(isShown: true, hasUnseenOutput: false))
    #expect(follow.pill.title == "Jump to latest")
    _ = follow.contentChanged()
    let unseen = follow.pill
    #expect(unseen.hasUnseenOutput)
    #expect(unseen.title == "New output")
    // More output while reading changes nothing the pill shows.
    _ = follow.contentChanged()
    #expect(follow.pill == unseen)
    follow.jumpToLatest()
    #expect(!follow.pill.isShown)
  }

  @Test("a width change keeps a viewport at the bottom there, and only then")
  func widthChangeKeepsTheBottom() {
    let atBottom = TranscriptViewport(width: 1032, visibleBottom: 5_000, contentHeight: 5_040)
    let reading = TranscriptViewport(width: 1032, visibleBottom: 3_000, contentHeight: 5_040)
    #expect(atBottom.isNearBottom)
    #expect(!reading.isNearBottom)
    // Rotated: the rows grew taller, so the bottom is now far away.
    let rotated = TranscriptViewport(width: 744.4, visibleBottom: 5_000, contentHeight: 7_000)
    #expect(rotated.width == 744)
    #expect(rotated.keepsBottom(after: atBottom))
    #expect(!rotated.keepsBottom(after: reading))
    // The keyboard changes the bottom inset, not the width.
    let keyboard = TranscriptViewport(width: 1032, visibleBottom: 4_600, contentHeight: 5_040)
    #expect(!keyboard.keepsBottom(after: atBottom))
    // The first layout has no width to compare with.
    let first = TranscriptViewport(width: 0, visibleBottom: 0, contentHeight: 0)
    #expect(!atBottom.keepsBottom(after: first))
  }

  @Test("only the row under the viewport's middle is the reading anchor")
  func anchorIsTheRowAtTheMiddle() {
    // The viewport in the row's coordinates: its middle is 300 pt into a 1,200 pt row.
    let viewport = CGRect(x: 0, y: -200, width: 1032.3, height: 1_000)
    let anchor = TranscriptReadingAnchor.sample(id: "a", height: 1_200, viewport: viewport)
    #expect(anchor == Self.anchor("a", 0.25, row: 1_200, width: 1032))
    // A row wholly above or below the middle is not it.
    #expect(TranscriptReadingAnchor.sample(id: "b", height: 250, viewport: viewport) == nil)
    let below = viewport.offsetBy(dx: 0, dy: -400)
    #expect(TranscriptReadingAnchor.sample(id: "c", height: 250, viewport: below) == nil)
    #expect(TranscriptReadingAnchor.sample(id: "d", height: 250, viewport: nil) == nil)
  }

  @Test("the restore anchor puts the same point of the reflowed row at the middle")
  func restoreAnchorSolvesForTheMiddle() {
    let before = Self.anchor("a", 0.25, row: 1_200, width: 1032)
    // Narrower, the row is taller: 300 of 1,200 pt is now 400 of 1,600 pt.
    let after = Self.anchor("a", 0.6, row: 1_600, width: 744)
    let point = before.unitPoint(in: after)
    // scrollTo puts the row's top at y * (viewport - row); the point must land at 500.
    let top = point.y * (1_000 - 1_600)
    #expect(abs(top + 0.25 * 1_600 - 500) < 0.001)
    // A row as tall as the viewport falls back to its fraction.
    #expect(before.unitPoint(in: Self.anchor("a", 0.5, row: 1_000, width: 744)).y == 0.25)
  }

  @MainActor
  @Test("a resize restores the anchor recorded at the width before it, then refines it")
  func anchorSurvivesTheResizesSamples() {
    let state = TranscriptScrollState()
    var scrolls: [(String, UnitPoint)] = []
    state.scrollToRow = { scrolls.append(($0, $1)) }
    state.record(Self.anchor("a", 0.5, row: 800, width: 1032))
    state.record(Self.anchor("b", 0.1, row: 3_000, width: 1032))
    // Another row reports at the new width before the resize is handled.
    state.record(Self.anchor("z", 0.9, row: 300, width: 744))
    #expect(state.readingAnchor(atWidth: 1032)?.id == "b")
    #expect(state.readingAnchor(atWidth: 500) == nil)
    state.restoreReading(from: 1032, to: 744)
    #expect(scrolls.map { $0.0 } == ["b"])
    #expect(scrolls.last?.1.y == 0.1)
    // Row b reports its new height: one exact scroll, then nothing more.
    state.record(Self.anchor("b", 0.3, row: 4_000, width: 744))
    state.record(Self.anchor("b", 0.31, row: 4_000, width: 744))
    #expect(scrolls.map { $0.0 } == ["b", "b"])
  }

  private static func anchor(_ id: String, _ fraction: Double, row: CGFloat, width: CGFloat)
    -> TranscriptReadingAnchor
  {
    TranscriptReadingAnchor(
      id: id, fraction: fraction, rowHeight: row, viewportWidth: width, viewportHeight: 1_000)
  }
}
