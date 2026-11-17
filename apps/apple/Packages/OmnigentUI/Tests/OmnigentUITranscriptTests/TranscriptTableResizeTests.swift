#if os(macOS) && DEBUG
  import AppKit
  import Observation
  import OmnigentViewTesting
  import QuartzCore
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents
  @testable import OmnigentUITestSupport

  /// The table transcript in a pane whose width and tab visibility a test changes.
  private struct ResizedTableHost: View {
    let conversation: LiveConversation
    let width: PaneWidth
    let tab: TabVisibility

    var body: some View {
      TableTranscriptHost(conversation: conversation, actions: ConversationActions())
        .modifier(HiddenTabContent(isHidden: tab.isHidden))
        .frame(width: width.value)
    }
  }

  /// Where the table transcript keeps its reader through a new width, a hidden tab and the bars
  /// over it.
  @Suite("Transcript table resizing", .serialized)
  @MainActor
  struct TranscriptTableResizeTests {
    private static let wide: CGFloat = 900
    private static let narrow: CGFloat = 480
    private static let height: CGFloat = 600

    /// Answers of a few long paragraphs, so a narrower pane makes every row taller.
    private func session() -> LiveConversation {
      let paragraph = String(repeating: "A reasonably long line of the answer. ", count: 30)
      let rows = (0..<30).flatMap { index in
        [
          TranscriptFixture.user("u\(index)", "Question \(index)"),
          TranscriptFixture.answer(
            "a\(index)",
            Array(repeating: paragraph, count: 1 + index % 3).joined(separator: "\n\n"),
            responseID: "r\(index)"),
        ]
      }
      return LiveConversation(ConversationViewState(header: TranscriptFixture.header, rows: rows))
    }

    private func open(_ width: PaneWidth, _ tab: TabVisibility = TabVisibility()) async throws
      -> (TranscriptScrollDriver, TranscriptTableController)
    {
      let window = transcriptScreen(
        ResizedTableHost(conversation: session(), width: width, tab: tab),
        width: Self.wide + 100, height: Self.height)
      try await letOpeningEnd(window)
      let driver = TranscriptScrollDriver(screen: window)
      let controller = try #require(driver.tableController)
      // The reader goes to the middle of the conversation, which stops following.
      let scrollView = try #require(driver.scrollView)
      window.liveScroll(scrollView, began: true)
      driver.move(to: driver.maximumOffset / 2)
      window.liveScroll(scrollView, began: false)
      window.run(for: TranscriptTableController.prefetchDelay + 0.3)
      return (driver, controller)
    }

    /// How far the middle anchor's point is from the viewport's middle, in points.
    private func drift(
      of anchor: TranscriptTableController.MiddleAnchor, _ controller: TranscriptTableController
    ) throws -> CGFloat {
      let index = try #require(controller.model.index(of: anchor.id))
      let rect = controller.tableView.rect(ofRow: index)
      return abs(rect.minY + anchor.fraction * rect.height - controller.readingMiddle)
    }

    @Test("A narrower or wider pane keeps the point under the viewport's middle there")
    func widthKeepsTheMiddle() async throws {
      let width = PaneWidth(Self.wide)
      let (driver, controller) = try await open(width)
      let window = driver.screen
      defer { window.close() }
      for next in [Self.narrow, Self.wide, Self.narrow + 120] {
        let anchor = try #require(controller.middleAnchor())
        width.value = next
        window.settle()
        #expect(abs(controller.model.width - next) < 1)
        #expect(try drift(of: anchor, controller) < 2, "at \(next)")
        #expect(!controller.follow.follows)
      }
    }

    @Test("A reader at the top stays there through a new width; one following stays at the end")
    func widthKeepsTheEnds() async throws {
      let width = PaneWidth(Self.wide)
      let (driver, controller) = try await open(width)
      let window = driver.screen
      defer { window.close() }
      driver.move(to: controller.minimumOffset)
      width.value = Self.narrow
      window.settle()
      #expect(abs(driver.offset - controller.minimumOffset) < 1)

      controller.jumpToLatest()
      window.settle()
      width.value = Self.wide
      window.settle()
      #expect(abs(driver.offset - driver.maximumOffset) < 1)
      #expect(controller.follow.follows)
    }

    @Test("A hidden tab takes no width and measures nothing; shown, it keeps the reader's place")
    func hiddenTabHoldsItsWidth() async throws {
      let width = PaneWidth(Self.wide)
      let tab = TabVisibility()
      let (driver, controller) = try await open(width, tab)
      let window = driver.screen
      defer { window.close() }
      let anchor = try #require(controller.middleAnchor())
      let measured = controller.measurements
      let hiding = HangTrace.tallies()

      tab.isHidden = true
      window.settle()
      for next in [Self.narrow, Self.narrow + 100, Self.narrow + 200] {
        width.value = next
        window.settle()
      }
      window.run(for: TranscriptTableController.prefetchDelay + 0.3)
      #expect(abs(controller.model.width - Self.wide) < 1)
      #expect(controller.measurements == measured)
      #expect(HangTrace.tallies().count("transcript width", since: hiding) == 0)

      let showing = HangTrace.tallies()
      tab.isHidden = false
      window.settle()
      #expect(abs(controller.model.width - (Self.narrow + 200)) < 1)
      #expect(HangTrace.tallies().count("transcript width", since: showing) == 1)
      #expect(try drift(of: anchor, controller) < 2)
    }

    @Test("The rows fade out across the bars over them")
    func softEdges() async throws {
      let (driver, controller) = try await open(PaneWidth(Self.wide))
      let window = driver.screen
      defer { window.close() }
      let scrollView = try #require(driver.scrollView as? TranscriptTableScrollView)
      #expect(scrollView.layer?.mask == nil)

      controller.setInsets(EdgeInsets(top: 30, leading: 0, bottom: 120, trailing: 0))
      window.settle()
      let mask = try #require(scrollView.layer?.mask as? CAGradientLayer)
      let height = Double(scrollView.bounds.height)
      let locations = try #require(mask.locations).map(\.doubleValue)
      // The layer's unit space runs up from the bottom of a view that is not flipped.
      let (first, last): (Double, Double) = scrollView.isFlipped ? (30, 120) : (120, 30)
      let expected = [0, first / height, 1 - last / height, 1]
      #expect(zip(locations, expected).allSatisfy { abs($0 - $1) < 0.001 }, "\(locations)")
      #expect(mask.colors?.count == 4)

      controller.setInsets(EdgeInsets())
      window.settle()
      #expect(scrollView.layer?.mask == nil)
    }
  }
#endif
