import Foundation
import Testing

@testable import OmnigentUIComponents

/// User bubbles read like the web's: @-mention markers become chips and long prompts collapse.
@Suite("User prompt")
struct UserPromptTests {
  @Test("attachment markers become mentions and leave the text; uploads get no chip")
  func mentions() {
    let text = """
      Fix this
      [Attached: src/main.rs:3-9]
      [Attached file: docs/]
      [Attached: /tmp/upload.png]

      """
    let prompt = UserPrompt.parse(text)
    #expect(prompt.text == "Fix this")
    #expect(
      prompt.mentions == [
        UserPrompt.Mention(path: "src/main.rs:3-9", isFolder: false),
        UserPrompt.Mention(path: "docs", isFolder: true),
      ])
    #expect(UserPrompt.parse("No markers [here]").text == "No markers [here]")
  }

  @Test("a prompt over 12,000 characters starts collapsed")
  func collapse() {
    #expect(UserPrompt.collapsed(String(repeating: "a", count: 12_000)) == nil)
    let long = String(repeating: "b", count: 12_001)
    #expect(UserPrompt.collapsed(long)?.count == 12_000)
    // The web's wording, with the whole prompt's length.
    #expect(
      UserPrompt.expandTitle(long) == "Show full prompt (\(12_001.formatted()) chars)")
  }

  @Test("a reply's quote blocks split from the text around them; fenced code never quotes")
  func quoteRuns() {
    let text = "Before\n\n> first line\n>\n> second\n\nReply\n```\n> not a quote\n```"
    #expect(
      UserPrompt.runs(text) == [
        UserPrompt.Run(text: "Before", isQuote: false),
        UserPrompt.Run(text: "first line\n\nsecond", isQuote: true),
        UserPrompt.Run(text: "Reply\n```\n> not a quote\n```", isQuote: false),
      ])
    #expect(UserPrompt.runs("a -> b") == [UserPrompt.Run(text: "a -> b", isQuote: false)])
  }

  @Test("a reply to an agent's questions draws from its replies: each quoted question, its answer")
  func questionReplies() throws {
    let replies = [
      QuestionReply(question: "Color?", answer: "Blue"), QuestionReply(answer: "**Large**"),
    ]
    let source = try #require(QuestionReplyMarkdown.text(replies))
    #expect(QuestionReplyMarkdown.replies(in: source) == replies)
    #expect(QuestionReplyMarkdown.text([]) == nil)
    let shown = "\u{21AA} Re: Color?\nBlue\n\n**Large**"
    #expect(QuestionReplyMarkdown.replies(in: shown).isEmpty, "the text the core shows is a prompt")
    // The question is one small quoted line; the answers are markdown, a small gap under it.
    let blocks = MarkdownParser.parse(source)
    try #require(blocks.count == 3)
    guard case .paragraph(let quote) = blocks[0] else {
      Issue.record("\(blocks) starts with the quoted question")
      return
    }
    #expect(quote.isQuestionReplyQuote)
    #expect(String(quote.characters) == "\u{21AA} Re: Color?")
    let answers = MarkdownParser.parse("Blue") + MarkdownParser.parse("**Large**")
    #expect(Array(blocks.dropFirst()) == answers)
    #expect(TypeRamp.spacing(above: blocks[1], after: blocks[0]) == TypeRamp.questionQuoteBelow)
    #expect(TypeRamp.spacing(above: blocks[2], after: blocks[1]) == TypeRamp.paragraphSpacing)
    let marksQuote = MarkdownParser.parse(shown).contains { block in
      guard case .paragraph(let text) = block else { return false }
      return text.isQuestionReplyQuote
    }
    #expect(!marksQuote, "typed text never draws as a quoted question")
  }

  @Test("Share counts one button width in the titlebar beside the session menu")
  func titlebarShare() {
    // The right-panel toggle and the group's margins, then each button.
    var state = ConversationViewState(header: SessionHeader(id: "s", title: "T"))
    #expect(
      TitlebarTrailingItems.count(state, hasShare: true, tabsInTitlebar: true, isRegular: true)
        == 4)
    state.sections = [EventSection(id: "presence", title: "Viewers", summary: "")]
    #expect(
      TitlebarTrailingItems.count(state, hasShare: true, tabsInTitlebar: true, isRegular: true)
        == 4, "the toolbar shows no viewers")
    state.agentInfo = AgentInfo(name: "Helper", tools: ["docs"])
    #expect(
      TitlebarTrailingItems.count(state, hasShare: true, tabsInTitlebar: true, isRegular: true)
        == 5, "Agent info")
    state.agentInfo = nil
    #expect(
      TitlebarTrailingItems.count(state, hasShare: false, tabsInTitlebar: true, isRegular: true)
        == 3)
    #expect(
      TitlebarTrailingItems.count(state, hasShare: true, tabsInTitlebar: false, isRegular: false)
        == 2)
  }
}
