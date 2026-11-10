#if os(macOS) && DEBUG
  import AppKit
  import Observation
  import OmnigentViewTesting
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  /// Whether a transcript's tab is hidden, which a test changes as a tab switch does.
  @MainActor
  @Observable
  final class TabVisibility {
    var isHidden = false
  }

  /// The transcript as a kept tab's content, in a pane whose width changes under it.
  struct KeptTranscriptHost: View {
    let conversation: LiveConversation
    let width: PaneWidth
    let tab: TabVisibility

    var body: some View {
      ResizedTranscriptHost(conversation: conversation, width: width)
        .modifier(HiddenTabContent(isHidden: tab.isHidden))
    }
  }

  /// How far a pane widens and comes back while its tab is hidden.
  enum HiddenWidening: CaseIterable, Sendable {
    /// The message navigator stays under the rows.
    case besideNothing
    /// Wide enough that the navigator moves beside the rows, and its inset under them goes.
    case pastTheNavigator

    var widest: CGFloat {
      switch self {
      case .besideNothing: WidthDrive.narrow + 200
      case .pastTheNavigator: WidthDrive.wide
      }
    }
  }

  /// A kept chat's tab is hidden while its pane changes width, as another tab's window resize
  /// does to it. Hidden, it lays out nothing for the width; these read every frame committed
  /// once it shows again: none may show the top, rows at the old width, or the reader elsewhere.
  @Suite("Transcript frames on showing a hidden tab", .serialized)
  @MainActor
  struct TranscriptHiddenTabFramesTests {
    private static let height: CGFloat = 700
    private static let turns = 400
    private static let lastLine = "Line 11 of answer \(turns - 1)"
    /// What a hidden transcript may not do: take a width, scroll for layout, put a reader back.
    private static let scrolling = [
      "transcript width", "transcript passage", "transcript layout scroll", "transcript restore",
    ]

    /// The width of the rows' column in a pane `width` wide.
    private func column(in width: CGFloat) -> CGFloat {
      min(width - 2 * Theme.Spacing.gutter, TranscriptAppearance().contentWidth.maxWidth)
    }

    /// A conversation of `turns` open in a narrow pane, with its reader where `reader` says: on
    /// the bottom row, where a jump to the latest row rests, or mid-conversation.
    private func pane(_ width: PaneWidth, _ tab: TabVisibility, reader: ResizedReader)
      async throws -> OffscreenWindow<AnyView>
    {
      let conversation = LiveConversation(
        ConversationViewState(
          header: TranscriptFixture.header, rows: TranscriptFixture.turns(Self.turns)))
      let window = transcriptScreen(
        KeptTranscriptHost(conversation: conversation, width: width, tab: tab),
        width: WidthDrive.wide + 120, height: Self.height)
      window.settle(0.5)
      try await letTasksRun(window, milliseconds: 600)
      switch reader {
      case .atEnd:
        conversation.scrollRequest += 1
      case .midConversation:
        let viewport = TranscriptScrollDriver(screen: window)
        let scroll = try #require(viewport.scrollView)
        window.liveScroll(scroll, began: true)
        viewport.move(to: viewport.maximumOffset / 2)
        window.liveScroll(scroll, began: false)
      }
      try await letTasksRun(window, milliseconds: 300)
      return window
    }

    /// How many of `names` were recorded since `before`.
    private func count(_ names: [String], since before: HangTrace.Tallies) -> Int {
      let now = HangTrace.tallies()
      return names.reduce(0) { $0 + now.count($1, since: before) }
    }

    /// Where `frame` has the reader: how far above the viewport's clear bottom the conversation's
    /// last line ends, or how far below the viewport's middle `anchor` is.
    private func place(of reader: ResizedReader, anchor: String, in frame: CommittedFrame)
      -> CGFloat?
    {
      switch reader {
      case .atEnd:
        frame.lines.last { $0.text == Self.lastLine }.map {
          frame.viewport.maxY - frame.bottomInset - $0.frame.maxY
        }
      case .midConversation: frame.distanceBelowMiddle(of: anchor)
      }
    }

    @Test(
      "Hidden through a drag the rows are left alone; shown, one frame has them at the new width",
      arguments: ResizedReader.allCases)
    func showingTakesTheWidth(reader: ResizedReader) async throws {
      let width = PaneWidth(WidthDrive.narrow)
      let tab = TabVisibility()
      let window = try await pane(width, tab, reader: reader)
      defer { window.close() }
      let recorder = try CommittedFrames(window)
      let settled = recorder.settled
      let anchor = try #require(settled.lineAtMiddle).text
      let placed = try #require(place(of: reader, anchor: anchor, in: settled))
      // What the rows' own padding takes from the column, the same at every width.
      let padding = column(in: WidthDrive.narrow) - (try #require(settled.textSpan))

      let hiding = HangTrace.tallies()
      var hidden: [CommittedFrame] = []
      let built = RenderTally.recording {
        hidden = recorder.recording {
          tab.isHidden = true
          for turn in WidthDrive.drag.turns {
            width.value = turn.last ?? width.value
            commitFrames(for: 0.016)
          }
          commitFrames(for: 0.5)
        }
      }
      // The pane's widths went by with the rows as they were.
      #expect(hidden.last?.viewport.width == WidthDrive.wide)
      for frame in hidden {
        let span = try #require(frame.textSpan)
        #expect(abs(span + padding - column(in: WidthDrive.narrow)) < 0.5)
      }
      #expect(built["row", default: 0] == 0)
      #expect(count(Self.scrolling, since: hiding) == 0)

      let showing = HangTrace.tallies()
      let frames = recorder.recording {
        tab.isHidden = false
        commitFrames(for: 0.5)
      }
      // The frame that shows the tab has the reader back, and nothing moves after it.
      #expect(frames.count == 1)
      for frame in frames {
        // More than a screen below the top, with the rows at the pane's column.
        #expect(frame.offset > Self.height)
        let span = try #require(frame.textSpan)
        #expect(abs(span + padding - column(in: WidthDrive.wide)) < 0.5)
        let shown = try #require(place(of: reader, anchor: anchor, in: frame))
        #expect(abs(shown - placed) <= 2)
      }
      // One passage took the width, and its layout pass ended it.
      #expect(count(["transcript width"], since: showing) == 1)
      #expect(count([TranscriptScrollState.latePassage], since: showing) == 0)
    }

    @Test(
      "A tab shown at the width it hid at builds no row, and scrolls a follower back at most",
      arguments: ResizedReader.allCases, HiddenWidening.allCases)
    func showingAtTheSameWidth(reader: ResizedReader, widening: HiddenWidening) async throws {
      let width = PaneWidth(WidthDrive.narrow)
      let tab = TabVisibility()
      let window = try await pane(width, tab, reader: reader)
      defer { window.close() }
      let settled = try CommittedFrames(window).settled
      let anchor = try #require(settled.lineAtMiddle).text
      let placed = try #require(place(of: reader, anchor: anchor, in: settled))
      let before = HangTrace.tallies()

      let built = RenderTally.recording {
        // A sidebar closed and opened again while another tab shows.
        tab.isHidden = true
        for next in [widening.widest, WidthDrive.narrow] {
          width.value = next
          commitFrames(for: 0.1)
        }
        tab.isHidden = false
        commitFrames(for: 0.5)
      }
      #expect(built["row", default: 0] == 0)
      let shown = try CommittedFrames(window).settled
      #expect(shown.viewport.width == WidthDrive.narrow)
      let place = try #require(place(of: reader, anchor: anchor, in: shown))
      #expect(abs(place - placed) <= 2)
      // Narrow again, the navigator's inset is back under a follower: one scroll returns them
      // to the bottom row.
      let insetCameBack = reader == .atEnd && widening == .pastTheNavigator
      #expect(count(Self.scrolling, since: before) == (insetCameBack ? 1 : 0))
    }
  }
#endif
