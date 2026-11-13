#if os(iOS)
  import OmnigentViewTesting
  import SwiftUI
  import Testing
  import UIKit

  @testable import OmnigentUIComponents

  @MainActor
  private final class Dismissals {
    var times = 0
  }

  /// The overview over a window, with what it asks the window to do recorded. Its cards sit in
  /// a scroll view, which the window can't reach into: these tests press the bar under them.
  @MainActor
  private struct Overview {
    let spy = TabSpy()
    let dismissals = Dismissals()
    let screen: InProcessWindow

    init(_ state: TabsState, tablet: Bool = false) async throws {
      let dismissals = dismissals
      let grid = TabGridOverview(
        state: state, actions: spy.actions, dismiss: { dismissals.times += 1 })
      screen = try InProcessWindow(
        grid, width: tablet ? 1024 : 393, height: tablet ? 768 : 852,
        horizontalSizeClass: tablet ? .regular : .compact)
      // The shown tab zooms out into its card before the grid takes presses.
      await screen.settle(.milliseconds(500))
    }

    /// Whether the overview asked to be removed, soon: it waits for its zoom to end.
    func dismissed() async -> Bool {
      for _ in 0..<40 where dismissals.times < 1 {
        await screen.settle(.milliseconds(50))
      }
      return dismissals.times == 1
    }
  }

  @MainActor
  @Suite("The tab overview grid on iPhone and iPad", .serialized)
  struct TabGridOverviewTests {
    private func tabs(_ count: Int) -> TabsState {
      let names = ["one", "two", "three", "four", "five", "six"].prefix(count)
      return TabsState(tabs: names.map { TabFixture.tab($0) }, selectedID: "one")
    }

    @Test("the bar under the cards counts the tabs and offers New Tab and Done")
    func bar() async throws {
      let overview = try await Overview(TabFixture.pair)
      defer { overview.screen.close() }
      let shown = overview.screen.identifiers
      for identifier in ["tab-overview-sheet", "tab-overview-new", "tab-overview-done"] {
        #expect(shown.contains(identifier), "\(identifier) is missing")
      }
      #expect(overview.screen.labels.contains("2 Tabs"))
      #expect(overview.spy.calls.isEmpty)
      #expect(overview.dismissals.times < 1)

      let tablet = try await Overview(tabs(5), tablet: true)
      defer { tablet.screen.close() }
      #expect(tablet.screen.labels.contains("5 Tabs"))
    }

    @Test("Done goes back to the shown tab without selecting it again, once its zoom ends")
    func done() async throws {
      var state = TabFixture.pair
      state.tabs.append(TabFixture.tab("kept", isClosable: false))
      let overview = try await Overview(state)
      defer { overview.screen.close() }
      #expect(overview.screen.labels.contains("3 Tabs"))
      try await overview.screen.activate("tab-overview-done")
      // While it closes, further presses do nothing.
      try await overview.screen.activate("tab-overview-done")
      #expect(await overview.dismissed())
      #expect(overview.spy.calls.isEmpty)
    }

    @Test("with no tab left to show, Done closes the overview at once")
    func doneWithNoTabs() async throws {
      let overview = try await Overview(TabsState(tabs: [], selectedID: nil))
      defer { overview.screen.close() }
      #expect(overview.screen.labels.contains("0 Tabs"))
      try await overview.screen.activate("tab-overview-done")
      #expect(overview.dismissals.times == 1)
      #expect(overview.spy.calls.isEmpty)
    }

    @Test("a shown tab that is gone from the list leaves Done to close the overview")
    func doneWithAStaleSelection() async throws {
      let overview = try await Overview(
        TabsState(tabs: [TabFixture.tab("one")], selectedID: "closed-elsewhere"))
      defer { overview.screen.close() }
      try await overview.screen.activate("tab-overview-done")
      #expect(overview.dismissals.times == 1)
      #expect(overview.spy.calls.isEmpty)
    }

    @Test("New Tab opens one and closes the overview, with or without a tab to reopen")
    func newTab() async throws {
      let overview = try await Overview(TabsState(tabs: [TabFixture.tab("one")], selectedID: "one"))
      defer { overview.screen.close() }
      #expect(overview.screen.labels.contains("1 Tab"))
      try await overview.screen.activate("tab-overview-new")
      #expect(overview.spy.calls == ["new tab"])
      #expect(overview.dismissals.times == 1)

      var state = TabFixture.pair
      state.recentlyClosed = [TabFixture.tab("gone")]
      let again = try await Overview(state)
      defer { again.screen.close() }
      try await again.screen.activate("tab-overview-new")
      #expect(again.spy.calls == ["new tab"])
      #expect(again.dismissals.times == 1)
    }
  }
#endif
