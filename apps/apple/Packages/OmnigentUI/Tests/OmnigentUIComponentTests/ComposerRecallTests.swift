import Testing

@testable import OmnigentUIComponents

/// Up and Down through earlier prompts, and the completion rows the keys pick.
struct ComposerRecallTests {
  @Test func upWalksBackAndDownReturnsToTheOriginalText() {
    var recall = PromptRecall()
    let prompts = ["first", "second", "third"]
    #expect(recall.older(draft: "", prompts: prompts) == "third")
    #expect(recall.older(draft: "third", prompts: prompts) == "second")
    #expect(recall.older(draft: "second", prompts: prompts) == "first")
    #expect(recall.older(draft: "first", prompts: prompts) == nil, "nothing older")
    #expect(recall.newer(draft: "first", prompts: prompts) == "second")
    #expect(recall.newer(draft: "second", prompts: prompts) == "third")
    #expect(recall.newer(draft: "third", prompts: prompts)?.isEmpty == true, "back to the field")
    #expect(recall.newer(draft: "", prompts: prompts) == nil)
  }

  @Test func typingEndsBrowsingAndTextIsNeverReplaced() {
    var recall = PromptRecall()
    let prompts = ["first", "second"]
    #expect(recall.older(draft: "draft", prompts: prompts) == nil, "only from an empty field")
    #expect(recall.older(draft: "", prompts: prompts) == "second")
    #expect(recall.isBrowsing("second"))
    #expect(!recall.isBrowsing("second, edited"))
    #expect(recall.newer(draft: "second, edited", prompts: prompts) == nil)
    #expect(recall.older(draft: "second, edited", prompts: prompts) == nil)
    #expect(recall.older(draft: "", prompts: []) == nil)
  }

  @Test func modelAndEffortCycleThroughThePickerAndWrap() {
    let efforts = ["low", "medium", "high"]
    var configuration = ComposerConfiguration(
      modelOptions: [
        ModelOption(id: "a", defaultReasoningEffort: "medium", supportedReasoningEfforts: efforts),
        ModelOption(id: "hidden", hidden: true),
        ModelOption(id: "b", supportedReasoningEfforts: efforts, isDefault: true),
      ])
    #expect(configuration.nextModelID == "a", "from the default row")
    configuration.selectedModelId = "a"
    #expect(configuration.nextModelID == "b")
    #expect(configuration.nextEffort == "high", "from the model's default effort")
    configuration.selectedEffort = "high"
    #expect(configuration.nextEffort == "low")
    #expect(ComposerConfiguration(modelOptions: [ModelOption(id: "only")]).nextModelID == nil)
    #expect(ComposerConfiguration().nextEffort == nil)
  }

  @Test func highlightedRowsClampToTheList() {
    let commands = [
      SlashCommand(name: "help"), SlashCommand(name: "new"), SlashCommand(name: "context"),
    ]
    let completions = ComposerCompletions(draft: "/", commands: commands, mentions: [])
    #expect(completions.item(at: 1)?.title == "/new")
    #expect(completions.item(at: 9)?.title == "/context")
    #expect(completions.item(at: -1)?.title == "/help")
    #expect(ComposerCompletions(draft: "hi", commands: commands, mentions: []).item(at: 0) == nil)
    #expect(ComposerCompletions.isTypingMention("see @src/ma"))
    #expect(ComposerCompletions.isTypingMention("@"))
    #expect(!ComposerCompletions.isTypingMention("mail me@x"))
    #expect(!ComposerCompletions.isTypingMention("@src/main.swift and"))
  }
}
