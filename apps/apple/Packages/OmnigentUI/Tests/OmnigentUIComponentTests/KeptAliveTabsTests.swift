#if os(macOS)
  import AppKit
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  /// Hidden tabs keep the size they last showed at. The split view lays its column out at a
  /// placeholder minimum while it sizes it; a tab mounted hidden then must not freeze there, or its
  /// right panel lays out smaller than its content and the window's constraint passes never settle.
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

    private func tabs(_ ids: [String], sizes: Sizes) -> some View {
      KeptAliveTabs(ids.map(Tab.init(id:)), shownID: "shown") { tab in
        Color.clear.onGeometryChange(for: CGSize.self) {
          $0.size
        } action: { size in
          sizes.byID[tab.id] = size
        }
      }
    }

    private func layOut(_ view: NSView, at size: CGSize) {
      view.frame = CGRect(origin: .zero, size: size)
      view.layoutSubtreeIfNeeded()
      RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    @Test func aTabMountedAfterAPlaceholderPassTakesTheColumnsSize() {
      _ = NSApplication.shared
      let sizes = Sizes()
      let column = CGSize(width: 800, height: 600)
      let view = NSHostingView(rootView: tabs(["shown"], sizes: sizes))
      layOut(view, at: .zero)
      layOut(view, at: UnmeasuredMinimum.column)
      // Another session's tabs take over, one kept hidden ahead of the shown one.
      view.rootView = tabs(["hidden", "shown"], sizes: sizes)
      layOut(view, at: column)

      #expect(sizes.byID["shown"] == column)
      #expect(sizes.byID["hidden"] == column)
    }

    @Test func aHiddenTabKeepsItsSizeWhenTheWindowResizes() {
      _ = NSApplication.shared
      let sizes = Sizes()
      let view = NSHostingView(rootView: tabs(["shown", "hidden"], sizes: sizes))
      layOut(view, at: CGSize(width: 800, height: 600))
      layOut(view, at: CGSize(width: 900, height: 700))

      #expect(sizes.byID["shown"] == CGSize(width: 900, height: 700))
      #expect(sizes.byID["hidden"] == CGSize(width: 800, height: 600))
    }
  }
#endif
