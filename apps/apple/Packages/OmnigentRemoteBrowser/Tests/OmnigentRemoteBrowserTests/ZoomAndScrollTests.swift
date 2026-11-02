import CoreGraphics
import Foundation
import OmnigentCoreFFI
import Testing

@testable import OmnigentRemoteBrowser

/// The local zoom transform, input mapping through it, and the scroll physics (design doc
/// sections 16.3 and 16.4).
@Suite("Remote browser zoom and scroll math")
struct ZoomAndScrollTests {
  /// A 1280×800 page letterboxed in a 1000×800 view: fit 1000×625 at y 87.5.
  private let viewport = RemoteViewport(width: 1280, height: 800, dpr: 1)
  private let bounds = CGSize(width: 1000, height: 800)
  private var geometry: RemoteViewportGeometry {
    get throws { try #require(RemoteViewportGeometry(viewport: viewport, bounds: bounds)) }
  }

  private func close(_ left: CGPoint?, _ right: CGPoint, within tolerance: Double = 0.001) -> Bool {
    guard let left else { return false }
    return abs(left.x - right.x) < tolerance && abs(left.y - right.y) < tolerance
  }

  @Test func unzoomedIsTheFit() throws {
    let zoom = RemoteZoomState()
    #expect(zoom.apply(to: try geometry) == (try geometry))
    #expect(!zoom.isZoomed)
  }

  @Test func zoomKeepsThePagePointUnderTheAnchor() throws {
    var zoom = RemoteZoomState()
    let anchor = CGPoint(x: 700, y: 400)
    let before = try geometry.cssPoint(for: anchor)
    zoom.zoom(by: 2, anchor: anchor, fit: try geometry.contentRect, bounds: bounds)
    let zoomed = zoom.apply(to: try geometry)
    #expect(zoom.scale == 2)
    #expect(close(zoomed.cssPoint(for: anchor), try #require(before)))
    #expect(zoomed.scale == (try geometry.scale) * 2)
    // A tap anywhere maps to the page pixel drawn there, and back.
    let css = try #require(zoomed.cssPoint(for: CGPoint(x: 120, y: 650)))
    #expect(close(zoomed.viewPoint(for: css), CGPoint(x: 120, y: 650)))
    // Wheel deltas shrink with the zoom: one point is less of the page.
    #expect(abs(zoomed.cssLength(10) - (try geometry.cssLength(10)) / 2) < 1e-9)
  }

  @Test func zoomIsClampedAndTheZoomedPageCoversTheView() throws {
    var zoom = RemoteZoomState()
    zoom.zoom(by: 50, anchor: .zero, fit: try geometry.contentRect, bounds: bounds)
    #expect(zoom.scale == RemoteZoomState.maxScale)
    let rect = zoom.contentRect(fit: try geometry.contentRect)
    #expect(rect.minX <= 0 && rect.minY <= 0)
    #expect(rect.maxX >= bounds.width && rect.maxY >= bounds.height)
    zoom.zoom(by: 0.01, anchor: .zero, fit: try geometry.contentRect, bounds: bounds)
    #expect(zoom == RemoteZoomState())
  }

  @Test func pinchRubberBandsAndSettles() throws {
    var zoom = RemoteZoomState()
    let anchor = CGPoint(x: 500, y: 400)
    zoom.zoom(by: 0.5, anchor: anchor, fit: try geometry.contentRect, bounds: bounds, elastic: true)
    #expect(zoom.scale < 1 && zoom.scale > 0.5, "beyond the limit with resistance")
    zoom.settle(anchor: anchor, fit: try geometry.contentRect, bounds: bounds)
    #expect(zoom == RemoteZoomState())
    zoom.zoom(by: 8, anchor: anchor, fit: try geometry.contentRect, bounds: bounds, elastic: true)
    #expect(zoom.scale > RemoteZoomState.maxScale)
    zoom.settle(anchor: anchor, fit: try geometry.contentRect, bounds: bounds)
    #expect(zoom.scale == RemoteZoomState.maxScale)
  }

  @Test func panMovesTheZoomedPageAndReturnsWhatIsLeftForThePage() throws {
    var zoom = RemoteZoomState()
    // Unzoomed, everything scrolls the page.
    #expect(
      zoom.pan(by: CGPoint(x: 0, y: -40), fit: try geometry.contentRect, bounds: bounds)
        == CGPoint(x: 0, y: -40))
    zoom.zoom(by: 2, anchor: CGPoint(x: 500, y: 400), fit: try geometry.contentRect, bounds: bounds)
    let rect = zoom.contentRect(fit: try geometry.contentRect)
    let roomDown = -rect.minY  // How far the page can move down before its top edge shows.
    let left = zoom.pan(
      by: CGPoint(x: 0, y: roomDown + 30), fit: try geometry.contentRect, bounds: bounds)
    #expect(abs(left.y - 30) < 1e-9, "the rest scrolls the page")
    #expect(abs(zoom.contentRect(fit: try geometry.contentRect).minY) < 1e-9)
  }

  @Test func doubleTapTogglesAtThePoint() throws {
    var zoom = RemoteZoomState()
    let point = CGPoint(x: 300, y: 300)
    let css = try #require(try geometry.cssPoint(for: point))
    zoom.toggle(at: point, fit: try geometry.contentRect, bounds: bounds)
    #expect(zoom.scale == RemoteZoomState.doubleTapScale)
    #expect(close(zoom.apply(to: try geometry).cssPoint(for: point), css))
    zoom.toggle(at: point, fit: try geometry.contentRect, bounds: bounds)
    #expect(zoom == RemoteZoomState())
  }

