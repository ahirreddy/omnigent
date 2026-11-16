import Foundation
import Testing

@testable import OmnigentUIComponents

@Suite("Markdown table and code exports")
struct MarkdownBlockControlsTests {
  private let table = MarkdownTable(
    header: ["Name", "Note"],
    rows: [["a|b", "says \"hi\", twice"], ["tab\there", "two\nlines"], ["short"]],
    alignments: [.leading, .trailing])

  @Test("tables copy as Markdown with escaped pipes and their alignment")
  func markdown() {
    #expect(
      MarkdownTableText.markdown(table) == """
        | Name | Note |
        | --- | ---: |
        | a\\|b | says "hi", twice |
        | tab\there | two lines |
        | short |  |

        """)
  }

  @Test("CSV quotes cells with commas, quotes and line breaks; TSV flattens them")
  func delimited() {
    #expect(
      MarkdownTableText.csv(table) == """
        Name,Note
        a|b,"says ""hi"", twice"
        tab\there,"two
        lines"
        short,

        """)
    #expect(
      MarkdownTableText.tsv(table)
        == "Name\tNote\na|b\tsays \"hi\", twice\ntab here\ttwo lines\nshort\t\n")
  }

  @Test("code downloads take the language's extension")
  func extensions() {
    #expect(CodeFileExtension.for("Python") == "py")
    #expect(CodeFileExtension.for("c++") == "cpp")
    #expect(CodeFileExtension.for("elixir") == "elixir")
    #expect(CodeFileExtension.for(nil) == "txt")
    #expect(CodeFileExtension.for("some lang!") == "txt")
  }
}
