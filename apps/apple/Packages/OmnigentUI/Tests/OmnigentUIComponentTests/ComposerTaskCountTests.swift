#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  /// The last height a probed view reported.
  @MainActor
  private final class MeasuredHeights {
    var last: CGFloat?
  }

  extension OffscreenWindow {
    /// The enabled buttons in the open popover, top to bottom, in its window.
    fileprivate func popoverButtonFrames() -> [CGRect] {
      popoverViews.filter { String(describing: Swift.type(of: $0)) == "KeyViewProxy" }
        .map { $0.convert($0.bounds, to: nil) }
        .sorted { $0.midY > $1.midY }
    }
  }

  /// The tray's sub-agent count and its list (web `SubagentTaskIndicator`), and the background
  /// list's commands (web `TaskCommand`).
  @Suite("Composer: the sub-agent count and background commands", .serialized)
  @MainActor
  struct ComposerTaskCountTests {
    private let log = ComposerActionLog()

    private func child(_ id: String, _ status: AgentTreeActivity, agent: String? = nil)
      -> SubagentChild
    {
      SubagentChild(id: id, title: "Agent \(id)", agent: agent, status: status)
    }

    /// The parent's count with a working child (its tool under its name) and a waiting one.
    private var subagentTray: ComposerTray {
      var tray = ComposerTray()
      tray.indicators = ComposerTaskIndicators(subagents: [
        child("a", .working, agent: "Survey the docs"), child("b", .needsYou, agent: "Agent b"),
      ])
      return tray
    }

    /// Opens the count's list by clicking the count.
    private func openList(_ screen: OffscreenWindow<ComposerScreen>) throws -> NSView {
      let count = try #require(screen.chips.first)
      try screen.click(screen.clickPoint(count))
      _ = MainLoop.settle(until: { screen.popoverWindow?.contentView != nil })
      return try #require(screen.popoverWindow?.contentView)
    }

    @Test("the sub-agent count opens its list; a row opens its child and closes the list")
    func subagents() throws {
      let model = ComposerScreenModel(state: ComposerViewState(tray: subagentTray))
      let screen = openComposer(model, log.actions)
      defer { screen.close() }
      #expect(try screen.shows("2"))
      let list = try openList(screen)
      let shown = try screen.shownText(under: list)
      for text in ["Agent a", "Working", "Survey the docs", "Agent b", "Needs you"] {
        #expect(shown.contains(text), "\(text) in \(shown)")
      }
      // A tool that repeats the name is left out.
      #expect(shown.filter { $0 == "Agent b" }.count == 1, "\(shown)")
      // The rows keep the count's order: the second from the top is the second child.
      let rows = screen.popoverButtonFrames()
      try #require(rows.count == 2)
      try screen.clickInPopover(at: CGPoint(x: rows[1].midX, y: rows[1].midY))
      #expect(log.events == ["subagent:b"])
      #expect(MainLoop.settle(until: { screen.popoverWindow == nil }))
    }

    @Test("without a way to open sub-agents the list's rows can't be pressed")
    func subagentsWithoutOpening() throws {
      var actions = log.actions
      actions.extras.indicators.openSubagent = nil
      let screen = openComposer(
        ComposerScreenModel(state: ComposerViewState(tray: subagentTray)), actions)
      defer { screen.close() }
      let list = try openList(screen)
      #expect(try screen.shownText(under: list).contains { $0.contains("Agent a") })
      #expect(screen.popoverButtonFrames().isEmpty)
    }

    @Test("an emptied sub-agent count goes away and closes its list")
    func subagentsDropOut() throws {
      let model = ComposerScreenModel(state: ComposerViewState(tray: subagentTray))
      let screen = openComposer(model, log.actions)
      defer { screen.close() }
      _ = try openList(screen)
      model.state.tray?.indicators.subagents = []
      #expect(MainLoop.settle(until: { screen.popoverWindow == nil }))
      #expect(screen.chips.isEmpty)
    }

    @Test("a failure, a request and plain work each tint the count their own way")
    func subagentTint() throws {
      var pictures: Set<Data> = []
      for status in [AgentTreeActivity.working, .needsYou, .failed] {
        let indicators = ComposerTaskIndicators(subagents: [child("a", status)])
        pictures.insert(
          try RenderSupport.picture(
            ComposerIndicatorsView(indicators: indicators, actions: ComposerIndicatorActions()),
            width: 80, height: 30))
      }
      #expect(pictures.count == 3)
    }

    @Test("each status in the list draws its own mark and word")
    func subagentRowStatuses() throws {
      var pictures: Set<Data> = []
      for status in AgentTreeActivity.allCases.filter(\.isTallied) {
        pictures.insert(
          try RenderSupport.picture(
            SubagentRows(children: [child("a", status)], open: nil), width: 360, height: 60))
      }
      #expect(pictures.count == 5)
    }

    @Test("a long command folds to two lines behind a chevron; a short one has none")
    func backgroundCommand() throws {
      let heights = MeasuredHeights()
      let long = Array(repeating: "--flag value", count: 40).joined(separator: " ")
      let indicators = ComposerTaskIndicators(
        backgroundTasks: 1,
        backgroundTaskList: [ComposerBackgroundTask(id: "1", title: "Server", command: long)])
      let screen = OffscreenWindow(
        BackgroundTaskRows(indicators: indicators)
          .frame(width: 360)
          .onGeometryChange(for: CGFloat.self) {
            $0.size.height
          } action: {
            heights.last = $0
          },
        width: 400, height: 900)
      defer { screen.close() }
      screen.settle(0.3)
      let folded = try #require(heights.last)
      func toggle() throws {
        let chevron = try #require(screen.controlFrames.first, "the chevron")
        try screen.click(CGPoint(x: chevron.midX, y: chevron.midY))
        screen.settle(0.3)
      }
      try toggle()
      #expect(try #require(heights.last) > folded)
      try toggle()
      #expect(heights.last == folded)

      let short = OffscreenWindow(
        BackgroundTaskRows(
          indicators: ComposerTaskIndicators(
            backgroundTasks: 1,
            backgroundTaskList: [
              ComposerBackgroundTask(id: "1", title: "Server", command: "npm run dev")
            ])
        ).frame(width: 360), width: 400, height: 300)
      defer { short.close() }
      #expect(try MainLoop.settle(until: { try short.shows("npm run dev") }))
      #expect(short.controlFrames.isEmpty)
    }
  }
#endif
