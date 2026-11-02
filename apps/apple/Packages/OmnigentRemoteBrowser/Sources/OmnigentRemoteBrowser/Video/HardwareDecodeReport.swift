public import CoreMedia
import VideoToolbox

/// Whether VideoToolbox decodes a format in hardware, read from a probe session that requires
/// the hardware decoder (`kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder`).
/// `AVSampleBufferDisplayLayer` picks the same decoder for the same format.
nonisolated public struct HardwareDecodeReport: Hashable, Sendable, CustomStringConvertible {
  /// `VTIsHardwareDecodeSupported` for H.264.
  public var codecSupported: Bool
  /// A session that requires hardware was created for this format.
  public var sessionCreated: Bool
  /// The session reports it uses the hardware decoder.
  public var usingHardware: Bool
  /// The creation or property status when something failed.
  public var status: OSStatus

  /// A one-line summary for logs.
  public var description: String {
    "hardware decode: codec \(codecSupported), session \(sessionCreated), "
      + "using hardware \(usingHardware), status \(status)"
  }

  /// Probes `format` with a session that requires the hardware decoder.
  /// - Parameter format: An H.264 format description.
  /// - Returns: The report.
  public static func probe(_ format: CMVideoFormatDescription) -> Self {
    let supported = VTIsHardwareDecodeSupported(kCMVideoCodecType_H264)
    var session: VTDecompressionSession?
    let specification =
      [kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: true] as CFDictionary
    let created = unsafe VTDecompressionSessionCreate(
      allocator: nil, formatDescription: format, decoderSpecification: specification,
      imageBufferAttributes: nil, outputCallback: nil, decompressionSessionOut: &session)
    guard created == noErr, let session else {
      return Self(
        codecSupported: supported, sessionCreated: false, usingHardware: false, status: created)
    }
    defer { VTDecompressionSessionInvalidate(session) }
    var value: CFTypeRef?
    let read = withUnsafeMutablePointer(to: &value) { pointer in
      unsafe VTSessionCopyProperty(
        session, key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,
        allocator: nil, valueOut: UnsafeMutableRawPointer(pointer))
    }
    let using = (value as? Bool) ?? false
    return Self(codecSupported: supported, sessionCreated: true, usingHardware: using, status: read)
  }
}
