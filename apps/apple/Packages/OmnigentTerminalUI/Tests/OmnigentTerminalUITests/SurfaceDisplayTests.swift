#if os(macOS)
  import AppKit
  import Foundation
  import OmnigentViewTesting
  import Testing

  @testable import OmnigentTerminalUI

  /// A surface in a window on a display, as the app shows it.
  @MainActor
  @Suite("The display a terminal paces its frames to", .serialized)
  struct SurfaceDisplayTests {
    @Test("a surface paces its frames to the display its window is on")
    func displayOfTheWindow() async throws {
      SystemSideEffects.install()
      let controller = try TerminalSurfaceController(connection: EchoTerminalConnection())
      let host = try SurfaceHost(controller: controller, width: 480, height: 240)
      let screen = try #require(host.window.screen, "the window is on a display")
      let display = try #require(
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32)
      #expect(await eventually { controller.displayID == display })
    }
  }
#endif
