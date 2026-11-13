import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents
import Testing

@testable import OmnigentAppUI

/// The model a session's menu names when neither the user nor the server names one.
@MainActor
@Suite("Composer: the model in use")
struct ComposerModelInUseTests {
  private typealias Fixtures = ConversationFixtures

  @Test("With no model named, the menu shows the one the session has been running on")
  func modelInUse() async throws {
    let usage = OmnigentCoreFFI.EventSection(
      id: "usage", title: "", summary: "",
      details: [
        OmnigentCoreFFI.DetailSection(
          id: "model_in_use", title: "Model in use", text: "gpt-5.2-codex", isCode: false)
      ], sessionId: nil)
    let unnamed = try await Fixtures.store(
      header: Fixtures.header(settings: Fixtures.settings()), sections: [usage])
    let shown = ComposerAdapter.state(unnamed, isStopping: false, dismissedError: nil)
    #expect(shown.configuration?.baseModel == "gpt-5.2-codex")
    #expect(shown.configuration?.modelTitle == "gpt-5.2-codex")

    // Before its first turn a session has reported no usage, and the menu has nothing to name.
    let unused = try await Fixtures.store(header: Fixtures.header(settings: Fixtures.settings()))
    let empty = ComposerAdapter.state(unused, isStopping: false, dismissedError: nil)
    #expect(empty.configuration?.baseModel == nil)
    #expect(empty.configuration?.modelTitle == "Agent default")
  }
}
