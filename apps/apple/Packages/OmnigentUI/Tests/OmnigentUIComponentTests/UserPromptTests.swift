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

  @Test("Share counts two button widths in the titlebar beside the session menu")
  func titlebarShare() {
    let state = ConversationViewState(header: SessionHeader(id: "s", title: "T"))
    #expect(
      TitlebarTrailingItems.count(state, hasShare: true, tabsInTitlebar: true, isRegular: true)
        == 4)
    #expect(
      TitlebarTrailingItems.count(state, hasShare: false, tabsInTitlebar: true, isRegular: true)
        == 2)
    #expect(
      TitlebarTrailingItems.count(state, hasShare: true, tabsInTitlebar: false, isRegular: false)
        == 1)
  }
}
