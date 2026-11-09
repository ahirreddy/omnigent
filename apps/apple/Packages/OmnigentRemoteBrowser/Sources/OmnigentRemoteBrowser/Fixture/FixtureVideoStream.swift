public import Foundation
public import OmnigentCoreFFI

/// Why a fixture stream could not load.
nonisolated public enum FixtureStreamError: Error, Hashable, Sendable, CustomStringConvertible {
  /// A resource is missing from the bundle.
  case missingResource(String)
  /// The index or stream is malformed.
  case malformed(String)

  /// A readable message.
  public var description: String {
    switch self {
    case .missingResource(let name): "The fixture \(name) is not in the bundle."
    case .malformed(let detail): "The fixture is malformed: \(detail)"
    }
  }
}

/// A recorded H.264 stream from `client-core/fixtures/remote_browser/h264`, converted to the
/// frames the core delivers (AVCC, SPS/PPS split out, AUD and SEI dropped). In the app the core
/// does this conversion; this copy exists only to play fixtures without it.
nonisolated public struct FixtureVideoStream: Sendable {
  /// The coded picture size.
  public var width: Int
  /// The coded picture height.
  public var height: Int
  /// Frames in order, the first a keyframe.
  public var frames: [VideoFrame]

  /// The 1280×800 stream (30 frames).
  public static let large = "testsrc_1280x800"
  /// The 640×400 stream, a format change after ``large``.
  public static let small = "testsrc_640x400"

  /// Loads a bundled stream.
  /// - Parameters:
  ///   - name: ``large`` or ``small``.
  ///   - streamID: The stream id to stamp on its frames.
  ///   - formatChanged: Mark the keyframe as a format change.
  /// - Throws: ``FixtureStreamError``.
  public init(named name: String, streamID: UInt32 = 1, formatChanged: Bool = false)
    throws(FixtureStreamError)
  {
    try self.init(named: name, streamID: streamID, formatChanged: formatChanged, in: .module)
  }

  /// Loads a stream from `resources`.
  init(named name: String, streamID: UInt32 = 1, formatChanged: Bool = false, in resources: Bundle)
    throws(FixtureStreamError)
  {
    guard let streamURL = resources.url(forResource: name, withExtension: "annexb"),
      let indexURL = resources.url(forResource: name + ".frames", withExtension: "json")
    else { throw .missingResource(name) }
    let stream: Data
    let index: Data
    do {
      stream = try Data(contentsOf: streamURL)
      index = try Data(contentsOf: indexURL)
    } catch {
      throw .malformed(String(describing: error))
    }
    try self.init(
      annexB: stream, index: index, streamID: streamID, formatChanged: formatChanged)
  }

  /// Parses a stream and its `.frames.json` index.
  /// - Parameters:
  ///   - annexB: The elementary stream.
  ///   - index: The index JSON.
  ///   - streamID: The stream id.
  ///   - formatChanged: Mark the keyframe as a format change.
  /// - Throws: ``FixtureStreamError/malformed(_:)``.
  public init(annexB: Data, index: Data, streamID: UInt32, formatChanged: Bool)
    throws(FixtureStreamError)
  {
    let manifest: Manifest
    do {
      manifest = try JSONDecoder().decode(Manifest.self, from: index)
    } catch {
      throw .malformed(String(describing: error))
    }
    width = manifest.width
    height = manifest.height
    frames = []
    for entry in manifest.frames {
      guard entry.offset >= 0, entry.length > 0, entry.offset + entry.length <= annexB.count else {
        throw .malformed("frame \(entry.index) is outside the stream")
      }
      let start = annexB.startIndex + entry.offset
      let unit = annexB[start..<start + entry.length]
      frames.append(
        try Self.frame(
          unit, entry: entry, streamID: streamID, formatChanged: formatChanged && entry.keyframe))
    }
    guard frames.first?.keyframe == true else { throw .malformed("the first frame is a delta") }
  }

  /// The NAL units of an Annex-B access unit, without start codes.
  /// - Parameter unit: The access unit.
  /// - Returns: The NAL units.
  public static func nalUnits(_ unit: Data) -> [Data] {
    let bytes = [UInt8](unit)
    var starts: [(code: Int, payload: Int)] = []
    var index = 0
    while index + 3 <= bytes.count {
      if bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 1 {
        let code = index > 0 && bytes[index - 1] == 0 ? index - 1 : index
        starts.append((code, index + 3))
        index += 3
      } else {
        index += 1
      }
    }
    return starts.enumerated().map { position, start in
      let end = position + 1 < starts.count ? starts[position + 1].code : bytes.count
      return Data(bytes[start.payload..<end])
    }
  }

  private static func frame(
    _ unit: Data, entry: FixtureFrameEntry, streamID: UInt32, formatChanged: Bool
  ) throws(FixtureStreamError) -> VideoFrame {
    var sps: Data?
    var pps: Data?
    var avcc = Data()
    for nal in nalUnits(unit) {
      guard let header = nal.first else { continue }
      switch header & 0x1F {
      case 7: sps = nal
      case 8: pps = nal
      case 6, 9: continue  // SEI and access unit delimiters are not decoded.
      default:
        let length = UInt32(nal.count)
        avcc.append(contentsOf: [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: length >> $0) })
        avcc.append(nal)
      }
    }
    var parameterSets: H264ParameterSets?
    if entry.keyframe {
      guard let sps, let pps else { throw .malformed("keyframe \(entry.index) has no SPS/PPS") }
      parameterSets = H264ParameterSets(sps: sps, pps: pps)
    }
    return VideoFrame(
      streamId: streamID, keyframe: entry.keyframe, ptsUs: entry.ptsMicroseconds,
      params: parameterSets, formatChanged: formatChanged, avcc: avcc)
  }

  private struct Manifest: Decodable {
    var width: Int
    var height: Int
    var frames: [FixtureFrameEntry]
  }
}

/// One access unit in a fixture's `.frames.json`.
private nonisolated struct FixtureFrameEntry: Decodable {
  var index: Int
  var offset: Int
  var length: Int
  var keyframe: Bool
  var ptsMicroseconds: UInt64

  enum CodingKeys: String, CodingKey {
    case index, offset, length, keyframe
    case ptsMicroseconds = "pts_us"
  }
}
