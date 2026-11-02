import AVFoundation
import ImageIO
import Observation
import OmnigentCoreFFI
import OmnigentInput
import QuartzCore
import os

#if os(macOS)
  public import AppKit
  /// The platform view type.
  public typealias RemotePlatformView = NSView
#else
  public import UIKit
  /// The platform view type.
  public typealias RemotePlatformView = UIView
#endif

/// Shows a remote tab: hardware-decoded video in an `AVSampleBufferDisplayLayer`, letterboxed
/// and scaled to fit (then zoomed and panned locally on iOS), a JPEG still until the first
/// frame, the page's cursor, and a scroll indicator for mobile pages; input goes to the store in
/// viewport CSS pixels. Input handling is in the platform extensions.
public final class RemoteBrowserView: RemotePlatformView {
  /// The tab.
  public let store: RemoteBrowserStore
  let renderer = RemoteVideoRenderer()
  private let stillLayer = CALayer()
  private let indicatorLayer = CALayer()
  private var showsVideo = false
  private var lastScroll: RemoteScrollMetrics?
  private var indicatorFade: Task<Void, Never>?
  private var lastViewport: RemoteViewport?
  private var zoomResets = 0
  /// Local zoom and pan (design doc section 16.3); identity on macOS.
  var zoom = RemoteZoomState()
  /// The rubber-band displacement at the page's edges, view points.
  var rubberBand = CGPoint.zero
  #if os(iOS)
    var touchInput: RemoteTouchController?
    let keyboardProxy = RemoteKeyboardProxy()
    /// When the user last tapped the page; a field focused soon after shows the keyboard.
    var lastTapAt: ContinuousClock.Instant?
    /// When the keyboard was last hidden because the page's field lost focus.
    var keyboardHiddenAt: ContinuousClock.Instant?
    var keyboardHide: Task<Void, Never>?
  #endif
  #if os(macOS)
    var trackingArea: NSTrackingArea?
    var pointerInside = false
    let textComposer = TextInputComposer()
  #endif

  /// Creates the view and connects it to the store's video.
  /// - Parameter store: The tab.
  public init(store: RemoteBrowserStore) {
    self.store = store
    super.init(frame: CGRect(x: 0, y: 0, width: 800, height: 500))
    #if os(macOS)
      wantsLayer = true
      layer?.masksToBounds = true
      layer?.addSublayer(stillLayer)
      layer?.addSublayer(renderer.layer)
      textComposer.sink = self
      setAccessibilityElement(true)
      setAccessibilityRole(.group)
      setAccessibilityLabel("Remote page")
      setAccessibilityIdentifier("remote-browser.surface")
    #else
      isAccessibilityElement = true
      accessibilityLabel = "Remote page"
      accessibilityIdentifier = "remote-browser.surface"
      clipsToBounds = true
      layer.addSublayer(stillLayer)
      layer.addSublayer(renderer.layer)
      layer.addSublayer(indicatorLayer)
      installGestures()
    #endif
    indicatorLayer.backgroundColor = CGColor(gray: 0.35, alpha: 0.6)
    indicatorLayer.cornerRadius = RemoteScrollIndicator.width / 2
    indicatorLayer.opacity = 0
    stillLayer.contentsGravity = .resize
    renderer.videoSizeChanged = { [weak self] _ in
      self?.showsVideo = true
      self?.relayout()
    }
    store.renderer = renderer
    observeStore()
    relayout()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    nil
  }

  /// The current fit of the viewport in the view, once its size is known.
  public var geometry: RemoteViewportGeometry? {
    let viewport =
      store.snapshot.viewport
      ?? renderer.videoSize.map { RemoteViewportGeometry.viewport(videoSize: $0) }
    guard var fit = viewport.flatMap({ RemoteViewportGeometry(viewport: $0, bounds: bounds.size) })
    else { return nil }
    // Where the remote follows the view, a size mismatch is a resize in flight: keep the page
    // at the top left, where it lands, instead of centring it for a moment.
    if store.viewportMode.followsView { fit.contentRect.origin = .zero }
    return fit
  }

  /// The fit with the local zoom applied: where the page is drawn and how touches map to it.
  public var displayGeometry: RemoteViewportGeometry? {
    geometry.map { zoom.apply(to: $0) }
  }

  #if os(macOS)
    override public var isFlipped: Bool { true }

