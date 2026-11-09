#if os(macOS)
  import AppKit
  import Foundation
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentWorkspaceUI

  /// A diff: its header at any width, navigation between changes, layouts and every state.
  @MainActor
  @Suite("Diff viewer", .serialized)
  struct DiffViewerTests {
    private func hosted(
      _ diff: FileDiff = WorkspaceSamples.libDiff, mode: DiffLayoutMode = .unified,
      width: CGFloat = 900, actions: WorkspaceActions = .none
    ) -> OffscreenWindow<DiffViewerView> {
      OffscreenWindow(
        DiffViewerView(
          diff: diff, mode: mode, source: SampleWorkspaceDataSource(), actions: actions),
        width: width, height: 420)
    }

    /// Previous and next change sit together, left of the layout picker, in the header's row.
    private func navigationButton(
      _ screen: OffscreenWindow<DiffViewerView>, next: Bool
    ) throws -> CGPoint {
      let group = try #require(screen.segmentedPickers.first)
      let frame = group.convert(group.bounds, to: screen.host)
      let half = frame.width / 4
      return CGPoint(x: next ? frame.maxX - half : frame.minX + half, y: frame.midY)
    }

    @Test("the header's label counts the changes, and each move names where it is")
    func navigation() async throws {
      let screen = hosted()
      defer { screen.close() }
      let total = WorkspaceSamples.libDiff.hunks.count
      #expect(total >= 2, "the sample needs two hunks to move between")
      #expect(try screen.shows("\(total) changes"))
      try screen.click(try navigationButton(screen, next: true))
      await flush(screen)
      #expect(try screen.shows("Change 1 of \(total)"))
      try screen.click(try navigationButton(screen, next: true))
      await flush(screen)
      #expect(try screen.shows("Change 2 of \(total)"))
      try screen.click(try navigationButton(screen, next: false))
      await flush(screen)
      #expect(try screen.shows("Change 1 of \(total)"))
    }

    @Test("once clicked, n and j move to the next change and p and k back", arguments: ["n", "j"])
    func keys(next: String) async throws {
      let screen = hosted()
      defer { screen.close() }
      try screen.click(CGPoint(x: 400, y: 200))
      await flush(screen)
      let code: UInt16 = next == "n" ? 45 : 38
      try screen.press(keyCode: code, characters: next)
      await flush(screen)
      #expect(try screen.shows("Change 1 of"))
      try screen.press(keyCode: code, characters: next)
      await flush(screen)
      #expect(try screen.shows("Change 2 of"))
      let back = next == "n" ? ("p", UInt16(35)) : ("k", UInt16(40))
      try screen.press(keyCode: back.1, characters: back.0)
      await flush(screen)
      #expect(try screen.shows("Change 1 of"))
    }

    @Test("a line with no final newline draws a mark")
    func missingNewline() throws {
      let plain = hosted()
      defer { plain.close() }
      var marked = WorkspaceSamples.libDiff
      marked.hunks[0].lines[0].missingNewline = true
      let screen = hosted(marked)
      defer { screen.close() }
      let again = hosted()
      defer { again.close() }
      #expect(try drawing(again) == drawing(plain), "two identical diffs draw the same")
      #expect(try drawing(screen) != drawing(plain))
    }

    private func drawing(_ screen: OffscreenWindow<DiffViewerView>) throws -> Data? {
      let bitmap = try #require(screen.host.bitmapImageRepForCachingDisplay(in: screen.host.bounds))
      screen.host.cacheDisplay(in: screen.host.bounds, to: bitmap)
      return bitmap.tiffRepresentation
    }

    @Test("a diff with no changes turns navigation off and says it matches")
    func identical() async throws {
      let diff = FileDiff(
        oldPath: "same.txt", newPath: "same.txt", change: .modified, hunks: [], splitRows: [],
        added: 0, removed: 0)
      let screen = hosted(diff)
      defer { screen.close() }
      #expect(try screen.shows("No Differences"))
      #expect(try screen.shows("No changes"))
      try screen.click(try navigationButton(screen, next: true))
      await flush(screen)
      #expect(try screen.shows("No changes"), "nothing to move to")
    }

    @Test("binary and too-large diffs say so instead of drawing lines")
    func states() throws {
      let binary = hosted(
        FileDiff(
          oldPath: "a.png", newPath: "a.png", change: .modified, hunks: [], splitRows: [],
          added: 0, removed: 0, binary: true))
      defer { binary.close() }
      #expect(try binary.shows("Binary File"))
      let large = hosted(WorkspaceSamples.tooLargeDiff)
      defer { large.close() }
      #expect(try large.shows("Diff Too Large"))
      #expect(try !large.shows("No Differences"))
    }

    @Test("an approximate diff warns it's a replacement")
    func approximate() throws {
      var diff = WorkspaceSamples.mainDiff
      diff.approximate = true
      let screen = hosted(diff)
      defer { screen.close() }
      #expect(try screen.shows("too large to align line by line"))
      let exact = hosted()
      defer { exact.close() }
      #expect(try !exact.shows("too large to align line by line"))
    }

    @Test("the subtitle says what happened to the file")
    func subtitles() throws {
      let added = hosted(WorkspaceSamples.addedDiff)
      defer { added.close() }
      #expect(try added.shows("new file"))
      let deleted = hosted(WorkspaceSamples.deletedDiff)
      defer { deleted.close() }
      #expect(try deleted.shows(", deleted"))
      var moved = WorkspaceSamples.mainDiff
      moved.change = .renamed
      moved.oldPath = "old/name.rs"
      moved.newPath = "new/name.rs"
      let renamed = hosted(moved)
      defer { renamed.close() }
      #expect(try renamed.shows("old/name.rs \u{2192} new/name.rs"))
    }

    @Test("automatic follows the width; a chosen layout stays")
    func layouts() {
      #expect(DiffLayoutMode.automatic.resolved(width: 859) == .unified)
      #expect(DiffLayoutMode.automatic.resolved(width: 860) == .split)
      #expect(DiffLayoutMode.unified.resolved(width: 2_000) == .unified)
      #expect(DiffLayoutMode.split.resolved(width: 100) == .split)
      #expect(DiffLayoutMode.allCases.map(\.title) == ["Automatic", "Unified", "Side by Side"])
      #expect(DiffLayoutMode.split.id == "split")
    }

    @Test("the layout menu offers the three layouts and changes the drawing")
    func layoutMenu() async throws {
      let screen = hosted(mode: .unified, width: 1_000)
      defer { screen.close() }
      let picker = try #require(screen.popUps.first { $0.numberOfItems == 3 })
      #expect(picker.itemTitles == ["Automatic", "Unified", "Side by Side"])
      let unifiedText = try screen.shownText()
      let frame = picker.convert(picker.bounds, to: screen.host)
      let menu = try screen.openMenu(CGPoint(x: frame.midX, y: frame.midY))
      try screen.choose("Side by Side", in: menu)
      await flush(screen)
      let splitText = try screen.shownText()
      // Side by side draws changed lines in two columns, so strings differ from one column's.
      #expect(splitText != unifiedText)
    }

    @Test("the actions menu offers the path actions")
    func actionsMenu() throws {
      SystemSideEffects.reset()
      let screen = hosted()
      defer { screen.close() }
      let menus = screen.popUps.filter { $0.numberOfItems != 3 }
      let frame = try #require(menus.first).convert(menus[0].bounds, to: screen.host)
      let menu = try screen.openMenu(CGPoint(x: frame.midX, y: frame.midY))
      try screen.choose("Copy Path", in: menu)
      #expect(SystemSideEffects.pasteboard.string(forType: .string) != nil)
    }

    @Test(
      "a narrow diff's controls never crush its name",
      arguments: [300.0, 340.0, 460.0, 560.0, 700.0])
    func narrowHeader(width: Double) throws {
      let screen = hosted(width: width)
      defer { screen.close() }
      let name = "lib.rs"
      #expect(try screen.shows(name))
      // A focusable diff lists itself as a control filling the window.
      let controls = screen.controls.filter { $0.height < 40 }
      #expect(controls.count >= 3)
      for frame in controls where frame.minY < 44 {
        #expect(frame.minX > 12 + 16 + 8 + 30, "\(frame) on the name's line at \(width)")
      }
      for frame in controls { #expect(frame.maxX <= width + 1, "\(frame) past \(width)") }
    }

    @Test("the navigator stops at the ends and counts")
    func navigator() {
      var navigator = HunkNavigator(total: 2)
      #expect(navigator.label == "2 changes")
      #expect(navigator.previous() == 0)
      #expect(navigator.next() == 1)
      #expect(navigator.next() == 1)
      #expect(navigator.label == "Change 2 of 2")
      var one = HunkNavigator(total: 1)
      #expect(one.label == "1 change")
      #expect(one.next() == 0)
      var none = HunkNavigator(total: 0)
      #expect(none.label == "No changes")
      #expect(none.next() == nil)
      #expect(none.previous() == nil)
    }
  }

  /// Every file of a change set in one scroll.
  @MainActor
  @Suite("Stacked diff", .serialized)
  struct StackedDiffTests {
    private let files = [
      WorkspaceSamples.mainDiff, WorkspaceSamples.addedDiff, WorkspaceSamples.tooLargeDiff,
    ]

    private func hosted(_ files: [FileDiff]) -> OffscreenWindow<StackedDiffView> {
      OffscreenWindow(StackedDiffView(files: files), width: 620, height: 520)
    }

    /// The Collapse All button, at the toolbar's trailing end.
    private func collapseAll(_ screen: OffscreenWindow<StackedDiffView>) throws -> CGRect {
      let button = try #require(screen.appKitButtons.last)
      return button.convert(button.bounds, to: screen.host)
    }

    /// The file headers, full width bars under the toolbar: a collapsed file's next one moves up.
    private func headers(_ screen: OffscreenWindow<StackedDiffView>) -> [CGRect] {
      screen.controlFrames.filter { $0.minY > 20 && $0.height < 60 && $0.width > 400 }
    }

    @Test("the toolbar counts files, and a single file reads as one")
    func counts() throws {
      let many = hosted(files)
      defer { many.close() }
      #expect(try many.shows("3 files"))
      let one = hosted([WorkspaceSamples.mainDiff])
      defer { one.close() }
      #expect(try one.shows("1 file"))
    }

    @Test("Collapse All can be seen in both states: a missing symbol draws nothing at all")
    func collapseAllShows() async throws {
      let screen = hosted(files)
      defer { screen.close() }
      let button = try collapseAll(screen)
      #expect(button.width > 8, "\(button)")
      #expect(button.maxX <= 620)
      try screen.click(CGPoint(x: button.midX, y: button.midY))
      await flush(screen)
      #expect(try collapseAll(screen).width > 8)
    }

    @Test("Collapse All stacks the headers and the same button opens them again")
    func collapse() async throws {
      let screen = hosted(files)
      defer { screen.close() }
      let open = headers(screen)
      try #require(open.count >= 2, "\(screen.controlFrames)")
      let button = try collapseAll(screen)
      try screen.click(CGPoint(x: button.midX, y: button.midY))
      await flush(screen)
      let shut = headers(screen)
      #expect(shut[1].minY < open[1].minY, "the second header rose")
      try screen.click(CGPoint(x: button.midX, y: button.midY))
      await flush(screen)
      #expect(headers(screen)[1].minY == open[1].minY)
    }

    @Test("clicking a file's header collapses just that file")
    func collapseOne() async throws {
      let screen = hosted(files)
      defer { screen.close() }
      let open = headers(screen)
      try #require(open.count >= 2, "\(screen.controlFrames)")
      try screen.click(CGPoint(x: open[0].midX, y: open[0].midY))
      await flush(screen)
      let shut = headers(screen)
      #expect(shut[1].minY < open[1].minY, "the first file's lines went away")
      #expect(shut[0].minY == open[0].minY)
    }

    @Test("a too-large file says so where its lines would be")
    func tooLarge() throws {
      let screen = hosted([WorkspaceSamples.tooLargeDiff])
      defer { screen.close() }
      #expect(try screen.shows("This change is too large to show."))
    }

    @Test("a binary file says so, and subtitles say what happened")
    func binaryAndSubtitles() throws {
      var binary = WorkspaceSamples.mainDiff
      binary.hunks = []
      binary.binary = true
      var renamed = WorkspaceSamples.mainDiff
      renamed.hunks = []
      renamed.change = .renamed
      renamed.oldPath = "old.rs"
      renamed.newPath = "new.rs"
      let screen = hosted([
        binary, renamed, WorkspaceSamples.addedDiff, WorkspaceSamples.deletedDiff,
      ])
      defer { screen.close() }
      #expect(try screen.shows("Binary file"))
      #expect(try screen.shows("old.rs \u{2192} new.rs"))
      #expect(try screen.shows("new file"))
      #expect(try screen.shows("deleted"))
    }

    @Test("the file menu lists every file and jumping to one opens it again")
    func jumpMenu() async throws {
      let screen = hosted(files)
      defer { screen.close() }
      let button = try collapseAll(screen)
      try screen.click(CGPoint(x: button.midX, y: button.midY))
      await flush(screen)
      let collapsed = headers(screen)
      let menu = try screen.menu(ofPopUp: 0)
      let titles = menu.items.map(\.title).filter { !$0.isEmpty }
      #expect(titles == files.map(\.path))
      try screen.choose(WorkspaceSamples.mainDiff.path, in: menu)
      await flush(screen)
      #expect(headers(screen)[1].minY > collapsed[1].minY)
    }
  }
#endif
