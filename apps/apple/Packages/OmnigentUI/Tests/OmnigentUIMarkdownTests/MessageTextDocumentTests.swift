#if os(macOS)
  import AppKit
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents
  @testable import OmnigentUITestSupport

  @MainActor
  @Suite("A message's text as one TextKit document")
  struct MessageTextDocumentTests {
    @Test("Headings, emphasis, inline code and links keep their words and styles")
    func inlineStyles() throws {
      let document = MessageTextFixture.document(
        "# Title\n\nSome **bold**, *slanted*, `code` and [a link](https://example.com/a).")
      let text = document.text
      #expect(text.string == "Title\nSome bold, slanted, code and a link.")
      let ramp = MessageTextFixture.ramp
      let heading = try #require(MessageTextFixture.font(at: 0, in: text))
      #expect(heading.pointSize == ramp.heading(1))
      #expect(abs(MessageTextFixture.weight(of: heading) - NSFont.Weight.semibold.rawValue) < 0.01)
      let headingStyle = try #require(MessageTextFixture.paragraph(at: 0, in: text))
      #expect(
        headingStyle.minimumLineHeight + headingStyle.lineSpacing == ramp.headingLineHeight(1))
      let body = MessageTextFixture.offset(of: "Some", in: text)
      let bodyStyle = try #require(MessageTextFixture.paragraph(at: body, in: text))
      // The gap, with the heading's extra line height traded for the body's (see `emit`).
      #expect(
        bodyStyle.paragraphSpacingBefore
          == TypeRamp.headingBelow + headingStyle.lineSpacing - bodyStyle.lineSpacing)
      #expect(bodyStyle.maximumLineHeight + bodyStyle.lineSpacing == ramp.bodyLineHeight)
      #expect(bodyStyle.lineSpacing > 0, "a body line's extra height is under its glyphs")
      let bold = try #require(MessageTextFixture.font(at: "bold", in: text))
      #expect(abs(MessageTextFixture.weight(of: bold) - NSFont.Weight.bold.rawValue) < 0.01)
      let slanted = try #require(MessageTextFixture.font(at: "slanted", in: text))
      #expect(slanted.fontDescriptor.symbolicTraits.contains(.italic))
      let code = try #require(MessageTextFixture.font(at: "code", in: text))
      #expect(code.fontDescriptor.symbolicTraits.contains(.monoSpace))
      #expect(code.pointSize == ramp.code)
      let fill = MessageTextFixture.value(.backgroundColor, at: "code", in: text, as: NSColor.self)
      #expect(fill != nil)
      let link = MessageTextFixture.value(.link, at: "a link", in: text, as: URL.self)
      #expect(link == URL(string: "https://example.com/a"))
      #expect(document.links.map(\.url) == [URL(string: "https://example.com/a")])
      #expect(document.links.first?.range.length == 6)
    }

    @Test("List items hang their text past a marker; nested items and quotes indent further")
    func listsAndQuotes() throws {
      let document = MessageTextFixture.document(
        "- one\n- two\n  - nested\n\n3. three\n4. four\n\n> quoted")
      let text = document.text
      #expect(text.string == "\t•\tone\n\t•\ttwo\n\t•\tnested\n\t3.\tthree\n\t4.\tfour\nquoted")
      let two = try #require(
        MessageTextFixture.paragraph(at: MessageTextFixture.offset(of: "two", in: text), in: text))
      #expect(two.paragraphSpacingBefore == TypeRamp.listSpacing)
      #expect(two.headIndent == 12 + Theme.Spacing.small)
      let nested = try #require(
        MessageTextFixture.paragraph(
          at: MessageTextFixture.offset(of: "nested", in: text), in: text))
      #expect(nested.headIndent == 2 * (12 + Theme.Spacing.small))
      #expect(nested.firstLineHeadIndent == 12 + Theme.Spacing.small)
      let three = try #require(
        MessageTextFixture.paragraph(
          at: MessageTextFixture.offset(of: "three", in: text), in: text))
      #expect(three.headIndent == 22 + Theme.Spacing.small, "an ordered marker's wider column")
      let quoted = MessageTextFixture.offset(of: "quoted", in: text)
      let quotes = MessageTextFixture.value(
        .messageQuotes, at: quoted, in: text, as: MessageQuoteMarks.self)
      #expect(quotes?.bars.count == 1)
      let quoteStyle = try #require(MessageTextFixture.paragraph(at: quoted, in: text))
      #expect(quoteStyle.headIndent == MessageTextBuilder.quoteBarWidth + Theme.Spacing.medium)
      let color = MessageTextFixture.value(.foregroundColor, at: quoted, in: text, as: NSColor.self)
      #expect(color == document.palette.secondary)
    }

    @Test("A code block is a header line and a paragraph per code line, colored, with Copy")
    func codeBlock() throws {
      let code = "let a = 1\n\nlet b = 2"
      let document = MessageTextFixture.document("Before\n\n```swift\n\(code)\n```")
      let text = document.text
      #expect(text.string == "Before\n \nlet a = 1\n\nlet b = 2")
      #expect(document.hasWideBlocks)
      guard case .code(let copied, let language)? = document.chrome.values.first else {
        Issue.record("no code block control")
        return
      }
      #expect(copied == code)
      #expect(language == "swift")
      let header = MessageTextFixture.offset(of: " ", in: text, after: "Before")
      let headerMark = MessageTextFixture.value(
        .messageBlock, at: header, in: text, as: MessageBlockMark.self)
      guard case .codeHeader? = headerMark?.role else {
        Issue.record("the header line is not marked: \(String(describing: headerMark?.role))")
        return
      }
      let before = try #require(MessageTextFixture.paragraph(at: 0, in: text))
      let headerStyle = try #require(MessageTextFixture.paragraph(at: header, in: text))
      #expect(headerStyle.lineSpacing == 0, "the header line is all line height")
      #expect(headerStyle.minimumLineHeight == MessageTextBuilder.codeHeaderHeight + 1)
      #expect(
        headerStyle.paragraphSpacingBefore == TypeRamp.paragraphSpacing + before.lineSpacing)
      let first = MessageTextFixture.offset(of: "let a", in: text)
      let firstStyle = try #require(MessageTextFixture.paragraph(at: first, in: text))
      #expect(
        firstStyle.paragraphSpacingBefore
          == MessageTextBuilder.codePadding - firstStyle.lineSpacing)
      #expect(firstStyle.headIndent == MessageTextBuilder.codePadding)
      #expect(firstStyle.tailIndent == -MessageTextBuilder.codePadding)
      let last = MessageTextFixture.offset(of: "let b", in: text)
      let lastStyle = try #require(MessageTextFixture.paragraph(at: last, in: text))
      #expect(lastStyle.paragraphSpacing == MessageTextBuilder.codePadding)
      let keyword = MessageTextFixture.value(
        .foregroundColor, at: first, in: text, as: NSColor.self)
      let plain = MessageTextFixture.value(
        .foregroundColor, at: first + 4, in: text, as: NSColor.self)
      #expect(keyword != nil && keyword != plain, "the keyword is colored")
      let font = try #require(MessageTextFixture.font(at: first, in: text))
      #expect(font.fontDescriptor.symbolicTraits.contains(.monoSpace))
    }

    @Test("A table that fits is a row per line, cells on tab stops; a wide one stays a grid")
    func tables() throws {
      let markdown = "| Step | Owner | Latency |\n| --- | :---: | ---: |\n| 1 | team-a | 40 |"
      let document = MessageTextFixture.document(markdown)
      let text = document.text
      #expect(text.string == "Step\tOwner\tLatency\n1\tteam-a\t40")
      let header = try #require(MessageTextFixture.font(at: 0, in: text))
      #expect(abs(MessageTextFixture.weight(of: header) - NSFont.Weight.semibold.rawValue) < 0.01)
      let row = try #require(
        MessageTextFixture.paragraph(
          at: MessageTextFixture.offset(of: "team-a", in: text), in: text))
      #expect(row.tabStops.map(\.alignment) == [.center, .right])
      #expect(row.lineBreakMode == .byClipping)
      let ramp = MessageTextFixture.ramp
      let blocks = MarkdownParser.parse(markdown)
      #expect(MessageTextSplit(blocks, ramp: ramp).pieces.count == 1)
      let wide = "| Notes |\n| --- |\n| \(String(repeating: "wide words ", count: 60)) |"
      let pieces = MessageTextSplit(MarkdownParser.parse(wide), ramp: ramp).pieces
      guard pieces.count == 1, case .block(.table) = pieces[0].content else {
        Issue.record("a wide table should stay a grid: \(pieces.map(\.content))")
        return
      }
    }

    @Test("Display math and diagrams split a message into text runs and blocks between them")
    func split() {
      let markdown = """
        First paragraph.

        $$
        x^2
        $$

        Second paragraph.

        ```mermaid
        graph TD
          A --> B
        ```
        """
      let split = MessageTextSplit(MarkdownParser.parse(markdown), ramp: MessageTextFixture.ramp)
      let kinds = split.pieces.map { piece -> String in
        switch piece.content {
        case .text(let blocks): "text \(blocks.count)"
        case .block(.math): "math"
        case .block(.code(let language, _)): "code \(language ?? "")"
        case .block: "other"
        }
      }
      #expect(kinds == ["text 1", "math", "text 1", "code mermaid"])
      #expect(split.pieces.map(\.gapAbove) == [0, 16, 16, 16])
    }

    @Test("A rule is a line of its own; a last empty line keeps a space so it keeps its style")
    func ruleAndEnds() throws {
      let document = MessageTextFixture.document("Above\n\n---\n\nBelow")
      #expect(document.text.string == "Above\n \nBelow")
      let rule = MessageTextFixture.value(
        .messageBlock, at: 6, in: document.text, as: MessageBlockMark.self)
      guard case .rule? = rule?.role else {
        Issue.record("no rule mark")
        return
      }
      let trailing = MessageTextFixture.document("Above\n\n---")
      #expect(trailing.text.string == "Above\n ")
    }

    @Test("Equal text and style build one document, shared")
    func sharedDocuments() {
      let key = MessageTextDocumentKey(
        text: "Shared", piece: 0, style: MessageTextFixture.style, linked: [])
      var built = 0
      let cache = MessageTextDocuments(limit: 4)
      let first = cache.document(for: key) {
        built += 1
        return MessageTextFixture.document("Shared")
      }
      let second = cache.document(for: key) {
        built += 1
        return MessageTextFixture.document("Shared")
      }
      #expect(first === second)
      #expect(built == 1)
    }
  }
#endif
