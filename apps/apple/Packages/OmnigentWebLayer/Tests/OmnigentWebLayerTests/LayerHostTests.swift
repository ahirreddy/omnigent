import CoreGraphics
import Foundation
import IOSurface
import OWLProtocol
import QuartzCore
import Testing

@testable import OmnigentWebLayer

@MainActor
@Suite("Layer host")
struct LayerHostTests {
  private func surface() throws -> IOSurfaceRef {
    let properties: [CFString: Any] = [
      kIOSurfaceWidth: 4, kIOSurfaceHeight: 4, kIOSurfaceBytesPerElement: 4,
      kIOSurfacePixelFormat: 0x4247_5241,
    ]
    return try #require(IOSurfaceCreate(properties as CFDictionary))
  }

  private func frame(
    id: UInt32, layer: OWLLayer = .page, pixels: CGSize = CGSize(width: 800, height: 600),
    scale: Double = 2, origin: CGPoint = .zero, visible: Bool = true
  ) throws -> SurfaceFrame {
    SurfaceFrame(
      surface: try surface(), surfaceID: id, layer: layer, pixelSize: pixels, scale: scale,
      popupOrigin: origin, popupVisible: visible)
  }

  @Test func framesReleaseTheSurfaceTheyReplace() throws {
    let host = LayerHost()
    #expect(host.mode == nil)
    #expect(host.present(try frame(id: 1)).isEmpty)
    #expect(host.mode == .ioSurface)
    #expect(host.present(try frame(id: 1)).isEmpty)
    #expect(host.present(try frame(id: 2)) == [1])
    #expect(host.present(try frame(id: 5, layer: .popup, origin: CGPoint(x: 3, y: 4))).isEmpty)
    #expect(host.present(try frame(id: 6, layer: .popup, visible: false)) == [5])
    #expect(host.setPopupVisible(true) == nil)
    #expect(host.setPopupVisible(false) == 6)
    #expect(host.setPopupVisible(false) == nil)
    host.reset()
    #expect(host.mode == nil)
    #expect(host.present(try frame(id: 2)).isEmpty)
  }

  @Test(
    "Frames with an empty, negative or vanishing size still draw",
    arguments: [(0.0, 2.0), (800.0, -2.0), (800.0, Double.infinity)])
  func oddFrameSizes(pixels: Double, scale: Double) throws {
    let host = LayerHost()
    let size = CGSize(width: pixels, height: pixels)
    _ = host.present(try frame(id: 1, pixels: size, scale: scale))
    _ = host.present(try frame(id: 2, layer: .popup, pixels: size, scale: scale))
    #expect(host.mode == .ioSurface)
  }

  @Test(
    "A frame whose size is not a number is dropped, never a crash",
    .disabled("Traps: LayerHost.present divides by the scale and CALayer raises on a NaN frame"),
    arguments: [
      (0.0, 0.0), (800.0, 0.0), (800.0, Double.nan),
      (Double.greatestFiniteMagnitude, Double.leastNonzeroMagnitude),
    ])
  func framesOfNoRealSize(pixels: Double, scale: Double) throws {
    let host = LayerHost()
    _ = host.present(try frame(id: 1, pixels: CGSize(width: pixels, height: pixels), scale: scale))
    #expect(host.mode == .ioSurface)
  }

  @Test(
    "A popup at no real place is dropped, never a crash",
    .disabled("Traps: LayerHost.present sets the popup frame and CALayer raises on a NaN origin"))
  func oddPopupOrigin() throws {
    let host = LayerHost()
    let origin = CGPoint(x: CGFloat.nan, y: CGFloat.infinity)
    _ = host.present(try frame(id: 2, layer: .popup, origin: origin))
    #expect(host.mode == .ioSurface)
  }

  @Test func remoteContextsAttachAndDetach() throws {
    #expect(LayerHost.isRemoteLayerSupported)
    let host = LayerHost()
    host.layout(bounds: CGRect(x: 0, y: 0, width: 10, height: 10))
    try host.attachRemoteContext(.max)
    #expect(host.mode == .remoteLayer)
    try host.attachRemoteContext(0)
    host.layout(bounds: .zero)
    #expect(host.rootLayer.sublayers?.count == 3)
    host.reset()
    #expect(host.rootLayer.sublayers?.count == 2)
  }

  @Test func framesFromTheHostAreShownAndAcknowledged() throws {
    let fixture = ProtocolFixture()
    let surface = try surface()
    func send(_ id: UInt64) throws {
      let message = IncomingMessage(
        kindValue: OWLMessageKind.frame.rawValue, request: 0, target: fixture.webView.id,
        protocolMajor: 1,
        fields: try WireDecoder(
          WireEncoder().u64(.surfaceIndex, id).u64(.pixelWidth, 8).u64(.pixelHeight, 8)
            .u64(.hostTimestampNanos, .max).bytes),
        port: MachSendRight(name: IOSurfaceCreateMachPort(surface)))
      fixture.session.handle(message)
    }
    try send(1)
    try send(2)
    #expect(fixture.webView.statistics.framesPresented == 2)
    #expect(fixture.last(.frameAck)?.u64(.surfaceIndex) == 1)
    try fixture.receive(.popupVisibility, WireEncoder().bool(.visible, false))
    #expect(fixture.webView.lastError == nil)
  }

  @Test func framesWithoutASurfaceAreReported() throws {
    let fixture = ProtocolFixture()
    try fixture.receive(.frame, WireEncoder())
    #expect(
      fixture.webView.lastError == .renderingUnavailable("A frame arrived without its surface."))
    fixture.webView.lastError = nil
    let message = IncomingMessage(
      kindValue: OWLMessageKind.frame.rawValue, request: 0, target: fixture.webView.id,
      protocolMajor: 1,
      fields: try WireDecoder(
        WireEncoder().u64(.surfaceIndex, 1).u64(.pixelWidth, .max).u64(.pixelHeight, .max).bytes),
      port: MachSendRight(name: 0))
    fixture.session.handle(message)
    #expect(
      fixture.webView.lastError
        == .renderingUnavailable("The frame's IOSurface port could not be opened."))
  }
}
