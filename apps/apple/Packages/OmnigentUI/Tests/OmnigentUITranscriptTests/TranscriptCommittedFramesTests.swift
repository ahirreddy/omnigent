#if os(macOS) && DEBUG
  import AppKit
  import OmnigentViewTesting
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents
  @testable import OmnigentUITestSupport

  /// Where the reader of a long conversation is when its pane changes width.
  enum ResizedReader: CaseIterable, Sendable {
    case atEnd, midConversation
  }

  /// A way a pane's width changes, as the widths laid out in each turn of the run loop.
  enum WidthDrive: CaseIterable, Sendable {
    case widen, drag, collapseAndBack, twoWidthsATurn

    static let narrow: CGFloat = 400
    /// Past the width at which the rows stop growing.
    static let wide: CGFloat = 800
    static let dragSteps = 20

    /// The widths of a drag from narrow to wide.
    private static var dragged: [CGFloat] {
      (1...dragSteps).map { narrow + (wide - narrow) * CGFloat($0) / CGFloat(dragSteps) }
    }

    /// Each turn's widths: all but the last are laid out before the turn's frame, as a resize
    /// whose events outrun the display does.
    var turns: [[CGFloat]] {
      switch self {
      case .widen: [[Self.wide]]
      case .drag: Self.dragged.map { [$0] }
      case .collapseAndBack: [[UnmeasuredMinimum.column.width], [Self.narrow]]
      case .twoWidthsATurn:
        stride(from: 0, to: Self.dragSteps, by: 2).map { Array(Self.dragged[$0..<($0 + 2)]) }
      }
    }

    /// How long the run loop gets for a turn's frame. With none it makes a single pass, so the
    /// end of a turn is still owed when the next widths arrive, and takes one of them itself.
    var frameTime: TimeInterval { self == .twoWidthsATurn ? 0 : 0.016 }
  }

  /// The rows take a new width at the scroll view's top, within one layout pass. These read
  /// every frame committed through a width change: none may show the top, or rows at an old
  /// width, to a reader who was elsewhere.
  @Suite("Transcript frames through a width change", .serialized)
  @MainActor
  struct TranscriptCommittedFramesTests {
    private static let height: CGFloat = 700
    private static let turns = 400
    /// The width of the rows' column in a pane `width` wide.
    private func column(in width: CGFloat) -> CGFloat {
      min(width - 2 * Theme.Spacing.gutter, TranscriptAppearance().contentWidth.maxWidth)
    }

    /// A conversation of `turns` open in a narrow pane over `list`, with its reader where
    /// `reader` says.
    private func pane(_ width: PaneWidth, reader: ResizedReader, list: TranscriptListKind)
      async throws -> OffscreenWindow<AnyView>
    {
      // These start from where the opening leaves the reader; its framing wait runs a tenth as long.
      Theme.Timing.scale = 0.1
      defer { Theme.Timing.scale = 1 }
      let conversation = LiveConversation(
        ConversationViewState(
          header: TranscriptFixture.header, rows: TranscriptFixture.turns(Self.turns)))
      let window = transcriptScreen(
        ResizedTranscriptHost(conversation: conversation, width: width)
          .messageRenderer(for: list),
        width: WidthDrive.wide + 120, height: Self.height)
      try await letOpeningEnd(window)
      if reader == .midConversation {
        let viewport = TranscriptScrollDriver(screen: window)
        let scroll = try #require(viewport.scrollView)
        window.liveScroll(scroll, began: true)
        viewport.move(to: viewport.maximumOffset / 2)
        window.liveScroll(scroll, began: false)
        try await letTasksRun(window, milliseconds: 300)
      }
      return window
    }

    @Test(
      "Every frame of a width change shows the reader's place, with the rows at the pane's width",
      arguments: ResizedReader.allCases, WidthDrive.allCases)
    func framesKeepTheReader(reader: ResizedReader, drive: WidthDrive) async throws {
      try await overTranscriptList(.stack) {
        try await recordWidthChange(reader: reader, drive: drive, list: .stack)
      }
    }

    @Test(
      "Every frame of a width change over the table shows the reader's place, at the new width",
      arguments: ResizedReader.allCases, WidthDrive.allCases)
    func tableFramesKeepTheReader(reader: ResizedReader, drive: WidthDrive) async throws {
      try await overTranscriptList(.table) {
        try await recordWidthChange(reader: reader, drive: drive, list: .table)
      }
    }

    @Test(
      "Every frame of a live drag over the table shows the reader's place, at snapped widths",
      arguments: ResizedReader.allCases)
    func tableLiveDragKeepsTheReader(reader: ResizedReader) async throws {
      try await overTranscriptList(.table) {
        try await recordWidthChange(reader: reader, drive: .drag, list: .table, isLive: true)
      }
    }

    /// Lays out each of `drive`'s turns' widths and lets the turn's frame commit, inside a live
    /// resize of `liveResizing` when there is one.
    private func run(
      _ drive: WidthDrive, _ width: PaneWidth, in window: OffscreenWindow<AnyView>,
      liveResizing scrollView: NSScrollView?
    ) {
      scrollView?.viewWillStartLiveResize()
      for turn in drive.turns {
        for early in turn.dropLast() {
          width.value = early
          window.host.layoutSubtreeIfNeeded()
        }
        width.value = turn.last ?? width.value
        commitFrames(for: drive.frameTime)
      }
      scrollView?.viewDidEndLiveResize()
      commitFrames(for: 0.5)
    }

    /// Drives the pane's width as `drive` says under `reader` and reads every frame committed.
    /// `isLive` drives it as a window's live resize, whose text lays out at snapped widths
    /// until it ends.
    private func recordWidthChange(
      reader: ResizedReader, drive: WidthDrive, list: TranscriptListKind, isLive: Bool = false
    ) async throws {
      let width = PaneWidth(WidthDrive.narrow)
      let window = try await pane(width, reader: reader, list: list)
      defer { window.close() }
      let recorder = try CommittedFrames(window)
      let settled = recorder.settled
      let anchor = try #require(settled.lineAtMiddle)
      let anchorDistance = anchor.frame.midY - settled.middle
      // What the rows' own padding takes from the column, the same at every width.
      let padding = column(in: WidthDrive.narrow) - (try #require(settled.textSpan))
      let lastLine = "Line 11 of answer \(Self.turns - 1)"

      let scrollView = try #require(TranscriptScrollDriver(screen: window).scrollView)
      let before = HangTrace.tallies()
      let frames = recorder.recording {
        run(drive, width, in: window, liveResizing: isLive ? scrollView : nil)
      }
      let probed = HangTrace.tallies()

      // Each turn's last width was committed, in order, and nothing else between; a live
      // resize's end lays the text out again at the last.
      var widths = frames.map(\.viewport.width)
      if isLive, widths.count > 1, widths.last == widths.dropLast().last { widths.removeLast() }
      #expect(widths == drive.turns.compactMap(\.last))
      for (index, frame) in frames.enumerated() {
        // More than a screen below the top.
        #expect(frame.offset > Self.height)
        // The rows are at this frame's column, not the one before; during a live resize at
        // one snapped down to its step, at no more than a step's cost.
        let span = try #require(frame.textSpan)
        let column = column(in: frame.viewport.width)
        if isLive, index < frames.count - 1 {
          #expect(span + padding <= column + 0.5)
          #expect(span + padding > column - TranscriptTableTextStyle.liveResizeSnap)
        } else {
          #expect(abs(span + padding - column) < 0.5)
        }
        // Nothing is drawn past the pane, and the scroll view clips what would be.
        #expect(try #require(frame.trailingEdge) <= frame.viewport.maxX)
        #expect(frame.clips)
        switch reader {
        case .atEnd:
          // The conversation's last line is in view, in the viewport's lower half.
          #expect(try #require(frame.distanceBelowMiddle(of: lastLine)) > 0)
        case .midConversation:
          let distance = try #require(frame.distanceBelowMiddle(of: anchor.text))
          #expect(abs(distance - anchorDistance) <= 2)
        }
      }
      // Every frame's width was taken at the top, and no passage was left for a turn's end. The
      // table measures its rows at a new width where they are, with no passage.
      if list == .stack {
        #expect(probed.count("transcript passage", since: before) >= 2 * drive.turns.count)
      }
      #expect(probed.count(TranscriptScrollState.latePassage, since: before) == 0)
    }
  }
#endif
