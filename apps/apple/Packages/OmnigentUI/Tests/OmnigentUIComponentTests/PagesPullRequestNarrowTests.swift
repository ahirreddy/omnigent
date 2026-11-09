#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  @Suite("Pull request detail at narrow widths", .serialized)
  @MainActor
  struct PagesPullRequestNarrowTests {
    private let log = ActionLog()

    private var extras: PullRequestPanelExtras {
      let log = log
      var actions = PullRequestPanelActions()
      actions.showList = { log.record("list") }
      actions.refresh = { log.record("refresh") }
      actions.unlink = { log.record("unlink \($0)") }
      var extras = PullRequestPanelExtras()
      extras.actions = actions
      return extras
    }

    private var state: PullRequestDetailViewState {
      PullRequestDetailViewState(
        url: "https://example.com/pr/123456", title: String(repeating: "A long title ", count: 12),
        numberLabel: "#123456", status: .unknown,
        context: "omnigent/omnigent \u{00B7} a-very-long-branch-name-for-this-change \u{2192} main",
        providerName: "GitHub")
    }

    private func screen(width: CGFloat) -> OffscreenWindow<some View> {
      SystemSideEffects.reset()
      let log = log
      return OffscreenWindow(
        PullRequestDetailView(
          content: .ready(state), extras: extras, listCount: 1_234,
          open: { log.record("open \($0.absoluteString)") }
        ), width: width, height: 500)
    }

    @Test("every control stays inside the panel", arguments: [260.0, 320.0, 420.0])
    func controlsFit(width: CGFloat) throws {
      let screen = screen(width: width)
      defer { screen.close() }
      let frames = screen.controlFrames
      try #require(frames.count >= 4, "back, refresh, open, unlink, the tabs")
      for frame in frames {
        #expect(frame.minX >= 0 && frame.maxX <= width, "\(frame) in \(width)")
      }
    }

    @Test("the toolbar's actions still work when it's tight")
    func toolbarActs() throws {
      let screen = screen(width: 260)
      defer { screen.close() }
      let toolbar = screen.controlFrames.sorted { $0.minX < $1.minX }.filter { $0.minY < 50 }
      try #require(toolbar.count == 4, "\(toolbar)")
      for frame in toolbar { try screen.click(frame.center) }
      let url = "https://example.com/pr/123456"
      #expect(log.entries == ["list", "refresh", "open \(url)", "unlink \(url)"])
    }

    @Test("each tab still draws its section when narrow")
    func tabs() throws {
      let screen = screen(width: 260)
      defer { screen.close() }
      let tabs = try #require(screen.segmentedControls.first)
      for segment in 0..<tabs.segmentCount {
        try screen.click(segment: segment, of: tabs)
        #expect(tabs.selectedSegment == segment)
        for frame in screen.controlFrames {
          #expect(frame.maxX <= 260, "segment \(segment): \(frame)")
        }
      }
    }
  }
#endif
