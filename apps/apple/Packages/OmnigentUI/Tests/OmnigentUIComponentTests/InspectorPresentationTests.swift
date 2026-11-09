#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  private struct PresentationHarness: View {
    let host: WorkspaceHost
    var isActivePane = true
    var slots = WorkspaceSlots.filled

    var body: some View {
      Text("conversation")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .workspaceInspector(
          state: .inspectorSample, actions: ConversationActions(), slots: slots,
          isPresented: host.presentedBinding, tab: host.tabBinding
        )
        .environment(\.isActiveTabPane, isActivePane)
    }
  }

  @Suite("Inspector: presenting the right panel", .serialized)
  @MainActor
  struct InspectorPresentationTests {
    private func screen(_ harness: PresentationHarness) -> OffscreenWindow<AnyView> {
      OffscreenWindow(AnyView(harness), width: 1_000, height: 600)
    }

    @Test("The panel shows beside the conversation only while it's presented")
    func presented() throws {
      let host = WorkspaceHost()
      let screen = screen(PresentationHarness(host: host))
      defer { screen.close() }
      #expect(try screen.shows("conversation"))
      #expect(try screen.shows("files slot"))
      #expect(!screen.sideColumnCollapsed)
      host.isPresented = false
      screen.settle()
      #expect(screen.sideColumnCollapsed)
    }

    @Test("Full screen swaps the side column for a cover, and hiding the panel leaves full screen")
    func maximized() throws {
      let host = WorkspaceHost()
      let screen = screen(PresentationHarness(host: host))
      defer { screen.close() }
      try screen.clickFullScreen()
      // The cover's own Files tab is at the window's left, over the conversation.
      #expect(screen.controlFrames.first?.minX == 10)
      #expect(screen.sideColumnCollapsed)
      // Reading asks the new cover for its labels; they're there by the next read.
      _ = try screen.shownText()
      screen.settle(0.3)
      #expect(try screen.shows("Exit full screen"))

      host.isPresented = false
      screen.settle(0.3)
      host.isPresented = true
      screen.settle(0.3)
      #expect(try !screen.shows("Exit full screen"))
    }

    @Test("Shift-Command-F opens the panel on Search from wherever it was")
    func searchShortcut() throws {
      let host = WorkspaceHost()
      host.isPresented = false
      host.selectedDocument = "one"
      var slots = WorkspaceSlots.filled
      slots.documents = host.documents
      let screen = screen(PresentationHarness(host: host, slots: slots))
      defer { screen.close() }
      try screen.press(keyCode: 3, characters: "f", modifiers: [.command, .shift])
      #expect(host.tab == .search)
      #expect(host.isPresented)
      #expect(host.calls == ["show panel"])
    }

    @Test("Option-Command-2 opens the panel's second tab")
    func tabShortcut() throws {
      let host = WorkspaceHost()
      host.isPresented = false
      let screen = screen(PresentationHarness(host: host))
      defer { screen.close() }
      try screen.press(keyCode: 19, characters: "2", modifiers: [.command, .option])
      #expect(host.tab == .changes)
      #expect(host.isPresented)
    }

    @Test("A pane that isn't focused leaves those shortcuts to the focused one")
    func inactivePane() throws {
      let host = WorkspaceHost()
      host.isPresented = false
      let screen = screen(PresentationHarness(host: host, isActivePane: false))
      defer { screen.close() }
      try screen.press(keyCode: 3, characters: "f", modifiers: [.command, .shift])
      try screen.press(keyCode: 19, characters: "2", modifiers: [.command, .option])
      #expect(host.tab == .files)
      #expect(!host.isPresented)
    }

    @Test("Shift-Command-F does nothing on a server without search")
    func noSearchShortcut() throws {
      let host = WorkspaceHost()
      host.isPresented = false
      let screen = screen(PresentationHarness(host: host, slots: WorkspaceSlots()))
      defer { screen.close() }
      try screen.press(keyCode: 3, characters: "f", modifiers: [.command, .shift])
      #expect(host.tab == .files)
      #expect(!host.isPresented)
    }
  }

  extension OffscreenWindow {
    /// Whether the panel's column is folded away.
    fileprivate var sideColumnCollapsed: Bool {
      let splitView = allViews.lazy.compactMap { $0 as? NSSplitView }.first
      let controller = splitView?.delegate as? NSSplitViewController
      return controller?.splitViewItems.last?.isCollapsed ?? false
    }

    /// Clicks the panel's full screen button: the last control of its tab row.
    fileprivate func clickFullScreen() throws {
      let lastInRow = controlFrames.lastIndex { $0.minY < 40 }
      try clickControl(at: #require(lastInRow))
    }
  }
#endif
