#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentWorkspaceUI

  /// The stacked diff the Changes tab draws: side by side, gaps of unchanged lines that
  /// expand, controls beside headers, and the files a patch has no text for.
  @Suite("Stacked diff list", .serialized)
  @MainActor
  struct StackedDiffListTests {
    private let twoHunks = SampleDiffs.diff(
      path: "src/a.txt",
      hunks: [
        SampleDiffs.Hunk(
          old: 2, new: 2,
          lines: [.context("two"), .removed("three"), .added("THREE"), .context("four")]),
        SampleDiffs.Hunk(
          old: 20, new: 20,
          lines: [.context("twenty"), .removed("old 21"), .added("new 21"), .context("22")]),
      ])

    private func screen(_ content: StackedDiffContent, actions: StackedDiffActions = .init())
      -> OffscreenWindow<StackedDiffList>
    {
      OffscreenWindow(StackedDiffList(content: content, actions: actions), width: 900, height: 600)
    }

    @Test("Side by side, a changed line pairs its old and new text on one row")
    func sideBySide() throws {
      var content = StackedDiffContent(files: [StackedDiffFile(diff: twoHunks)])
      content.layout = .split
      let shown = screen(content)
      defer { shown.close() }
      for text in ["three", "THREE", "old 21", "new 21"] {
        #expect(try shown.shows(text), "\(text)")
      }
    }

    @Test("A gap says how many lines it hides, and expanding shows them")
    func gaps() throws {
      var log: [String] = []
      var actions = StackedDiffActions()
      actions.expand = { path, gap, expansion in log.append("\(path) \(gap.index) \(expansion)") }
      let file = StackedDiffFile(diff: twoHunks)
      let shown = screen(StackedDiffContent(files: [file]), actions: actions)
      defer { shown.close() }
      #expect(try shown.shows("15 unchanged lines"))
      #expect(try shown.shows("1 unchanged line"))

      var expanded = StackedDiffContent(files: [file])
      let lines = (1...25).map { "line \($0)" }
      let gap = try #require(DiffContext.gaps(twoHunks, lineCount: 25).first { $0.index == 1 })
      expanded.context["src/a.txt"] = DiffContextState(lines: lines).expanding(gap, .below)
      let more = screen(expanded, actions: actions)
      defer { more.close() }
      #expect(try more.shows("line 5"))
      #expect(try more.shows("5 unchanged lines"))
      #expect(try !more.shows("line 16"))
    }

    @Test("Without an expander, hunks keep their headers; a file without text says so")
    func plainHeadersAndNotices() throws {
      var content = StackedDiffContent(files: [
        StackedDiffFile(diff: twoHunks),
        StackedDiffFile(path: "logo.png", kind: .added, added: nil, removed: nil),
      ])
      content.annotations.headers["logo.png"] = AnyView(Text("Viewed mark"))
      content.footer = AnyView(Text("Earlier conversations"))
      let shown = screen(content)
      defer { shown.close() }
      #expect(try shown.shows("@@ -20,3 +20,3 @@"))
      #expect(try !shown.shows("unchanged lines"))
      #expect(try shown.shows("No text diff available for this file."))
      #expect(try shown.shows("Viewed mark"))
      #expect(try shown.shows("Earlier conversations"))
    }
  }
#endif
