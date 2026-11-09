#if os(macOS)
  import AppKit
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  @Suite("Toggling the sidebar just after a window resizes", .serialized)
  @MainActor
  struct AppShellSidebarToggleTests {
    /// A resize and the toggle's animated update in one layout pass makes the window run away.
    @Test("No layout is left waiting for the next pass when the toggle returns")
    func layoutSettlesAroundToggle() {
      let toggle = SidebarToggle()
      let shell = AppShell(
        sidebar: SidebarSamples.empty, selection: .constant(nil), searchText: .constant(""),
        actions: SidebarActions(sessions: SessionListActions())
      ) { _ in
        Color.red
      }
      .environment(\.sidebarToggle, toggle)
      // A plain window, so it isn't key: the toggle has to reach a window in the background too.
      NSApplication.shared.setActivationPolicy(.accessory)
      let host = NSHostingView(rootView: shell)
      let window = NSWindow(
        contentRect: CGRect(x: -20_000, y: -20_000, width: 900, height: 600),
        styleMask: [.borderless], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.contentView = host
      window.orderFrontRegardless()
      defer {
        window.orderOut(nil)
        window.contentView = nil
        // AppKit queues run loop stops as windows change; left to the runner, one ends it early.
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
      }
      RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
      #expect(!window.isKeyWindow)

      // What a resize leaves behind when it arrives just before the toggle.
      host.needsLayout = true
      toggle()
      #expect(!host.needsLayout)
    }
  }
#endif
