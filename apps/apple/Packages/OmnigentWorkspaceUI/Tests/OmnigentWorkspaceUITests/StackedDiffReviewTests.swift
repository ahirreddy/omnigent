import Foundation
import Testing

@testable import OmnigentWorkspaceUI

/// The review tools' rules a stacked diff uses, as the web's Changes tab: find, the path filter,
/// expanding context, and viewed fingerprints.
@Suite("Stacked diff review rules")
@MainActor
struct StackedDiffReviewTests {
  /// Two hunks of `a.txt`, 17 lines apart.
  private let twoHunks = SampleDiffs.diff(
    path: "src/a.txt",
    hunks: [
      SampleDiffs.Hunk(
        old: 2, new: 2,
        lines: [.context("two"), .removed("three"), .added("THREE"), .context("four")]),
      SampleDiffs.Hunk(
        old: 20, new: 20,
        lines: [.context("twenty"), .removed("twentyone"), .added("TWENTYONE"), .context("22")]),
    ])

  @Test("Hunk headers give their ranges, counts of one left out")
  func hunkRanges() throws {
    let header = try #require(DiffHunk.ranges("@@ -2,3 +4 @@ fn x"))
    #expect([header.oldStart, header.oldCount, header.newStart, header.newCount] == [2, 3, 4, 1])
    let added = try #require(DiffHunk.ranges("@@ -0,0 +1,2 @@"))
    #expect([added.oldStart, added.oldCount, added.newStart, added.newCount] == [0, 0, 1, 2])
    #expect(DiffHunk.ranges("not a header") == nil)
    let insertion = DiffHunk(header: "@@ -3,0 +4,2 @@", lines: [])
    #expect((insertion.oldFirst, insertion.oldEnd, insertion.newFirst) == (4, 4, 4))
  }

  @Test("Gaps sit before each hunk and after the last, whose length waits for the text")
  func gaps() {
    let gaps = DiffContext.gaps(twoHunks, lineCount: nil)
    #expect(gaps.map(\.index) == [0, 1, 2])
    #expect(gaps.map(\.count) == [1, 15, nil])
    #expect((gaps[1].oldStart, gaps[1].newStart) == (5, 5))
    let known = DiffContext.gaps(twoHunks, lineCount: 30)
    #expect(known.last?.count == 8)
    #expect(DiffContext.gaps(twoHunks, lineCount: 22).count == 2, "a gap of no lines is left out")
    #expect(DiffContext.gaps(WorkspaceSamples.addedDiff, lineCount: 10).isEmpty)
  }

  @Test("Expanding shows ten lines from either end, then all, numbered on both sides")
  func expanding() throws {
    let lines = (1...30).map { "line \($0)" }
    var state = DiffContextState(lines: lines)
    let gap = try #require(DiffContext.gaps(twoHunks, lineCount: 30).first { $0.index == 1 })
    state = state.expanding(gap, .below)
    state = state.expanding(gap, .above)
    let reveal = try #require(state.reveals[1])
    #expect(reveal == DiffGapReveal(top: 10, bottom: 5), "the second step shows the rest")
    #expect(DiffContext.hidden(gap, reveal) == 0)
    let shown = DiffContext.revealed(gap, reveal, lines: lines)
    #expect(shown.top.first?.newNumber == 5 && shown.top.first?.text == "line 5")
    #expect(shown.top.first?.oldNumber == 5)
    #expect(shown.bottom.last?.newNumber == 19)
    let all = DiffContextState(lines: lines).expanding(gap, .all)
    #expect(all.reveals[1]?.top == 15)
    #expect(DiffContextState.lines(of: "a\nb\n") == ["a", "b"])
    #expect(DiffContextState.lines(of: "a\n\nb") == ["a", "", "b"])
  }

