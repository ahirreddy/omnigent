#if os(macOS)
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  @Suite("CLI markdown blocks", .serialized)
  @MainActor
  struct TranscriptCLIMarkdownTests {
    private static let source = """
      ```swift
      let answer = 42
      ```

      ```
      plain block
      ```

      ---

      <div>raw html</div>

      ![a chart](./chart.png)

      ![](./untitled.png)

      $$x^2$$

      The end
      """

    @Test("Code, rules, raw HTML, images and math all draw as terminal text")
    func settledBlocks() throws {
      let screen = transcriptScreen(CLIStyledMarkdown(text: Self.source), height: 700)
      defer { screen.close() }
      for text in [
        "let answer", "plain block", "raw html", "[Image: a chart]",
        "[Image: ./untitled.png]", "x\u{00B2}", "The end",
      ] {
        #expect(try screen.shows(text), "\(text)")
      }
    }

    @Test("While streaming, the cursor follows the last block whatever kind it is")
    func streamingBlocks() throws {
      let tails = [
        "```swift\nlet answer = 42\n```", "<div>raw html</div>", "![a chart](./c.png)",
        "$$x^2$$",
      ]
      let expected = ["let answer", "raw html", "[Image: a chart]", "x\u{00B2}"]
      for (tail, text) in zip(tails, expected) {
        let screen = transcriptScreen(CLIStyledMarkdown(text: tail, isStreaming: true))
        defer { screen.close() }
        #expect(try screen.shows(text), "\(text)")
      }
    }
  }
#endif
