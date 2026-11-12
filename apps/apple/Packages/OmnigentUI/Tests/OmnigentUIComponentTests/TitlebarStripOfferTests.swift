#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  /// The toolbar folds away a strip too wide for it and does not fit it again when it narrows.
  @Suite("Titlebar strip: a strip the toolbar left out", .serialized)
  @MainActor
  struct TitlebarStripOfferTests {
    /// Runs the main run loop until `condition` holds, for at most `seconds`.
    private func wait(_ seconds: TimeInterval, until condition: () -> Bool) {
      let deadline = Date().addingTimeInterval(seconds)
      while !condition(), Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
      }
    }

    /// A strip whose toolbar is on screen and has folded it away, as far as it can tell.
    private func foldedAnchor(_ space: TitlebarStripSpace) -> TitlebarStripAnchorView {
      let anchor = TitlebarStripAnchorView()
      anchor.space = space
      anchor.isFoldedOnScreen = { _ in true }
      return anchor
    }

    /// Sizes the strip wide, then narrower, as the launch's settling columns do.
    private func narrow(_ anchor: TitlebarStripAnchorView, _ space: TitlebarStripSpace) {
      for width in [1_052.0, 768.0] {
        space.detailWidth = width
        anchor.sizeItem()
      }
    }

    @Test("A strip that narrowed outside the toolbar is offered again, once, after it settles")
    func offeredAgainOutsideTheToolbar() {
      TitlebarStripAnchorView.offerDelay = 0.05
      defer { TitlebarStripAnchorView.offerDelay = 0.3 }
      let space = TitlebarStripSpace()
      let anchor = foldedAnchor(space)
      // The launch's passing widths: each change puts the offer off.
      for width in [240.0, 1052.0, 768.0] {
        space.detailWidth = width
        anchor.sizeItem()
      }
      #expect(space.stripOffer == 0)
      wait(5) { space.stripOffer > 0 }
      #expect(space.stripOffer == 1)
      wait(0.3) { space.stripOffer > 1 }
      #expect(space.stripOffer == 1, "one offer per settled width")

      // The offer made a new strip. Left out at the same width, or a wider one, it is not
      // offered again: a window too narrow for the strip would rebuild its toolbar without end.
      let offered = foldedAnchor(space)
      offered.sizeItem()
      space.detailWidth = 1_200
      offered.sizeItem()
      wait(0.3) { space.stripOffer > 1 }
      #expect(space.stripOffer == 1)
      // Narrower again is a new chance to fit.
      space.detailWidth = 900
      offered.sizeItem()
      wait(5) { space.stripOffer > 1 }
      #expect(space.stripOffer == 2)
    }

    @Test("A strip in a window, one taken down, or one no toolbar folded is not offered again")
    func notOfferedInAWindow() {
      TitlebarStripAnchorView.offerDelay = 0.05
      defer { TitlebarStripAnchorView.offerDelay = 0.3 }
      let space = TitlebarStripSpace()
      let screen = OffscreenWindow(Color.clear, width: 300, height: 100)
      defer { screen.close() }
      let anchor = foldedAnchor(space)
      narrow(anchor, space)
      // It reaches a window before the wait is over.
      screen.host.addSubview(anchor)
      narrow(anchor, space)
      wait(0.3) { space.stripOffer > 0 }
      #expect(space.stripOffer == 0)

      let removed = foldedAnchor(space)
      narrow(removed, space)
      removed.cancelOffer()
      wait(0.3) { space.stripOffer > 0 }
      #expect(space.stripOffer == 0)

      // No toolbar on screen holds this one, so nothing folded it away.
      let unhosted = TitlebarStripAnchorView()
      unhosted.space = space
      narrow(unhosted, space)
      wait(0.3) { space.stripOffer > 0 }
      #expect(space.stripOffer == 0)
    }
  }
#endif
