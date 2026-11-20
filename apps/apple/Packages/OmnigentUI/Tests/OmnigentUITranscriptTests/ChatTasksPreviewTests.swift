import Testing

@testable import OmnigentUIComponents

/// The one-line task preview over the chat.
@Suite("The chat's task preview")
struct ChatTasksPreviewTests {
  @Test("It reads the count and the line, and marks a task waiting for the user")
  func preview() {
    let waiting = ChatTasksPreviewState(
      finished: 3, total: 7, text: "Waiting for you: Pick a region", planName: "Launch")
    #expect(waiting.isWaiting)
    #expect(
      waiting.accessibilityLabel
        == "Tasks for Launch, 3 of 7 finished: Waiting for you: Pick a region")
    let running = ChatTasksPreviewState(
      finished: 0, total: 2, text: "Profiling the request", planName: nil)
    #expect(!running.isWaiting)
    #expect(running.accessibilityLabel == "Tasks, 0 of 2 finished: Profiling the request")
  }
}
