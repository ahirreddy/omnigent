import Testing

@testable import OmnigentWorkspaceUI

/// The Markdown preview's table of contents, cut at the file's headings.
@Suite("Markdown preview: table of contents")
struct MarkdownOutlineTests {
  private let file = """
    Intro with a [ref][docs] link.

    # Setup ##
    Install it.

    ```sh
    # not a heading
    ```

    ## Use **the** `cli`
    ####### seven marks is text
    #hashtag
        # indented code
    ### [Links](https://example.com)

    [docs]: https://example.com/docs
    """

  @Test func headingsOutsideCodeAreSectionsReadAsText() {
    let outline = MarkdownOutline(file)
    #expect(outline.headings.map(\.title) == ["Setup", "Use the cli", "Links"])
    #expect(outline.headings.map(\.level) == [1, 2, 3])
    #expect(outline.sections.first?.title == nil, "the text before the first heading")
    #expect(outline.sections.map(\.id) == [0, 1, 2, 3])
    let setup = outline.sections[1].text
    #expect(setup.hasPrefix("# Setup ##"))
    #expect(setup.contains("# not a heading"), "code stays in its section")
    #expect(setup.hasSuffix("[docs]: https://example.com/docs"), "references go everywhere")
  }

  @Test func aFileWithoutHeadingsIsOneSection() {
    let outline = MarkdownOutline("Just text.")
    #expect(outline.headings.isEmpty)
    #expect(outline.sections.map(\.text) == ["Just text."])
  }
}