    override public func layout() {
      super.layout()
      relayout()
    }
  #else
    override public func layoutSubviews() {
      super.layoutSubviews()
      relayout()
    }
  #endif

  func relayout(animated: Bool = false) {
    if let fit = geometry {
      // A new remote size starts unzoomed; otherwise the zoom stays inside the view.
      if lastViewport != fit.viewport {
        lastViewport = fit.viewport
        zoom = RemoteZoomState()
      }
      zoom.clamp(fit: fit.contentRect, bounds: bounds.size)
    }
    CATransaction.begin()
    CATransaction.setDisableActions(!animated)
    if animated { CATransaction.setAnimationDuration(0.25) }
    let rect = (displayGeometry?.contentRect ?? bounds).offsetBy(dx: rubberBand.x, dy: rubberBand.y)
    renderer.layer.frame = rect
    stillLayer.frame = rect
    stillLayer.isHidden = showsVideo
    updateIndicator(content: rect)
    CATransaction.commit()
    cursorChanged()
    reportSize()
    updateAccessibilityValue()
  }

  /// The page title, and the zoom when zoomed, for VoiceOver (and UI tests).
  private func updateAccessibilityValue() {
    var value = store.navigation.title
    let percent = zoom.isZoomed ? Int((zoom.scale * 100).rounded()) : nil
    if let percent { value += ", zoomed \(percent)%" }
    if store.zoomPercent != percent { store.zoomPercent = percent }
    #if os(macOS)
      setAccessibilityValue(value)
    #else
      accessibilityValue = value
    #endif
  }

  /// Tells the store the view's size, for the viewport modes that follow it.
  private func reportSize() {
    #if os(macOS)
      let scale = hostWindowScale
    #else
      let scale = traitCollection.displayScale
    #endif
    store.viewChanged(size: bounds.size, scale: scale)
  }

  /// The mobile page's scroll indicator (its own overlay scroll bars are hidden).
  private func updateIndicator(content: CGRect) {
    guard store.viewportMode.isMobile, let metrics = store.snapshot.scroll,
      let indicator = RemoteScrollIndicator(metrics: metrics, content: content)
    else {
      indicatorLayer.opacity = 0
      return
    }
    indicatorLayer.frame = indicator.thumb
  }

  /// The scroll indicator for the current metrics, when the page scrolls.
  var scrollIndicator: RemoteScrollIndicator? {
    guard let metrics = store.snapshot.scroll, let rect = displayGeometry?.contentRect else {
      return nil
    }
    return RemoteScrollIndicator(metrics: metrics, content: rect)
  }

  /// Shows the scroll indicator while the page scrolls, then fades it.
  func flashIndicator() {
    guard store.viewportMode.isMobile, scrollIndicator != nil else { return }
    indicatorLayer.opacity = 1
    indicatorFade?.cancel()
    indicatorFade = Task { [weak self] in
      do {
        try await Task.sleep(for: .seconds(1.2))
      } catch {
        return  // Scrolled again.
      }
      self?.indicatorLayer.opacity = 0
    }
  }

  private func observeStore() {
    withObservationTracking {
      _ = store.snapshot.viewport
      _ = store.snapshot.nav
      _ = store.snapshot.cursor
      _ = store.snapshot.scroll
      _ = store.snapshot.textInput
      _ = store.viewportMode
      _ = store.still
      _ = store.zoomResets
    } onChange: { [weak self] in
      Task { @MainActor in
        guard let self else { return }
        if self.store.zoomResets != self.zoomResets {
          self.zoomResets = self.store.zoomResets
          self.zoom = RemoteZoomState()
          self.relayout(animated: true)
        }
        let scrolled = self.store.snapshot.scroll != self.lastScroll
        self.lastScroll = self.store.snapshot.scroll
        self.updateStill()
        self.relayout()
        if scrolled { self.flashIndicator() }
        #if os(iOS)
          self.textInputChanged()
        #endif
        self.observeStore()
      }
    }
  }

  private func updateStill() {
    guard let jpeg = store.still?.jpeg else { return }
    guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else {
      Self.log.error("A remote still (\(jpeg.count) bytes) is not a decodable JPEG.")
      return
    }
    stillLayer.contents = image
  }

  private static let log = Logger(subsystem: "ai.omnigent.remote-browser", category: "view")
}
