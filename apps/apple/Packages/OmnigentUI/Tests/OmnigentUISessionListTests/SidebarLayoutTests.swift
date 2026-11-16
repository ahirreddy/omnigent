#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  /// A shown sidebar takes its width from the content: the detail column (and a split view's
  /// panes in it) sits beside the sidebar, not under it. The window is never shown.
  @Suite("The Mac sidebar resizes the content")
  @MainActor
  struct SidebarLayoutTests {
    private let windowWidth: CGFloat = 1300

    @Test("the detail column sits beside a shown sidebar, before and after a toggle")
    func detailBesideSidebar() throws {
      let toggle = SidebarToggle()
      let window = NSWindow(
        contentRect: CGRect(x: 0, y: 0, width: windowWidth, height: 800),
        styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.contentViewController = NSHostingController(
        rootView: TabsPlayground(split: true).environment(\.sidebarToggle, toggle))
      window.setContentSize(CGSize(width: windowWidth, height: 800))
      defer { window.close() }
      settle(window)

      let controller = try #require(window.contentView.flatMap(splitController(in:)))
      let sidebar = try #require(controller.splitViewItems.first { $0.behavior == .sidebar })
      let detail = try #require(controller.splitViewItems.first { $0.behavior == .default })
      expectBeside(sidebar: sidebar, detail: detail)
      let shownWidth = sidebar.viewController.view.frame.width

      toggle()
      #expect(
        MainLoop.settle(until: {
          window.contentView?.layoutSubtreeIfNeeded()
          return sidebar.isCollapsed && detail.viewController.view.frame.width == windowWidth
        }))

      // Shown again once the sidebar is back at its width.
      toggle()
      #expect(
        MainLoop.settle(until: {
          window.contentView?.layoutSubtreeIfNeeded()
          return !sidebar.isCollapsed && sidebar.viewController.view.frame.width == shownWidth
        }))
      expectBeside(sidebar: sidebar, detail: detail)
    }

    private func expectBeside(sidebar: NSSplitViewItem, detail: NSSplitViewItem) {
      let detailView = detail.viewController.view
      #expect(!detail.automaticallyAdjustsSafeAreaInsets)
      #expect(detailView.safeAreaInsets.left == 0)
      #expect(
        detailView.frame.width <= windowWidth - sidebar.viewController.view.frame.width)
    }

    /// Lets the never-shown window's split view finish laying out, as long as it keeps working.
    private func settle(_ window: NSWindow) {
      MainLoop.settle(limit: 0.6, windows: [window])
    }

    private func splitController(in view: NSView) -> NSSplitViewController? {
      if let split = view as? NSSplitView, let controller = split.delegate as? NSSplitViewController
      {
        return controller
      }
      return view.subviews.lazy.compactMap(splitController(in:)).first
    }
  }
#endif
