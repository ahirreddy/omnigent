#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  /// How often the toolbar put each trailing item's view into the window.
  @MainActor
  private final class ItemMounts {
    var counts: [String: Int] = [:]
  }

  /// A view that counts each time it joins a window: the toolbar takes a folded item's view out
  /// and puts a shown one's in.
  private final class MountCountingView: NSView {
    var joined: () -> Void = {}

    override func viewWillMove(toWindow newWindow: NSWindow?) {
      super.viewWillMove(toWindow: newWindow)
      if newWindow != nil { joined() }
    }
  }

  private struct MountCounter: NSViewRepresentable {
    let name: String
    let mounts: ItemMounts

    func makeNSView(context: Context) -> MountCountingView {
      let view = MountCountingView()
      view.joined = { [mounts, name] in mounts.counts[name, default: 0] += 1 }
      return view
    }

    func updateNSView(_ view: MountCountingView, context: Context) {}
  }

  /// A shell whose detail has two trailing buttons and reports one, so the strip leaves room
  /// for the first and the toolbar folds the second.
  private struct TrailingItemsHarness: View {
    let mounts: ItemMounts

    var body: some View {
      AppShell(
        sidebar: SidebarFixture.state, selection: .constant(nil), searchText: .constant(""),
        actions: SidebarActions(sessions: SessionListActions()),
        tabs: (TabsState(tabs: [TabFixture.tab("a")], selectedID: "a"), TabActions())
      ) { _ in
        Text("detail")
          .preference(key: TitlebarTrailingItems.self, value: 1)
          .toolbar {
            ForEach(["first", "second"], id: \.self) { name in
              ToolbarItem(placement: .primaryAction) {
                MountCounter(name: name, mounts: mounts).frame(width: 28, height: 28)
              }
            }
          }
      }
    }
  }

  @Suite("The titlebar while the window resizes", .serialized)
  @MainActor
  struct AppShellResizeTests {
    /// The toolbar lays out at the window's new width before the detail column is measured. A
    /// strip still at its old width then leaves the trailing items too little room on the way
    /// down and too much on the way up, and the toolbar folds a shown item or shows a folded
    /// one for that one pass.
    @Test("A resize step folds no shown trailing item and shows no folded one")
    func resizeKeepsTrailingItems() throws {
      let mounts = ItemMounts()
      let screen = OffscreenWindow(
        AnyView(TrailingItemsHarness(mounts: mounts)), width: 1_100, height: 700)
      defer { screen.close() }
      screen.window.contentView = nil
      screen.window.styleMask = [.titled, .resizable, .fullSizeContentView]
      screen.host.sceneBridgingOptions = [.toolbars, .title]
      screen.window.contentView = screen.host
      screen.settle(0.5)
      // The toolbar places its items in the first pass after the window has them. A taller
      // window leaves the strip as it is.
      screen.window.setContentSize(CGSize(width: 1_100, height: 701))
      screen.settle(0.5)
      let toolbar = try #require(screen.window.toolbar)
      let shownAtRest = toolbar.items.map(\.isVisible)
      #expect(shownAtRest == [true, true, true, true, false], "the second item is folded")
      #expect(mounts.counts == ["first": 1, "second": 1])
      let strip = try #require(toolbar.items.first?.view)
      let widthAtRest = strip.frame.width

      for width in [1_040, 980, 920, 980, 1_040, 1_100] as [CGFloat] {
        screen.window.setContentSize(CGSize(width: width, height: 700))
        screen.settle(0.3)
        #expect(mounts.counts == ["first": 1, "second": 1], "at \(width)")
        #expect(toolbar.items.map(\.isVisible) == shownAtRest, "at \(width)")
        #expect(strip.frame.width == widthAtRest + width - 1_100, "at \(width)")
      }
    }
  }
#endif
