import Testing

@testable import OmnigentUIComponents

/// A `sys_advise_models` call read as the web's Smart Routing card reads it.
@Suite("Transcript: smart routing plan")
struct SmartRoutingPlanTests {
  private let arguments = #"""
    {"tasks":[{"title":"Fix login","agents":[{"agent":"codex"},{"agent":"claude"}]},
              {"title":"Write docs","agents":[]},{"title":""}]}
    """#

  @Test func plannedTasksGetTheirSizedModels() {
    let output = #"""
      {"recommendations":[{"title":"Fix login","model":"databricks-claude-opus-4",
                            "rationale":"Hard bug","agent":"claude"}]}
      """#
    let plan = SmartRoutingPlan.read(arguments: arguments, output: output)
    #expect(plan.isSized && plan.sizedCount == 1)
    #expect(plan.tasks.map(\.title) == ["Fix login", "Write docs"])
    #expect(plan.tasks.first?.agent == "claude", "the recommendation names the worker")
    #expect(plan.tasks.first?.model == "databricks-claude-opus-4")
    #expect(plan.tasks.last?.model == nil)
    #expect(plan.tasks.last?.agent.isEmpty == true)
  }

  @Test func aWrappedAnswerAndAnErrorReadAsTheWebReadsThem() {
    let wrapped = #"""
      [{"type":"text",
        "text":"{\"recommendations\":[{\"title\":\"Write docs\",\"model\":\"haiku-4\"}]}"}]
      """#
    let plan = SmartRoutingPlan.read(arguments: nil, output: wrapped)
    #expect(plan.tasks.map(\.title) == ["Write docs"])
    let failed = SmartRoutingPlan.read(arguments: arguments, output: "Error: router off")
    #expect(!failed.isSized)
    #expect(failed.tasks.first?.agent == "codex, claude", "planned workers show while unsized")
  }

  @Test func modelsShortenToTheirFamily() {
    #expect(SmartRoutingPlan.shortModelName("databricks-claude-sonnet-4") == "sonnet")
    #expect(SmartRoutingPlan.shortModelName("databricks-gpt-5") == "gpt-5")
    #expect(SmartRoutingPlan.shortModelName("gpt-5") == "gpt-5")
  }
}
