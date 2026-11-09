#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  /// Drags arriving at the sidebar through AppKit's destination protocol, with no real drag.
  @Suite("Sidebar drops, delivered", .serialized)
  @MainActor
  struct SidebarDropGapsTests {
    private let area = CGPoint(x: 100, y: 100)

    private func target(
      accept: @escaping @MainActor (SidebarDragItem) -> Bool
    ) -> OffscreenWindow<some View> {
      OffscreenWindow(
        Color.clear.frame(width: 200, height: 200).contentShape(Rectangle())
          .sidebarDropTarget(accept), width: 200, height: 200)
    }

    private func bitmapData<Content: View>(_ screen: OffscreenWindow<Content>) throws -> Data {
      let bitmap = try #require(screen.host.bitmapImageRepForCachingDisplay(in: screen.host.bounds))
      screen.host.cacheDisplay(in: screen.host.bounds, to: bitmap)
      return try #require(bitmap.tiffRepresentation)
    }

    @Test("A session's drag reaches the target with its id, outlining it while over")
    func deliversSession() async throws {
      var accepted: [SidebarDragItem] = []
      let screen = target {
        accepted.append($0)
        return true
      }
      defer { screen.close() }
      let empty = try bitmapData(screen)
      let arrival = try screen.dragEnters(SidebarDragItem.session("abc").payload, at: area)
      #expect(try bitmapData(screen) != empty, "outlined while the drag is over it")
      try await screen.dragDrops(arrival)
      #expect(accepted == [.session("abc")])
      #expect(try bitmapData(screen) == empty, "the outline leaves with the drag")
    }

    @Test("A drag from outside the app is not a sidebar item")
    func ignoresOutsiders() async throws {
      var accepted: [SidebarDragItem] = []
      let screen = target {
        accepted.append($0)
        return true
      }
      defer { screen.close() }
      try await screen.drop("https://example.test", at: area)
      #expect(accepted.isEmpty)
    }

    @Test("Dropping a session on the Pinned header pins it")
    func ontoPinnedHeader() async throws {
      let spy = SidebarSpy(SidebarFixture.state)
      let screen = OffscreenWindow(SidebarHarness(spy: spy), width: 300, height: 800)
      defer { screen.close() }
      try await screen.drop(
        SidebarDragItem.session("beta").payload, at: try screen.center(ofRow: 5))
      #expect(spy.calls == ["drop beta pin(slotOf: nil)"])
    }

    @Test("Dropping on a pinned row takes its slot; on the Sessions list unpins")
    func ontoRows() async throws {
      let spy = SidebarSpy(SidebarFixture.state)
      let screen = OffscreenWindow(SidebarHarness(spy: spy), width: 300, height: 800)
      defer { screen.close() }
      try await screen.drop(
        SidebarDragItem.session("beta").payload,
        at: try screen.center(ofRow: SidebarFixture.pinnedRow))
      try await screen.drop(
        SidebarDragItem.session("pinned").payload,
        at: try screen.center(ofRow: SidebarFixture.gammaRow))
      #expect(spy.calls == ["drop beta pin(slotOf: Optional(\"pinned\"))", "drop pinned unpin"])
    }

    @Test("While selecting sessions, a drop does nothing")
    func whileSelecting() async throws {
      let spy = SidebarSpy(SidebarFixture.state)
      let screen = OffscreenWindow(SidebarHarness(spy: spy), width: 340, height: 800)
      defer { screen.close() }
      try screen.click(try screen.plainButtons(inRow: 9)[1])
      try await screen.drop(
        SidebarDragItem.session("beta").payload, at: try screen.center(ofRow: 5))
      #expect(spy.calls.isEmpty)
    }

    @Test("Delete archives the selected session, and does nothing without one")
    func deleteCommand() throws {
      let spy = SidebarSpy(SidebarFixture.state)
      let screen = OffscreenWindow(SidebarHarness(spy: spy), width: 300, height: 800)
      defer { screen.close() }
      let delete = #selector(NSText.delete(_:))
      let list = try #require(screen.list)
      screen.window.makeFirstResponder(list)
      _ = list.tryToPerform(delete, with: nil)
      #expect(spy.calls.isEmpty)
      spy.selection = .session("beta")
      screen.settle(0.05)
      _ = list.tryToPerform(delete, with: nil)
      screen.settle(0.05)
      #expect(spy.calls == ["archive beta true"])
    }
  }
#endif
