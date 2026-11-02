import AVFoundation
import ImageIO
import OmnigentCoreFFI
import OmnigentInput
import Observation
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
/// and scaled to fit, a JPEG still until the first frame, and the page's cursor; input goes to
/// the store in viewport CSS pixels. Input handling is in the platform extensions.
public final class RemoteBrowserView: RemotePlatformView {
  /// The tab.
  public let store: RemoteBrowserStore
  let renderer = RemoteVideoRenderer()
  private let stillLayer = CALayer()
  private var showsVideo = false
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
      installGestures()
    #endif
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
    return viewport.flatMap { RemoteViewportGeometry(viewport: $0, bounds: bounds.size) }
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

  func relayout() {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    let rect = geometry?.contentRect ?? bounds
    renderer.layer.frame = rect
    stillLayer.frame = rect
    stillLayer.isHidden = showsVideo
    CATransaction.commit()
    cursorChanged()
  }

  private func observeStore() {
    withObservationTracking {
      _ = store.snapshot.viewport
      _ = store.snapshot.cursor
      _ = store.still
    } onChange: { [weak self] in
      Task { @MainActor in
        guard let self else { return }
        self.updateStill()
        self.relayout()
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
