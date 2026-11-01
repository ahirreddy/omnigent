internal import AppKit
internal import IOSurface
internal import OWLProtocol
public import QuartzCore

/// The client side of compositing: owns the layer tree a view displays and applies the
/// compositing information the host sends.
///
/// - Remote-layer mode: one `CALayerHost` sublayer showing the host's `CAContext`, which already
///   contains the page and any popup.
/// - IOSurface mode: a page layer and a popup layer whose contents are the IOSurfaces the host
///   sends per frame.
public final class LayerHost {
  /// Add this layer to the hosting view. Its geometry is flipped (top-left origin).
  public let rootLayer = CALayer()
  /// The mode of the content currently attached, if any.
  public private(set) var mode: RenderMode?

  private var remoteLayer: CALayer?
  private let pageLayer = CALayer()
  private let popupLayer = CALayer()
  private var pageSurfaceID: UInt32 = 0
  private var popupSurfaceID: UInt32 = 0
  private var popupVisible = false
  private var popupOrigin = CGPoint.zero

  /// Whether this macOS still provides the private `CALayerHost` class used by remote-layer mode.
  public static var isRemoteLayerSupported: Bool {
    guard let layerClass = NSClassFromString("CALayerHost") as? CALayer.Type else { return false }
    return layerClass.instancesRespond(to: NSSelectorFromString("setContextId:"))
  }

  init() {
    rootLayer.isGeometryFlipped = true
    rootLayer.masksToBounds = true
    rootLayer.backgroundColor = NSColor.white.cgColor
    for layer in [pageLayer, popupLayer] {
      layer.anchorPoint = .zero
      layer.contentsGravity = .resize
      layer.isHidden = true
      rootLayer.addSublayer(layer)
    }
  }

  /// Sizes the root (and the remote layer) to the view.
  func layout(bounds: CGRect) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    rootLayer.frame = bounds
    remoteLayer?.frame = CGRect(origin: .zero, size: bounds.size)
    CATransaction.commit()
  }

  /// Remote-layer mode: embeds the host's CAContext.
  func attachRemoteContext(_ contextID: UInt32) throws(WebLayerError) {
    guard let layerClass = NSClassFromString("CALayerHost") as? CALayer.Type,
      layerClass.instancesRespond(to: NSSelectorFromString("setContextId:"))
    else {
      throw .renderingUnavailable("CALayerHost is not available on this macOS version.")
    }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    remoteLayer?.removeFromSuperlayer()
    let layer = layerClass.init()
    layer.setValue(contextID, forKey: "contextId")
    layer.anchorPoint = .zero
    layer.frame = CGRect(origin: .zero, size: rootLayer.bounds.size)
    rootLayer.addSublayer(layer)
    remoteLayer = layer
    pageLayer.isHidden = true
    popupLayer.isHidden = true
    CATransaction.commit()
    mode = .remoteLayer
  }

  /// IOSurface mode: shows a new frame. Returns the surface IDs the client no longer displays,
  /// which the host may reuse.
  func present(_ frame: SurfaceFrame) -> [UInt32] {
    var released: [UInt32] = []
    let size = CGSize(
      width: frame.pixelSize.width / frame.scale, height: frame.pixelSize.height / frame.scale)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    if frame.layer == .popup {
      if popupSurfaceID != 0, popupSurfaceID != frame.surfaceID { released.append(popupSurfaceID) }
      popupSurfaceID = frame.surfaceID
      popupOrigin = frame.popupOrigin
      popupVisible = frame.popupVisible
      popupLayer.contents = frame.surface
      popupLayer.frame = CGRect(origin: popupOrigin, size: size)
      popupLayer.isHidden = !popupVisible
    } else {
      if pageSurfaceID != 0, pageSurfaceID != frame.surfaceID { released.append(pageSurfaceID) }
      pageSurfaceID = frame.surfaceID
      pageLayer.contents = frame.surface
      pageLayer.frame = CGRect(origin: .zero, size: size)
      pageLayer.isHidden = false
    }
    CATransaction.commit()
    mode = .ioSurface
    return released
  }

  /// IOSurface mode: shows or hides the popup. Returns the popup surface to release on hide.
  func setPopupVisible(_ visible: Bool) -> UInt32? {
    popupVisible = visible
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    popupLayer.isHidden = !visible
    var released: UInt32?
    if !visible {
      popupLayer.contents = nil
      if popupSurfaceID != 0 { released = popupSurfaceID }
      popupSurfaceID = 0
    }
    CATransaction.commit()
    return released
  }

  /// Drops all content, for example when the host exits.
  func reset() {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    remoteLayer?.removeFromSuperlayer()
    remoteLayer = nil
    for layer in [pageLayer, popupLayer] {
      layer.contents = nil
      layer.isHidden = true
    }
    CATransaction.commit()
    pageSurfaceID = 0
    popupSurfaceID = 0
    popupVisible = false
    mode = nil
  }
}

/// One IOSurface-mode frame from the host.
struct SurfaceFrame {
  let surface: IOSurfaceRef
  /// The host's ID for the surface, acknowledged when the client stops showing it.
  let surfaceID: UInt32
  let layer: OWLLayer
  let pixelSize: CGSize
  let scale: Double
  /// Popup frames only: where the popup sits, in view points.
  let popupOrigin: CGPoint
  /// Popup frames only: whether the popup is open.
  let popupVisible: Bool
}
