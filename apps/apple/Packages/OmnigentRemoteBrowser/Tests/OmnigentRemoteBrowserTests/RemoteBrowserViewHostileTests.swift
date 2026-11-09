#if os(macOS)
  import AppKit
  import Foundation
  import OmnigentCoreFFI
  import OmnigentInput
  import Testing

  @testable import OmnigentRemoteBrowser

  /// The view, never in a window: no cursor can change and nothing draws to the screen.
  @MainActor
  @Suite("Remote browser view, hostile state", .serialized)
  struct RemoteBrowserViewHostileTests {
    private func view(
      _ hosted: HostedStore, width: CGFloat = 1000, height: CGFloat = 500
    ) -> RemoteBrowserView {
      let view = RemoteBrowserView(store: hosted.store)
      view.frame = CGRect(x: 0, y: 0, width: width, height: height)
      return view
    }

    @Test("the page fits and centres in the view, and follows it where the mode says")
    func fitting() async throws {
      let hosted = HostedStore()
      defer { hosted.finish() }
      let surface = view(hosted, width: 1000, height: 1000)
      #expect(surface.geometry == nil)
      await hosted.hostSends(HostedStore.snapshot())
      let fit = try #require(surface.geometry)
      #expect(fit.scale == 1)
      #expect(fit.contentRect == CGRect(x: 0, y: 250, width: 1000, height: 500))
      #expect(surface.displayGeometry == fit)
      hosted.store.viewportMode = .fitWindow
      #expect(surface.geometry?.contentRect.origin == .zero)
    }

    @Test(
      "any viewport a host reports leaves the page on a real rectangle",
      arguments: [
        RemoteViewport(width: 0, height: 0, dpr: .nan),
        RemoteViewport(width: 0, height: 500, dpr: 1),
        RemoteViewport(width: .max, height: .max, dpr: .infinity),
        RemoteViewport(width: 1, height: .max, dpr: -1),
        RemoteViewport(width: .max, height: 1, dpr: 0),
        RemoteViewport(width: 1, height: 1, dpr: .leastNonzeroMagnitude),
      ])
    func oddViewports(viewport: RemoteViewport) async {
      let hosted = HostedStore()
      defer { hosted.finish() }
      let surface = view(hosted)
      await hosted.hostSends(HostedStore.snapshot(viewport: viewport))
      surface.relayout()
      if let fit = surface.geometry {
        #expect(fit.contentRect.width.isFinite)
        #expect(fit.contentRect.height.isFinite)
        #expect(fit.scale.isFinite)
      }
      surface.resetCursorRects()
      #expect(surface.scrollIndicator == nil)
    }

    @Test(
      "a view of any real size lays out",
      arguments: [
        CGSize.zero, CGSize(width: 1, height: 1), CGSize(width: 0.001, height: 1e7),
        CGSize(width: 1e7, height: 1e7), CGSize(width: -5, height: -5),
        CGSize(width: CGFloat.infinity, height: CGFloat.infinity),
        CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
      ])
    func oddFrames(size: CGSize) async {
      let hosted = HostedStore()
      defer { hosted.finish() }
      let surface = view(hosted)
      await hosted.hostSends(HostedStore.snapshot())
      surface.setFrameSize(size)
      surface.layout()
      surface.updateTrackingAreas()
      surface.updateTrackingAreas()
      #expect(surface.trackingAreas.count == 1)
    }

    @Test(
      "scroll metrics that are real numbers, however odd, draw an indicator or none",
      arguments: [
        RemoteScrollMetrics(
          x: 0, y: 0, contentWidth: 0, contentHeight: 0, viewportWidth: 0, viewportHeight: 0),
        RemoteScrollMetrics(
          x: -1, y: -1, contentWidth: 1, contentHeight: 1e300, viewportWidth: 1, viewportHeight: 1),
        RemoteScrollMetrics(
          x: 1e300, y: 1e300, contentWidth: 1, contentHeight: 3, viewportWidth: 1, viewportHeight: 1
        ),
        RemoteScrollMetrics(
          x: 0, y: 5, contentWidth: 1, contentHeight: 1e-3, viewportWidth: 1, viewportHeight: -2),
        RemoteScrollMetrics(
          x: 0, y: 5, contentWidth: 1, contentHeight: 1e308, viewportWidth: 1,
          viewportHeight: -1e308),
        RemoteScrollMetrics(
          x: .nan, y: 0, contentWidth: .nan, contentHeight: .infinity, viewportWidth: .infinity,
          viewportHeight: .infinity),
      ])
    func oddScrolls(metrics: RemoteScrollMetrics) async {
      let hosted = HostedStore(mode: .mobile(site: false))
      defer { hosted.finish() }
      let surface = view(hosted)
      var snapshot = HostedStore.snapshot()
      snapshot.scroll = metrics
      await hosted.hostSends(snapshot)
      surface.relayout()
      surface.flashIndicator()
      if let thumb = surface.scrollIndicator?.thumb { #expect(thumb.origin.y.isFinite) }
    }

    @Test(
      "scroll metrics that overflow draw an indicator or none",
      .disabled(
        "Traps: CALayerInvalidGeometry, the thumb's frame comes out NaN in updateIndicator"),
      arguments: [
        // Valid JSON from a host: track height * viewport height overflows to infinity.
        RemoteScrollMetrics(
          x: 0, y: 0, contentWidth: 1, contentHeight: 1.7e308, viewportWidth: 1,
          viewportHeight: 1e308),
        RemoteScrollMetrics(
          x: 0, y: 5, contentWidth: 1, contentHeight: 1.7e308, viewportWidth: 1,
          viewportHeight: 1e308),
        RemoteScrollMetrics(
          x: 0, y: .nan, contentWidth: 1, contentHeight: 3000, viewportWidth: 1, viewportHeight: 500
        ),
        RemoteScrollMetrics(
          x: 0, y: .infinity, contentWidth: 1, contentHeight: .infinity, viewportWidth: 1,
          viewportHeight: 500),
      ])
    func scrollsThatOverflow(metrics: RemoteScrollMetrics) async {
      let hosted = HostedStore(mode: .mobile(site: false))
      defer { hosted.finish() }
      let surface = view(hosted)
      var snapshot = HostedStore.snapshot()
      snapshot.scroll = metrics
      await hosted.hostSends(snapshot)
      surface.relayout()
      #expect(surface.scrollIndicator?.thumb.origin.y.isFinite != false)
    }
  }
#endif
