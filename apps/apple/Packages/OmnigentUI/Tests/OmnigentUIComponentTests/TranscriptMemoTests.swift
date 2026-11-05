import Foundation
import SwiftUI
import Testing

@testable import OmnigentUIComponents

/// The transcript computes its folded layout once per change, and keeps its environment values
/// stable, so unchanged rows skip re-rendering while output streams.
@Suite("Transcript layout and environment stay stable between changes")
@MainActor
struct TranscriptMemoTests {
  static func conversation(rows: [Row], status: TurnStatus = .running) -> ConversationViewState {
    ConversationViewState(
      header: SessionHeader(id: "sess", title: "Memo", status: status), rows: rows)
  }

  static let rows = [
    Row(id: "u1", role: .user, text: "Fix the bug"),
    Row(id: "a1", role: .assistant, text: "Looking", responseId: "r1"),
    Row(id: "u2", role: .user, text: "And add tests"),
    Row(id: "a2", role: .assistant, text: "On it", isStreaming: true, responseId: "r2"),
  ]

  @Test("the same rows reuse the layout; a streamed delta recomputes it")
  func layoutComputedOncePerChange() {
    let memo = TranscriptLayoutMemo()
    var state = Self.conversation(rows: Self.rows)
    let first = memo.entries(for: state)
    // A new state value with equal rows, as every parent update builds.
    _ = memo.entries(for: Self.conversation(rows: Self.rows))
    _ = memo.blocks(for: state)
    _ = memo.blocks(for: state)
    #expect(memo.computations == 1)
    #expect(first.map(\.segment) == TranscriptView.segments(for: state))

    state.rows[3].text += " now"
    let streamed = memo.entries(for: state)
    #expect(memo.computations == 2)
    #expect(streamed.map(\.segment) == TranscriptView.segments(for: state))
  }

  @Test("decorations and durations follow the state")
  func decorationsFollowState() {
    let memo = TranscriptLayoutMemo()
    var rows = Self.rows
    rows[3].isStreaming = false
    var state = Self.conversation(rows: rows, status: .idle)
    state.turnDurations = ["r2": 12]
    state.timestamps = ["a2": Date(timeIntervalSince1970: 100)]
    let entries = memo.entries(for: state)
    let answer = entries.first { $0.id == "a2" }
    #expect(answer?.decorations["a2"]?.showsActions == true)
    #expect(answer?.decorations["a2"]?.timestamp == Date(timeIntervalSince1970: 100))
    #expect(entries.first { $0.id == "a1" }?.decorations["a1"]?.showsActions == false)

    state.timestamps["a2"] = Date(timeIntervalSince1970: 200)
    let updated = memo.entries(for: state)
    #expect(memo.computations == 2)
    #expect(updated.first { $0.id == "a2" }?.decorations["a2"]?.timestamp != nil)
  }

  @Test("a streamed delta folds only the open turn, and matches a full rebuild")
  func deltaReusesSettledTurns() {
    var rows = TranscriptBenchmarks.rows(turns: 12)
    rows[rows.count - 1].isStreaming = true
    let memo = TranscriptLayoutMemo()
    var state = Self.conversation(rows: rows)
    _ = memo.entries(for: state)
    for word in ["more", "words", "here"] {
      state.rows[state.rows.count - 1].text += " \(word)"
      #expect(memo.entries(for: state).map(\.segment) == TranscriptView.segments(for: state))
    }
    #expect(memo.prefixReuses == 3)

    // A change above the last user message folds everything again.
    state.rows[1].activity?.status = "failed"
    #expect(memo.entries(for: state).map(\.segment) == TranscriptView.segments(for: state))
    #expect(memo.prefixReuses == 3)
    // So does settling the turn: the last answer's actions move.
    state.rows[state.rows.count - 1].isStreaming = false
    state.header.status = .idle
    let settled = memo.entries(for: state)
    #expect(settled.map(\.segment) == TranscriptView.segments(for: state))
    let lastID = state.rows[state.rows.count - 1].id
    #expect(settled.last?.decorations[lastID]?.showsActions == true)
  }

  @Test("a steer inside a response keeps its Worked for on the answer after it")
  func steerDecoratesAcrossTheMessage() {
    let rows = [
      Row(id: "u1", role: .user, text: "Fix it"),
      Row(id: "a1", role: .assistant, text: "Starting", responseId: "r1"),
      Row(id: "u2", role: .user, text: "Also the tests"),
      Row(id: "a2", role: .assistant, text: "Done", responseId: "r1"),
    ]
    var state = Self.conversation(rows: rows, status: .idle)
    state.turnDurations = ["r1": 30]
    let entries = TranscriptLayoutMemo().entries(for: state)
    #expect(entries.first { $0.id == "a1" }?.decorations["a1"]?.workedFor == nil)
    #expect(entries.first { $0.id == "a2" }?.decorations["a2"]?.workedFor == 30)
  }

  @Test("fresh conversation actions publish one environment value that calls the latest")
  func actionsKeepIdentity() throws {
    let relay = TranscriptEnvironmentRelay()
    var opened: [String] = []
    _ = relay.publish(ConversationActions(openSession: { opened.append("first \($0)") }))
    let published = relay.publish(
      ConversationActions(openSession: { opened.append("second \($0)") }))
    #expect(relay.publications == 1)
    published.openSession?("child")
    #expect(opened == ["second child"])

    _ = relay.publish(ConversationActions(openSession: { _ in }, retry: {}))
    #expect(relay.publications == 2)
  }

  @Test("the link action is built once and opens through the latest actions")
  func openURLStable() throws {
    let relay = TranscriptEnvironmentRelay()
    var links: [URL] = []
    _ = relay.publish(ConversationActions(openURL: { _ in links.append(URL(filePath: "/old")) }))
    let action = relay.openURL
    _ = relay.publish(ConversationActions(openURL: { links.append($0) }))
    let url = try #require(URL(string: "https://example.com"))
    action(url)
    #expect(links == [url])
  }
}
