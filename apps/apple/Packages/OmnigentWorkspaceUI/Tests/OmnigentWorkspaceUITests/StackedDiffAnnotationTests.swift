#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentWorkspaceUI

  /// Views under a stacked diff's lines and file headers, and choosing lines for a review.
  @Suite("Stacked diff annotations", .serialized)
  @MainActor
  struct StackedDiffAnnotationTests {
    private let path = WorkspaceSamples.libDiff.path

    @Test("A view sits under the line its anchor names, and a file's under its header")
    func placesAnnotations() throws {
      var annotations = StackedDiffAnnotations()
      annotations.lines[DiffLineAnchor(path: path, side: .new, line: 1)] = AnyView(
        Text("Conversation on new line 1"))
      annotations.lines[DiffLineAnchor(path: path, side: .old, line: 3)] = AnyView(
        Text("Conversation on old line 3"))
      annotations.lines[DiffLineAnchor(path: "elsewhere.rs", side: .new, line: 1)] = AnyView(
        Text("Never shown"))
      annotations.files[path] = AnyView(Text("Outdated conversation"))
      let screen = OffscreenWindow(
        StackedDiffView(files: [WorkspaceSamples.libDiff], annotations: annotations),
        width: 700, height: 600)
      defer { screen.close() }
      for line in [
        "Outdated conversation", "Conversation on new line 1", "Conversation on old line 3",
      ] {
        #expect(try screen.shows(line))
      }
      #expect(try !screen.shows("Never shown"))

      // The removed line 1, the added line 1, then unchanged lines 2 and 3.
      let anchors: Set<DiffLineAnchor> = [
        DiffLineAnchor(path: path, side: .new, line: 1),
        DiffLineAnchor(path: path, side: .old, line: 3),
        DiffLineAnchor(path: path, side: .new, line: 3),
        DiffLineAnchor(path: "elsewhere.rs", side: .new, line: 1),
      ]
      let placements = StackedDiffView.placements(WorkspaceSamples.libDiff, among: anchors)
      #expect(placements[1] == [DiffLineAnchor(path: path, side: .new, line: 1)])
      #expect(
        placements[3]
          == [
            DiffLineAnchor(path: path, side: .old, line: 3),
            DiffLineAnchor(path: path, side: .new, line: 3),
          ], "an unchanged line carries both its numbers")
      #expect(placements.values.joined().count == 3, "another file's anchor goes nowhere")
    }

    @Test("An unchanged line answers to both its numbers; a changed one to its own side")
    func anchors() {
      let context = DiffLine(
        kind: .context, oldNumber: 3, newNumber: 4, text: "x", missingNewline: false)
      #expect(
        DiffLineAnchor.all(context, path: "a")
          == [
            DiffLineAnchor(path: "a", side: .old, line: 3),
            DiffLineAnchor(path: "a", side: .new, line: 4),
          ])
      #expect(DiffLineAnchor.of(context, path: "a")?.side == .new)
      let removed = DiffLine(
        kind: .removed, oldNumber: 7, newNumber: nil, text: "y", missingNewline: false)
      #expect(
        DiffLineAnchor.of(removed, path: "a") == DiffLineAnchor(path: "a", side: .old, line: 7))
    }

    @Test("Shift-click extends a choice within its side and hunk, and starts over otherwise")
    func extendsSelections() {
      let start = DiffLineSelection(path: "a", side: .new, start: 5, end: 5, hunk: 0)
      let downward = start.extended(to: DiffLineAnchor(path: "a", side: .new, line: 8), hunk: 0)
      #expect((downward.start, downward.end) == (5, 8))
      let upward = downward.extended(to: DiffLineAnchor(path: "a", side: .new, line: 2), hunk: 0)
      #expect((upward.start, upward.end) == (2, 8))
      let otherSide = start.extended(to: DiffLineAnchor(path: "a", side: .old, line: 8), hunk: 0)
      #expect((otherSide.start, otherSide.end, otherSide.side) == (8, 8, .old))
      let otherHunk = start.extended(to: DiffLineAnchor(path: "a", side: .new, line: 40), hunk: 1)
      #expect((otherHunk.start, otherHunk.end, otherHunk.hunk) == (40, 40, 1))
      #expect(downward.contains(DiffLineAnchor(path: "a", side: .new, line: 6)))
      #expect(!downward.contains(DiffLineAnchor(path: "a", side: .old, line: 6)))
    }
  }
#endif
