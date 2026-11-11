#if os(macOS) && DEBUG
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  /// The sidebar's rows and the tabs a host holds, changed from the test.
  @MainActor
  @Observable
  private final class HostContent {
    var sidebar = SidebarFixture.state
    var tabs = TabsState(tabs: [TabFixture.tab("a")], selectedID: "a")
    var search = ""
    var showsTabs = true
    /// Sets the selection a host keeps in its own state.
    @ObservationIgnored var select: (SidebarDestination?) -> Void = { _ in }
  }

  /// A shell whose host keeps the selection in its state, as the app's window root does.
  private struct SelectingShellHarness: View {
    let content: HostContent
    let actions: SidebarActions
    @State private var selection: SidebarDestination?

    var body: some View {
      AppShell(
        sidebar: content.sidebar, selection: $selection, searchText: .constant(""),
        actions: actions
      ) { destination in
        Text("detail of \(destination.map { "\($0)" } ?? "nothing")")
      }
      .onAppear { content.select = { selection = $0 } }
    }
  }

  /// Says whether the detail sits under a strip, counting each time it is told.
  private struct TitlebarProbe: View {
    @Environment(\.tabsInTitlebar) private var tabsInTitlebar

    var body: some View {
      Text(tabsInTitlebar ? "under a strip" : "no strip").countsRenders("probe")
    }
  }

  /// A shell whose host hands it the sidebar and the tabs to read, as the connected window does.
  private struct ReadingShellHarness: View {
    let content: HostContent
    let spy: SidebarSpy

    var body: some View {
      AppShell(
        sidebar: { content.sidebar },
        selection: Binding(get: { spy.selection }, set: { spy.selection = $0 }),
        searchText: { Binding(get: { content.search }, set: { content.search = $0 }) },
        actions: spy.actions,
        tabs: ShellTabs(
          isShown: { content.showsTabs }, content: { (content.tabs, TabActions()) }),
        detail: { TitlebarProbe() })
    }
  }

  extension AdaptiveShellTests {
    @Test("A session's row renders the sidebar and a tab's title the strip, not the shell")
    func hostStateRendersWhereItShows() throws {
      let content = HostContent()
      let screen = titled(
        ReadingShellHarness(content: content, spy: SidebarSpy(SidebarFixture.state)))
      defer { screen.close() }
      let forRow = RenderTally.recording {
        content.sidebar = SidebarViewState(
          list: SessionListViewState(sessions: [SidebarFixture.beta]))
        screen.settle(0.2)
      }
      #expect(forRow == ["sidebar": 1, "session row": 1], "\(forRow)")
      #expect(try screen.shows("Beta"))
      #expect(try !screen.shows("Gamma"))
      #expect(try screen.toolbarText().contains("A"))
      let forTitle = RenderTally.recording {
        content.tabs = TabsState(tabs: [TabFixture.tab("b")], selectedID: "b")
        screen.settle(0.2)
      }
      #expect(forTitle == ["strip": 1, "tab controls": 1], "\(forTitle)")
      #expect(try screen.toolbarText().contains("B"), "the strip shows the new tab")
      #expect(try !screen.toolbarText().contains("A"), "and not the one it replaced")
    }

    @Test("The selection renders the detail, which shows it, and not the shell")
    func selectionRendersTheDetail() throws {
      let content = HostContent()
      let actions = SidebarSpy(SidebarFixture.state).actions
      let screen = shell(SelectingShellHarness(content: content, actions: actions))
      defer { screen.close() }
      #expect(try screen.shows("detail of nothing"))
      let forSelection = RenderTally.recording {
        content.select(.session("beta"))
        screen.settle(0.2)
      }
      #expect(forSelection["shell"] == nil, "\(forSelection)")
      #expect(forSelection["sidebar"] == nil, "\(forSelection)")
      #expect(try screen.shows("detail of session(\"beta\")"))
    }

    @Test("A page takes the strip away without rendering it or the detail under it")
    func pageHidesTheStrip() throws {
      let content = HostContent()
      let screen = titled(
        ReadingShellHarness(content: content, spy: SidebarSpy(SidebarFixture.state)))
      defer { screen.close() }
      #expect(toolbarItems(screen).compactMap(\.view).count == 2)
      let forPage = RenderTally.recording {
        content.showsTabs = false
        screen.settle(0.3)
      }
      #expect(forPage.isEmpty, "\(forPage)")
      #expect(toolbarItems(screen).compactMap(\.view).isEmpty, "the strip and its controls left")
      #expect(try screen.shows("under a strip"), "what sits under the page is told nothing new")
      let forBack = RenderTally.recording {
        content.showsTabs = true
        screen.settle(0.3)
      }
      #expect(forBack == ["strip": 1, "tab controls": 1], "\(forBack)")
      #expect(toolbarItems(screen).compactMap(\.view).count == 2)
      #expect(try screen.toolbarText().contains("A"), "the strip is back with its tab")
    }

    @Test("The search text renders the sidebar, which shows it, and not the shell")
    func searchTextRendersTheSidebar() throws {
      let content = HostContent()
      let screen = titled(
        ReadingShellHarness(content: content, spy: SidebarSpy(SidebarFixture.state)))
      defer { screen.close() }
      let forSearch = RenderTally.recording {
        content.search = "zeta"
        screen.settle(0.2)
      }
      #expect(forSearch == ["sidebar": 1, "session row": 3, "search field": 1], "\(forSearch)")
      let fields = screen.allViews.compactMap { $0 as? NSSearchField }
      #expect(fields.map(\.stringValue) == ["zeta"], "the search field shows the host's text")
    }
  }
#endif