  @Test("Find matches paths and lines, by case or not, as text or a pattern, up to a limit")
  func find() {
    let files = [
      StackedDiffFile(diff: twoHunks),
      StackedDiffFile(path: "new.txt", previousPath: "old.txt", kind: .renamed),
    ]
    let corpus = DiffFind.corpus(files)
    #expect(corpus.filter { $0.kind == .path }.map(\.text) == ["src/a.txt", "new.txt", "old.txt"])
    let removed = corpus.first { $0.text == "three" }
    #expect(removed?.side == .old && removed?.line == 3)
    let three = DiffFind.matches(in: corpus, query: "three", matchCase: false, regex: false)
    #expect(three.matches.count == 2)
    #expect(
      DiffFind.matches(in: corpus, query: "three", matchCase: true, regex: false).matches.count == 1
    )
    let pattern = DiffFind.matches(in: corpus, query: "^tw.*e$", matchCase: false, regex: true)
    #expect(pattern.matches.map(\.target.text) == ["twentyone", "TWENTYONE"])
    #expect(DiffFind.matches(in: corpus, query: "(", matchCase: false, regex: true).invalid)
    #expect(
      DiffFind.matches(in: corpus, query: "t.o", matchCase: false, regex: false).matches.isEmpty)
    #expect(
      DiffFind.matches(in: corpus, query: "  ", matchCase: false, regex: false).matches.isEmpty)
    let capped = DiffFind.matches(in: corpus, query: "t", matchCase: false, regex: false, limit: 3)
    #expect(capped.matches.count == 3 && capped.truncated)
    let ranges = DiffFind.matches(in: corpus, query: "en", matchCase: false, regex: false)
    #expect(ranges.matches.first { $0.target.text == "twenty" }?.range == 2..<4)
  }

  @Test("The first match is at or below the top file; a refresh keeps the nearest occurrence")
  func navigation() {
    let corpus = DiffFind.corpus([
      StackedDiffFile(diff: twoHunks), StackedDiffFile(path: "b.txt", kind: .added),
    ])
    let all = DiffFind.matches(in: corpus, query: "t", matchCase: false, regex: false).matches
    let paths = ["src/a.txt", "b.txt"]
    #expect(
      DiffFind.firstAtOrBelow(all, paths: paths, top: "b.txt")
        == all.firstIndex { $0.target.path == "b.txt" })
    #expect(DiffFind.firstAtOrBelow(all, paths: paths, top: nil) == 0)
    #expect(DiffFind.step(from: nil, forward: false, count: 4) == 3)
    #expect(DiffFind.step(from: 3, forward: true, count: 4) == 0)
    let previous = DiffFindMatch(
      target: DiffFindTarget(path: "src/a.txt", kind: .line, side: .new, line: 21, text: "gone"),
      range: 0..<1)
    let nearest = DiffFind.refreshedIndex(all, previous: previous)
    #expect(all[nearest].target.line == 21, "the nearest line on the same side")
    let result = DiffFind.matches(in: corpus, query: "t", matchCase: false, regex: false)
    #expect(DiffFind.status(query: "t", result: result, position: 2) == "2 of \(all.count)")
    #expect(DiffFind.status(query: "t", result: result, position: 0) == "\(all.count) matches")
    #expect(DiffFind.status(query: "zz", result: DiffFindResult(), position: 0) == "No results")
    #expect(DiffFind.status(query: "", result: result, position: 1).isEmpty)
  }

  @Test("The path filter reads old paths, either slash and any case")
  func pathFilter() {
    let files = [
      StackedDiffFile(path: "src/A.rs", kind: .modified),
      StackedDiffFile(path: "lib/new.rs", previousPath: "lib/old.rs", kind: .renamed),
    ]
    #expect(ChangedPathFilter.filter(files, query: " src\\a ").map(\.path) == ["src/A.rs"])
    #expect(ChangedPathFilter.filter(files, query: "OLD").map(\.path) == ["lib/new.rs"])
    #expect(ChangedPathFilter.filter(files, query: "").count == 2)
    #expect(
      ChangedPathFilter.visible(files, query: "", hiding: ["src/A.rs"]).map(\.path)
        == ["lib/new.rs"])
  }

  @Test("A fingerprint follows the hunks, and a file without hunks has none")
  func fingerprints() throws {
    let print = try #require(DiffFingerprint.of(twoHunks))
    #expect(DiffFingerprint.of(twoHunks) == print)
    var moved = twoHunks
    moved.hunks[1].lines[2].text = "21"
    #expect(DiffFingerprint.of(moved) != print)
    #expect(DiffFingerprint.of(WorkspaceSamples.tooLargeDiff) == nil)
    #expect(DiffFingerprint.isVerified(print))
    #expect(!DiffFingerprint.isVerified(DiffFingerprint.unverified(head: "abc")))
    #expect(DiffFingerprint.hash("a") != DiffFingerprint.hash("b"))
  }

  @Test("A file from its own patch takes the patch's status, old path and counts")
  func patchFiles() {
    var renamed = WorkspaceSamples.mainDiff
    renamed.change = .renamed
    renamed.oldPath = "old.rs"
    let file = StackedDiffFile(diff: renamed)
    #expect(file.kind == .renamed && file.renamedFrom == "old.rs")
    #expect(file.added == renamed.added)
    #expect(StackedDiffFile(diff: WorkspaceSamples.addedDiff).kind == .added)
    #expect(StackedDiffFile(diff: WorkspaceSamples.deletedDiff).kind == .deleted)
    #expect(StackedDiffFile(diff: WorkspaceSamples.mainDiff).kind == .modified)
  }
}
