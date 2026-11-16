import Foundation
import SwiftUI
import Testing

@testable import OmnigentUIComponents

@Suite("CLI style: an edit's files and numbered lines")
struct CLIDiffFileTests {
  // MARK: Diffs

  private func rows(_ file: CLIDiffFile) -> [String] {
    file.rows.map { row in
      "\(row.number.map(String.init) ?? "_")\(CLIDiffRows.sign(row.kind))\(row.text)"
    }
  }

  @Test("a unified diff's lines are numbered from its hunks, with a gap between two")
  func unifiedDiff() throws {
    let text = """
      diff --git a/a.txt b/a.txt
      --- a/a.txt
      +++ b/a.txt
      @@ -3,3 +3,3 @@
       keep
      -old
      +new
      \\ No newline at end of file
      @@ -20 +20,2 @@
       far
      +added
      """
    let diff = try #require(DiffSummary.parse(text))
    let file = try #require(CLIDiffFile.files(in: diff).first)
    #expect(file.path == "a.txt")
    #expect(file.verb == "Edited")
    #expect(file.added == 2)
    #expect(file.removed == 1)
    #expect(rows(file) == ["3 keep", "4-old", "4+new", "_ \u{22EE}", "20 far", "21+added"])
  }

  @Test("a patch names added and deleted files, and what follows its end is not a file's")
  func patch() throws {
    let text = """
      apply_patch <<'EOF'
      *** Begin Patch
      *** Add File: new.txt
      +one
      +two
      *** Delete File: old.txt
      *** Update File: kept.txt
      @@
       same
      +more

      *** End Patch
      EOF
      """
    let files = CLIDiffFile.files(in: try #require(DiffSummary.parse(text)))
    #expect(files.map(\.path) == ["new.txt", "old.txt", "kept.txt"])
    #expect(files.map(\.verb) == ["Added", "Deleted", "Edited"])
    #expect(rows(files[0]) == ["1+one", "2+two"])
    #expect(files[1].rows.isEmpty)
    #expect(rows(files[2]) == ["_ same", "_+more"])
  }

  @Test("an edit with no file header is one unnamed file, and a written file counts from one")
  func otherDiffs() throws {
    let pair = try #require(DiffSummary.parse("@@ edit @@\n-a\n+b"))
    let unnamed = CLIDiffFile.files(in: pair)
    #expect(unnamed.map(\.path) == [""])
    #expect(rows(unnamed[0]) == ["_-a", "_+b"])

    let created = DiffSummary(
      files: ["n.txt"], added: 2, removed: 0,
      lines: [
        .init(kind: .header, text: "+++ b/n.txt"), .init(kind: .added, text: "+x"),
        .init(kind: .added, text: "+y"),
      ])
    let new = try #require(CLIDiffFile.files(in: created).first)
    #expect(new.verb == "Added")
    #expect(rows(new) == ["1+x", "2+y"])

    // A write over an existing file lists its content as it is: no column to drop.
    let written = DiffSummary(
      files: ["w.txt"], added: 0, removed: 0,
      lines: [.init(kind: .header, text: "+++ b/w.txt"), .init(kind: .context, text: " kept")])
    #expect(rows(try #require(CLIDiffFile.files(in: written).first)) == ["_  kept"])
  }

  @Test("an edit's shown lines share one budget across its files")
  func diffBudget() {
    let row = CLIDiffFile.Row(kind: .added, number: nil, text: "x")
    let files = [
      CLIDiffFile(path: "a", change: .edited, rows: [row, row, row]),
      CLIDiffFile(path: "b", change: .edited, rows: [row, row]),
    ]
    #expect(CLIDiffFiles.rows(of: files, limit: 4).map(\.count) == [3, 1])
    #expect(CLIDiffRows.sign(.context) == " ")
    #expect(CLIDiffRows.sign(nil) == " ")
  }
}
