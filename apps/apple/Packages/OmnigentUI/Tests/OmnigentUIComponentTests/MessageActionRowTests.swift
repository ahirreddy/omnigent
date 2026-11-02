import Foundation
import Testing

@testable import OmnigentUIComponents

@Suite("Message actions")
@MainActor
struct MessageActionRowTests {
  private let forking = ConversationActions(
    forkFrom: { _ in },
    messageURL: { URL(string: "https://omnigent.example.com/c/s?message=\($0.id)") })

  private func kinds(_ row: Row, _ actions: ConversationActions) -> [MessageActionItem.Kind] {
    MessageActionItem.items(for: row, actions: actions).map(\.kind)
  }

  @Test("A settled answer offers Copy, Fork chat from here and Copy link, in that order")
  func answer() {
    let row = Row(id: "a1", role: .assistant, text: "Done.", responseId: "resp_1")
    let items = MessageActionItem.items(for: row, actions: forking)
    #expect(items.map(\.kind) == [.copy, .fork, .link])
    #expect(items.map(\.identifier) == ["message-copy-a1", "message-fork-a1", "message-link-a1"])
    #expect(items[1].title == "Fork chat from here")
    #expect(items[1].systemImage == "arrow.triangle.branch")
  }

  @Test("Fork needs a host that forks and a settled assistant message with a response")
  func forkPoints() {
    let answer = Row(id: "a1", role: .assistant, text: "Done.", responseId: "resp_1")
    #expect(!kinds(answer, ConversationActions()).contains(.fork))
    var streaming = answer
    streaming.isStreaming = true
    var preview = answer
    preview.isEphemeral = true
    var unanchored = answer
    unanchored.responseId = nil
    let user = Row(id: "u1", role: .user, text: "Hi", responseId: "turn_1")
    for row in [streaming, preview, unanchored, user] {
      #expect(!kinds(row, forking).contains(.fork), "\(row.id)")
    }
  }

  @Test("An empty message has nothing to copy")
  func emptyText() {
    let row = Row(id: "a1", role: .assistant, text: "", responseId: "resp_1")
    #expect(kinds(row, forking) == [.fork, .link])
  }
}
