import Testing

@testable import OmnigentUIComponents

/// The `/` menu's sections and inline skills, the `@` folder browser, and Smart Routing's labels.
struct ComposerCompletionsTests {
  private let commands = [
    SlashCommand(name: "compact"), SlashCommand(name: "context"),
    SlashCommand(name: "triage", isSkill: true), SlashCommand(name: "commit", isSkill: true),
  ]

  @Test func commandsAndSkillsHaveHeadersAndAreNotCapped() {
    let many = (0..<12).map { SlashCommand(name: "skill\($0)", isSkill: true) }
    let completions = ComposerCompletions(draft: "/", commands: commands + many, mentions: [])
    #expect(completions.items.count == 16, "every match, not the first eight")
    #expect(completions.items.first?.section == "Commands")
    #expect(completions.items[2].section == "Skills")
    #expect(completions.items[2].title == "/triage")
    #expect(completions.items.filter { $0.section != nil }.count == 2)
  }

  @Test func onlySkillsCompleteAfterOtherText() {
    let completions = ComposerCompletions(
      draft: "please run /co", commands: commands, mentions: [])
    #expect(completions.items.map(\.title) == ["/commit"], "built-ins need the start")
    #expect(completions.applying(completions.items[0]) == "please run /commit ")
    #expect(
      ComposerCompletions(draft: "a /usr/bin", commands: commands, mentions: []).items
        .isEmpty)
    #expect(ComposerCompletions(draft: "/co ", commands: commands, mentions: []).items.isEmpty)
    #expect(ComposerCompletions(draft: "/co", commands: commands, mentions: []).items.count == 3)
  }

  @Test func mentionsBrowseFoldersAndOpenThemOnReturn() {
    let mentions = ["src/", "docs/", "README.md", "src/main.swift"]
    let root = ComposerCompletions(draft: "see @", commands: [], mentions: mentions)
    #expect(root.mentionFolder?.isEmpty == true)
    #expect(root.items.map(\.title) == ["src/", "docs/", "README.md", "src/main.swift"])
    let folder = root.items[0]
    #expect(folder.isFolder)
    #expect(root.applying(folder) == "see @src/", "Return opens the folder")
    #expect(root.removingToken() == "see ")
    let inside = ComposerCompletions(draft: "@src/", commands: [], mentions: mentions)
    #expect(inside.mentionFolder == "src")
    #expect(inside.items.map(\.title) == ["src/main.swift"])
    let filtered = ComposerCompletions(draft: "@src/ma", commands: [], mentions: mentions)
    #expect(filtered.items.map(\.title) == ["src/main.swift"])
    #expect(!filtered.items[0].isFolder)
    #expect(filtered.applying(filtered.items[0]) == "@src/main.swift ")
  }

  @Test func mentionRowsStopAtTheWebsLimit() {
    let mentions = (0..<80).map { "file\($0).txt" }
    let completions = ComposerCompletions(draft: "@", commands: [], mentions: mentions)
    #expect(completions.items.count == ComposerCompletions.mentionLimit)
  }

  @Test func smartRoutingNamesTheChipAndClearsTheChecks() {
    var configuration = ComposerConfiguration(
      modelOptions: [ModelOption(id: "fast", supportedReasoningEfforts: ["low", "high"])],
      selectedModelId: "fast", selectedEffort: "high")
    #expect(configuration.modelTitle == "fast")
    #expect(configuration.pickedModelId == "fast")
    configuration.smartRouting = .enabled
    #expect(configuration.modelTitle == "Smart Routing")
    #expect(configuration.effortTitle == nil)
    #expect(configuration.pickedModelId != "fast")
    #expect(configuration.pickedEffort != "high")
    #expect(!configuration.isModelInherited)
  }
}
