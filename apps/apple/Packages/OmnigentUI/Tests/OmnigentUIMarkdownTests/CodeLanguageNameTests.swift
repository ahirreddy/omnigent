import Testing

@testable import OmnigentUIComponents

@Suite("Code block headers name the language")
struct CodeLanguageNameTests {
  @Test(
    "fences read as the language's name",
    arguments: [
      ("py", "Python"), ("Python", "Python"), ("ts", "TypeScript"), ("c++", "C++"), ("yml", "YAML"),
      ("swift title=a.swift", "Swift"), ("  go  ", "Go"), ("Elixir", "Elixir"),
      ("elixir linenos", "elixir"), ("", "Code"), ("   ", "Code"),
    ])
  func names(language: String, label: String) {
    #expect(CodeLanguageName.label(for: language) == label)
  }

  @Test("a fence with no language reads Code")
  func noLanguage() {
    #expect(CodeLanguageName.label(for: nil) == "Code")
  }

  @Test("a download named by a fence with more in it takes the language's extension")
  func downloadExtension() {
    #expect(CodeFileExtension.for("swift title=a.swift") == "swift")
    #expect(CodeFileExtension.for("Python") == "py")
    #expect(CodeFileExtension.for(nil) == "txt")
  }
}
