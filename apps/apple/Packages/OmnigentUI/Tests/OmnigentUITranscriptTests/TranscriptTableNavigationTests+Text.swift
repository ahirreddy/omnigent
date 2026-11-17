#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents
  @testable import OmnigentUITestSupport

  /// The keys a message's text passes on to the table transcript.
  extension TranscriptTableNavigationTests {
    @Test("A message's text with the keyboard scrolls the table for its keys, past its own row")
    func textPassesScrollingKeys() async throws {
      let window = transcriptScreen(
        TableTranscriptHost(conversation: session(turns: 12), actions: ConversationActions())
          .environment(\.messageTextRenderer, .textKit),
        width: Self.width, height: Self.height)
      defer { window.close() }
      try await letOpeningEnd(window)
      let driver = TranscriptScrollDriver(screen: window)
      let controller = try #require(driver.tableController)
      window.run(for: TranscriptTableController.prefetchDelay + 0.5)
      driver.move(to: driver.maximumOffset - 1200)
      window.settle()
      let shown = try #require(driver.scrollView).contentView.bounds
      let isShown = { (view: NSView) in
        view.convert(view.bounds, to: controller.tableView).intersects(shown)
      }
      // A run drawn ahead lays its live text over it on a press, as a click does.
      let views = window.allViews
      let text = try #require(
        views.compactMap { $0 as? MessageTextKitView }.first(where: isShown)
          ?? views.compactMap { $0 as? MessageTextRasterView }.first(where: isShown)?
          .activate().textView)
      #expect(window.window.makeFirstResponder(text))
      let start = driver.offset
      text.keyDown(with: try key(NSDownArrowFunctionKey))
      window.settle(0.05)
      #expect(abs(driver.offset - start - TranscriptTableController.keyLine) < 1)
      text.keyDown(with: try key(0x20))
      window.settle(0.05)
      #expect(driver.offset > start + 200)
      // Shift-arrows still select in the text.
      let selecting = driver.offset
      text.keyDown(with: try key(NSDownArrowFunctionKey, .shift))
      #expect(abs(driver.offset - selecting) < 1)
      // Home takes the text's row out of view; the keys still scroll.
      text.keyDown(with: try key(NSHomeFunctionKey))
      window.settle()
      #expect(abs(driver.offset - controller.minimumOffset) < 1)
      let responder = try #require(window.window.firstResponder)
      responder.keyDown(with: try key(NSEndFunctionKey))
      window.run(for: TranscriptTableController.wheelEnd + 0.1)
      #expect(abs(driver.offset - driver.maximumOffset) < 1)
    }
  }
#endif
