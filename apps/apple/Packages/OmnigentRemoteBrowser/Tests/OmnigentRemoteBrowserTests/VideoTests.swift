import CoreMedia
import Foundation
import OmnigentCoreFFI
import Synchronization
import Testing
import VideoToolbox

@testable import OmnigentRemoteBrowser

/// The shared protocol fixtures, read from the source tree.
enum SharedFixtures {
  static let directory = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()
    .appending(path: "client-core/fixtures/remote_browser")

  static func stream(_ name: String, formatChanged: Bool = false) throws -> FixtureVideoStream {
    let h264 = directory.appending(path: "h264")
    return try FixtureVideoStream(
      annexB: Data(contentsOf: h264.appending(path: "\(name).annexb")),
      index: Data(contentsOf: h264.appending(path: "\(name).frames.json")), streamID: 1,
      formatChanged: formatChanged)
  }

  static func index(_ name: String) throws -> [String: Any] {
    let data = try Data(
      contentsOf: directory.appending(path: "h264").appending(path: "\(name).frames.json"))
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  static func hex(_ string: String) -> Data {
    var bytes: [UInt8] = []
    var index = string.startIndex
    while index < string.endIndex {
      let next = string.index(index, offsetBy: 2)
      bytes.append(UInt8(string[index..<next], radix: 16) ?? 0)
      index = next
    }
    return Data(bytes)
  }
}

@Suite("H.264 fixtures to sample buffers")
struct VideoTests {
  @Test func fixtureFramesMatchTheCoreDeliveryShape() throws {
    let stream = try SharedFixtures.stream(FixtureVideoStream.large)
    let index = try SharedFixtures.index(FixtureVideoStream.large)
    #expect(stream.frames.count == 30)
    #expect(stream.width == 1280 && stream.height == 800)
    let first = try #require(stream.frames.first)
    #expect(first.keyframe)
    #expect(first.params?.sps == SharedFixtures.hex(try #require(index["sps_hex"] as? String)))
    #expect(first.params?.pps == SharedFixtures.hex(try #require(index["pps_hex"] as? String)))
    #expect(stream.frames.dropFirst().allSatisfy { !$0.keyframe && $0.params == nil })
    for frame in stream.frames {
      // Walk the AVCC lengths: only slices remain (no SPS, PPS, AUD or SEI).
      let bytes = [UInt8](frame.avcc)
      var offset = 0
      while offset < bytes.count {
        let length = bytes[offset..<offset + 4].reduce(0) { $0 << 8 | Int($1) }
        let type = bytes[offset + 4] & 0x1F
        #expect(type == (frame.keyframe ? 5 : 1))
        offset += 4 + length
      }
      #expect(offset == bytes.count)
    }
  }

  @Test func formatDescriptionsComeFromTheParameterSets() throws {
    let large = try #require(try SharedFixtures.stream(FixtureVideoStream.large).frames.first)
    let small = try #require(try SharedFixtures.stream(FixtureVideoStream.small).frames.first)
    let largeFormat = try H264SampleBuffers.formatDescription(try #require(large.params))
    let smallFormat = try H264SampleBuffers.formatDescription(try #require(small.params))
    #expect(largeFormat.dimensions.width == 1280 && largeFormat.dimensions.height == 800)
    #expect(smallFormat.dimensions.width == 640 && smallFormat.dimensions.height == 400)
    #expect(largeFormat.mediaSubType == .h264)
  }

  @Test func badParameterSetsAreReported() {
    #expect(throws: RemoteVideoError.self) {
      try H264SampleBuffers.formatDescription(H264ParameterSets(sps: Data([0x67]), pps: Data()))
    }
    #expect(throws: RemoteVideoError.self) {
      try H264SampleBuffers.formatDescription(
        H264ParameterSets(sps: Data([0x67, 0x42]), pps: Data([0x68])))
    }
  }

