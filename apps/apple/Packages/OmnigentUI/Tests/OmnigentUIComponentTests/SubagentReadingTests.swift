import Foundation
import Testing

@testable import OmnigentUIComponents

@Suite("Sub-agent groups")
struct SubagentGroupTests {
  @Test("the headline counts children by status, most urgent first")
  func headline() throws {
    let group = try #require(SubagentGroup(state: PreviewData.subagentConversation))
    #expect(group.children.map(\.id) == ["sess_c1", "sess_c3", "sess_c2"])
    #expect(group.headline == "3 agents \u{00B7} 1 needs you \u{00B7} 1 running \u{00B7} 1 ready")
    #expect(group.startsExpanded)
    #expect(group.active.map(\.id) == ["sess_c1", "sess_c3"])
    #expect(group.done.map(\.id) == ["sess_c2"])
    let first = try #require(group.children.first)
    #expect(first.goal == "Cover expiry and concurrent refresh in auth/tests.rs.")
    #expect(first.activity == "Running cargo test -p omnigent-core auth")
    #expect(first.agent == "tester")
    #expect(first.startedAt == PreviewData.now.addingTimeInterval(-260))
  }

  @Test("a mirrored request makes its child need you and renders in the group, not inline")
  func blockedChild() throws {
    var state = PreviewData.subagentConversation
    let group = try #require(SubagentGroup(state: state))
    let blocked = try #require(group.children.first { $0.id == "sess_c3" })
    #expect(blocked.status == .needsYou)
    #expect(blocked.decisions.map(\.id) == [PreviewData.subagentCommand.id])
    #expect(group.decisionIDs == [PreviewData.subagentCommand.id])
    #expect(
      SubagentGroup.context(for: PreviewData.subagentCommand, in: state)
        == "Subagent \u{00B7} Check migrations")

    // Answered locally: back to what the core says (running) until the server confirms.
    state.decisionPhases[PreviewData.subagentCommand.id] = .answered(summary: "Approved")
    let answered = try #require(SubagentGroup(state: state))
    #expect(answered.count(.needsYou) == 0)
    #expect(answered.headline == "3 agents \u{00B7} 2 running \u{00B7} 1 ready")
    #expect(!answered.startsExpanded)

    // A failed answer keeps the request in front of the user.
    state.decisionPhases[PreviewData.subagentCommand.id] = .failed(message: "Offline")
    #expect(SubagentGroup(state: state)?.count(.needsYou) == 1)
  }

  @Test("no children means no group; unknown states read as starting")
  func edges() {
    var state = PreviewData.conversation
    state.sections = []
    #expect(SubagentGroup(state: state) == nil)
    state.sections = [
      EventSection(id: "child-x", title: "Legacy", summary: "Created", sessionId: "x"),
      EventSection(id: "child-orphan", title: "No session", summary: "Running"),
    ]
    let group = SubagentGroup(state: state)
    #expect(group?.children.map(\.status) == [.starting])
    #expect(group?.headline == "1 agent \u{00B7} 1 starting")
  }

  @Test("a mirrored request for an unknown child stays inline and keeps the generic context")
  func unknownChild() {
    var state = PreviewData.subagentConversation
    var orphan = PreviewData.subagentCommand
    orphan.id = "elic_orphan"
    orphan.targetSessionId = "sess_unknown"
    state.decisions.append(orphan)
    let group = SubagentGroup(state: state)
    #expect(group?.decisionIDs == [PreviewData.subagentCommand.id])
    #expect(SubagentGroup.context(for: orphan, in: state) == "Subagent")
    #expect(SubagentGroup.context(for: PreviewData.codexCommand, in: state) == nil)
  }
}

