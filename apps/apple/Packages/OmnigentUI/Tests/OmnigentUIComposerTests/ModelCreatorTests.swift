import Testing

@testable import OmnigentUIComponents

/// Who made a model, as the web's `modelCreators` reads it, and the model menu's groups.
@Suite("Composer: model creators")
struct ModelCreatorTests {
  private func creator(_ id: String, model: String? = nil, name: String? = nil) -> String {
    ModelCreator.of(id: id, model: model, displayName: name).id
  }

  @Test func theCreatorComesFromTheNamespaceThePrefixOrTheName() {
    #expect(creator("claude-opus-4") == "anthropic")
    #expect(creator("us.anthropic.claude-sonnet") == "anthropic", "a Bedrock prefix")
    #expect(creator("databricks-kimi-k2") == "moonshotai", "a serving prefix is dropped")
    #expect(creator("openrouter/meta-llama/llama-3") == "meta", "an organization under a host")
    #expect(creator("mistral/zai-glm-5") == "zai", "a lone namespace is the server")
    #expect(creator("accounts/fireworks/models/deepseek-v3") == "deepseek")
    #expect(creator("nvidia/llama-nemotron") == "nvidia")
    #expect(creator("o3-mini") == "openai")
    #expect(creator("house-model", name: "Gemini 2.5") == "google", "the display name")
    #expect(creator("house-model") == "other")
  }

  @Test func aLongCatalogFromSeveralCreatorsGroupsInTheirOrder() {
    func model(_ id: String) -> ModelOption {
      ModelOption(
        id: id, model: nil, displayName: nil, defaultReasoningEffort: nil,
        supportedReasoningEfforts: [], isDefault: false, hidden: false)
    }
    let short = (1...3).map { model("gpt-\($0)") }
    #expect(ModelCreator.groups(short).count == 1)
    let long =
      ["house-a", "gpt-5", "claude-opus-4", "gemini-2", "claude-haiku"]
      + (1...6).map { "gpt-4.\($0)" }
    let groups = ModelCreator.groups(long.map(model))
    #expect(groups.map(\.creator.id) == ["anthropic", "openai", "google", "other"])
    #expect(groups.first?.models.map(\.id) == ["claude-opus-4", "claude-haiku"])
    let oneMaker = (1...12).map { model("gpt-\($0)") }
    #expect(ModelCreator.groups(oneMaker).count == 1)
  }
}
