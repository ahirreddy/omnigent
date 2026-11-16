#if os(macOS)
  import AppKit
  import CoreImage
  import Foundation
  import IOSurface
  import OmnigentViewTesting
  import Testing

  @testable import OmnigentTerminalUI

  /// The frames libghostty presents while the main thread is busy.
  @MainActor
  @Suite("Presented terminal frames", .serialized)
  struct PresentedFrameTests {
    /// The IOSurface the layer holds now: the frame Core Animation shows.
    private static func shown(_ controller: TerminalSurfaceController) -> IOSurface? {
      controller.view.layer?.contents as? IOSurface
    }

    private static func pixels(_ surface: IOSurface) throws -> Data {
      let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
      return try #require(
        CIContext().pngRepresentation(
          of: CIImage(ioSurface: surface), format: .RGBA8, colorSpace: space))
    }

    /// A full screen of `marker`'s last digit, in synchronized output, as a TUI redraws.
    private static func screen(_ marker: Int, grid: TerminalGridSize?) -> [UInt8] {
      let rows = grid?.rows ?? 24
      let columns = grid?.columns ?? 80
      var text = "\u{1B}[?2026h\u{1B}[H\u{1B}[2J"
      for row in 0..<rows {
        let line = String(repeating: "\(marker % 10)", count: max(columns - 8, 1))
        text += "\u{1B}[\(row + 1);1H\(row):\(line)"
      }
      return Array((text + "\u{1B}[?2026l").utf8)
    }

    /// A program redraws its screen every 30 ms while the main thread stays busy, as it is
    /// while a chat streams the same turn: libghostty draws meanwhile, but no frame can reach
    /// the layer until the main thread is free.
    @Test("a busy main thread never has the frame Core Animation shows drawn over")
    func busyMainThread() async throws {
      let surface = try WindowedSurface(width: 640, height: 400)
      defer { surface.screen.close() }
      let controller = surface.controller
      #expect(await surface.ready())
      // The terminal with the keyboard draws on every display refresh.
      controller.focus()
      #expect(await surface.settles { Self.shown(controller) != nil })
      try await Task.sleep(for: .milliseconds(300))
      var drawnOver = 0
      var surfaces = Set<ObjectIdentifier>()
      for burst in 0..<8 {
        let shown = try #require(Self.shown(controller))
        surfaces.insert(ObjectIdentifier(shown))
        let before = try Self.pixels(shown)
        for frame in 0..<6 {
          controller.render(.bytes(Self.screen(burst * 10 + frame, grid: controller.gridSize)))
          usleep(30_000)
        }
        if Self.shown(controller) === shown, try Self.pixels(shown) != before { drawnOver += 1 }
        try await Task.sleep(for: .milliseconds(150))
      }
      #expect(drawnOver == 0, "the shown frame was drawn over in \(drawnOver) of 8 bursts")
      #expect(surfaces.count > 1, "the bursts' frames reach the layer")
      controller.render(.bytes(Array("\r\nall output parsed".utf8)))
      #expect(await surface.settles { controller.visibleText().contains("all output parsed") })
    }
  }
#endif
