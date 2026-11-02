public import CoreMedia
public import Foundation
public import OmnigentCoreFFI

/// Why a frame could not be handed to the decoder.
nonisolated public enum RemoteVideoError: Error, Hashable, Sendable, CustomStringConvertible {
  /// CoreMedia rejected the SPS/PPS.
  case badParameterSets(String)
  /// The access unit could not be wrapped in a sample buffer.
  case sampleBufferFailed(String)
  /// A delta arrived before any keyframe.
  case noFormat

  /// A readable message.
  public var description: String {
    switch self {
    case .badParameterSets(let detail): "The H.264 parameter sets are invalid: \(detail)."
    case .sampleBufferFailed(let detail): "The H.264 frame could not be wrapped: \(detail)."
    case .noFormat: "A video frame arrived before its keyframe."
    }
  }
}

/// CoreMedia wrapping for the stream the core delivers: a format description from SPS/PPS, and
/// one `CMSampleBuffer` per AVCC access unit, marked to display immediately.
nonisolated public enum H264SampleBuffers {
  /// The format description for a keyframe's parameter sets (4-byte NAL lengths).
  /// - Parameter parameterSets: SPS and PPS.
  /// - Returns: The description; its dimensions are the coded picture size.
  /// - Throws: ``RemoteVideoError/badParameterSets(_:)``.
  public static func formatDescription(_ parameterSets: H264ParameterSets) throws(RemoteVideoError)
    -> CMVideoFormatDescription
  {
    // CoreMedia's Swift initializer traps on an empty parameter set.
    guard !parameterSets.sps.isEmpty, !parameterSets.pps.isEmpty else {
      throw .badParameterSets("an empty SPS or PPS")
    }
    do {
      return try CMFormatDescription(
        h264ParameterSets: [parameterSets.sps, parameterSets.pps], nalUnitHeaderLength: 4)
    } catch {
      throw .badParameterSets(String(describing: error))
    }
  }

  /// A ready sample buffer for one access unit, with `DisplayImmediately` set so the layer shows
  /// it on arrival instead of scheduling it against a timebase.
  /// - Parameters:
  ///   - avcc: NAL units with 4-byte big-endian lengths.
  ///   - format: The stream's format description.
  ///   - presentationMicroseconds: Host capture time.
  /// - Returns: The sample buffer.
  /// - Throws: ``RemoteVideoError/sampleBufferFailed(_:)``.
  public static func sampleBuffer(
    avcc: Data, format: CMVideoFormatDescription, presentationMicroseconds: UInt64
  ) throws(RemoteVideoError) -> CMSampleBuffer {
    do {
      let block = try CMBlockBuffer(length: avcc.count)
      try unsafe avcc.withUnsafeBytes { bytes in
        try unsafe block.replaceDataBytes(with: bytes)
      }
      let timing = CMSampleTimingInfo(
        duration: .invalid,
        presentationTimeStamp: CMTime(
          value: CMTimeValue(clamping: presentationMicroseconds), timescale: 1_000_000),
        decodeTimeStamp: .invalid)
      let sample = try CMSampleBuffer(
        dataBuffer: block, formatDescription: format, numSamples: 1, sampleTimings: [timing],
        sampleSizes: [avcc.count])
      sample.sampleAttachments[0][.displayImmediately] = true
      return sample
    } catch {
      throw .sampleBufferFailed(String(describing: error))
    }
  }
}
