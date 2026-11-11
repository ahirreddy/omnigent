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
  /// drawn under them: a page starts where they end, and a scroll view clips its rows there.
  @Suite("The Mac detail below the window's tabs", .serialized)
  @MainActor
  struct AppShellBelowTitlebarTests {
    /// The shell over `detail` in a window with a title bar and toolbar, as the app's has.
    private func window(_ detail: some View) -> OffscreenWindow<AnyView> {
      let screen = transcriptScreen(ShellOver { detail }, width: 1_100, height: 700)
      let frame = screen.window.frame
      screen.window.contentView = nil
      screen.window.styleMask = [.titled, .resizable, .fullSizeContentView]
      screen.window.setFrame(frame, display: false)
      screen.host.sceneBridgingOptions = [.toolbars, .title]
      screen.window.contentView = screen.host
      screen.settle(0.5)
      return screen
    }

    /// The bottom of the title bar and toolbar, in window coordinates (the origin at the bottom).
    private func tabsBottom(_ screen: OffscreenWindow<AnyView>) throws -> CGFloat {
      let bottom = screen.window.contentLayoutRect.maxY
      let top = screen.host.convert(screen.host.bounds, to: nil).maxY
      try #require(bottom < top, "the toolbar floats over the top of the content")
      return bottom
    }

    private func frameInWindow(_ view: NSView) -> CGRect {
      view.convert(view.bounds, to: nil)
    }

    private func marker(_ screen: OffscreenWindow<AnyView>) throws -> NSView {
      try #require(screen.allViews.first { $0 is FrameMarker.MarkerView })
    }

    /// The detail's scroll view: the tallest one beside the sidebar, which has its own.
    private func detailScrollView(_ screen: OffscreenWindow<AnyView>) throws -> NSScrollView {
      let beside = screen.allViews.compactMap { $0 as? NSScrollView }.filter {
        frameInWindow($0).minX >= AppShellMetrics.sidebarMinWidth
      }
      return try #require(beside.max { $0.frame.height < $1.frame.height })
    }

    @Test("A page ends where the tabs do, even one that ignores the safe area")
    func pageStopsAtTheTabs() throws {
      let screen = window(FrameMarker().ignoresSafeArea())
      defer { screen.close() }
      let bottom = try tabsBottom(screen)
      let page = frameInWindow(try marker(screen))
      #expect(abs(page.maxY - bottom) < 0.5, "the page's top \(page.maxY), the tabs' \(bottom)")
      #expect(page.minY < 0.5, "and it still reaches the window's bottom")
    }

    @Test("A scroll view starts where the tabs end, with its first row whole")
    func scrollViewStartsAtTheTabs() throws {
      let rowHeight: CGFloat = 40
      let screen = window(
        ScrollView {
          VStack(spacing: 0) {
            FrameMarker().frame(height: rowHeight)
            Color.clear.frame(height: 3_000)
          }
        })
      defer { screen.close() }
      let bottom = try tabsBottom(screen)
      let firstRow = try marker(screen)
      let scroll = try #require(firstRow.enclosingScrollView)
      #expect(abs(frameInWindow(scroll).maxY - bottom) < 0.5, "the scroll view's frame")
      #expect(abs(frameInWindow(firstRow).maxY - bottom) < 0.5, "the first row's top")
      #expect(firstRow.visibleRect.height == rowHeight, "none of the first row is clipped")
    }

    @Test("The transcript's scroll view starts where the tabs end, and its first row shows there")
    func transcriptStartsAtTheTabs() async throws {
      // Short enough to sit at the top with nothing to scroll.
      let rows = [TranscriptFixture.user("u", "Question"), TranscriptFixture.answer("a", "Answer")]
      let conversation = LiveConversation(
        ConversationViewState(header: TranscriptFixture.header, rows: rows))
      let screen = window(
        LiveTranscriptHost(conversation: conversation, actions: ConversationActions()))
      defer { screen.close() }
      try await letTasksRun(screen, milliseconds: 300)
      let bottom = try tabsBottom(screen)
      let scroll = try detailScrollView(screen)
      #expect(abs(frameInWindow(scroll).maxY - bottom) < 0.5, "the transcript's frame")
      let content = try #require(scroll.documentView)
      #expect(abs(frameInWindow(content).maxY - bottom) < 0.5, "the top of its rows")
    }
  }
#endif
