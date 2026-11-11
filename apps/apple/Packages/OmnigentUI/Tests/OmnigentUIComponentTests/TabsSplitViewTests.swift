#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  /// Draws a pane's name and whether it's the active one, the other one, or out of sight.
  private struct PaneProbe: View {
    let pane: TabPane
    @Environment(\.isActiveTabPane) private var isActive
    @Environment(\.isTabContentHidden) private var isHidden

    var body: some View {
      Text("\(pane.label) \(isHidden ? "hidden" : isActive ? "active" : "idle")")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  @Suite("Tabs: the split view", .serialized)
  @MainActor
  struct TabsSplitViewTests {
    private let split = TabSplitState(leadingID: "one", trailingID: "two", focused: .leading)

    private func view(
      _ split: TabSplitState?, _ actions: TabActions, tracker: TabDragTracker = TabDragTracker(),
      width: CGFloat = 900
    ) -> OffscreenWindow<AnyView> {
      let content = TabSplitView(split: split, actions: actions) { PaneProbe(pane: $0) }
        .environment(tracker)
        .frame(width: width, height: 400)
      return OffscreenWindow(AnyView(content), width: width, height: 400)
    }

    /// A press and release through the application, where the pane's event monitor listens.
    private func sendThroughApp(_ screen: OffscreenWindow<AnyView>, at point: CGPoint) throws {
      let location = screen.host.convert(point, to: nil)
      for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
        let event = try #require(
          NSEvent.mouseEvent(
            with: type, location: location, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: screen.window.windowNumber, context: nil, eventNumber: 1, clickCount: 1,
            pressure: 1))
        NSApp.sendEvent(event)
      }
      screen.settle(0.02)
    }

    @Test("Without a split one pane shows, active")
    func single() throws {
      let screen = view(nil, TabSpy().actions)
      defer { screen.close() }
      #expect(try screen.shows("Left active"))
      #expect(try !screen.shows("Right"))
    }

    @Test("A split shows both panes; only the focused one is active")
    func both() throws {
      let screen = view(split, TabSpy().actions)
      defer { screen.close() }
      #expect(try screen.shows("Left active"))
      #expect(try screen.shows("Right idle"))
    }

    @Test("Too narrow for both, only the focused pane shows; the other stays built for later")
    func narrow() throws {
      let tracker = TabDragTracker()
      tracker.dividerX = 300
      let focused = TabSplitState(leadingID: "one", trailingID: "two", focused: .trailing)
      let screen = view(focused, TabSpy().actions, tracker: tracker, width: 500)
      defer { screen.close() }
      #expect(try screen.shows("Right active"))
      #expect(try screen.shows("Left hidden"))
      #expect(!tracker.isSplit)
      #expect(tracker.dividerX == nil)
    }

    @Test("A wide split tells the tracker its divider and frame")
    func tracksGeometry() throws {
      let tracker = TabDragTracker()
      let screen = view(split, TabSpy().actions, tracker: tracker)
      defer { screen.close() }
      #expect(tracker.isSplit)
      let divider = try #require(tracker.dividerX)
      #expect(abs(divider - 450) < 2)
      #expect(tracker.contentFrame.width == 900)
    }

    @Test("A click in the other pane focuses it")
    func clickFocuses() throws {
      let spy = TabSpy()
      let screen = view(split, spy.actions)
      defer { screen.close() }
      try sendThroughApp(screen, at: CGPoint(x: 700, y: 200))
      #expect(spy.calls == ["focus trailing"])
    }

    @Test("A click in the focused pane doesn't refocus")
    func clickFocusedPane() throws {
      let spy = TabSpy()
      let screen = view(split, spy.actions)
      defer { screen.close() }
      try sendThroughApp(screen, at: CGPoint(x: 200, y: 200))
      #expect(spy.calls.isEmpty)
    }

    @Test("A click on the divider focuses neither pane")
    func clickDivider() throws {
      let spy = TabSpy()
      let screen = view(split, spy.actions)
      defer { screen.close() }
      try sendThroughApp(screen, at: CGPoint(x: 450.5, y: 200))
      #expect(spy.calls.isEmpty)
    }

    @Test("The pane without focus looks exactly like the focused one")
    func noDim() throws {
      func picture(_ focused: TabPane) throws -> Data {
        let state = TabSplitState(leadingID: "one", trailingID: "two", focused: focused)
        let rendered = try RenderSupport.render(
          TabSplitView(split: state, actions: TabActions()) { _ in Color.black },
          width: 900, height: 200, scheme: .dark, layout: .regular)
        return try #require(rendered.image.tiffRepresentation)
      }
      #expect(try picture(.leading) == picture(.trailing))
    }

    @Test("While a tab is dragged over an edge, that pane's preview shows")
    func dropPreview() throws {
      let tracker = TabDragTracker()
      let screen = view(nil, TabSpy().actions, tracker: tracker)
      defer { screen.close() }
      #expect(try !screen.shows("Left Pane"))
      let frame = tracker.contentFrame
      tracker.update(
        id: "one", pane: nil, location: CGPoint(x: frame.minX + 20, y: frame.midY))
      screen.settle(0.02)
      #expect(try screen.shows("Left Pane"))
      tracker.update(
        id: "one", pane: nil, location: CGPoint(x: frame.maxX - 20, y: frame.midY))
      screen.settle(0.02)
      #expect(try screen.shows("Right Pane"))
    }

    @Test("In a split, the preview doesn't offer the tab's own pane")
    func previewOtherPane() throws {
      let tracker = TabDragTracker()
      let screen = view(split, TabSpy().actions, tracker: tracker)
      defer { screen.close() }
      let frame = tracker.contentFrame
      let onLeft = CGPoint(x: frame.minX + 20, y: frame.midY)
      tracker.update(id: "one", pane: .leading, location: onLeft)
      screen.settle(0.02)
      #expect(try !screen.shows("Left Pane"))
      tracker.update(id: "two", pane: .trailing, location: onLeft)
      screen.settle(0.02)
      #expect(try screen.shows("Left Pane"))
    }

    @Test("In a split, the whole of the other pane previews the drop, up to the divider")
    func previewWholePane() throws {
      let tracker = TabDragTracker()
      let screen = view(split, TabSpy().actions, tracker: tracker)
      defer { screen.close() }
      let frame = tracker.contentFrame
      let divider = try #require(tracker.dividerX)
      tracker.update(
        id: "one", pane: .leading, location: CGPoint(x: divider - 10, y: frame.midY))
      screen.settle(0.02)
      #expect(try !screen.shows("Right Pane"))
      tracker.update(
        id: "one", pane: .leading, location: CGPoint(x: divider + 10, y: frame.midY))
      screen.settle(0.02)
      #expect(try screen.shows("Right Pane"))
    }

    @Test("A tab over the other pane's strip section previews that pane")
    func previewFromSection() throws {
      let tracker = TabDragTracker()
      let screen = view(split, TabSpy().actions, tracker: tracker)
      defer { screen.close() }
      tracker.update(id: "one", pane: .leading, location: nil)
      screen.settle(0.02)
      #expect(try !screen.shows("Right Pane"))
      tracker.update(id: "one", pane: .leading, location: nil, section: .trailing)
      screen.settle(0.02)
      #expect(try screen.shows("Right Pane"))
    }
  }

  @Suite("Tabs: side chat pages", .serialized)
  @MainActor
  struct TabsSideChatTests {
    private func page(_ phase: SideChatTabState.Phase, opened: @escaping @MainActor () -> Void)
      -> OffscreenWindow<AnyView>
    {
      let view = SideChatTabView(
        state: SideChatTabState(phase: phase, sessionTitle: "Parent"), openConversation: opened
      )
      .frame(width: 600, height: 400)
      return OffscreenWindow(AnyView(view), width: 600, height: 400)
    }

    @Test("While loading it says so")
    func loading() throws {
      let screen = page(.loading) {}
      defer { screen.close() }
      #expect(try screen.shows("Loading the side chat\u{2026}"))
    }

    @Test("A row gone from the transcript offers the conversation")
    func unavailable() throws {
      var opened = 0
      let screen = page(.unavailable) { opened += 1 }
      defer { screen.close() }
      #expect(try screen.shows("Side Chat Unavailable"))
      try screen.clickControl(at: 0)
      #expect(opened == 1)
    }

    @Test("The question and answer show, with a way back")
    func loaded() throws {
      var opened = 0
      let screen = page(.loaded(question: "Why?", answer: "Because.")) { opened += 1 }
      defer { screen.close() }
      #expect(try screen.shows("From Parent"))
      #expect(try screen.shows("Why?"))
      #expect(try screen.shows("Because."))
      try screen.clickControl(at: 0)
      #expect(opened == 1)
    }

    @Test("A question without an answer says so")
    func noAnswer() throws {
      let screen = page(.loaded(question: "Why?", answer: nil)) {}
      defer { screen.close() }
      #expect(try screen.shows("No answer yet."))
    }

    private func pending(
      isStarting: Bool = false, failure: String? = nil, calls: @escaping @MainActor (String) -> Void
    ) -> OffscreenWindow<AnyView> {
      let view = PendingHost(isStarting: isStarting, failure: failure, calls: calls)
        .frame(width: 600, height: 500)
      return OffscreenWindow(AnyView(view), width: 600, height: 500)
    }

    @Test("A new side chat explains itself and names its parent")
    func pendingIntro() throws {
      let screen = pending { _ in }
      defer { screen.close() }
      #expect(try screen.shows(SideChatCopy.title))
      #expect(try screen.shows(SideChatCopy.detail))
      #expect(try screen.shows("Parent"))
    }

    @Test("A failure to start shows, with the draft kept")
    func pendingFailure() throws {
      let screen = pending(failure: "No server") { _ in }
      defer { screen.close() }
      #expect(try screen.shows("No server"))
    }

    @Test("Typing a first message and pressing Return sends it")
    func pendingSend() throws {
      var calls: [String] = []
      let screen = pending { calls.append($0) }
      defer { screen.close() }
      try screen.click(try #require(screen.allViews.compactMap { $0 as? NSTextView }.first))
      try screen.type("hello")
      try screen.press(keyCode: 36, characters: "\r")
      #expect(calls == ["send hello"])
    }

    @Test("While starting it can't send again")
    func pendingStarting() throws {
      var calls: [String] = []
      let screen = pending(isStarting: true) { calls.append($0) }
      defer { screen.close() }
      try screen.click(try #require(screen.allViews.compactMap { $0 as? NSTextView }.first))
      try screen.type("hello")
      try screen.press(keyCode: 36, characters: "\r")
      #expect(calls.isEmpty)
    }
  }

  private struct PendingHost: View {
    let isStarting: Bool
    let failure: String?
    let calls: @MainActor (String) -> Void
    @State private var draft = ""

    var body: some View {
      PendingSideChatView(
        draft: $draft, parent: CreatingSession(id: "p", title: "Parent"), isStarting: isStarting,
        failure: failure, send: { calls("send \(draft)") }, dismissFailure: { calls("dismiss") },
        openParent: { calls("open \($0)") })
    }
  }
#endif
