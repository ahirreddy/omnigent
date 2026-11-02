import CoreMedia
import CoreVideo
import Foundation
import OmnigentCoreFFI
import Synchronization
import VideoToolbox

@testable import OmnigentRemoteBrowser

/// One pixel, 8 bits per channel.
nonisolated struct RGB: Equatable, Sendable, CustomStringConvertible {
  var red: Int
  var green: Int
  var blue: Int

  var isGreen: Bool { green > red + 60 && green > blue + 30 }
  var isRed: Bool { red > green + 60 && red > blue + 60 }
  var isDark: Bool { red < 80 && green < 80 && blue < 80 }
  var description: String { "rgb(\(red), \(green), \(blue))" }
}

/// Samples of one decoded frame at the fixture page's landmarks (viewport CSS pixels).
nonisolated struct DecodedFrame: Sendable {
  /// When decoding finished.
  var decodedAt: ContinuousClock.Instant
  var keyframe: Bool
  var streamID: UInt32
  var width: Int
  var height: Int
  /// The toggle box's centre (1050, 190).
  var box: RGB
  /// Plain page background (1150, 600).
  var background: RGB
  /// Whether typed text shows in the field: dark pixels along its text line.
  var fieldHasText: Bool
}

/// A `RemoteBrowserListener` that decodes every access unit with a VideoToolbox session that
/// requires the hardware decoder, using the renderer's format-description and sample-buffer code,
/// and keeps pixel samples and the latest state.
nonisolated final class E2EDecodingListener: RemoteBrowserListener {
  private struct Decoder {
    var parameterSets: H264ParameterSets?
    var format: CMVideoFormatDescription?
    var session: VTDecompressionSession?
  }

  private struct Received {
    var snapshot: RemoteBrowserSnapshot?
    var frames: [DecodedFrame] = []
    var titles: [String] = []
    var hardware: HardwareDecodeReport?
    var errors: [String] = []
    var notices: [String] = []
    var closed: RemoteTabClosedReason??
  }

  private let decoder = Mutex(Decoder())
  private let received = Mutex(Received())

  var snapshot: RemoteBrowserSnapshot? { received.withLock { $0.snapshot } }
  var frames: [DecodedFrame] { received.withLock { $0.frames } }
  var titles: [String] { received.withLock { $0.titles } }
  var hardware: HardwareDecodeReport? { received.withLock { $0.hardware } }
  var errors: [String] { received.withLock { $0.errors } }
  var notices: [String] { received.withLock { $0.notices } }
  var closed: RemoteTabClosedReason?? { received.withLock { $0.closed } }

  func onState(snapshot: RemoteBrowserSnapshot) {
    received.withLock { state in
      state.snapshot = snapshot
      if let title = snapshot.nav?.title, state.titles.last != title { state.titles.append(title) }
    }
  }

  func onVideo(frame: VideoFrame) {
    do {
      let sampled = try decoder.withLock { try decode(frame, with: &$0) }
      received.withLock { $0.frames.append(sampled) }
    } catch {
      received.withLock { $0.errors.append(String(describing: error)) }
    }
  }

  func onStill(still: StillImage) {}

  func onClosed(reason: RemoteTabClosedReason?) {
    received.withLock { $0.closed = .some(reason) }
  }

  func onNotice(message: String) {
    received.withLock { $0.notices.append(message) }
  }

  private func decode(_ frame: VideoFrame, with state: inout Decoder) throws -> DecodedFrame {
    if frame.keyframe, let sets = frame.params, sets != state.parameterSets {
      let format = try H264SampleBuffers.formatDescription(sets)
      if let old = state.session { VTDecompressionSessionInvalidate(old) }
      state.session = try Self.hardwareSession(format)
      state.format = format
      state.parameterSets = sets
      let report = HardwareDecodeReport.probe(format)
      received.withLock { $0.hardware = report }
    }
    guard let format = state.format, let session = state.session else {
      throw E2EError("a delta frame arrived before any keyframe")
    }
    let sample = try H264SampleBuffers.sampleBuffer(
      avcc: frame.avcc, format: format, presentationMicroseconds: frame.ptsUs)
    // Without asynchronous flags the output handler runs before DecodeFrame returns.
    let output = Mutex<Result<DecodedFrame, E2EError>?>(nil)
    let status = VTDecompressionSessionDecodeFrame(
      session, sampleBuffer: sample, flags: [], infoFlagsOut: nil
    ) { status, _, buffer, _, _ in
      let result: Result<DecodedFrame, E2EError>
      if status != noErr {
        result = .failure(E2EError("decode failed: \(status)"))
      } else if let buffer {
        result = .success(Self.samples(buffer, frame: frame))
      } else {
        result = .failure(E2EError("the decoder dropped a frame"))
      }
      output.withLock { $0 = result }
    }
    guard status == noErr else { throw E2EError("DecodeFrame failed: \(status)") }
    guard let result = output.withLock({ $0 }) else { throw E2EError("no decoder output") }
    return try result.get()
  }

  private static func hardwareSession(_ format: CMVideoFormatDescription) throws
    -> VTDecompressionSession
  {
    let specification =
      [kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: true] as CFDictionary
    let attributes =
      [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA] as CFDictionary
    var session: VTDecompressionSession?
    let created = unsafe VTDecompressionSessionCreate(
      allocator: nil, formatDescription: format, decoderSpecification: specification,
      imageBufferAttributes: attributes, outputCallback: nil, decompressionSessionOut: &session)
    guard created == noErr, let session else {
      throw E2EError("no hardware H.264 decoder for this stream: \(created)")
    }
    return session
  }

  private static func samples(_ buffer: CVImageBuffer, frame: VideoFrame) -> DecodedFrame {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let width = CVPixelBufferGetWidth(buffer)
    let height = CVPixelBufferGetHeight(buffer)
    let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
    let scale = Double(width) / 1280
    let base = unsafe CVPixelBufferGetBaseAddress(buffer)
    func pixel(_ cssX: Double, _ cssY: Double) -> RGB {
      let column = min(width - 1, Int(cssX * scale))
      let row = min(height - 1, Int(cssY * scale))
      guard let base = unsafe base else { return RGB(red: -1, green: -1, blue: -1) }
      let bytes = unsafe base.advanced(by: row * rowBytes + column * 4)
        .assumingMemoryBound(to: UInt8.self)
      return unsafe RGB(red: Int(bytes[2]), green: Int(bytes[1]), blue: Int(bytes[0]))
    }
    // The text line of the field, right of where the caret sits while it is empty.
    let fieldHasText = stride(from: 54.0, through: 100, by: 1).contains { pixel($0, 70).isDark }
    return DecodedFrame(
      decodedAt: .now, keyframe: frame.keyframe, streamID: frame.streamId, width: width,
      height: height, box: pixel(1050, 190), background: pixel(1150, 600),
      fieldHasText: fieldHasText)
  }
}

/// A failure inside the end-to-end harness.
nonisolated struct E2EError: Error, CustomStringConvertible {
  let description: String

  init(_ description: String) {
    self.description = description
  }
}
