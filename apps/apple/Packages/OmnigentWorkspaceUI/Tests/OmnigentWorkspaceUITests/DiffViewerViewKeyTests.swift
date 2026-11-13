#if os(macOS)
  import AppKit
  import Foundation
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentWorkspaceUI

  /// The diff's Option-Command-Down and Up, the key equivalents of its next and previous buttons.
  @MainActor
  @Suite("Diff viewer chords", .serialized)
  struct DiffViewerViewKeyTests {
    /// An arrow key as a keyboard sends it: its flags say the key is a function key on the pad.
    private static let arrowFlags: NSEvent.ModifierFlags = [
      .option, .command, .numericPad, .function,
    ]

    private func hosted(_ diff: FileDiff) -> OffscreenWindow<DiffViewerView> {
      OffscreenWindow(
        DiffViewerView(
          diff: diff, mode: .unified, source: SampleWorkspaceDataSource(), actions: .none),
        width: 900, height: 420)
    }

    @Test("Option-Command-Down moves to the next change and Option-Command-Up back")
    func chords() async throws {
      let screen = hosted(WorkspaceSamples.libDiff)
      defer { screen.close() }
      let total = WorkspaceSamples.libDiff.hunks.count
      try #require(total >= 2, "the sample needs two changes to move between")
      #expect(try screen.shows("\(total) changes"))
      #expect(try screen.pressShortcut("\u{F701}", keyCode: 125, modifiers: Self.arrowFlags))
      await flush(screen)
      #expect(try screen.shows("Change 1 of \(total)"))
      #expect(try screen.pressShortcut("\u{F701}", keyCode: 125, modifiers: Self.arrowFlags))
      await flush(screen)
      #expect(try screen.shows("Change 2 of \(total)"))
      #expect(try screen.pressShortcut("\u{F700}", keyCode: 126, modifiers: Self.arrowFlags))
      await flush(screen)
      #expect(try screen.shows("Change 1 of \(total)"))
    }

    @Test("with no changes the chords move nowhere")
    func nothingToMoveTo() async throws {
      let same = FileDiff(
        oldPath: "same.txt", newPath: "same.txt", change: .modified, hunks: [], splitRows: [],
        added: 0, removed: 0)
      let screen = hosted(same)
      defer { screen.close() }
      #expect(try screen.shows("No changes"))
      try screen.pressShortcut("\u{F701}", keyCode: 125, modifiers: Self.arrowFlags)
      await flush(screen)
      #expect(try screen.shows("No changes"))
      #expect(try !screen.shows("Change 1 of"))
    }
  }
#endif
