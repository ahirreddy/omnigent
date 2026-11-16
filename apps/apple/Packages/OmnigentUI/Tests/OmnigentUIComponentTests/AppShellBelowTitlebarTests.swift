#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  /// Marks where SwiftUI put a view, with an AppKit view whose frame a test reads.
  private struct FrameMarker: NSViewRepresentable {
    final class MarkerView: NSView {}

    func makeNSView(context: Context) -> MarkerView { MarkerView() }
    func updateNSView(_ view: MarkerView, context: Context) {}
  }

  /// The shell with one tab in its strip, over a detail the test supplies.
  private struct ShellOver<Detail: View>: View {
    @ViewBuilder let detail: Detail

    var body: some View {
      AppShell(
        sidebar: SidebarSamples.empty, selection: .constant(nil), searchText: .constant(""),
        actions: SidebarActions(sessions: SessionListActions()),
        tabs: (TabsState(tabs: [TabFixture.tab("a")], selectedID: "a"), TabActions())
      ) { _ in
        detail
      }
    }
  }

  /// The window's tabs float over its content in the title bar. On Mac nothing in the detail is
  /// drawn under them: a page starts where they end, and a scroll view has no rows above that.
  @Suite("The Mac detail below the window's tabs", .serialized)
  @MainActor
  struct AppShellBelowTitlebarTests {
    private typealias Screen = OffscreenWindow<AnyView>

    /// The shell over `detail` in a window with a title bar, once its toolbar holds the tabs. The
    /// root takes the window's size from it: a fixed frame would overflow the title bar's inset.
    private func window(_ detail: some View) async throws -> Screen {
      let root = ShellOver { detail }
        .environment(\.flattensGlass, true)
        .transaction { $0.disablesAnimations = true }
      let screen = OffscreenWindow(AnyView(root), width: 1_100, height: 700)
      let frame = screen.window.frame
      screen.window.contentView = nil
      screen.window.styleMask = [.titled, .resizable, .fullSizeContentView]
      screen.window.setFrame(frame, display: false)
      screen.host.sceneBridgingOptions = [.toolbars, .title]
      screen.window.contentView = screen.host
      let hasTabs = await screen.waitUntil { screen.window.toolbar?.items.isEmpty == false }
      #expect(hasTabs, "the toolbar holds the tab strip")
      return screen
    }

    /// The bottom of the title bar and toolbar, in window coordinates (the origin at the bottom).
    private func tabsBottom(_ screen: Screen) -> CGFloat {
      screen.window.contentLayoutRect.maxY
    }

    private func frameInWindow(_ view: NSView) -> CGRect {
      view.convert(view.bounds, to: nil)
    }

    /// Whether `top` is where the tabs end: below them by the one pixel that keeps a page out
    /// of the title bar's safe area, and no more.
    private func startsAtTheTabs(_ top: CGFloat?, _ screen: Screen) -> Bool {
      guard let top else { return false }
      let bottom = tabsBottom(screen)
      return top < bottom && bottom - top <= 1
    }

    /// Waits for `top` to be where the tabs end, and says where it is if it never gets there.
    private func expectAtTheTabs(
      _ screen: Screen, _ what: String, top: @MainActor () -> CGFloat?
    ) async throws {
      let arrived = await screen.waitUntil { startsAtTheTabs(top(), screen) }
      let found = top().map { "\($0)" } ?? "nothing"
      #expect(arrived, "\(what): its top \(found), the tabs' bottom \(tabsBottom(screen))")
    }

    /// The marker the detail shows: the shell also builds its detail to measure it.
    private func marker(_ screen: Screen) -> NSView? {
      let markers = screen.drawnViews.filter { $0 is FrameMarker.MarkerView }
      return markers.max { $0.frame.width < $1.frame.width }
    }

    /// The detail's scroll view: the tallest one beside the sidebar, which has its own.
    private func detailScrollView(_ screen: Screen) -> NSScrollView? {
      let beside = screen.drawnViews.compactMap { $0 as? NSScrollView }.filter {
        frameInWindow($0).minX >= AppShellMetrics.sidebarMinWidth
      }
      return beside.max { $0.frame.height < $1.frame.height }
    }

    private func top(_ view: NSView?) -> CGFloat? {
      view.map { frameInWindow($0).maxY }
    }

    @Test("The toolbar floats over the top of the content, as the app's does")
    func toolbarCoversTheContent() async throws {
      let screen = try await window(Color.clear)
      defer { screen.close() }
      let covers = await screen.waitUntil {
        frameInWindow(screen.host).maxY - tabsBottom(screen) > 40
      }
      #expect(covers, "by a title bar and a toolbar's height: \(tabsBottom(screen))")
    }

    @Test("A page ends where the tabs do, even one that ignores the safe area")
    func pageStopsAtTheTabs() async throws {
      let screen = try await window(FrameMarker().ignoresSafeArea())
      defer { screen.close() }
      try await expectAtTheTabs(screen, "the page") { top(marker(screen)) }
      let page = frameInWindow(try #require(marker(screen)))
      #expect(page.minY < 0.5, "and it still reaches the window's bottom")
    }

    @Test("A scroll view starts where the tabs end, with no inset and its first row at its top")
    func scrollViewStartsAtTheTabs() async throws {
      let screen = try await window(ScrollView { Color.clear.frame(height: 3_000) })
      defer { screen.close() }
      try await expectAtTheTabs(screen, "the scroll view") { top(detailScrollView(screen)) }
      let scroll = try #require(detailScrollView(screen))
      #expect(scroll.contentInsets.top == 0, "no room is kept for a bar it isn't under")
      let rows = try #require(scroll.documentView)
      #expect(abs(frameInWindow(rows).maxY - frameInWindow(scroll).maxY) < 0.5, "the first row")

      // Scrolled, its rows leave at the tabs' edge: the scroll view still ends there.
      scroll.contentView.scroll(to: CGPoint(x: 0, y: 500))
      let scrolled = await screen.waitUntil {
        frameInWindow(rows).maxY > tabsBottom(screen)
      }
      #expect(scrolled, "the rows moved up")
      #expect(startsAtTheTabs(top(scroll), screen))
    }

    @Test("The transcript's scroll view starts where the tabs end, and its first row shows there")
    func transcriptStartsAtTheTabs() async throws {
      // Short enough to sit at the top with nothing to scroll.
      let rows = [TranscriptFixture.user("u", "Question"), TranscriptFixture.answer("a", "Answer")]
      let conversation = LiveConversation(
        ConversationViewState(header: TranscriptFixture.header, rows: rows))
      let screen = try await window(
        LiveTranscriptHost(conversation: conversation, actions: ConversationActions())
          .environment(\.layoutWidth, .regular))
      defer { screen.close() }
      try await expectAtTheTabs(screen, "the transcript") { top(detailScrollView(screen)) }
      let scroll = try #require(detailScrollView(screen))
      #expect(scroll.contentInsets.top == 0)
      try await expectAtTheTabs(screen, "the transcript's rows") { top(scroll.documentView) }
    }
  }
#endif
