import Testing

@testable import OmnigentUIComponents

@Suite("Error rows")
struct ErrorRowTests {
  @Test("only failures a new session gets past offer a fork, labelled as the web labels them")
  func forkLabels() {
    let label = ErrorRowView.forkLabel(code:)
    #expect(label("workspace_missing") == "Continue in Another Directory\u{2026}")
    #expect(label("session_agent_missing") == "Fork Session\u{2026}")
    #expect(label("codex_compaction_model_failed") == "Fork Session\u{2026}")
    #expect(label("rate_limit_exceeded") == nil)
    #expect(label(nil) == nil)
  }
}
