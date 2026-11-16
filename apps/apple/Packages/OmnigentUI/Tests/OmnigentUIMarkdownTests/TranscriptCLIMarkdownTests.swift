#if os(macOS)
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents
  @testable import OmnigentUITestSupport

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

    @Test("Headings, lists, tasks, quotes and rules draw the way the Codex CLI draws them")
    func codexBlocks() throws {
      let source = """
        # Title

        #### Minor

        first line
        second line

        - item
          - nested
        - [x] done
        - [ ] open

        1. one
        2. [x] two, long enough to wrap onto another line of this narrow window, and then some

        > quoted
        > more
        >
        > again

        ---
        """
      let screen = transcriptScreen(CLIStyledMarkdown(text: source), width: 420, height: 700)
      defer { screen.close() }
      let shown = try screen.shownText()
      let expected = [
        "# Title", "#### Minor", "first line\nsecond line", "\u{2022}", "\u{2611}", "\u{2610}",
        "1. ", "2. \u{2611}", "quoted\nmore", "again", "\u{2014}\u{2014}\u{2014}",
      ]
      for text in expected { #expect(shown.contains(text), "\(text) in \(shown)") }
      // A quote has its marker before every line, not only its first.
      #expect(shown.contains { $0.hasPrefix(">\n>\n>\n>") })
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
