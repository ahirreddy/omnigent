import Testing

@testable import OmnigentStores

/// The `@` menu's rows: the browsed folder's entries (folders first, filtered by name), then
/// deeper matches, without repeats; and new-session paths relative to the chosen folder.
@MainActor
struct MentionRowsTests {
  private let listing = [
    MentionEntry(path: "src/zeta.swift", isDirectory: false),
    MentionEntry(path: "src/model", isDirectory: true),
    MentionEntry(path: "src/main.swift", isDirectory: false),
  ]

  @Test func foldersComeFirstAndEndInASlash() {
    let rows = ComposerStore.mentionRows(query: "src/", listing: listing)
    #expect(rows == ["src/model/", "src/main.swift", "src/zeta.swift"])
  }

  @Test func theFilterMatchesNamesThenDeeperPathsUnderTheFolder() {
    let matches = [
      MentionEntry(path: "src/main.swift", isDirectory: false),
      MentionEntry(path: "src/model/main_view.swift", isDirectory: false),
      MentionEntry(path: "docs/main.md", isDirectory: false),
    ]
    let rows = ComposerStore.mentionRows(query: "src/ma", listing: listing, matches: matches)
    #expect(rows == ["src/main.swift", "src/model/main_view.swift"])
  }

  @Test func rowsStopAtTheLimit() {
    let many = (0..<80).map { MentionEntry(path: "f\($0)", isDirectory: false) }
    #expect(ComposerStore.mentionRows(query: "", listing: many).count == 50)
  }

  @Test func hostPathsBecomeRelativeToTheFolder() {
    let relative = LaunchCompletionsStore.relative
    #expect(relative("/work/repo/src/a.swift", "/work/repo") == "src/a.swift")
    #expect(relative("/elsewhere/b", "/work/repo") == "/elsewhere/b")
    #expect(relative("/etc/hosts", "/") == "etc/hosts")
  }
}
