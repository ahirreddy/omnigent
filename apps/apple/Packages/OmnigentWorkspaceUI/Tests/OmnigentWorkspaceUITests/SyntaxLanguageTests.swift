import Testing

@testable import OmnigentWorkspaceUI

/// Each language family's own keywords, comments and strings.
@Suite("Syntax languages")
struct SyntaxLanguageTests {
  private func tokens(_ line: String, _ language: SyntaxLanguage) -> [SyntaxToken] {
    SyntaxHighlighter(language: language).spans(in: line).map(\.token)
  }

  @Test("each language colors its own keywords and comments")
  func keywordsAndComments() {
    #expect(tokens("func main() // x", .go) == [.keyword, .comment])
    #expect(tokens("def greet # hi", .ruby) == [.keyword, .comment])
    #expect(tokens("export x # note", .bash) == [.keyword, .comment])
    #expect(tokens("FROM ubuntu # base", .dockerfile) == [.keyword, .comment])
    #expect(tokens("SELECT x -- note", .sql) == [.keyword, .comment])
    #expect(tokens("echo 1 # done", .php) == [.keyword, .number, .comment])
    #expect(tokens("echo 1 // done", .php) == [.keyword, .number, .comment])
    #expect(tokens("val x // note", .kotlin) == [.keyword, .comment])
    #expect(tokens("using x // note", .csharp) == [.keyword, .comment])
  }

  @Test("JSON and CSS know only their few words, and JSON's only string is double quoted")
  func fewWords() {
    #expect(tokens("true 'x'", .json) == [.keyword])
    #expect(tokens("color: red !important", .css) == [.keyword])
    #expect(tokens("<p class=\"a\">", .html) == [.string])
  }

  @Test("Markdown's code and quotes stand out from its text")
  func markdown() {
    #expect(tokens("```swift", .markdown) == [.string])
    #expect(tokens("    indented code", .markdown) == [.string])
    #expect(tokens("> a quote", .markdown) == [.comment])
  }
}
