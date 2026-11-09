import OmnigentCoreFFI
import OmnigentUIComponents
import Testing

@testable import OmnigentAppUI
@testable import OmnigentStores

/// The inspector and the composer name the session's approval mode the same way.
@MainActor
@Suite("Approval mode title")
struct ApprovalModeTitleTests {
  @Test("the inspector's title is the chip's name for the mode")
  func titleMatchesTheChip() async throws {
    let store = try await ConversationFixtures.store()
    #expect(ConversationAdapter.approvalModeTitle(store) == nil)
    var configuration = ConversationFixtures.configuration(
      harness: "codex-native", wrapper: "codex-native-ui")
    configuration.approvalMode = "approve-for-me"
    store.composer.configuration = configuration
    #expect(ConversationAdapter.approvalModeTitle(store) == "Auto-approve")
    #expect(
      ConversationAdapter.screenState(store, summary: nil).approvalModeTitle == "Auto-approve")
    #expect(ConversationAdapter.state(store, summary: nil).approvalModeTitle == "Auto-approve")
  }
}