  @Test func accessUnitsBecomeImmediateSampleBuffers() throws {
    let stream = try SharedFixtures.stream(FixtureVideoStream.large)
    let format = try H264SampleBuffers.formatDescription(
      try #require(stream.frames[0].params))
    for frame in stream.frames.prefix(3) {
      let sample = try H264SampleBuffers.sampleBuffer(
        avcc: frame.avcc, format: format, presentationMicroseconds: frame.ptsUs)
      #expect(sample.numSamples == 1)
      #expect(sample.totalSampleSize == frame.avcc.count)
      #expect(try sample.dataBuffer?.dataBytes() == frame.avcc)
      #expect(sample.presentationTimeStamp.seconds == Double(frame.ptsUs) / 1e6)
      #expect(sample.sampleAttachments[0][.displayImmediately] as? Bool == true)
    }
  }

  /// The hardware decoder accepts the stream and decodes every frame. Verified on Apple silicon
  /// Macs; the probe is what the renderer logs in the app on each platform.
  @Test func theStreamDecodesInHardware() throws {
    let stream = try SharedFixtures.stream(FixtureVideoStream.large)
    let format = try H264SampleBuffers.formatDescription(
      try #require(stream.frames[0].params))
    let report = HardwareDecodeReport.probe(format)
    #expect(report.codecSupported)
    #expect(report.sessionCreated)
    #expect(report.usingHardware)
    #expect(try decodedFrameCount(stream, format: format) == stream.frames.count)
  }

  private func decodedFrameCount(_ stream: FixtureVideoStream, format: CMVideoFormatDescription)
    throws -> Int
  {
    var session: VTDecompressionSession?
    let specification =
      [kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: true] as CFDictionary
    let created = unsafe VTDecompressionSessionCreate(
      allocator: nil, formatDescription: format, decoderSpecification: specification,
      imageBufferAttributes: nil, outputCallback: nil, decompressionSessionOut: &session)
    #expect(created == noErr)
    let decoder = try #require(session)
    defer { VTDecompressionSessionInvalidate(decoder) }
    var decoded = 0
    for frame in stream.frames {
      let sample = try H264SampleBuffers.sampleBuffer(
        avcc: frame.avcc, format: format, presentationMicroseconds: frame.ptsUs)
      // Without asynchronous flags the output handler runs before DecodeFrame returns.
      let output = Mutex<(status: OSStatus, width: Int)>((noErr, 0))
      let status = VTDecompressionSessionDecodeFrame(
        decoder, sampleBuffer: sample, flags: [], infoFlagsOut: nil
      ) { status, _, buffer, _, _ in
        output.withLock { $0 = (status, buffer.map(CVPixelBufferGetWidth) ?? 0) }
      }
      let (frameStatus, width) = output.withLock { $0 }
      #expect(status == noErr)
      #expect(frameStatus == noErr)
      if width > 0 {
        #expect(width == 1280)
        decoded += 1
      }
    }
    return decoded
  }
}

@MainActor
@Suite("Video renderer")
struct RendererTests {
  @Test func deltasWaitForAKeyframeAndAskForOneOnce() throws {
    let stream = try SharedFixtures.stream(FixtureVideoStream.large)
    let renderer = RemoteVideoRenderer()
    var requests: [KeyframeReason] = []
    renderer.requestKeyframe = { requests.append($0) }
    renderer.reset()
    renderer.enqueue(stream.frames[1])
    renderer.enqueue(stream.frames[2])
    #expect(renderer.framesEnqueued == 0)
    #expect(requests == [.flush])
    renderer.enqueue(stream.frames[0])
    renderer.enqueue(stream.frames[1])
    #expect(renderer.framesEnqueued == 2)
    #expect(renderer.videoSize == CGSize(width: 1280, height: 800))
  }

  @Test func aFormatChangeReplacesTheFormat() throws {
    let large = try SharedFixtures.stream(FixtureVideoStream.large)
    let small = try SharedFixtures.stream(FixtureVideoStream.small, formatChanged: true)
    let renderer = RemoteVideoRenderer()
    var sizes: [CGSize] = []
    renderer.videoSizeChanged = { sizes.append($0) }
    renderer.enqueue(large.frames[0])
    renderer.enqueue(small.frames[0])
    renderer.enqueue(small.frames[1])
    #expect(sizes == [CGSize(width: 1280, height: 800), CGSize(width: 640, height: 400)])
    #expect(renderer.framesEnqueued == 3)
    #expect(renderer.hardwareDecode?.sessionCreated == true)
  }

  @Test func aKeyframeWithoutParameterSetsIsAnError() throws {
    var frame = try #require(try SharedFixtures.stream(FixtureVideoStream.large).frames.first)
    frame.params = nil
    let renderer = RemoteVideoRenderer()
    var requests: [KeyframeReason] = []
    renderer.requestKeyframe = { requests.append($0) }
    renderer.enqueue(frame)
    #expect(renderer.lastError == RemoteVideoError.noFormat.description)
    #expect(requests == [.decoderError])
  }
}
