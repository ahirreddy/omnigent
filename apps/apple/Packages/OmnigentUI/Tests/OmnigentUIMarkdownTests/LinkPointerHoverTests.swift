#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents
  @testable import OmnigentUITestSupport

  @Suite("The pointer is a hand over a link", .serialized)
  @MainActor
  struct LinkPointerHoverTests {
    private static let address = "https://a.test/first"
    private static let source = "plain words [the site](\(address)) more words"

    @Test(
      "Over a link the pointer is a hand; over the text beside it, the I-beam; off it, the arrow")
    func hover() throws {
      let hosted = LinkedTextScreen(MarkdownView(Self.source).padding(40))
      defer { hosted.screen.close() }
      let areas = try #require(hosted.areas.first)
      let link = try #require(hosted.linkRects.first)
      let beside = CGPoint(x: link.minX - 30, y: link.midY)
      #expect(areas.trackingAreas.count == 1)
      #expect(areas.hitTest(areas.frame.center) == nil, "the text under it takes every click")
      let overLink = hosted.viewUnder(link.center)
      #expect(overLink is NSTextField, "clicks and menus on a link go to the text itself")
      #expect(overLink === hosted.viewUnder(beside))
      areas.mouseEntered(with: try hosted.moved(to: link.center))
      #expect(NSCursor.current == NSCursor.pointingHand)
      areas.mouseMoved(with: try hosted.moved(to: beside))
      #expect(NSCursor.current == NSCursor.iBeam, "the text beside the link selects")
      areas.mouseMoved(with: try hosted.moved(to: link.center))
      #expect(NSCursor.current == NSCursor.pointingHand)
      areas.mouseExited(with: try hosted.moved(to: CGPoint(x: link.midX, y: link.maxY + 30)))
      #expect(NSCursor.current == NSCursor.arrow, "nothing selectable is under the pointer")
      areas.mouseMoved(with: try hosted.moved(to: beside))
      #expect(NSCursor.current == NSCursor.arrow, "off a link the cursor is the text's own")
    }

    @Test("A message's link shows the hand in the chat's bubble and in the terminal view's band")
    func messageRows() throws {
      let row = TranscriptFixture.user(
        "u1", "\(Self.address) and then enough plain words after it to wrap on to a second line")
      let views = [
        AnyView(MessageRowView(row: row, decoration: MessageDecoration())),
        AnyView(CLIUserBand(row: row, decoration: MessageDecoration())),
      ]
      for view in views {
        let hosted = LinkedTextScreen(view, width: 420)
        defer { hosted.screen.close() }
        let areas = try #require(hosted.areas.first)
        let link = try #require(hosted.linkRects.first)
        areas.mouseMoved(with: try hosted.moved(to: link.center))
        #expect(NSCursor.current == NSCursor.pointingHand)
        areas.mouseMoved(with: try hosted.moved(to: CGPoint(x: link.maxX + 30, y: link.midY)))
        #expect(NSCursor.current == NSCursor.iBeam)
      }
    }

    @Test("A pointer resting on a link has the hand back as each turn ends, whoever set another")
    func turnsKeepTheHand() throws {
      let hosted = LinkedTextScreen(MarkdownView(Self.source))
      defer { hosted.screen.close() }
      let areas = try #require(hosted.areas.first)
      let link = try #require(hosted.linkRects.first)
      let resting = hosted.screen.host.convert(link.center, to: nil)
      areas.pointerLocation = { resting }
      areas.mouseMoved(with: try hosted.moved(to: link.center))
      for other in [NSCursor.arrow, NSCursor.iBeam] {
        other.set()
        hosted.screen.settle(0.05)
        #expect(NSCursor.current == NSCursor.pointingHand, "back after \(other)")
      }
    }

    @Test("Once the link is not under the pointer, a turn gives up the hand and nothing brings it")
    func turnsGiveUpTheHand() throws {
      let hosted = LinkedTextScreen(MarkdownView(Self.source))
      defer { hosted.screen.close() }
      let areas = try #require(hosted.areas.first)
      let link = try #require(hosted.linkRects.first)
      // The real pointer is nowhere near a window off every display.
      areas.mouseMoved(with: try hosted.moved(to: link.center))
      #expect(NSCursor.current == NSCursor.pointingHand)
      hosted.screen.settle(0.05)
      #expect(NSCursor.current == NSCursor.arrow)
      NSCursor.iBeam.set()
      hosted.screen.settle(0.05)
      #expect(NSCursor.current == NSCursor.iBeam)
    }

    @Test("A link under something else, or in a tab kept behind another, shows no hand")
    func coveredLink() throws {
      let text = MarkdownView(Self.source)
      let covered = LinkedTextScreen(text.overlay { Color.gray })
      defer { covered.screen.close() }
      let areas = try #require(covered.areas.first)
      areas.mouseMoved(with: try covered.moved(to: try #require(covered.linkRects.first).center))
      #expect(NSCursor.current == NSCursor.arrow)

      let hidden = LinkedTextScreen(text.opacity(0).allowsHitTesting(false))
      defer { hidden.screen.close() }
      let kept = try #require(hidden.areas.first)
      kept.mouseMoved(with: try hidden.moved(to: try #require(hidden.linkRects.first).center))
      #expect(NSCursor.current == NSCursor.arrow)
    }

    @Test("A text taken away under the pointer gives the arrow back")
    func removedUnderThePointer() throws {
      let hosted = LinkedTextScreen(MarkdownView(Self.source))
      let areas = try #require(hosted.areas.first)
      areas.mouseMoved(with: try hosted.moved(to: try #require(hosted.linkRects.first).center))
      #expect(NSCursor.current == NSCursor.pointingHand)
      hosted.screen.close()
      #expect(NSCursor.current == NSCursor.arrow)
    }

    @Test("A text that changes under the pointer finds its links again")
    func changedText() throws {
      let source = EditedValue("see \(Self.address)")
      struct Host: View {
        let source: EditedValue<String>
        var body: some View { CLISourceText(text: source.value) }
      }
      let hosted = LinkedTextScreen(Host(source: source))
      defer { hosted.screen.close() }
      let before = try #require(hosted.linkRects.first)
      source.value = "now go and see \(Self.address)"
      hosted.screen.settle()
      let after = try #require(hosted.linkRects.first)
      #expect(after.minX > before.minX + 20, "the link moved right with the words before it")
      #expect(try hosted.openedByClicking(after.center) == [Self.address])
      #expect(try hosted.openedByClicking(CGPoint(x: before.minX + 4, y: before.midY)).isEmpty)
    }

    @Test("A drag across a link selects its text and opens nothing")
    func dragSelects() throws {
      let hosted = LinkedTextScreen(MarkdownView(Self.source))
      defer { hosted.screen.close() }
      let link = try #require(hosted.linkRects.first)
      try hosted.screen.dragSelection(
        from: CGPoint(x: link.minX - 20, y: link.midY), to: CGPoint(x: link.maxX + 20, y: link.midY)
      )
      let editor = try #require(hosted.screen.window.firstResponder as? NSTextView)
      let selected = Range(editor.selectedRange(), in: editor.string).map { editor.string[$0] }
      #expect(try #require(selected).contains("the site"))
      #expect(hosted.opened.isEmpty)
    }

    @Test("A double-click on a word beside a link selects it, and the popup offers Reply")
    func selectionPopup() async throws {
      let hosted = LinkedTextScreen(
        MarkdownView(Self.source).padding(.top, 60)
          .transcriptSelectionPopup(reply: { _ in }, ask: nil))
      defer { hosted.screen.close() }
      let link = try #require(hosted.linkRects.first)
      try hosted.screen.click(CGPoint(x: link.minX - 30, y: link.midY), clickCount: 2)
      try await announceSelection(hosted.screen)
      #expect(try hosted.screen.shows("Reply"))
      #expect(hosted.opened.isEmpty)
    }
  }
#endif
