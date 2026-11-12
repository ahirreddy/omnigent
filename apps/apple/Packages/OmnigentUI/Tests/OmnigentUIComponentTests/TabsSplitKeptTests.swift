#if os(macOS)
  import AppKit
  import Observation
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  private struct KeptTab: Identifiable {
    let id: String
  }

  /// What the window shows, changed from the test.
  @MainActor
  @Observable
  private final class ShownTabs {
    var shownID = "one"
    var split: TabSplitState?
    /// The room the tabs' pages ask the titlebar to keep for their toolbar items.
    @ObservationIgnored var trailingItems: Int?
  }

  /// How often each tab's content was built.
  @MainActor
  private final class TabBuilds {
    var counts: [String: Int] = [:]
  }

  /// Draws a tab's name and whether it is hidden, the active pane or the other one.
  private struct KeptTabProbe: View {
    /// The toolbar buttons each tab's page shows: a chat's, none reported (a page that says
    /// nothing, as a terminal's) and a few.
    static let toolbarItems: [String: Int] = ["one": 9, "three": 4]

    let id: String
    let builds: TabBuilds
    @Environment(\.isActiveTabPane) private var isActive
    @Environment(\.isTabContentHidden) private var isHidden

    var body: some View {
      let probe = Text("\(id) \(isHidden ? "hidden" : isActive ? "active" : "idle")")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { builds.counts[id, default: 0] += 1 }
      if let items = Self.toolbarItems[id] {
        probe.titlebarTrailingItems(items)
      } else {
        probe
      }
    }
  }

  private struct KeptTabsHost: View {
    let shown: ShownTabs
    let builds: TabBuilds

    var body: some View {
      TabSplitView(
        ["one", "two", "three"].map(KeptTab.init(id:)), shownID: shown.shownID,
        split: shown.split, actions: TabActions()
      ) { tab in
        KeptTabProbe(id: tab.id, builds: builds)
      }
      .onPreferenceChange(TitlebarTrailingItems.self) { shown.trailingItems = $0 }
    }
  }

  /// The window's tabs stay built through a split: a pane's tab is the tab that showed whole.
  @Suite("Tabs: the split view over kept tabs", .serialized)
  @MainActor
  struct TabsSplitKeptTests {
    private func window(
      _ shown: ShownTabs, _ builds: TabBuilds, width: CGFloat = 900
    ) -> OffscreenWindow<AnyView> {
      let content = KeptTabsHost(shown: shown, builds: builds)
        .environment(TabDragTracker())
        .frame(width: width, height: 400)
      return OffscreenWindow(AnyView(content), width: width, height: 400)
    }

    @Test("Without a split the shown tab is active and the rest stay built out of sight")
    func single() throws {
      let builds = TabBuilds()
      let screen = window(ShownTabs(), builds)
      defer { screen.close() }
      #expect(try screen.shows("one active"))
      #expect(try screen.shows("two hidden"))
      #expect(try screen.shows("three hidden"))
      #expect(builds.counts == ["one": 1, "two": 1, "three": 1])
    }

    @Test("Splitting, focusing the other pane, unsplitting and switching build no tab again")
    func keepsTabsBuilt() throws {
      let shown = ShownTabs()
      let builds = TabBuilds()
      let screen = window(shown, builds)
      defer { screen.close() }

      shown.split = TabSplitState(leadingID: "one", trailingID: "two", focused: .leading)
      screen.settle(0.05)
      #expect(try screen.shows("one active"))
      #expect(try screen.shows("two idle"))
      #expect(try screen.shows("three hidden"))

      shown.split = TabSplitState(leadingID: "one", trailingID: "two", focused: .trailing)
      shown.shownID = "two"
      screen.settle(0.05)
      #expect(try screen.shows("one idle"))
      #expect(try screen.shows("two active"))

      shown.split = nil
      screen.settle(0.05)
      #expect(try screen.shows("one hidden"))
      #expect(try screen.shows("two active"))

      shown.shownID = "three"
      screen.settle(0.05)
      #expect(try screen.shows("two hidden"))
      #expect(try screen.shows("three active"))
      #expect(builds.counts == ["one": 1, "two": 1, "three": 1])
    }

    /// Lets the window update until the titlebar is asked to keep room for `items`.
    private func reserved(_ items: Int?, _ shown: ShownTabs, in screen: OffscreenWindow<AnyView>)
      -> Bool
    {
      for _ in 0..<100 where shown.trailingItems != items { screen.settle(0.02) }
      return shown.trailingItems == items
    }

    @Test("The titlebar keeps room for the focused pane's toolbar items, not the other pane's")
    func focusedPaneReservesTheTitlebar() throws {
      let shown = ShownTabs()
      let screen = window(shown, TabBuilds())
      defer { screen.close() }
      #expect(reserved(9, shown, in: screen), "the shown tab's: \(shown.trailingItems ?? -1)")

      // A page with no toolbar items of its own, focused beside the chat: the chat shows none.
      shown.split = TabSplitState(leadingID: "one", trailingID: "two", focused: .trailing)
      shown.shownID = "two"
      #expect(reserved(nil, shown, in: screen), "the chat's: \(shown.trailingItems ?? -1)")

      shown.split = TabSplitState(leadingID: "one", trailingID: "two", focused: .leading)
      shown.shownID = "one"
      #expect(reserved(9, shown, in: screen), "back in the chat: \(shown.trailingItems ?? -1)")

      // Two pages with items: the focused one's, whichever side it is on.
      shown.split = TabSplitState(leadingID: "one", trailingID: "three", focused: .trailing)
      shown.shownID = "three"
      #expect(reserved(4, shown, in: screen), "the right pane's: \(shown.trailingItems ?? -1)")
      shown.split = TabSplitState(leadingID: "one", trailingID: "three", focused: .leading)
      shown.shownID = "one"
      #expect(reserved(9, shown, in: screen), "the left pane's: \(shown.trailingItems ?? -1)")
    }

    @Test("Too narrow for both panes, the focused pane's tab shows and the other stays built")
    func narrow() throws {
      let shown = ShownTabs()
      shown.shownID = "two"
      shown.split = TabSplitState(leadingID: "one", trailingID: "two", focused: .trailing)
      let builds = TabBuilds()
      let screen = window(shown, builds, width: 500)
      defer { screen.close() }
      #expect(try screen.shows("two active"))
      #expect(try screen.shows("one hidden"))
      #expect(builds.counts == ["one": 1, "two": 1, "three": 1])
    }
  }
#endif
