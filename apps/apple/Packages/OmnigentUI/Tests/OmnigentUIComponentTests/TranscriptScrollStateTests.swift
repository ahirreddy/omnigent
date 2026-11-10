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

  @Test("framing that lands away from the end shows the pill, however late it reports")
  func framingLandsAwayFromTheEnd() {
    var follow = TranscriptFollow()
    follow.frameLatest()
    #expect(!follow.follows)
    #expect(!follow.pill.isShown)
    follow.geometryChanged(isNearBottom: false)
    #expect(follow.pill.isShown)
    follow.frameLandingWaitEnded()
    #expect(!follow.follows)
    #expect(follow.pill.isShown)
  }

  @Test("framing that never leaves the end goes back to following, with no pill on the way")
  func framingStaysAtTheEnd() {
    var follow = TranscriptFollow()
    follow.frameLatest()
    #expect(!follow.layoutGrew())
    follow.frameLandingWaitEnded()
    #expect(follow.follows)
    #expect(follow.layoutGrew())
    #expect(!follow.pill.isShown)
  }

  @Test("framing that passes through a far estimate on its way back to the end still follows")
  func framingComesBackToTheEnd() {
    var follow = TranscriptFollow()
    follow.frameLatest()
    follow.geometryChanged(isNearBottom: false)
    follow.geometryChanged(isNearBottom: true)
    #expect(!follow.pill.isShown)
    follow.frameLandingWaitEnded()
    #expect(follow.follows)
  }

  @Test("after framing, the wait ending changes nothing the reader has since done")
  func framingWaitAfterReaderActed() {
    var navigated = TranscriptFollow()
    navigated.frameLatest()
    navigated.readEarlier()
    #expect(navigated.pill.isShown)
    navigated.frameLandingWaitEnded()
    #expect(!navigated.follows)

    var jumped = TranscriptFollow()
    jumped.frameLatest()
    jumped.jumpToLatest()
    jumped.geometryChanged(isNearBottom: false)
    jumped.frameLandingWaitEnded()
    #expect(jumped.follows)
    #expect(!jumped.pill.isShown)
  }

  private func stallThisThread(seconds: TimeInterval) {
    Thread.sleep(forTimeInterval: seconds)
  }

  @Test("a stalled main thread pauses the wait for framing to land instead of using it up")
  @MainActor
  func framingWaitOutlastsAStall() async throws {
    var hasEnded = false
    let wait = Task { @MainActor in
      try await TranscriptFollow.waitForFrameLanding()
      hasEnded = true
    }
    defer { wait.cancel() }
    await Task.yield()
    stallThisThread(seconds: 0.6)
    try await Task.sleep(for: .milliseconds(1))
    #expect(!hasEnded)
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

  @Test("a viewport knows whether its bottom is near the content's end")
  func viewportNearBottom() {
    let atBottom = TranscriptViewport(width: 1032, visibleBottom: 5_000, contentHeight: 5_040)
    let reading = TranscriptViewport(width: 1032, visibleBottom: 3_000, contentHeight: 5_040)
    #expect(atBottom.isNearBottom)
    #expect(!reading.isNearBottom)
    // Rotated: the rows grew taller, so the bottom is now far away.
    let rotated = TranscriptViewport(width: 744.4, visibleBottom: 5_000, contentHeight: 7_000)
    #expect(rotated.width == 744)
    #expect(!rotated.isNearBottom)
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

  private static func anchor(_ id: String, _ fraction: Double, row: CGFloat, width: CGFloat)
    -> TranscriptReadingAnchor
  {
    TranscriptReadingAnchor(
      id: id, fraction: fraction, rowHeight: row, viewportWidth: width, viewportHeight: 1_000)
  }

  @Test("growth that keeps reaching new heights is followed, a height coming back is not")
  func followedHeights() {
    var heights = FollowedHeights()
    let start = Date()
    func follows(_ height: CGFloat, from origin: CGFloat, after seconds: TimeInterval) -> Bool {
      heights.follows(height, from: origin, at: start.addingTimeInterval(seconds))
    }
    #expect(follows(658, from: 600, after: 0))
    #expect(follows(737, from: 658, after: 0))
    #expect(follows(770, from: 737, after: 0))
    // Lazy rows estimated again after the scroll: the content shrinks and grows back.
    #expect(!follows(737, from: 699, after: 0.1))
    #expect(!follows(770.4, from: 700, after: 0.2))
    // A bounce that keeps going stays let go; new output is followed.
    #expect(!follows(737, from: 701, after: 2.05))
    #expect(follows(812, from: 790, after: 2.1))
    // Long after, the same growth is growth like any other.
    #expect(follows(737, from: 658, after: 5))
  }

  @Test("growth to a new estimate from a height it already grew from is not followed")
  func followedHeightsBouncingToNewEstimates() {
    var heights = FollowedHeights()
    let start = Date()
    func follows(_ height: CGFloat, from origin: CGFloat, after seconds: TimeInterval) -> Bool {
      heights.follows(height, from: origin, at: start.addingTimeInterval(seconds))
    }
    #expect(follows(689, from: 616, after: 0))
    #expect(!follows(723, from: 616, after: 0.02))
    #expect(!follows(678, from: 616, after: 0.04))
    // The bounce keeps the start remembered for as long as it lasts.
    #expect(!follows(701, from: 616, after: 1.9))
    #expect(!follows(695, from: 616, after: 3.8))
    // Output growing on from elsewhere is followed meanwhile, and the start ages out after.
    #expect(follows(760, from: 730, after: 3.9))
    #expect(follows(689, from: 616, after: 6))
  }
}
