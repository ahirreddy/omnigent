#if os(macOS) && DEBUG
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing
  import os

  @testable import OmnigentUIComponents
  @testable import OmnigentUITestSupport

  /// What a scroll renders. Scrolling over rows already built renders none of the transcript,
  /// its row list or its rows: the scroll state, the visible rows and the pills' trackers are not
  /// observed. Nor does it update the AppKit views of the rows' text: selectable texts and links'
  /// pointer areas. The rail's ticks follow the active turn, and Jump to latest renders the
  /// transcript once as it shows or hides, however many steps the scroll takes.
  @Suite("Transcript scroll churn", .serialized)
  @MainActor
  struct TranscriptScrollChurnTests {
    private static let width: CGFloat = 900
    private static let height: CGFloat = 700
    private static let turns = 120
    /// Steps each way, and how far each moves: about a screen and a half.
    private static let steps = 30
    private static let step: CGFloat = 40
    /// The scopes a scroll over built rows may not render.
    private static let transcriptScopes = ["transcript", "rows", "row", "markdown"]

    /// A long conversation over a dock, opened at its newest row and following it.
    private func open(rows: [Row] = TranscriptFixture.turns(Self.turns))
      async throws -> (OffscreenWindow<AnyView>, TranscriptScrollDriver)
    {
      // These start from where the opening leaves the reader; its framing wait runs a tenth as long.
      Theme.Timing.scale = 0.1
      defer { Theme.Timing.scale = 1 }
      let conversation = LiveConversation(
        ConversationViewState(header: TranscriptFixture.header, rows: rows))
      let window = transcriptScreen(
        DockedTranscriptHost(
          conversation: conversation, pane: TranscriptPane(width: Self.width, dock: 68)),
        width: Self.width, height: Self.height)
      window.settle(0.5)
      try await letOpeningEnd(window)
      return (window, TranscriptScrollDriver(screen: window))
    }

    /// Moves the transcript ``steps`` steps of `step` points, laying each one out.
    private func scroll(_ viewport: TranscriptScrollDriver, by step: CGFloat) {
      for _ in 0..<Self.steps { viewport.move(to: viewport.offset + step) }
    }

    /// Down and back up over the same rows.
    private func scrollDownAndBack(_ viewport: TranscriptScrollDriver) {
      scroll(viewport, by: Self.step)
      scroll(viewport, by: -Self.step)
    }

    /// The scopes in `renders` that a scroll over built rows may not render.
    private func transcriptRenders(_ renders: [String: Int]) -> [String: Int] {
      renders.filter { Self.transcriptScopes.contains($0.key) }
    }

    @Test("A gesture over built rows renders no transcript, list or row; the rail follows")
    func gestureRendersNothing() async throws {
      let (window, viewport) = try await open()
      defer { window.close() }
      let scrollView = try #require(viewport.scrollView)
      window.liveScroll(scrollView, began: true)
      viewport.move(to: viewport.maximumOffset / 2)
      // Builds the rows the steps pass over.
      scrollDownAndBack(viewport)

      let before = HangTrace.tallies()
      let renders = RenderTally.recording {
        scrollDownAndBack(viewport)
        window.liveScroll(scrollView, began: false)
      }
      #expect(transcriptRenders(renders).isEmpty, "\(renders)")
      // A screen and a half passes several turns under the middle.
      #expect(HangTrace.tallies().count("turn rail active", since: before) >= 2)
    }

    @Test("Steps with no gesture over built rows render no transcript, list or row")
    func wheelRendersNothing() async throws {
      let (window, viewport) = try await open()
      defer { window.close() }
      let scrollView = try #require(viewport.scrollView)
      // A gesture away from the bottom stops following, so the steps below move the reader.
      window.liveScroll(scrollView, began: true)
      viewport.move(to: viewport.maximumOffset / 2)
      window.liveScroll(scrollView, began: false)
      scrollDownAndBack(viewport)

      let before = HangTrace.tallies()
      let renders = RenderTally.recording { scrollDownAndBack(viewport) }
      #expect(transcriptRenders(renders).isEmpty, "\(renders)")
      #expect(HangTrace.tallies().count("turn rail active", since: before) >= 2)
    }

    @Test("Steps over built rows of links, tables and code update no AppKit view of their text")
    func linkedRowsUpdateNoTextViews() async throws {
      let (window, viewport) = try await open(rows: TranscriptBenchmarks.rows(turns: 40))
      defer { window.close() }
      let scrollView = try #require(viewport.scrollView)
      window.liveScroll(scrollView, began: true)
      viewport.move(to: viewport.maximumOffset / 2)
      scrollDownAndBack(viewport)

      var renders: [String: Int] = [:]
      let textUpdates = try SelectableTextUpdates.recording {
        renders = RenderTally.recording { scrollDownAndBack(viewport) }
      }
      window.liveScroll(scrollView, began: false)
      // Each step moves the links' layout anchors; their pointer areas keep the same value.
      #expect(renders["link areas", default: 0] == 0, "\(renders)")
      #expect(textUpdates == 0, "selectable texts were handed their string again")

      // A link on screen still turns the pointer into a hand.
      let shown = scrollView.contentView.convert(scrollView.contentView.bounds, to: nil)
        .insetBy(dx: 0, dy: 100)
      let onScreen = window.allViews.compactMap { $0 as? LinkPointerAreas.AreasView }.lazy
        .compactMap { areas -> (LinkPointerAreas.AreasView, CGPoint)? in
          guard let link = areas.linkRects.first else { return nil }
          let center = areas.convert(CGPoint(x: link.midX, y: link.midY), to: nil)
          return shown.contains(center) ? (areas, center) : nil
        }.first
      let (areas, location) = try #require(onScreen)
      let moved = try #require(
        NSEvent.mouseEvent(
          with: .mouseMoved, location: location, modifierFlags: [],
          timestamp: ProcessInfo.processInfo.systemUptime,
          windowNumber: window.window.windowNumber, context: nil, eventNumber: 1, clickCount: 0,
          pressure: 0))
      NSCursor.arrow.set()
      areas.mouseMoved(with: moved)
      #expect(NSCursor.current == NSCursor.pointingHand)
    }

    @Test("Leaving the bottom and coming back renders the transcript once each way, for the pill")
    func pillRendersOnce() async throws {
      let (window, viewport) = try await open()
      defer { window.close() }
      let scrollView = try #require(viewport.scrollView)
      viewport.move(to: viewport.maximumOffset)
      #expect(try !window.shows("Jump to latest"))
      // The transcript's body reads the pill: opening's framing measures the rows that render
      // lays out, so the pill stays there.
      let once = ["transcript": 1, "rows": 1]
      // Builds the rows the steps pass over, and comes back to the end.
      window.liveScroll(scrollView, began: true)
      scroll(viewport, by: -Self.step)
      scroll(viewport, by: Self.step)
      viewport.move(to: viewport.maximumOffset)
      window.liveScroll(scrollView, began: false)
      #expect(try !window.shows("Jump to latest"))

      let leaving = RenderTally.recording {
        window.liveScroll(scrollView, began: true)
        scroll(viewport, by: -Self.step)
        window.liveScroll(scrollView, began: false)
      }
      #expect(
        transcriptRenders(leaving).allSatisfy { $0.value <= once[$0.key, default: 0] },
        "\(leaving)")
      #expect(try window.shows("Jump to latest"))

      let returning = RenderTally.recording {
        window.liveScroll(scrollView, began: true)
        scroll(viewport, by: Self.step)
        viewport.move(to: viewport.maximumOffset)
        window.liveScroll(scrollView, began: false)
      }
      #expect(
        transcriptRenders(returning).allSatisfy { $0.value <= once[$0.key, default: 0] },
        "\(returning)")
      #expect(try !window.shows("Jump to latest"))
    }

    /// The top of the transcript, where Jump to top shows, as drawn now.
    private func topEdge(of window: OffscreenWindow<AnyView>) throws -> [UInt32] {
      let rendered = try RenderSupport.capture(window.host)
      let pixels = try #require(RenderSupport.Pixels(rendered.image))
      let scale = CGFloat(pixels.width) / window.host.bounds.width
      let columns = Int((Self.width / 2 - 20) * scale)..<Int((Self.width / 2 + 20) * scale)
      return (0..<Int(48 * scale)).flatMap { row in columns.map { pixels.key($0, row) } }
    }

    @Test("A run of scrolls up shows Jump to top with one wait to hide it, not one a step")
    func scrollUpWaitsOnce() async throws {
      let (window, viewport) = try await open()
      defer { window.close() }
      let scrollView = try #require(viewport.scrollView)
      Theme.Timing.scale = 0.1
      defer { Theme.Timing.scale = 1 }
      let reveal = Double(JumpToTopReveal.scrollReveal.components.seconds) * Theme.Timing.scale
      let waits = OSAllocatedUnfairLock(initialState: 0)
      let observer = NotificationCenter.default.addObserver(
        forName: Theme.Timing.pauseBegan, object: nil, queue: nil
      ) { note in
        guard let seconds = note.userInfo?[Theme.Timing.secondsKey] as? Double else { return }
        if abs(seconds - reveal) < 0.001 { waits.withLock { $0 += 1 } }
      }
      defer { NotificationCenter.default.removeObserver(observer) }

      window.liveScroll(scrollView, began: true)
      scroll(viewport, by: -Self.step)
      let revealed = try topEdge(of: window)
      window.liveScroll(scrollView, began: false)
      try await letTasksRun(window, milliseconds: 100)
      #expect(waits.withLock { $0 } == 1)

      // The pill goes once the reader has not scrolled up for the reveal's time.
      try await Task.sleep(for: .seconds(reveal * 2))
      try await letTasksRun(window)
      #expect(try topEdge(of: window) != revealed)
    }
  }
#endif
