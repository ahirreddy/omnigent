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
      // Without the keyboard the terminal draws only when its content changes, so every frame
      // comes from the output under test; a blinking cursor would add frames of its own.
      #expect(surface.screen.window.makeFirstResponder(nil))
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

    /// A wheel event of whole lines; positive scrolls back toward older lines.
    private static func wheel(lines: Int32) throws -> NSEvent {
      let event = try #require(
        CGEvent(
          scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: lines, wheel2: 0,
          wheel3: 0))
      return try #require(NSEvent(cgEvent: event))
    }

    /// A surface with a long scrollback, scrolled to its newest line.
    private static func scrolledSurface(keyboard: Bool) async throws -> WindowedSurface {
      let surface = try WindowedSurface(width: 640, height: 400)
      let controller = surface.controller
      #expect(await surface.ready())
      controller.feed(WindowedSurface.numberedLines(2000))
      #expect(await surface.settles { controller.visibleText().contains("line-2000") })
      #expect(surface.screen.window.makeFirstResponder(keyboard ? controller.view : nil))
      #expect(await surface.settles { Self.shown(controller) != nil })
      try await Task.sleep(for: .milliseconds(300))
      return surface
    }

    /// The wheel scrolls the scrollback while the main thread stays busy, as it is while a chat
    /// streams beside the terminal. Scrolling draws a frame for every step without any output,
    /// so the output pacing does not apply: only the renderer can keep the shown frame intact.
    @Test(
      "scrolling while the main thread is busy never draws over the frame Core Animation shows",
      arguments: [false, true])
    func busyMainThreadScroll(keyboard: Bool) async throws {
      let surface = try await Self.scrolledSurface(keyboard: keyboard)
      defer { surface.screen.close() }
      let controller = surface.controller
      let framesBefore = controller.framesShown
      var drawnOver = 0
      for _ in 0..<8 {
        let shown = try #require(Self.shown(controller))
        let before = try Self.pixels(shown)
        for _ in 0..<6 {
          controller.view.scrollWheel(with: try Self.wheel(lines: 2))
          usleep(30_000)
        }
        if Self.shown(controller) === shown, try Self.pixels(shown) != before { drawnOver += 1 }
        try await Task.sleep(for: .milliseconds(150))
      }
      #expect(drawnOver == 0, "the shown frame was drawn over in \(drawnOver) of 8 bursts")
      #expect(controller.framesShown - framesBefore >= 8, "the scrolled frames reach the layer")
    }

    /// A frame skipped because every IOSurface was still on screen or queued for it is drawn
    /// once one is free, so the layer ends on the newest scroll position. Without the keyboard
    /// no display link asks for that frame again.
    @Test("a frame skipped while the main thread was busy is drawn once it is free")
    func skippedFrameIsDrawn() async throws {
      let surface = try await Self.scrolledSurface(keyboard: false)
      defer { surface.screen.close() }
      let controller = surface.controller
      for _ in 0..<12 {
        controller.view.scrollWheel(with: try Self.wheel(lines: 2))
        usleep(30_000)
      }
      try await Task.sleep(for: .milliseconds(400))
      let settled = try Self.pixels(try #require(Self.shown(controller)))
      // Away and back redraws the same rows while the main thread is free.
      for lines: Int32 in [-2, 2] {
        let before = controller.framesShown
        controller.view.scrollWheel(with: try Self.wheel(lines: lines))
        #expect(await surface.settles { controller.framesShown > before })
        try await Task.sleep(for: .milliseconds(200))
      }
      let redrawn = try Self.pixels(try #require(Self.shown(controller)))
      #expect(settled == redrawn, "the layer kept an older scroll position")
    }

    /// Held output waits for the count of frames on the layer to move, not for its limit.
    @Test("each frame libghostty puts on the layer is counted")
    func framesOnTheLayerAreCounted() async throws {
      let surface = try WindowedSurface(width: 640, height: 400)
      defer { surface.screen.close() }
      let controller = surface.controller
      #expect(await surface.ready())
      for marker in 1...3 {
        let before = controller.framesShown
        controller.render(.bytes(Self.screen(marker, grid: controller.gridSize)))
        #expect(await surface.settles { controller.framesShown > before }, "frame \(marker)")
      }
    }
  }
#endif
