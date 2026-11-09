import CoreGraphics
import Foundation
import OmnigentCoreFFI
import Testing

@testable import OmnigentRemoteBrowser

/// What a host or a stored preference can send that no well-behaved one would.
@MainActor
@Suite("Remote browser hostile data")
struct RemoteBrowserHostileDataTests {
  private func eventually(_ condition: () -> Bool) async throws -> Bool {
    for _ in 0..<200 {
      if condition() { return true }
      try await Task.sleep(for: .milliseconds(10))
    }
    return condition()
  }

  private func frame(
    keyframe: Bool = false, params: H264ParameterSets? = nil, avcc: Data = Data(),
    pts: UInt64 = 0, formatChanged: Bool = false
  ) -> VideoFrame {
    VideoFrame(
      streamId: .max, keyframe: keyframe, ptsUs: pts, params: params, formatChanged: formatChanged,
      avcc: avcc)
  }

  /// The parameter sets of the fixture stream, the only ones CoreMedia accepts here.
  private func goodParameterSets() throws -> H264ParameterSets {
    let stream = try FixtureVideoStream(named: FixtureVideoStream.small)
    return try #require(stream.frames.first?.params)
  }

  @Test("Video that can't be decoded is refused, and asks for a keyframe, never traps")
  func badVideo() throws {
    let renderer = RemoteVideoRenderer()
    var requested: [KeyframeReason] = []
    renderer.requestKeyframe = { requested.append($0) }

    renderer.enqueue(frame())
    #expect(renderer.framesEnqueued == 0)

    renderer.enqueue(frame(keyframe: true))
    #expect(renderer.lastError != nil)

    let garbage = H264ParameterSets(sps: Data([0xFF, 0x00]), pps: Data([0xFF]))
    renderer.enqueue(frame(keyframe: true, params: garbage))
    #expect(renderer.framesEnqueued == 0)
    #expect(renderer.lastError != nil)

    let empty = H264ParameterSets(sps: Data(), pps: Data())
    renderer.enqueue(frame(keyframe: true, params: empty, avcc: Data([1])))
    #expect(renderer.framesEnqueued == 0)
    #expect(requested.contains(.decoderError))
  }

  @Test("A keyframe's data may be empty or nonsense once the format is known")
  func nonsenseFrames() throws {
    let renderer = RemoteVideoRenderer()
    let sets = try goodParameterSets()
    renderer.enqueue(
      frame(keyframe: true, params: sets, avcc: Data(repeating: 0xFF, count: 16), pts: .max))
    #expect(renderer.videoSize == CGSize(width: 640, height: 400))
    renderer.enqueue(frame(avcc: Data([0xFF]), pts: .max))
    renderer.enqueue(frame(avcc: Data(), pts: 0))
    renderer.enqueue(frame(keyframe: true, params: sets, avcc: Data(), formatChanged: true))
    #expect(renderer.videoSize == CGSize(width: 640, height: 400))
  }

  @Test(
    "Sizes that aren't real numbers ask for nothing, or a clamped viewport",
    arguments: [
      CGSize(width: CGFloat.nan, height: CGFloat.nan),
      CGSize(width: CGFloat.infinity, height: -CGFloat.infinity),
      CGSize(width: -1, height: -1), CGSize.zero,
      CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.leastNonzeroMagnitude),
    ])
  func oddViewSizes(size: CGSize) {
    for scale in [Double.nan, .infinity, -1, 0, 1e300] {
      for mode in [RemoteViewportMode.fitWindow, .mobile(site: true), .keep] {
        if let request = mode.request(viewSize: size, screenScale: scale) {
          #expect(request.viewport.width <= 3840)
          #expect(request.viewport.height <= 3840)
        }
      }
    }
  }

  @Test("A store takes any view size while it follows the view")
  func oddSizesInTheStore() async throws {
    let host = FixtureRemoteBrowser(latency: .milliseconds(1))
    host.addTab(id: "t", url: "https://example.com/")
    let store = RemoteBrowserStore(sessionID: "s", tabID: "t")
    store.pasteboard = MemoryPasteboard()
    store.attach(using: host, mode: .control, hostID: nil)
    store.viewChanged(size: CGSize(width: CGFloat.nan, height: CGFloat.nan), scale: .nan)
    store.viewChanged(size: CGSize(width: CGFloat.infinity, height: 1), scale: .infinity)
    store.viewChanged(size: CGSize(width: -1, height: -1), scale: -1)
    #expect(try await eventually { store.canSendInput })
    store.detach()
  }

  @Test("Stored sizes clamp into the protocol's range")
  func storedSizes() {
    let huge = RemoteViewportSize(width: .max, height: .min, dpr: .infinity).viewport
    #expect(huge.width == 3840)
    #expect(huge.height == 200)
    #expect(huge.dpr == 3)
    #expect(RemoteViewportSize(width: 0, height: 0, dpr: -1).viewport.dpr == 1)
    #expect(RemoteViewportSize(width: 1, height: 1, dpr: .nan).label == "1 \u{00D7} 1")
  }

  @Test("A stored pixel ratio past Int still labels its menu item")
  func hugeStoredRatio() throws {
    let defaults = try #require(UserDefaults(suiteName: "RemoteBrowserHostile.\(UUID())"))
    defaults.set(
      #"{"fixed":{"_0":{"width":1,"height":1,"dpr":1e300}}}"#,
      forKey: RemoteViewportModeDefaults.key)
    #expect(!RemoteViewportModeDefaults.load(defaults).title.isEmpty)
  }

  @Test("A stored mode of the wrong shape falls back to keeping the size")
  func oddStoredModes() throws {
    let defaults = try #require(UserDefaults(suiteName: "RemoteBrowserHostile.\(UUID())"))
    for text in [
      "", "null", "[]", #"{"exploded":{}}"#, #"{"fixed":{"_0":{"width":1e300}}}"#,
      String(repeating: "[", count: 100_000),
    ] {
      defaults.set(text, forKey: RemoteViewportModeDefaults.key)
      #expect(RemoteViewportModeDefaults.load(defaults) == .keep)
    }
  }

  @Test("An IME range that isn't one has no record")
  func imeRanges() {
    #expect(ImeRange(NSRange(location: NSNotFound, length: 0)) == nil)
    #expect(ImeRange(NSRange(location: -1, length: 0)) == nil)
    #expect(ImeRange(NSRange(location: 1, length: -1)) == nil)
    let huge = ImeRange(NSRange(location: Int(UInt32.max) + 5, length: 5))
    #expect(huge?.start == .max)
    #expect(huge?.end == .max)
  }
}
