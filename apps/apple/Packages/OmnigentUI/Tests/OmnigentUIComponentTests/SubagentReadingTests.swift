import Foundation
import Testing

@testable import OmnigentUIComponents

@Suite("Sub-agents of a parent")
struct SubagentGroupTests {
  @Test("children read from their sections in order, with goal, activity, agent and start")
  func children() throws {
    var state = PreviewData.subagentConversation
    state.decisions = []
    let group = try #require(SubagentGroup(state: state))
    #expect(group.children.map(\.id) == ["sess_c1", "sess_c3", "sess_c2"])
    #expect(group.children.map(\.status) == [.working, .working, .done])
    #expect(group.children.map(\.statusLabel) == ["Working", "Working", "Done"])
    let first = try #require(group.children.first)
    #expect(first.goal == "Cover expiry and concurrent refresh in auth/tests.rs.")
    #expect(first.name == first.goal)
    #expect(first.activity == "Running cargo test -p omnigent-core auth")
    #expect(first.agent == "tester")
    #expect(first.startedAt == PreviewData.now.addingTimeInterval(-260))
  }

  @Test("the count lists starting, working, waiting, disconnected and failed children only")
  func tally() throws {
    var state = PreviewData.conversation
    state.sections = AgentTreeActivity.allCases.map { status in
      PreviewData.childSection(status.rawValue, title: status.title, state: status)
    }
    let group = try #require(SubagentGroup(state: state))
    #expect(
      group.tally.map(\.id) == ["launching", "working", "needs_you", "failed", "disconnected"])
    #expect(group.tally.allSatisfy { $0.status.isTallied })
    #expect(group.children.filter { !$0.status.isTallied }.map(\.id) == ["done", "idle", "other"])
  }

  @Test("a mirrored request makes its child need you until it is answered")
  func blockedChild() throws {
    var state = PreviewData.subagentConversation
    let blocked = try #require(SubagentGroup(state: state)?.children.first { $0.id == "sess_c3" })
    #expect(blocked.status == .needsYou)
    #expect(blocked.statusLabel == "Needs you")
    #expect(
      SubagentGroup.context(for: PreviewData.subagentCommand, in: state)
        == "Subagent \u{00B7} Check migrations")

    // Answered locally: back to what the core says (working) until the server confirms.
    state.decisionPhases[PreviewData.subagentCommand.id] = .answered(summary: "Approved")
    let answered = try #require(SubagentGroup(state: state)?.children.first { $0.id == "sess_c3" })
    #expect(answered.status == .working)
    #expect(answered.statusLabel == "Working")

    // A failed answer keeps the request in front of the user.
    state.decisionPhases[PreviewData.subagentCommand.id] = .failed(message: "Offline")
    #expect(SubagentGroup(state: state)?.tally.contains { $0.status == .needsYou } == true)
  }

  @Test("no children means no group; a missing state reads idle and a missing label its title")
  func edges() {
    var state = PreviewData.conversation
    state.sections = []
    #expect(SubagentGroup(state: state) == nil)
    state.sections = [
      EventSection(id: "child-x", title: "Legacy", summary: "", sessionId: "x"),
      EventSection(
        id: "child-y", title: "Odd", summary: "cancelled",
        details: [DetailSection(id: "state", title: "State", text: "other")], sessionId: "y"),
      EventSection(id: "child-orphan", title: "No session", summary: "Working"),
    ]
    let group = SubagentGroup(state: state)
    #expect(group?.children.map(\.status) == [.idle, .other])
    #expect(group?.children.map(\.statusLabel) == ["Idle", "cancelled"])
    #expect(group?.children.first?.name == "Legacy")
    #expect(group?.tally.isEmpty == true)
  }

  @Test("a mirrored request for an unknown child keeps the generic context")
  func unknownChild() {
    var orphan = PreviewData.subagentCommand
    orphan.id = "elic_orphan"
    orphan.targetSessionId = "sess_unknown"
    let state = PreviewData.subagentConversation
    #expect(SubagentGroup.context(for: orphan, in: state) == "Subagent")
    #expect(SubagentGroup.context(for: PreviewData.codexCommand, in: state) == nil)
  }

  @Test("each status has its word, and a child without one takes it")
  func titles() {
    let titles = AgentTreeActivity.allCases.map(\.title)
    #expect(
      titles == [
        "Launching", "Working", "Needs you", "Done", "Failed", "Disconnected", "Idle", "Other",
      ])
    #expect(SubagentChild(id: "a", title: "A", status: .failed).statusLabel == "Failed")
    #expect(SubagentChild(id: "a", title: "A", status: .failed).sectionID == "child-a")
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
