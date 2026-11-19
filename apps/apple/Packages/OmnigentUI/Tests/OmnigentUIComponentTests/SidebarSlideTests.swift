#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import QuartzCore
  import Testing

  @testable import OmnigentUIComponents

  /// A view that counts the widths it is given.
  private final class WidthLog: NSView {
    var widths: [CGFloat] = []

    override func setFrameSize(_ newSize: NSSize) {
      if newSize.width != frame.width { widths.append(newSize.width) }
      super.setFrameSize(newSize)
    }
  }

  /// The sidebar shows and hides in one layout at its final widths, and Core Animation moves
  /// what the window shows through the slide.
  @Suite("Sidebar slide", .serialized)
  @MainActor
  struct SidebarSlideTests {
    private static let width: CGFloat = 1_000
    private static let sidebar: CGFloat = 248

    /// A window off every display with a split view controller: a sidebar and a column.
    private final class Split {
      let window: NSWindow
      let controller = NSSplitViewController()
      let sidebarItem: NSSplitViewItem
      let column = WidthLog()
      let slide: SidebarSlide

      init(mode: SidebarSlideMode) {
        NSApplication.shared.setActivationPolicy(.accessory)
        let sidebarController = NSViewController()
        sidebarController.view = NSView(
          frame: CGRect(x: 0, y: 0, width: SidebarSlideTests.sidebar, height: 600))
        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarController)
        let columnController = NSViewController()
        columnController.view = column
        let columnItem = NSSplitViewItem(viewController: columnController)
        // Beside the sidebar, as the app's detail column is.
        columnItem.automaticallyAdjustsSafeAreaInsets = false
        controller.addSplitViewItem(sidebarItem)
        controller.addSplitViewItem(columnItem)
        let frame = CGRect(x: -20_000, y: -20_000, width: SidebarSlideTests.width, height: 600)
        window = NSWindow(
          contentRect: frame, styleMask: [.titled, .resizable, .fullSizeContentView],
          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setFrame(frame, display: false)
        window.orderFrontRegardless()
        slide = SidebarSlide(controller, mode: mode)
        MainLoop.run(for: 0.2)
      }

      func close() {
        slide.finish()
        window.orderOut(nil)
        window.contentViewController = nil
        // AppKit queues run loop stops as windows change; left to the runner, one ends it early.
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
      }

      /// The column's frame in the window.
      var columnFrame: NSRect { column.convert(column.bounds, to: nil) }

      /// Shows or hides the sidebar as View > Hide Sidebar, Control-Command-S and the
      /// toolbar's button do: in AppKit's animation group.
      func toggle() {
        controller.toggleSidebar(nil)
      }

      /// The column's slide, while one runs.
      var columnMove: CABasicAnimation? {
        column.layer?.animation(forKey: SidebarSlide.animationKey) as? CABasicAnimation
      }

      /// Layers the slide put in the split view's own layer.
      var pictures: [CALayer] {
        (controller.splitView.layer?.sublayers ?? []).filter { $0.contents != nil }
      }
    }

    @Test("Hiding lays the column out once at its new width, and moves it there from its middle")
    func hideLaysOutOnce() throws {
      let split = Split(mode: .prerendered)
      defer { split.close() }
      let before = split.column.widths.count
      let start = split.columnFrame
      #expect(SidebarSlide.collapsesAtOnce(split.sidebarItem))

      split.toggle()
      MainLoop.run(for: 0.05)
      #expect(split.sidebarItem.isCollapsed)
      // One new width, not one a frame.
      #expect(split.column.widths.count == before + 1)
      #expect(abs(split.column.frame.width - Self.width) < 1)
      #expect(split.slide.isSliding)
      let move = try #require(split.columnMove)
      // The column's middle starts where it was, to the right of where it is now.
      let from = try #require(move.fromValue as? CGFloat)
      #expect(abs(from - (start.midX - split.columnFrame.midX)) < 1)
      #expect(from > 0)
      // What the sidebar showed slides out over it.
      #expect(!split.pictures.isEmpty)

      MainLoop.run(for: SidebarSlide.duration + 0.5)
      #expect(!split.slide.isSliding)
      #expect(split.columnMove == nil)
      #expect(split.pictures.isEmpty)
      #expect(split.column.widths.count == before + 1)
    }

    @Test("Showing lays the column out once, and slides the sidebar in from the window's edge")
    func showLaysOutOnce() throws {
      let split = Split(mode: .prerendered)
      defer { split.close() }
      split.toggle()
      MainLoop.run(for: SidebarSlide.duration + 0.5)
      let before = split.column.widths.count
      let start = split.columnFrame

      split.toggle()
      MainLoop.run(for: 0.05)
      #expect(!split.sidebarItem.isCollapsed)
      #expect(split.column.widths.count == before + 1)
      let move = try #require(split.columnMove)
      let from = try #require(move.fromValue as? CGFloat)
      #expect(abs(from - (start.midX - split.columnFrame.midX)) < 1)
      #expect(from < 0)
      // The sidebar comes in from past the window's edge.
      let sidebar = split.sidebarItem.viewController.view
      let sidebarMove = try #require(
        sidebar.layer?.animation(forKey: SidebarSlide.animationKey) as? CABasicAnimation)
      let sidebarEnd = sidebar.convert(sidebar.bounds, to: nil).maxX
      #expect(abs(try #require(sidebarMove.fromValue as? CGFloat) + sidebarEnd) < 1)
      // What the column showed stays under the sidebar and beside the column's end.
      #expect(split.pictures.count == 2)

      MainLoop.run(for: SidebarSlide.duration + 0.5)
      #expect(!split.slide.isSliding)
      #expect(split.pictures.isEmpty)
    }

    @Test(
      "A view resized as the sidebar collapses takes its new size at once",
      arguments: [SidebarSlideMode.instant, .prerendered])
    func collapseAnimatesNothingBeside(mode: SidebarSlideMode) {
      let split = Split(mode: mode)
      defer { split.close() }
      let probe = WidthLog(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
      split.column.addSubview(probe)
      // As the toolbar and the hosting views lay out in AppKit's toggle.
      let watch = split.sidebarItem.observe(\.isCollapsed) { _, _ in
        MainActor.assumeIsolated { probe.setFrameSize(NSSize(width: 200, height: 20)) }
      }
      defer { watch.invalidate() }
      split.toggle()
      MainLoop.run(for: SidebarSlide.duration + 0.5)
      #expect(probe.widths == [200])
      #expect(!NSAnimationContext.current.allowsImplicitAnimation)
      #expect(NSAnimationContext.current.duration > 0)
    }

    @Test("A collapse outside an animation group leaves the context as it found it")
    func collapseOutsideAGroup() {
      let split = Split(mode: .prerendered)
      defer { split.close() }
      let context = NSAnimationContext.current
      let duration = context.duration
      split.sidebarItem.isCollapsed = true
      // Held while the window lays out at its new widths, given back before the frame.
      #expect(context.duration == 0)
      MainLoop.run(for: 0.05)
      #expect(context.duration == duration)
      #expect(!context.allowsImplicitAnimation)
      #expect(!SidebarSlide.holdsAnimations)
    }

    @Test("Without pictures the collapse still takes one layout, and nothing moves")
    func instantLaysOutOnce() {
      let split = Split(mode: .instant)
      defer { split.close() }
      let before = split.column.widths.count
      split.toggle()
      MainLoop.run(for: 0.05)
      #expect(split.sidebarItem.isCollapsed)
      #expect(split.column.widths.count == before + 1)
      #expect(!split.slide.isSliding)
      #expect(split.columnMove == nil)
    }

    @Test("The launch argument picks how the sidebar slides")
    func modeSetting() throws {
      let defaults = try #require(UserDefaults(suiteName: "SidebarSlideTests"))
      defer { defaults.removePersistentDomain(forName: "SidebarSlideTests") }
      #expect(SidebarSlideMode.read(defaults) == .prerendered)
      defaults.set("animated", forKey: "omnigent:sidebar-slide")
      #expect(SidebarSlideMode.read(defaults) == .animated)
      defaults.set("instant", forKey: "omnigent:sidebar-slide")
      #expect(SidebarSlideMode.read(defaults) == .instant)
    }
  }
#endif
