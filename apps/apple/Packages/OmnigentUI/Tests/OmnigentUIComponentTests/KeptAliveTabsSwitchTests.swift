#if os(macOS)
  import AppKit
  import Observation
  import OmnigentViewTesting
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  private struct SwitchedTab: Identifiable {
    let id: String
  }

  /// The shown tab and a value every tab's content takes, changed from the test.
  @MainActor
  @Observable
  private final class TabSwitcher {
    var shown = "a"
    var label = "first"
  }

  /// What each tab's content rendered: how often, and with which value last.
  @MainActor
  private final class TabRenders {
    var counts: [String: Int] = [:]
    var labels: [String: String] = [:]
  }

  private struct CountedTab: View {
    let id: String
    let label: String
    let renders: TabRenders

    var body: some View {
      renders.counts[id, default: 0] += 1
      renders.labels[id] = label
      return Text(label)
    }
  }

  private struct CountedTabs: View {
    let switcher: TabSwitcher
    let renders: TabRenders

    var body: some View {
      KeptAliveTabs(["a", "b"].map(SwitchedTab.init(id:)), shownID: switcher.shown) { tab in
        CountedTab(id: tab.id, label: switcher.label, renders: renders)
      }
    }
  }

  /// An AppKit view inside a tab, as a conversation's text, scroll and glass views are.
  private struct HostedView: NSViewRepresentable {
    let view: NSView

    func makeNSView(context: Context) -> NSView { view }

    func updateNSView(_ view: NSView, context: Context) {}
  }

  private struct HostedViewTabs: View {
    let switcher: TabSwitcher
    let views: [String: NSView]

    var body: some View {
      KeptAliveTabs(["a", "b"].map(SwitchedTab.init(id:)), shownID: switcher.shown) { tab in
        VStack {
          Text("Tab \(tab.id)")
          if let view = views[tab.id] { HostedView(view: view) }
          TextField("Message", text: .constant(""))
        }
      }
    }
  }

  /// A conversation with its own state, as the app's container gives it. `pass` differs on every
  /// render of the window, as the app's closures do, so each one hands the tab new values.
  private struct ConversationTab: View {
    let rows: [Row]
    let pass: Int
    @State private var showsInspector = false
    @State private var mode = SessionViewMode.chat
    @State private var fork: ForkViewState?
    @State private var draft = ""

    var body: some View {
      ConversationScreen(
        state: ConversationViewState(header: TranscriptFixture.header, rows: rows),
        composer: ComposerViewState(), draft: ComposerDraft($draft),
        showsInspector: $showsInspector, mode: $mode, fork: $fork,
        actions: ConversationActions(), composerActions: ComposerActions(send: {}),
        // The revision counts changes of the rows, and these never change.
        liveRows: LiveTranscriptRows { (rows: rows, revision: UInt64(rows.count)) }
      ) {
        EmptyView()
      }
    }
  }

  /// How often the window rendered.
  @MainActor
  private final class WindowPasses {
    var count = 0
  }

  private struct ConversationTabs: View {
    let switcher: TabSwitcher
    let rows: [String: [Row]]
    let passes: WindowPasses
    /// The pane's width, where a test resizes it; the window's otherwise.
    var width: PaneWidth?

    var body: some View {
      passes.count += 1
      let pass = passes.count
      return KeptAliveTabs(["a", "b"].map(SwitchedTab.init(id:)), shownID: switcher.shown) { tab in
        ConversationTab(rows: rows[tab.id] ?? [], pass: pass)
      }
      .frame(width: width?.value)
    }
  }

  /// What switching between two kept tabs costs: showing the views already built, not building,
  /// moving or re-rendering them.
  @MainActor
  @Suite("Switching between kept tabs", .serialized)
  struct KeptAliveTabsSwitchTests {
    init() {
      SystemSideEffects.reset()
    }

    /// The views above `view`, nearest first.
    private func ancestors(of view: NSView) -> [ObjectIdentifier] {
      var found: [ObjectIdentifier] = []
      var current = unsafe view.superview
      while let parent = current {
        found.append(ObjectIdentifier(parent))
        current = unsafe parent.superview
      }
      return found
    }

    @Test("A switch leaves every AppKit view of both tabs where it was")
    func switchingMovesNoAppKitView() {
      let switcher = TabSwitcher()
      let views = ["a": NSView(), "b": NSView()]
      let window = OffscreenWindow(HostedViewTabs(switcher: switcher, views: views))
      defer { window.close() }
      window.settle()
      let before = window.allViews
      let placed = views.mapValues(ancestors(of:))
      #expect(placed.values.allSatisfy { !$0.isEmpty }, "both tabs' views are in the window")

      switcher.shown = "b"
      window.settle()

      let after = window.allViews
      #expect(Set(after.map(ObjectIdentifier.init)) == Set(before.map(ObjectIdentifier.init)))
      #expect(views.mapValues(ancestors(of:)) == placed)
    }

    @Test("The tab that hides takes no new values; the one that shows takes the latest")
    func switchingRendersOnlyTheShownTab() {
      let switcher = TabSwitcher()
      let renders = TabRenders()
      let window = OffscreenWindow(CountedTabs(switcher: switcher, renders: renders))
      defer { window.close() }
      window.settle()
      #expect(renders.counts == ["a": 1, "b": 1])

      // The switch comes with new values for every tab, as the window's own re-render does.
      switcher.label = "second"
      switcher.shown = "b"
      window.settle()
      #expect(renders.counts == ["a": 1, "b": 2], "the tab that hides does not follow")
      #expect(renders.labels == ["a": "first", "b": "second"])

      switcher.label = "third"
      window.settle()
      #expect(renders.counts == ["a": 1, "b": 3], "a hidden tab does not follow the window")

      switcher.shown = "a"
      window.settle()
      #expect(renders.counts == ["a": 2, "b": 3])
      #expect(renders.labels["a"] == "third", "showing again takes what it missed")
    }

    /// The views a conversation scrolls and types in, in the tab drawn at no opacity.
    private func hiddenScrollAndTextViews(_ window: OffscreenWindow<AnyView>) -> [NSView] {
      let drawn = Set(window.drawnViews.map(ObjectIdentifier.init))
      return window.allViews.filter { view in
        (view is NSScrollView || view is NSTextView) && !drawn.contains(ObjectIdentifier(view))
      }
    }

    /// A hidden conversation follows the pane only once it shows: until then a resize step
    /// lays out its scroll view, composer and rows for nobody.
    @Test("A resize behind another tab moves nothing in the hidden conversation until it shows")
    func resizingLeavesTheHiddenConversation() async throws {
      let switcher = TabSwitcher()
      let width = PaneWidth(900)
      let rows = ["a": TranscriptFixture.turns(6), "b": TranscriptFixture.turns(40)]
      let window = transcriptScreen(
        ConversationTabs(switcher: switcher, rows: rows, passes: WindowPasses(), width: width),
        width: 900, height: 600)
      defer { window.close() }
      try await letTasksRun(window, milliseconds: 300)
      for shown in ["b", "a"] {
        switcher.shown = shown
        try await letTasksRun(window, milliseconds: 300)
      }
      let hidden = hiddenScrollAndTextViews(window)
      let transcript = try #require(
        hidden.compactMap { $0 as? NSScrollView }.max { $0.frame.height < $1.frame.height })
      let sizes = hidden.map(\.frame.size)
      #expect(transcript.frame.width == 900)

      for narrower in [860, 820] as [CGFloat] {
        width.value = narrower
        window.settle(0.1)
      }
      #expect(hidden.map(\.frame.size) == sizes)

      let recorder = try CommittedFrames(window, transcript: transcript)
      let frames = recorder.recording {
        switcher.shown = "b"
        commitFrames(for: 0.5)
      }
      // The frame that shows it has it at the pane's width, on its last row.
      #expect(frames.map(\.viewport.width) == [820])
      let last = try #require(frames.last)
      #expect(last.lines.last?.text == recorder.settled.lines.last?.text)
      #expect(transcript.frame.width == 820)
    }

    #if DEBUG
      @Test("A switch renders the conversation that shows once and the one that hides not at all")
      func switchingDoesNotRenderTheHiddenConversation() async throws {
        let switcher = TabSwitcher()
        let rows = ["a": TranscriptFixture.turns(6), "b": TranscriptFixture.turns(4)]
        let window = transcriptScreen(
          ConversationTabs(switcher: switcher, rows: rows, passes: WindowPasses()), width: 900,
          height: 600)
        defer { window.close() }
        try await letTasksRun(window, milliseconds: 300)
        // Each conversation has shown once, so the measured switch is between settled tabs.
        for shown in ["b", "a"] {
          switcher.shown = shown
          try await letTasksRun(window, milliseconds: 300)
        }

        let renders = RenderTally.recording {
          switcher.shown = "b"
          window.settle()
        }
        #expect(renders["screen"] == 1)
        #expect(renders["transcript"] == 1)
        #expect(renders["rows"] == 1)
      }
    #endif
  }
#endif
