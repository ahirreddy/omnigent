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
}
