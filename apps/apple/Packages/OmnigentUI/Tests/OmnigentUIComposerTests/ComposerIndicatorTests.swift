import Testing

@testable import OmnigentUIComponents

@Suite("Composer task indicators")
struct ComposerIndicatorTests {
  private func child(_ id: String, _ status: AgentTreeActivity) -> SubagentChild {
    SubagentChild(id: id, sectionID: "child-\(id)", title: id, status: status)
  }

  @Test("the sub-agent summary counts active, waiting, disconnected and failed, as the web does")
  func subagentSummary() {
    let indicators = ComposerTaskIndicators(
      subagents: [
        child("a", .working), child("b", .needsYou), child("c", .launching),
        child("d", .disconnected), child("e", .failed),
      ])
    #expect(
      indicators.subagentSummary
        == "5 sub-agents: 2 active, 1 awaiting input, 1 disconnected, 1 needs attention")
    let failures = ComposerTaskIndicators(subagents: [child("a", .failed), child("b", .failed)])
    #expect(failures.subagentSummary == "2 sub-agents: 2 need attention")
    #expect(
      ComposerTaskIndicators(subagents: [child("a", .working)]).subagentSummary
        == "1 sub-agent: 1 active")
    #expect(!indicators.isEmpty)
    #expect(ComposerTaskIndicators().isEmpty)
    #expect(ComposerTaskIndicators(backgroundTasks: 1).subagentSummary == "0 sub-agents")
  }

  @Test("a failure tints the sub-agent count before a request does; otherwise it stays plain")
  func subagentAlert() {
    let both = ComposerTaskIndicators(subagents: [child("a", .needsYou), child("b", .failed)])
    #expect(both.subagentAlert == .failed)
    #expect(ComposerTaskIndicators(subagents: [child("a", .needsYou)]).subagentAlert == .needsYou)
    #expect(ComposerTaskIndicators(subagents: [child("a", .working)]).subagentAlert == nil)
  }

  @Test("goal usage reads tokens against the budget, then minutes")
  func goalUsage() {
    #expect(ComposerGoal.usage(tokensUsed: 900, tokenBudget: nil, seconds: 30) == "900 tokens")
    #expect(
      ComposerGoal.usage(tokensUsed: 1_200, tokenBudget: 40_000, seconds: 125)
        == "1,200 / 40,000 tokens \u{00B7} 2 min")
  }
}
