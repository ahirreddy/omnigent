#if os(macOS) && DEBUG
  import AppKit
  import OmnigentViewTesting
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  /// Where the reader of a long conversation is when its pane changes width.
  enum ResizedReader: CaseIterable, Sendable {
    case atEnd, midConversation
  }

  /// A way a pane's width changes, as the widths laid out in each turn of the run loop.
  enum WidthDrive: CaseIterable, Sendable {
    case widen, drag, collapseAndBack, twoWidthsATurn

    static let narrow: CGFloat = 400
    /// Past the width at which the rows stop growing.
    static let wide: CGFloat = 780
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

    /// A conversation of `turns` open in a narrow pane, with its reader where `reader` says.
    private func pane(_ width: PaneWidth, reader: ResizedReader) async throws
      -> OffscreenWindow<AnyView>
    {
      let conversation = LiveConversation(
        ConversationViewState(
          header: TranscriptFixture.header, rows: TranscriptFixture.turns(Self.turns)))
      let window = transcriptScreen(
        ResizedTranscriptHost(conversation: conversation, width: width),
        width: WidthDrive.wide + 120, height: Self.height)
      window.settle(0.5)
      try await letTasksRun(window, milliseconds: 600)
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
      let width = PaneWidth(WidthDrive.narrow)
      let window = try await pane(width, reader: reader)
      defer { window.close() }
      let recorder = try CommittedFrames(window)
      let settled = recorder.settled
      let anchor = try #require(settled.lineAtMiddle)
      let anchorDistance = anchor.frame.midY - settled.middle
      // What the rows' own padding takes from the column, the same at every width.
      let padding = column(in: WidthDrive.narrow) - (try #require(settled.textSpan))
      let lastLine = "Line 11 of answer \(Self.turns - 1)"

      let before = HangTrace.tallies()
      let frames = recorder.recording {
        for turn in drive.turns {
          for early in turn.dropLast() {
            width.value = early
            window.host.layoutSubtreeIfNeeded()
          }
          width.value = turn.last ?? width.value
          commitFrames(for: drive.frameTime)
        }
        commitFrames(for: 0.5)
      }
      let probed = HangTrace.tallies()

      // Each turn's last width was committed, in order, and nothing else between.
      #expect(frames.map(\.viewport.width) == drive.turns.compactMap(\.last))
      for frame in frames {
        // More than a screen below the top.
        #expect(frame.offset > Self.height)
        // The rows are at this frame's column, not the one before.
        let span = try #require(frame.textSpan)
        #expect(abs(span + padding - column(in: frame.viewport.width)) < 0.5)
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
      // Every frame's width was taken at the top, and no passage was left for a turn's end.
      #expect(probed.count("transcript passage", since: before) >= 2 * drive.turns.count)
      #expect(probed.count(TranscriptScrollState.latePassage, since: before) == 0)
    }
  }
#endif
