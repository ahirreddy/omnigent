#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents
  @testable import OmnigentUITestSupport

  /// Selecting in a message drawn with TextKit: across paragraphs, and with the Reply popup.
  @MainActor
  @Suite("Selecting a TextKit message", .serialized)
  struct MessageTextSelectionTests {
    private static let markdown = """
      Characteristically deliberate paragraphs wrapping across several lines demonstrate \
      where selection popups belong.

      A second paragraph follows the first.
      """

    /// The message alone, or in an answer's row (which the keyboard can focus), in a scrolling
    /// transcript with the Reply popup.
    private func host(inRow: Bool = false, reply: @escaping @MainActor (String) -> Void)
      -> OffscreenWindow<AnyView>
    {
      let message =
        inRow
        ? AnyView(
          MessageRowView(
            row: TranscriptFixture.answer("a1", Self.markdown), decoration: MessageDecoration()))
        : AnyView(MessageMarkdown(text: Self.markdown))
      let screen = transcriptScreen(
        ScrollView {
          message
            .environment(\.messageTextRenderer, .textKit)
            .padding(.top, 60).padding(.horizontal, 40)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .transcriptSelectionPopup(reply: reply, ask: nil),
        width: 520, height: 400)
      restKeyboard(screen)
      return screen
    }

    @Test(
      "Double-clicking a word offers Reply above it, which quotes the word and ends the selection",
      arguments: [false, true])
    func replyToWord(inRow: Bool) async throws {
      let log = HostLog()
      let screen = host(inRow: inRow) { log.add($0) }
      defer { screen.close() }
      let content = try #require(MessageTextFixture.contentViews(in: screen).first)
      let text = content.textView
      #expect(text.textLayoutManager != nil, "TextKit 2")
      let word = try #require(
        SelectionWatcher.WatcherView.containerBounds(of: NSRange(location: 0, length: 5), in: text))
      let point = text.convert(CGPoint(x: word.midX, y: word.midY), to: screen.host)
      try screen.click(point, clickCount: 2)
      try await announceSelection(screen)
      #expect(screen.window.firstResponder === text)
      #expect(try screen.shows("Reply"))
      let popup = try #require(screen.controlFrames.first)
      #expect(popup.maxY <= point.y, "above the word: \(popup) over \(point)")
      try screen.clickControl(at: 0)
      #expect(log.entries == ["Characteristically"])
      try await letTasksRun(screen)
      #expect(try !screen.shows("Reply"))
      #expect(text.selectedRange().length == 0, "the selection ends with the reply")
      #expect(text.textLayoutManager != nil, "still TextKit 2")
    }

    @Test("A selection crosses paragraphs, copies as plain text, and a click elsewhere ends it")
    func acrossParagraphs() async throws {
      let screen = host { _ in }
      defer { screen.close() }
      let content = try #require(MessageTextFixture.contentViews(in: screen).first)
      let text = content.textView
      screen.window.makeFirstResponder(text)
      text.setSelectedRange(NSRange(location: 0, length: text.string.utf16.count))
      try await announceSelection(screen)
      #expect(try screen.shows("Reply"))
      let pasteboard = SystemSideEffects.pasteboard
      #expect(text.writeSelection(to: pasteboard, types: text.writablePasteboardTypes))
      let copied = try #require(pasteboard.string(forType: .string))
      #expect(copied.contains("belong.\nA second paragraph"))
      #expect(pasteboard.data(forType: .rtf) == nil, "plain text only")
      screen.window.makeFirstResponder(nil)
      try await announceSelection(screen)
      #expect(try !screen.shows("Reply"))
      #expect(text.selectedRange().length == 0)
    }

    @Test("Copy and Reply leave a list's markers and a code block's header line out")
    func copiesWithoutMarkers() async throws {
      let log = HostLog()
      let markdown = "Intro.\n\n- first\n- [x] second\n\n```swift\nlet a = 1\n```"
      let screen = transcriptScreen(
        ScrollView {
          MessageMarkdown(text: markdown).environment(\.messageTextRenderer, .textKit)
            .padding(.top, 60).padding(.horizontal, 40)
        }
        .transcriptSelectionPopup(reply: { log.add($0) }, ask: nil),
        width: 520, height: 400)
      defer { screen.close() }
      restKeyboard(screen)
      let text = try #require(MessageTextFixture.contentViews(in: screen).first).textView
      screen.window.makeFirstResponder(text)
      text.setSelectedRange(NSRange(location: 0, length: text.string.utf16.count))
      try await announceSelection(screen)
      let expected = "Intro.\nfirst\nsecond\nlet a = 1"
      let pasteboard = SystemSideEffects.pasteboard
      #expect(text.writeSelection(to: pasteboard, types: text.writablePasteboardTypes))
      #expect(pasteboard.string(forType: .string) == expected)
      try screen.clickControl(at: 0)
      #expect(log.entries == [expected])
    }

    /// The menu a real right click at `point` opens, closed as soon as it tracks.
    private func rightClickMenu(_ screen: OffscreenWindow<AnyView>, at point: CGPoint) throws
      -> NSMenu?
    {
      nonisolated(unsafe) var opened: NSMenu?
      let observer = NotificationCenter.default.addObserver(
        forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil
      ) { note in
        nonisolated(unsafe) let menu = note.object as? NSMenu
        unsafe opened = menu
        let tracking = CFRunLoopMode(RunLoop.Mode.eventTracking.rawValue as CFString)
        CFRunLoopPerformBlock(CFRunLoopGetMain(), tracking.rawValue) {
          MainActor.assumeIsolated { unsafe menu?.cancelTrackingWithoutAnimation() }
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
      }
      defer { NotificationCenter.default.removeObserver(observer) }
      let event = try #require(
        NSEvent.mouseEvent(
          with: .rightMouseDown, location: screen.host.convert(point, to: nil),
          modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
          windowNumber: screen.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
          pressure: 1))
      screen.window.makeKey()
      screen.window.sendEvent(event)
      screen.settle()
      return unsafe opened
    }

    @Test("A right click with nothing selected opens the row's menu; on a selection, the text's")
    func rightClick() throws {
      let row = TranscriptFixture.answer("a1", "Some words to right click on, in a row.")
      let screen = transcriptScreen(
        MessageRowView(row: row, decoration: MessageDecoration())
          .environment(\.messageTextRenderer, .textKit), width: 600, height: 300)
      defer { screen.close() }
      let text = try #require(MessageTextFixture.contentViews(in: screen).first).textView
      let point = text.convert(CGPoint(x: 12, y: 8), to: screen.host)
      let rowMenu = try #require(try rightClickMenu(screen, at: point), "no menu opened")
      let rowTitles = rowMenu.items.map(\.title)
      #expect(rowTitles.contains("Copy Message ID"), "\(rowTitles)")
      screen.window.makeFirstResponder(text)
      text.setSelectedRange(NSRange(location: 0, length: 4))
      let textMenu = try #require(try rightClickMenu(screen, at: point), "no menu opened")
      let textTitles = textMenu.items.map(\.title)
      #expect(
        textTitles.contains("Copy") && !textTitles.contains("Copy Message ID"), "\(textTitles)")
    }

    @Test("An answer row draws its text in one TextKit view with the TextKit renderer")
    func messageRow() throws {
      let row = TranscriptFixture.answer("a1", "First paragraph.\n\n- an item\n\nLast paragraph.")
      let screen = transcriptScreen(
        MessageRowView(row: row, decoration: MessageDecoration())
          .environment(\.messageTextRenderer, .textKit), width: 600, height: 300)
      defer { screen.close() }
      let texts = MessageTextFixture.contentViews(in: screen).map(\.textView.string)
      #expect(texts == ["First paragraph.\n\t•\tan item\nLast paragraph."])
      let user = TranscriptFixture.user("u1", "A short question")
      let bubble = transcriptScreen(
        MessageRowView(row: user, decoration: MessageDecoration())
          .environment(\.messageTextRenderer, .textKit), width: 600, height: 300)
      defer { bubble.close() }
      let prompt = try #require(MessageTextFixture.contentViews(in: bubble).first)
      #expect(prompt.textView.string == "A short question")
      #expect(prompt.bounds.width < 200, "the bubble hugs its text: \(prompt.bounds)")
    }
  }
#endif