@Suite("Reading position")
struct TranscriptFollowTests {
  @Test("incoming output follows only while following and never under the user's finger")
  func following() {
    var follow = TranscriptFollow()
    let step1 = follow.contentChanged()
    #expect(step1)
    #expect(!follow.showsJumpToLatest)
    // Growth below the viewport while still is not the reader moving.
    follow.geometryChanged(isNearBottom: false)
    #expect(follow.follows)
    let step2 = follow.contentChanged()
    #expect(step2)

    // A drag near the bottom keeps following but does not scroll mid-gesture.
    let step3 = follow.scrollPhaseChanged(isUserScrolling: true)
    #expect(!step3)
    follow.geometryChanged(isNearBottom: true)
    let step4 = follow.contentChanged()
    #expect(!step4)
    follow.geometryChanged(isNearBottom: true)
    let step5 = follow.scrollPhaseChanged(isUserScrolling: false)
    #expect(step5)
  }

  @Test("rows resizing after layout keep a following reader at the bottom, never a scrolling one")
  func layoutGrowthFollowsOnlyAStillFollower() {
    var follow = TranscriptFollow()
    #expect(follow.layoutGrew())
    let started = follow.scrollPhaseChanged(isUserScrolling: true)
    #expect(!started)
    #expect(!follow.layoutGrew())
    follow.geometryChanged(isNearBottom: false)
    let ended = follow.scrollPhaseChanged(isUserScrolling: false)
    #expect(!ended)
    #expect(!follow.layoutGrew())
    #expect(!follow.hasUnseenOutput)
  }

  @Test("a reader scrolled up is never moved; Jump to latest shows and marks new output")
  func readingEarlierRows() {
    var follow = TranscriptFollow()
    _ = follow.scrollPhaseChanged(isUserScrolling: true)
    follow.geometryChanged(isNearBottom: false)
    let step6 = follow.scrollPhaseChanged(isUserScrolling: false)
    #expect(!step6)
    #expect(follow.showsJumpToLatest)
    #expect(follow.jumpTitle == "Jump to latest")
    for _ in 0..<5 {
      let step7 = follow.contentChanged()
      #expect(!step7)
    }
    #expect(follow.hasUnseenOutput)
    #expect(follow.jumpTitle == "New output")
    // Content growth while reading never flips the mode.
    follow.geometryChanged(isNearBottom: true)
    #expect(follow.showsJumpToLatest)

    follow.jumpToLatest()
    #expect(!follow.showsJumpToLatest)
    #expect(!follow.hasUnseenOutput)
    let step8 = follow.contentChanged()
    #expect(step8)
  }

  @Test("scrolling back to the bottom resumes following and catches up once")
  func scrollingBack() {
    var follow = TranscriptFollow()
    _ = follow.scrollPhaseChanged(isUserScrolling: true)
    follow.geometryChanged(isNearBottom: false)
    _ = follow.scrollPhaseChanged(isUserScrolling: false)
    _ = follow.contentChanged()
    _ = follow.scrollPhaseChanged(isUserScrolling: true)
    follow.geometryChanged(isNearBottom: true)
    let step9 = follow.scrollPhaseChanged(isUserScrolling: false)
    #expect(step9)
    #expect(!follow.showsJumpToLatest)
    follow.reset()
    #expect(follow == TranscriptFollow())
  }
}

@Suite("Command-Return ownership")
struct CommandReturnOwnerTests {
  @Test("a sendable draft keeps Send; otherwise a docked approval takes it")
  func owner() {
    #expect(CommandReturnOwner.resolve(canSend: true, approvableCardID: "card") == .send)
    #expect(CommandReturnOwner.resolve(canSend: false, approvableCardID: "card") == .approve)
    #expect(CommandReturnOwner.resolve(canSend: false, approvableCardID: nil) == .send)
    #expect(CommandReturnOwner.resolve(canSend: true, approvableCardID: nil) == .send)
  }
}

@Suite("Inbox count")
struct InboxCountTests {
  @Test("the sample header counts sessions, not requests")
  func sessionsNotRequests() {
    let state = InboxTriageSamples.state
    let requests = state.items.filter { $0.decision != nil && $0.isUnresolved }
    #expect(requests.count == 3)
    #expect(state.needsYouCount == 2)
    var answered = state
    if let index = answered.items.firstIndex(where: { $0.id == "in5" }) {
      answered.items[index].phase = .answered(summary: "Answered")
    }
    // The other request in the same session still needs the user.
    #expect(InboxTriageSamples.sessionsNeedingYou(answered.items) == 2)
  }
}
