#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents
  @testable import OmnigentUITestSupport

  /// The pointer over a TextKit message's link, as ``LinkPointerHoverTests`` checks a `Text`'s.
  @Suite("The pointer is a hand over a TextKit message's link", .serialized)
  @MainActor
  struct MessageTextLinkPointerTests {
    private static let address = "https://a.test/first"
    private static let source = "plain words [the site](\(address)) more words"

    /// A hosted message, its text view and its link, from the screen's top left.
    private struct Hosted {
      let screen: LinkedTextScreen
      let text: MessageTextKitView
      let link: CGRect
    }

    private func host(_ view: some View) throws -> Hosted {
      let hosted = LinkedTextScreen(view.environment(\.messageTextRenderer, .textKit))
      // The hand is kept up only in the key window, where the pointer's moves are tracked.
      hosted.screen.window.makeKey()
      let content = try #require(MessageTextFixture.contentViews(in: hosted.screen).first)
      let rect = try #require(content.linkRects.first).rect
      return Hosted(
        screen: hosted, text: content.textView,
        link: content.textView.convert(rect, to: hosted.screen.host))
    }

    @Test("Over a link the hand; beside it, the I-beam; off the text, the arrow")
    func hover() throws {
      let found = try host(MessageMarkdown(text: Self.source).padding(40))
      let (hosted, text, link) = (found.screen, found.text, found.link)
      defer { hosted.screen.close() }
      let beside = CGPoint(x: link.minX - 30, y: link.midY)
      text.mouseMoved(with: try hosted.moved(to: link.center))
      #expect(NSCursor.current == NSCursor.pointingHand)
      text.mouseMoved(with: try hosted.moved(to: beside))
      #expect(NSCursor.current == NSCursor.iBeam, "the text beside the link selects")
      text.mouseMoved(with: try hosted.moved(to: link.center))
      #expect(NSCursor.current == NSCursor.pointingHand)
      text.mouseMoved(with: try hosted.moved(to: link.center))
      text.mouseMoved(with: try hosted.moved(to: CGPoint(x: link.midX, y: link.maxY + 300)))
      #expect(NSCursor.current == NSCursor.arrow, "nothing selectable is under the pointer")
    }

    @Test("A pointer resting on a link has the hand back as each turn ends, whoever set another")
    func turnsKeepTheHand() throws {
      let found = try host(MessageMarkdown(text: Self.source))
      let (hosted, text, link) = (found.screen, found.text, found.link)
      defer { hosted.screen.close() }
      let resting = hosted.screen.host.convert(link.center, to: nil)
      text.pointerLocation = { resting }
      text.mouseMoved(with: try hosted.moved(to: link.center))
      #expect(text.turns.isWatching, "each turn's end is watched while on the link")
      for other in [NSCursor.arrow, NSCursor.iBeam] {
        other.set()
        // A test's loop never sleeps, so the turn ends here.
        text.turns.endTurn()
        #expect(NSCursor.current == NSCursor.pointingHand, "back after \(other)")
      }
    }

    @Test("Once the link is not under the pointer, a turn gives up the hand and nothing brings it")
    func turnsGiveUpTheHand() throws {
      let found = try host(MessageMarkdown(text: Self.source))
      let (hosted, text, link) = (found.screen, found.text, found.link)
      defer { hosted.screen.close() }
      text.mouseMoved(with: try hosted.moved(to: link.center))
      #expect(NSCursor.current == NSCursor.pointingHand)
      // The pointer has gone far from the window by the turn's end.
      text.pointerLocation = { CGPoint(x: -10_000, y: -10_000) }
      text.turns.endTurn()
      #expect(NSCursor.current == NSCursor.arrow)
      #expect(!text.isOverLinkNow && !text.turns.isWatching)
      NSCursor.iBeam.set()
      text.turns.endTurn()
      hosted.screen.settle(0.05)
      #expect(NSCursor.current == NSCursor.iBeam)
    }

    @Test("A link under something else shows no hand")
    func coveredLink() throws {
      let found = try host(MessageMarkdown(text: Self.source).overlay { Color.gray })
      let (hosted, text, link) = (found.screen, found.text, found.link)
      defer { hosted.screen.close() }
      text.mouseMoved(with: try hosted.moved(to: link.center))
      #expect(NSCursor.current == NSCursor.arrow)
    }

    @Test("A text taken away under the pointer gives the arrow back")
    func removedUnderThePointer() throws {
      let found = try host(MessageMarkdown(text: Self.source))
      let (hosted, text, link) = (found.screen, found.text, found.link)
      text.mouseMoved(with: try hosted.moved(to: link.center))
      #expect(NSCursor.current == NSCursor.pointingHand)
      hosted.screen.close()
      #expect(NSCursor.current == NSCursor.arrow)
    }
  }
#endif
