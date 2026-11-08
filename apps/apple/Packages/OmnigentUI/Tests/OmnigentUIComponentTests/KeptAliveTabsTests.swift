#if os(macOS)
  import AppKit
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  /// Hidden tabs keep the size they last showed at. A pass before the window has a size must not
  /// freeze a hidden tab at nothing: its right panel then lays out at its minimum, smaller than
  /// its content, and the window's constraint passes never settle.
  @MainActor
  @Suite("Kept-alive tabs")
  struct KeptAliveTabsTests {
    private struct Tab: Identifiable {
      let id: String
    }

    /// The size each tab's content was laid out at.
    private final class Sizes {
      var byID: [String: CGSize] = [:]
    }

    private func host(shown: String, sizes: Sizes) -> NSHostingView<some View> {
      _ = NSApplication.shared
      let tabs = [Tab(id: "shown"), Tab(id: "hidden")]
      return NSHostingView(
        rootView: KeptAliveTabs(tabs, shownID: shown) { tab in
          Color.clear.onGeometryChange(for: CGSize.self) {
            $0.size
          } action: { size in
            sizes.byID[tab.id] = size
          }
        })
    }

    private func layOut(_ view: NSView, at size: CGSize) {
      view.frame = CGRect(origin: .zero, size: size)
      view.layoutSubtreeIfNeeded()
      RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    @Test func aTabHiddenBeforeTheWindowHasASizeTakesItsFirstSize() {
      let sizes = Sizes()
      let view = host(shown: "shown", sizes: sizes)
      layOut(view, at: .zero)
      layOut(view, at: CGSize(width: 800, height: 600))

      #expect(sizes.byID["shown"] == CGSize(width: 800, height: 600))
      #expect(sizes.byID["hidden"] == CGSize(width: 800, height: 600))
    }

    @Test func aHiddenTabKeepsItsSizeWhenTheWindowResizes() {
      let sizes = Sizes()
      let view = host(shown: "shown", sizes: sizes)
      layOut(view, at: CGSize(width: 800, height: 600))
      layOut(view, at: CGSize(width: 900, height: 700))

      #expect(sizes.byID["shown"] == CGSize(width: 900, height: 700))
      #expect(sizes.byID["hidden"] == CGSize(width: 800, height: 600))
    }
  }
#endif
