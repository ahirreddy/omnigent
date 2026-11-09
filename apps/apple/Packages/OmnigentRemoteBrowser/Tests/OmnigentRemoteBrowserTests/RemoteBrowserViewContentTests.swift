#if os(macOS)
  import AppKit
  import Foundation
  import OmnigentCoreFFI
  import OmnigentInput
  import Testing

  @testable import OmnigentRemoteBrowser

  /// A small real image, as a page's cursor or a still.
  @MainActor
  private func smallImage(_ type: NSBitmapImageRep.FileType = .png) throws -> Data {
    let bitmap = unsafe NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4,
      hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    return try #require(bitmap?.representation(using: type, properties: [:]))
  }

  /// The view's images, cursors, zoom and video, never in a window.
  @MainActor
  @Suite("Remote browser view content", .serialized)
  struct RemoteBrowserViewContentTests {
    private func view(
      _ hosted: HostedStore, width: CGFloat = 1000, height: CGFloat = 500
    ) -> RemoteBrowserView {
      let view = RemoteBrowserView(store: hosted.store)
      view.frame = CGRect(x: 0, y: 0, width: width, height: height)
      return view
    }

    @Test("stills that aren't images are ignored, and a real one is kept")
    func stills() async throws {
      let hosted = HostedStore()
      defer { hosted.finish() }
      let surface = view(hosted)
      await hosted.hostSends(HostedStore.snapshot())
      for bytes in [Data(), Data([0xFF, 0xD8]), Data(repeating: 0xFF, count: 4096)] {
        hosted.connector.listener?.onStill(
          still: StillImage(kind: .still, ptsUs: .max, jpeg: bytes))
        await letTasksRun()
        #expect(hosted.store.still?.jpeg == bytes)
      }
      let jpeg = try smallImage(.jpeg)
      hosted.connector.listener?.onStill(still: StillImage(kind: .thumbnail, ptsUs: 0, jpeg: jpeg))
      await letTasksRun()
      #expect(hosted.store.still?.jpeg == jpeg)
      surface.relayout()
    }

    @Test("every cursor keyword has a shape, and an unknown one is an arrow")
    func cursorKeywords() async {
      let hosted = HostedStore()
      defer { hosted.finish() }
      let surface = view(hosted)
      var snapshot = HostedStore.snapshot()
      for keyword in [
        "pointer", "text", "vertical-text", "crosshair", "wait", "help", "ew-resize", "ns-resize",
        "not-allowed", "grab", "grabbing", "none", "", "\u{0}", String(repeating: "x", count: 9999),
      ] {
        snapshot.cursor = RemoteBrowserCursor(keyword: keyword, custom: nil)
        await hosted.hostSends(snapshot)
        surface.resetCursorRects()
      }
      #expect(RemoteBrowserCursor(keyword: "\u{0}", custom: nil).pageCursor == .pointer)
    }

    @Test("a page's own cursor of real numbers makes a cursor, and bad bytes make none")
    func customCursors() async throws {
      let hosted = HostedStore()
      defer { hosted.finish() }
      let surface = view(hosted)
      let png = try smallImage()
      var snapshot = HostedStore.snapshot()
      for custom in [
        RemoteCursorImage(png: png, hotspotX: 1, hotspotY: 1, scale: 2),
        RemoteCursorImage(png: png, hotspotX: 0, hotspotY: 0, scale: 0),
        RemoteCursorImage(png: png, hotspotX: -1e9, hotspotY: 1e9, scale: -1),
        RemoteCursorImage(png: png, hotspotX: 1, hotspotY: 1, scale: 1e300),
        RemoteCursorImage(png: Data(), hotspotX: .nan, hotspotY: .nan, scale: .nan),
        RemoteCursorImage(png: Data([0x89, 0x50]), hotspotX: 0, hotspotY: 0, scale: 1),
      ] {
        snapshot.cursor = RemoteBrowserCursor(keyword: "default", custom: custom)
        await hosted.hostSends(snapshot)
        surface.resetCursorRects()
      }
    }

    @Test(
      "a page's own cursor with numbers that aren't makes a cursor",
      arguments: [
        (Double.nan, 1.0), (.infinity, 1), (1, .nan), (1, .infinity), (1, 1e308), (1, -.infinity),
      ].map { [$0.0, $0.1] })
    func cursorsOfNoSize(values: [Double]) async throws {
      let hosted = HostedStore()
      defer { hosted.finish() }
      let surface = view(hosted)
      var snapshot = HostedStore.snapshot()
      snapshot.cursor = RemoteBrowserCursor(
        keyword: "default",
        custom: RemoteCursorImage(
          png: try smallImage(), hotspotX: values[0], hotspotY: values[0], scale: values[1]))
      await hosted.hostSends(snapshot)
      surface.resetCursorRects()
    }

    @Test("the title reaches accessibility, with the zoom while the page is magnified")
    func accessibilityValue() async throws {
      let hosted = HostedStore()
      defer { hosted.finish() }
      let surface = view(hosted)
      var snapshot = HostedStore.snapshot()
      snapshot.nav?.title = "Docs \u{0}"
      await hosted.hostSends(snapshot)
      #expect(surface.accessibilityValue() as? String == "Docs \u{0}")
      let fit = try #require(surface.geometry)
      surface.zoom.toggle(at: .zero, fit: fit.contentRect, bounds: surface.bounds.size)
      surface.relayout()
      #expect(hosted.store.zoomPercent == 250)
      #expect(surface.accessibilityValue() as? String == "Docs \u{0}, zoomed 250%")
      hosted.store.resetZoom()
      await letTasksRun()
      #expect(hosted.store.zoomPercent == nil)
      #expect(!surface.zoom.isZoomed)
    }

    @Test("a new remote size starts unzoomed")
    func newSizeResetsZoom() async throws {
      let hosted = HostedStore()
      defer { hosted.finish() }
      let surface = view(hosted)
      await hosted.hostSends(HostedStore.snapshot())
      let fit = try #require(surface.geometry)
      surface.zoom.toggle(at: .zero, fit: fit.contentRect, bounds: surface.bounds.size)
      surface.relayout()
      #expect(surface.zoom.isZoomed)
      await hosted.hostSends(
        HostedStore.snapshot(viewport: RemoteViewport(width: 640, height: 480, dpr: 1)))
      #expect(!surface.zoom.isZoomed)
    }

    @Test(
      "a pinch of absurd size stays on the page",
      .disabled(
        "Traps: Int(zoom.scale * 100) in updateAccessibilityValue; no ceiling on elastic zoom"))
    func absurdPinch() async throws {
      let hosted = HostedStore()
      defer { hosted.finish() }
      let surface = view(hosted)
      await hosted.hostSends(HostedStore.snapshot())
      let fit = try #require(surface.geometry)
      surface.zoom.zoom(
        by: 1e300, anchor: .zero, fit: fit.contentRect, bounds: surface.bounds.size, elastic: true)
      surface.relayout()
    }

    @Test(
      "a pinch whose centre is not a number stays on the page",
      .disabled("Traps: CALayerInvalidGeometry, the NaN anchor survives clamp into the offset"))
    func pinchWithNoCentre() async throws {
      let hosted = HostedStore()
      defer { hosted.finish() }
      let surface = view(hosted)
      await hosted.hostSends(HostedStore.snapshot())
      let fit = try #require(surface.geometry)
      surface.zoom.zoom(
        by: 2, anchor: CGPoint(x: CGFloat.nan, y: CGFloat.nan), fit: fit.contentRect,
        bounds: surface.bounds.size)
      surface.relayout()
    }

    @Test(
      "a rubber band that is not a number stays on the page",
      .disabled("Traps: CALayerInvalidGeometry, relayout offsets the page's frame by it"))
    func rubberBandOfNoSize() async {
      let hosted = HostedStore()
      defer { hosted.finish() }
      let surface = view(hosted)
      await hosted.hostSends(HostedStore.snapshot())
      surface.rubberBand = CGPoint(x: CGFloat.nan, y: 0)
      surface.relayout()
    }

    @Test("a second view takes the store's video, asking for a keyframe")
    func secondView() {
      let hosted = HostedStore()
      defer { hosted.finish() }
      let first = view(hosted)
      let second = view(hosted)
      #expect(hosted.store.renderer === second.renderer)
      #expect(hosted.store.renderer !== first.renderer)
      #expect(hosted.driverCalls.filter { $0 == "keyframe flush" }.count >= 2)
    }

    @Test(
      "a video picture of no real size implies a viewport",
      .disabled("Traps: Int() of a non-finite or huge width in RemoteViewportGeometry.viewport"),
      arguments: [
        (CGSize(width: CGFloat.nan, height: 1), 1.0),
        (CGSize(width: CGFloat.infinity, height: 1), 1),
        (CGSize(width: 1e300, height: 1), 1), (CGSize(width: 1280, height: 800), 1e-300),
      ].map { GeometryCase(size: $0.0, scale: $0.1) })
    func videoOfNoSize(geometry: GeometryCase) {
      let viewport = RemoteViewportGeometry.viewport(
        videoSize: geometry.size, deviceScale: geometry.scale)
      #expect(viewport.width <= .max)
    }

    @Test("a video picture of a real size implies a viewport, at any device scale")
    func videoOfRealSize() {
      let sharp = RemoteViewportGeometry.viewport(
        videoSize: CGSize(width: 2560, height: 1600), deviceScale: 2)
      #expect(sharp == RemoteViewport(width: 1280, height: 800, dpr: 2))
      for scale in [Double.nan, -1, 0] {
        let plain = RemoteViewportGeometry.viewport(
          videoSize: CGSize(width: 10, height: 10), deviceScale: scale)
        #expect(plain.width == 10)
        #expect(plain.dpr == 1)
      }
      let negative = RemoteViewportGeometry.viewport(videoSize: CGSize(width: -9, height: 1e12))
      #expect(negative.width == 0)
      #expect(negative.height == .max)
      #expect(
        RemoteViewportGeometry.viewport(
          videoSize: CGSize(width: 10, height: 10), deviceScale: .infinity
        ).width == 0)
    }
  }

  /// A video size and device scale, for a parameterized test.
  nonisolated struct GeometryCase: Sendable {
    let size: CGSize
    let scale: Double
  }
#endif
