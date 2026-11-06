import CoreVideo
import OmnigentCoreFFI
import Testing

@testable import OmnigentRemoteBrowser

/// The iOS bars' models: collapse on scroll and the top edge's colour sampled from a decoded
/// frame.
@Suite("Remote browser chrome state")
struct ChromeStateTests {
  // MARK: Collapse on scroll

  private func metrics(_ offset: Double, viewport: Double = 700, content: Double = 5000)
    -> RemoteScrollMetrics
  {
    RemoteScrollMetrics(
      x: 0, y: offset, contentWidth: 400, contentHeight: content, viewportWidth: 400,
      viewportHeight: viewport)
  }

  @Test func scrollingDownCollapsesAndUpExpands() {
    var bars = RemoteChromeCollapse()
    bars.scrolled(metrics(0))
    let changed1 = bars.scrolled(metrics(10))
    #expect(!changed1, "a small scroll keeps the bars")
    let changed2 = bars.scrolled(metrics(60))
    #expect(changed2)
    #expect(bars.isCollapsed)
    bars.scrolled(metrics(400))
    let changed3 = bars.scrolled(metrics(390))
    #expect(!changed3, "a small scroll back keeps them collapsed")
    let changed4 = bars.scrolled(metrics(370))
    #expect(changed4)
    #expect(!bars.isCollapsed)
  }

  @Test func theTopAndShortPagesKeepTheBars() {
    var bars = RemoteChromeCollapse()
    bars.scrolled(metrics(0))
    let changed5 = bars.scrolled(metrics(30))
    #expect(!changed5, "not past the minimum offset")
    bars.scrolled(metrics(200))
    #expect(bars.isCollapsed)
    let changed6 = bars.scrolled(metrics(0))
    #expect(changed6, "the top of the page expands")
    var short = RemoteChromeCollapse()
    short.scrolled(metrics(0, content: 700))
    let changed7 = short.scrolled(metrics(100, content: 700))
    #expect(!changed7)
  }

  @Test func aResizeIsNotAScroll() {
    var bars = RemoteChromeCollapse()
    bars.scrolled(metrics(0))
    bars.scrolled(metrics(300))
    #expect(bars.isCollapsed)
    // Collapsing grew the viewport, and the page's end clamped the offset up by as much.
    let changed8 = bars.scrolled(metrics(260, viewport: 740))
    #expect(!changed8)
    #expect(bars.isCollapsed)
    let changed9 = bars.expand()
    #expect(changed9)
    let changed10 = bars.scrolled(metrics(600))
    #expect(!changed10, "after expand the next report only anchors")
  }

  // MARK: Control

  private func control(
    _ owner: ControlOwner, _ holder: ControlHolder, handoff: String? = nil
  ) -> RemoteBrowserControl {
    RemoteBrowserControl(
      owner: owner, holder: holder, userId: nil,
      handoff: handoff.map { RemoteBrowserHandoff(id: "h1", reason: $0) })
  }

  @Test func theControlStatusSaysWhoDrives() {
    let attached = RemoteBrowserConnection.attached(mode: .control)
    let agent = RemoteControlStatus(connection: attached, control: control(.agent, .nobody))
    #expect(agent.kind == .agentBrowsing)
    #expect(agent.canTakeOver)
    let mine = RemoteControlStatus(connection: attached, control: control(.user, .this))
    #expect(mine.kind == .inControl)
    #expect(!mine.canTakeOver)
    #expect(mine.message == "You're in control")
    let other = RemoteControlStatus(connection: attached, control: control(.user, .other))
    #expect(other.kind == .otherDevice)
    #expect(!other.canTakeOver)
    let handoff = RemoteControlStatus(
      connection: attached, control: control(.agent, .nobody, handoff: "Sign in to GitHub"))
    #expect(handoff.needsYou)
    #expect(handoff.canTakeOver)
    #expect(handoff.message == "Agent needs you: Sign in to GitHub")
    let viewer = RemoteControlStatus(
      connection: .attached(mode: .view), control: control(.agent, .nobody))
    #expect(viewer.kind == .viewing)
    #expect(!viewer.canTakeOver)
    #expect(RemoteControlStatus(connection: .connecting, control: nil).kind == .unavailable)
  }