  @Test func scrollBarsAreAtTheEdgesOfAScrollingPage() throws {
    let tall = RemoteScrollMetrics(
      x: 0, y: 0, contentWidth: 1280, contentHeight: 5000, viewportWidth: 1280,
      viewportHeight: 800)
    let wide = RemoteScrollMetrics(
      x: 0, y: 0, contentWidth: 3000, contentHeight: 800, viewportWidth: 1280,
      viewportHeight: 800)
    // 0.78 points per CSS px: the 22-point target is about 28 CSS px.
    let scale = try geometry.scale
    #expect(
      RemoteTouchRegions.isOnScrollBar(
        css: CGPoint(x: 1260, y: 300), viewport: viewport, pointsPerCSS: scale, scroll: tall))
    #expect(
      !RemoteTouchRegions.isOnScrollBar(
        css: CGPoint(x: 1200, y: 300), viewport: viewport, pointsPerCSS: scale, scroll: tall))
    #expect(
      !RemoteTouchRegions.isOnScrollBar(
        css: CGPoint(x: 600, y: 790), viewport: viewport, pointsPerCSS: scale, scroll: tall),
      "no horizontal bar on a page that does not scroll sideways")
    #expect(
      RemoteTouchRegions.isOnScrollBar(
        css: CGPoint(x: 600, y: 790), viewport: viewport, pointsPerCSS: scale, scroll: wide))
    #expect(
      !RemoteTouchRegions.isOnScrollBar(
        css: CGPoint(x: 1270, y: 300), viewport: viewport, pointsPerCSS: scale, scroll: wide))
    // Zoomed in, the band is the scroll bar itself.
    #expect(
      !RemoteTouchRegions.isOnScrollBar(
        css: CGPoint(x: 1260, y: 300), viewport: viewport, pointsPerCSS: 4, scroll: tall))
  }

  @Test func momentumMatchesUIScrollViewDeceleration() throws {
    var momentum = RemoteMomentum(velocity: CGPoint(x: 0, y: 3000))
    var travelled = 0.0
    var frames = 0
    while !momentum.isFinished, frames < 10_000 {
      travelled += momentum.step(1.0 / 60).y
      frames += 1
    }
    // The integral of 3000·0.998^t (t in ms) is 3000 / (1000·ln(1/0.998)) ≈ 1498.5 points.
    let total = 3000 / (1000 * -log(RemoteScrollPhysics.decelerationRate))
    #expect(abs(travelled - total) < 15, "\(travelled) vs \(total)")
    // About 2.8 s at 60 Hz until it is slower than 12 points per second.
    #expect((150...190).contains(frames), "\(frames)")
    // Frame rate does not change the distance (the step is the exact integral).
    var coarse = RemoteMomentum(velocity: CGPoint(x: 0, y: 3000))
    var coarseTravelled = 0.0
    while !coarse.isFinished { coarseTravelled += coarse.step(1.0 / 20).y }
    #expect(abs(coarseTravelled - travelled) < 2)
  }

  @Test func rubberBandResistsAndSpringsBack() throws {
    #expect(RemoteScrollPhysics.rubberBand(0, dimension: 800) == 0)
    let small = RemoteScrollPhysics.rubberBand(20, dimension: 800)
    #expect(small > 0 && small < 20)
    let large = RemoteScrollPhysics.rubberBand(5000, dimension: 800)
    #expect(large < 800)
    #expect(RemoteScrollPhysics.rubberBand(-20, dimension: 800) == -small)
    #expect(abs(RemoteScrollPhysics.springBack(60, elapsed: 0) - 60) < 1e-9)
    #expect(RemoteScrollPhysics.springBack(60, elapsed: 1) == 0)
  }

  @Test func edgesComeFromTheScrollReport() throws {
    let top = RemoteScrollMetrics(
      x: 0, y: 0, contentWidth: 390, contentHeight: 3000, viewportWidth: 390,
      viewportHeight: 664)
    // A finger moving down at the top would reveal content above: none.
    #expect(!RemoteScrollPhysics.canScroll(by: CGPoint(x: 0, y: 10), metrics: top).y)
    #expect(RemoteScrollPhysics.canScroll(by: CGPoint(x: 0, y: -10), metrics: top).y)
    var bottom = top
    bottom.y = 3000 - 664
    #expect(!RemoteScrollPhysics.canScroll(by: CGPoint(x: 0, y: -10), metrics: bottom).y)
    #expect(RemoteScrollPhysics.canScroll(by: CGPoint(x: 0, y: -10), metrics: nil).y)
  }

  @Test func theIndicatorTracksAndScrubsThePage() throws {
    let metrics = RemoteScrollMetrics(
      x: 0, y: 1168, contentWidth: 390, contentHeight: 3000, viewportWidth: 390,
      viewportHeight: 664)
    let content = CGRect(x: 0, y: 0, width: 390, height: 664)
    let indicator = try #require(RemoteScrollIndicator(metrics: metrics, content: content))
    #expect(indicator.thumb.height >= RemoteScrollIndicator.minimumLength)
    #expect(indicator.thumb.maxX <= content.maxX)
    #expect(indicator.grabs(CGPoint(x: indicator.thumb.midX - 10, y: indicator.thumb.midY)))
    #expect(!indicator.grabs(CGPoint(x: 100, y: indicator.thumb.midY)))
    // Half way along the track is half way down the page.
    let offset = indicator.scrollOffset(thumbCenterY: indicator.track.midY, metrics: metrics)
    #expect(abs(offset - (3000 - 664) / 2) < 1)
    #expect(indicator.scrollOffset(thumbCenterY: -100, metrics: metrics) == 0)
    var short = metrics
    short.contentHeight = 600
    #expect(RemoteScrollIndicator(metrics: short, content: content) == nil)
  }
}
