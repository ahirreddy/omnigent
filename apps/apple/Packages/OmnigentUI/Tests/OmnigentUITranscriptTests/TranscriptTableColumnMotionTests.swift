#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents
  @testable import OmnigentUITestSupport

  /// A split view controller's column collapsing beside the transcript (the sidebar hiding or
  /// showing) moves its width once a frame: meanwhile text lays out at snapped widths, as in a
  /// live resize, and at the exact width once the widths stop.
  @Suite("Transcript table through a column's slide", .serialized)
  @MainActor
  struct TranscriptTableColumnMotionTests {
    private static let height: CGFloat = 600
    /// About a sidebar's width.
    private static let slide: CGFloat = 248

    private func conversation() -> LiveConversation {
      LiveConversation(
        ConversationViewState(header: TranscriptFixture.header, rows: TranscriptFixture.turns(8)))
    }

    private func transcript(_ conversation: LiveConversation) -> some View {
      TableTranscriptHost(conversation: conversation, actions: ConversationActions())
        .environment(\.messageTextRenderer, .textKit)
        .environment(\.layoutWidth, .regular)
        .environment(\.flattensGlass, true)
    }

    /// The text width of each answer on screen.
    private func answerWidths(_ controller: TranscriptTableController) -> [CGFloat] {
      controller.model.rows.indices.compactMap { index in
        guard controller.model.rows[index].kind == .answer,
          let cell = controller.realizedCell(at: index) as? TranscriptTableTextCell
        else { return nil }
        return cell.runs.first?.view.frame.width
      }
    }

    /// The column an answer lays out at in a cell `width` wide, with no snapping.
    private func exactColumn(_ width: CGFloat) -> CGFloat {
      TranscriptTableTextMetrics(
        width: width, layoutWidth: .regular, maxWidth: Theme.transcriptWidth
      ).columnWidth
    }

    @Test("A slide lays each answer out at a width every 32 points, then once at the exact one")
    func slideSnapsTheText() async throws {
      let start = Theme.transcriptWidth + 2 * Theme.Spacing.gutter
      let window = transcriptScreen(transcript(conversation()), width: start, height: Self.height)
      defer { window.close() }
      try await letTasksRun(window, milliseconds: 200)
      let scrollView = try #require(TranscriptScrollDriver(screen: window).scrollView)
      let controller = try #require(TranscriptScrollDriver(screen: window).tableController)

      controller.columnMotionBegan()
      #expect(controller.widthHolds.contains(.columnMotion))
      var widths: Set<CGFloat> = []
      let steps = 16
      for step in 1...steps {
        let width = start - Self.slide * CGFloat(step) / CGFloat(steps)
        scrollView.setFrameSize(NSSize(width: width, height: scrollView.frame.height))
        window.settle(0.016)
        let shown = answerWidths(controller)
        #expect(!shown.isEmpty)
        #expect(shown.allSatisfy { $0.truncatingRemainder(dividingBy: 32) == 0 }, "\(shown)")
        widths.formUnion(shown)
      }
      // A width every 32 points of the slide, not one at each of its frames.
      #expect(widths.count <= Int(Self.slide / TranscriptTableTextStyle.liveResizeSnap) + 2)
      #expect(widths.count < steps)

      window.run(for: TranscriptTableController.columnMotionQuiet + 0.2)
      #expect(controller.widthHolds.isEmpty)
      let exact = exactColumn(controller.model.width)
      #expect(answerWidths(controller).allSatisfy { $0 == exact }, "at \(exact)")
      for index in controller.model.rows.indices where controller.realizedCell(at: index) != nil {
        #expect(!controller.model.needsMeasure(at: index), "row \(index)")
      }
    }

    @Test("A widening slide lays no answer out again until it ends, then once at the new width")
    func wideningSlideKeepsTheText() async throws {
      let start = Theme.transcriptWidth + 2 * Theme.Spacing.gutter - Self.slide
      let window = transcriptScreen(transcript(conversation()), width: start, height: Self.height)
      defer { window.close() }
      try await letTasksRun(window, milliseconds: 200)
      let scrollView = try #require(TranscriptScrollDriver(screen: window).scrollView)
      let controller = try #require(TranscriptScrollDriver(screen: window).tableController)
      let before = Set(answerWidths(controller))
      #expect(before.count == 1)

      controller.columnMotionBegan()
      let steps = 16
      for step in 1...steps {
        let width = start + Self.slide * CGFloat(step) / CGFloat(steps)
        scrollView.setFrameSize(NSSize(width: width, height: scrollView.frame.height))
        window.settle(0.016)
        #expect(Set(answerWidths(controller)) == before, "at \(width)")
      }

      window.run(for: TranscriptTableController.columnMotionQuiet + 0.2)
      #expect(controller.widthHolds.isEmpty)
      let exact = exactColumn(controller.model.width)
      #expect(exact > before.first ?? 0)
      #expect(answerWidths(controller).allSatisfy { $0 == exact }, "at \(exact)")
    }

    @Test("A slide that keeps the column's width lays nothing out again as it ends")
    func cappedSlideEndsQuietly() async throws {
      let wide: CGFloat = 1_200
      let window = transcriptScreen(transcript(conversation()), width: wide, height: Self.height)
      defer { window.close() }
      try await letTasksRun(window, milliseconds: 200)
      let scrollView = try #require(TranscriptScrollDriver(screen: window).scrollView)
      let controller = try #require(TranscriptScrollDriver(screen: window).tableController)

      controller.columnMotionBegan()
      for step in 1...8 {
        let width = wide - Self.slide * CGFloat(step) / 8
        scrollView.setFrameSize(NSSize(width: width, height: scrollView.frame.height))
        window.settle(0.016)
      }
      let serial = controller.textStyle.serial
      window.run(for: TranscriptTableController.columnMotionQuiet + 0.2)
      #expect(controller.widthHolds.isEmpty)
      // The reading column is at its limit at every width the slide passed: the cells keep
      // their style, and nothing on screen needs measuring.
      #expect(controller.textStyle.serial == serial)
      #expect(answerWidths(controller).allSatisfy { $0 == Theme.transcriptWidth })
      for index in controller.model.rows.indices where controller.realizedCell(at: index) != nil {
        #expect(!controller.model.needsMeasure(at: index), "row \(index)")
      }
    }

    @Test(
      "A sidebar collapsing beside the transcript holds its text until the widths stop, unless it collapses at once",
      arguments: [false, true])
    func sidebarCollapseHoldsTheText(atOnce: Bool) throws {
      NSApplication.shared.setActivationPolicy(.accessory)
      let sidebar = NSViewController()
      sidebar.view = NSView(frame: CGRect(x: 0, y: 0, width: Self.slide, height: Self.height))
      let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
      // As the shell's prerendered slide has it: the transcript takes one width, exactly.
      if atOnce { sidebarItem.animations = ["collapsed": SidebarSlide.collapse] }
      let split = NSSplitViewController()
      split.addSplitViewItem(sidebarItem)
      let content = NSSplitViewItem(
        viewController: NSHostingController(rootView: transcript(conversation())))
      // Beside the sidebar, not under it, as the app's detail column is.
      content.automaticallyAdjustsSafeAreaInsets = false
      split.addSplitViewItem(content)
      let window = NSWindow(
        contentRect: CGRect(x: -20_000, y: -20_000, width: 1_000, height: Self.height),
        styleMask: [.borderless], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.contentViewController = split
      window.setFrame(
        CGRect(x: -20_000, y: -20_000, width: 1_000, height: Self.height), display: false)
      window.orderFrontRegardless()
      defer {
        window.orderOut(nil)
        window.contentViewController = nil
        // AppKit queues run loop stops as windows change; left to the runner, one ends it early.
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
      }
      MainLoop.run(for: 0.3)
      let table = try #require(Self.table(in: window.contentView))
      let controller = try #require(table.owner)
      let before = controller.model.width
      #expect(before > 0)
      #expect(controller.widthHolds.isEmpty)

      sidebarItem.isCollapsed = true
      #expect(controller.widthHolds.contains(.columnMotion) == !atOnce)
      MainLoop.run(for: TranscriptTableController.columnMotionLimit + 0.2)
      #expect(controller.widthHolds.isEmpty)
      #expect(!controller.textStyle.isLiveResizing)
      #expect(controller.model.width > before)

      // A column the transcript is in is not one that slides beside it.
      let watched = controller.columnWatches.count
      #expect(watched == 1)
    }

    /// The transcript's table under `view`.
    private static func table(in view: NSView?) -> TranscriptTableNSView? {
      guard let view else { return nil }
      if let table = view as? TranscriptTableNSView { return table }
      for subview in view.subviews {
        if let table = table(in: subview) { return table }
      }
      return nil
    }

    @Test("Launched with exact widths, a slide lays text out at each width it passes")
    func exactWidthsSetting() throws {
      let defaults = try #require(UserDefaults(suiteName: "TranscriptTableColumnMotionTests"))
      defer { defaults.removePersistentDomain(forName: "TranscriptTableColumnMotionTests") }
      #expect(TranscriptTableController.holdsColumnMotion(in: defaults))
      defaults.set("exact", forKey: "omnigent:transcript-column-motion")
      #expect(!TranscriptTableController.holdsColumnMotion(in: defaults))
    }
  }
#endif