  // MARK: Edge colour

  @Test func aUniformTopEdgeIsSampledFromBGRA() throws {
    let buffer = try makeBuffer(kCVPixelFormatType_32BGRA) { _, column, row in
      row < 8
        ? [0x40, 0xFF, 0xD0, 0xFF]
        : (column.isMultiple(of: 2) ? [0, 0, 0, 0xFF] : [0xFF, 0xFF, 0xFF, 0xFF])
    }
    let color = try #require(RemoteEdgeColor.sample(buffer))
    #expect(abs(color.red - 0xD0 / 255.0) < 0.01)
    #expect(abs(color.green - 1) < 0.01)
    #expect(abs(color.blue - 0x40 / 255.0) < 0.01)
    #expect(!color.isDark)
  }

  @Test func aBusyTopEdgeHasNoColour() throws {
    let buffer = try makeBuffer(kCVPixelFormatType_32BGRA) { _, column, _ in
      column.isMultiple(of: 2) ? [0, 0, 0, 0xFF] : [0xFF, 0xFF, 0xFF, 0xFF]
    }
    #expect(RemoteEdgeColor.sample(buffer) == nil)
  }

  @Test func videoRangeYCbCrConvertsToRGB() throws {
    // Video-range BT.709 dark blue-grey: Y 0x30, Cb 0x90, Cr 0x78.
    let buffer = try makeBuffer(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) { plane, _, _ in
      plane == 0 ? [0x30] : [0x90, 0x78]
    }
    let color = try #require(RemoteEdgeColor.sample(buffer))
    #expect(color.isDark)
    #expect(color.blue > color.red, "Cb above neutral is bluish")
    let black = try makeBuffer(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) { plane, _, _ in
      plane == 0 ? [16] : [128, 128]
    }
    let sampled = try #require(RemoteEdgeColor.sample(black))
    #expect(sampled.isClose(to: RemoteEdgeColor(red: 0, green: 0, blue: 0)))
  }

  /// A 64 × 16 buffer filled per pixel: `fill(plane, column, row)` returns the pixel's bytes (BGRA, Y,
  /// or Cb Cr for the half-size chroma plane).
  private func makeBuffer(
    _ format: OSType, fill: (_ plane: Int, _ column: Int, _ row: Int) -> [UInt8]
  ) throws -> CVPixelBuffer {
    var created: CVPixelBuffer?
    let status = unsafe CVPixelBufferCreate(nil, 64, 16, format, nil, &created)
    let buffer = try #require(created, "CVPixelBufferCreate failed: \(status)")
    #expect(CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess)
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    let planar = CVPixelBufferIsPlanar(buffer)
    for plane in 0..<(planar ? CVPixelBufferGetPlaneCount(buffer) : 1) {
      guard let base = unsafe baseAddress(buffer, plane: planar ? plane : nil) else {
        throw BufferError.noBaseAddress
      }
      let rowBytes =
        planar
        ? CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) : CVPixelBufferGetBytesPerRow(buffer)
      let width =
        planar ? CVPixelBufferGetWidthOfPlane(buffer, plane) : CVPixelBufferGetWidth(buffer)
      let height =
        planar ? CVPixelBufferGetHeightOfPlane(buffer, plane) : CVPixelBufferGetHeight(buffer)
      for row in 0..<height {
        for column in 0..<width {
          let bytes = fill(plane, column, row)
          for (index, value) in bytes.enumerated() {
            unsafe base.storeBytes(
              of: value, toByteOffset: row * rowBytes + column * bytes.count + index,
              as: UInt8.self)
          }
        }
      }
    }
    return buffer
  }

  private enum BufferError: Error { case noBaseAddress }

  private func baseAddress(_ buffer: CVPixelBuffer, plane: Int?) -> UnsafeMutableRawPointer? {
    if let plane {
      return unsafe CVPixelBufferGetBaseAddressOfPlane(buffer, plane)
    }
    return unsafe CVPixelBufferGetBaseAddress(buffer)
  }
}
