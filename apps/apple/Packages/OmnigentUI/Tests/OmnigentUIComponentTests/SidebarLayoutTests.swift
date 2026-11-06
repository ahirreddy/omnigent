#if os(macOS)
  import AppKit
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
      settle()

      let controller = try #require(window.contentView.flatMap(splitController(in:)))
      let sidebar = try #require(controller.splitViewItems.first { $0.behavior == .sidebar })
      let detail = try #require(controller.splitViewItems.first { $0.behavior == .default })
      expectBeside(sidebar: sidebar, detail: detail)

      toggle()
      settle()
      #expect(sidebar.isCollapsed)
      #expect(detail.viewController.view.frame.width == windowWidth)

      toggle()
      settle()
      #expect(!sidebar.isCollapsed)
      expectBeside(sidebar: sidebar, detail: detail)
    }

    private func expectBeside(sidebar: NSSplitViewItem, detail: NSSplitViewItem) {
      let detailView = detail.viewController.view
      #expect(!detail.automaticallyAdjustsSafeAreaInsets)
      #expect(detailView.safeAreaInsets.left == 0)
      #expect(
        detailView.frame.width <= windowWidth - sidebar.viewController.view.frame.width)
    }

    private func settle() {
      RunLoop.main.run(until: Date().addingTimeInterval(0.6))
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
