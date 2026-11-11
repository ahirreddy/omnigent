import CoreGraphics
import Foundation
import Testing

@testable import OmnigentUIComponents

/// A message the user sends takes the transcript to its end, which it then follows until they
/// scroll away; nothing else that arrives moves a reader of earlier rows.
@MainActor
@Suite("Transcript sends", .serialized)
struct TranscriptSendsTests {
  /// The user scrolls and lets go with the viewport's bottom near the end or far from it, as
  /// the transcript hears it: the phase, the geometry seen meanwhile, the phase ending.
  /// - Returns: Whether the scroll's end asks for a scroll to the newest row.
  @discardableResult
  private func userScrolls(_ state: TranscriptScrollState, endingNearEnd: Bool) -> Bool {
    state.readerMoved()
    _ = state.follow.scrollPhaseChanged(isUserScrolling: true)
    _ = state.sees(
      TranscriptViewport(
        width: 900, visibleBottom: endingNearEnd ? 5_000 : 1_000, contentHeight: 5_000))
    state.readerMoved()
    state.settleFollow()
    return state.follow.scrollPhaseChanged(isUserScrolling: false)
  }

  /// The scroll a send asked for lands: the viewport's bottom is seen at the content's end.
  private func landsAtTheEnd(_ state: TranscriptScrollState) {
    _ = state.sees(TranscriptViewport(width: 900, visibleBottom: 5_000, contentHeight: 5_000))
    state.settleFollow()
  }

  /// Lets blocks waiting on the main run loop run.
  private func returnToRunLoop() {
    CFRunLoopRunInMode(.defaultMode, 0.02, false)
  }

  @Test("Only a higher count in the same session is a send")
  func newSends() {
    let before = TranscriptSends(sessionID: "a", count: 2)
    #expect(TranscriptSends(sessionID: "a", count: 3).hasNewSend(since: before))
    #expect(!before.hasNewSend(since: before))
    // Another session shown in the same view, and a conversation opened again.
    #expect(!TranscriptSends(sessionID: "b", count: 3).hasNewSend(since: before))
    #expect(!TranscriptSends(sessionID: "a", count: 0).hasNewSend(since: before))
  }

  @Test("The sends compared are the shown session's")
  func sendsOfAState() {
    var state = ConversationViewState(header: SessionHeader(id: "session-1", title: "A session"))
    #expect(TranscriptSends(state) == TranscriptSends(sessionID: "session-1", count: 0))
    state.sendCount = 4
    #expect(TranscriptSends(state) == TranscriptSends(sessionID: "session-1", count: 4))
  }

  @Test("A send while reading earlier rows goes to the end, and growth after it is followed")
  func sendWhileScrolledUp() {
    let state = TranscriptScrollState()
    userScrolls(state, endingNearEnd: false)
    #expect(!state.follow.follows)
    #expect(state.follow.pill.isShown)

    #expect(state.userSent())
    #expect(state.follow.follows)
    #expect(!state.follow.pill.isShown)
    landsAtTheEnd(state)
    // The sent row, the working indicator and a reply taller than the viewport all grow it.
    state.contentChanged()
    let followsOutput = state.follow.contentChanged()
    #expect(followsOutput)
    #expect(state.contentHeightChanged(5_080, from: 5_000))
    #expect(state.contentHeightChanged(5_120, from: 5_080))
    #expect(state.contentHeightChanged(7_400, from: 5_120))
    returnToRunLoop()
  }

  @Test("A reply with no send leaves a reader of earlier rows where they are")
  func replyWithoutASend() {
    let state = TranscriptScrollState()
    userScrolls(state, endingNearEnd: false)
    state.contentChanged()
    let followsOutput = state.follow.contentChanged()
    #expect(!followsOutput)
    #expect(!state.contentHeightChanged(5_400, from: 5_000))
    #expect(!state.dockChanged(140, from: 100))
    #expect(state.follow.pill == TranscriptFollow.Pill(isShown: true, hasUnseenOutput: true))
    returnToRunLoop()
  }

  @Test("Scrolling up after a send stops following; scrolling back to the end follows again")
  func scrollingUpAfterASend() {
    let state = TranscriptScrollState()
    userScrolls(state, endingNearEnd: false)
    #expect(state.userSent())
    landsAtTheEnd(state)
    #expect(state.contentHeightChanged(5_080, from: 5_000))

    userScrolls(state, endingNearEnd: false)
    #expect(!state.follow.follows)
    state.contentChanged()
    let followsOutput = state.follow.contentChanged()
    #expect(!followsOutput)
    #expect(!state.contentHeightChanged(5_300, from: 5_080))
    #expect(state.follow.pill == TranscriptFollow.Pill(isShown: true, hasUnseenOutput: true))

    // Back at the end with output they have not seen: one scroll catches up, then it follows.
    let catchesUp = userScrolls(state, endingNearEnd: true)
    #expect(catchesUp)
    #expect(!state.follow.pill.isShown)
    #expect(state.contentHeightChanged(5_500, from: 5_300))
    returnToRunLoop()
  }

  @Test("Growth under the reader's own scroll is not followed, even right after a send")
  func growthDuringAScroll() {
    let state = TranscriptScrollState()
    #expect(state.userSent())
    _ = state.follow.scrollPhaseChanged(isUserScrolling: true)
    #expect(!state.contentHeightChanged(5_080, from: 5_000))
    returnToRunLoop()
  }
}
