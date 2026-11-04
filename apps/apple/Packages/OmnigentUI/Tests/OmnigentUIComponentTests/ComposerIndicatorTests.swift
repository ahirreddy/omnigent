import Testing

@testable import OmnigentUIComponents

@Suite("Composer task indicators")
struct ComposerIndicatorTests {
  private func child(_ id: String, _ status: SubagentStatus) -> SubagentChild {
    SubagentChild(id: id, sectionID: "child-\(id)", title: id, status: status)
  }

  @Test("the sub-agent summary counts each status, most urgent first")
  func subagentSummary() {
    let indicators = ComposerTaskIndicators(
      subagents: [child("a", .running), child("b", .needsYou), child("c", .running)])
    #expect(indicators.subagentSummary == "3 sub-agents: 1 needs you, 2 running")
    #expect(!indicators.isEmpty)
    #expect(ComposerTaskIndicators().isEmpty)
    #expect(ComposerTaskIndicators(backgroundTasks: 1).subagentSummary == "0 sub-agents")
  }

  @Test("goal usage reads tokens against the budget, then minutes")
  func goalUsage() {
    #expect(ComposerGoal.usage(tokensUsed: 900, tokenBudget: nil, seconds: 30) == "900 tokens")
    #expect(
      ComposerGoal.usage(tokensUsed: 1_200, tokenBudget: 40_000, seconds: 125)
        == "1,200 / 40,000 tokens \u{00B7} 2 min")
  }
}
