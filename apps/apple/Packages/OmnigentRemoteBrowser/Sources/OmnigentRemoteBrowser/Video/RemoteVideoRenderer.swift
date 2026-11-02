public import AVFoundation
import CoreMedia
public import OmnigentCoreFFI
import os

/// Feeds access units to an `AVSampleBufferDisplayLayer`, which decodes H.264 in hardware on
/// macOS and iOS. Deltas wait for a keyframe; a decode failure, a flush the system requires (iOS
/// background) or a format change flushes the layer and asks for a new keyframe.
public final class RemoteVideoRenderer {
  /// The layer to show; size and position it over the content rect.
  public let layer = AVSampleBufferDisplayLayer()
  /// Asks the host for an IDR. Called once per recovery, not per dropped frame.
  public var requestKeyframe: (KeyframeReason) -> Void = { _ in }
  /// The decoded picture size changed (a new format), in video pixels.
  public var videoSizeChanged: (CGSize) -> Void = { _ in }
  /// The coded picture size of the current format, in video pixels.
  public private(set) var videoSize: CGSize?
  /// The last wrapping or decode error, for the UI.
  public private(set) var lastError: String?
  /// Frames handed to the decoder since creation.
  public private(set) var framesEnqueued = 0
  /// Whether the hardware decoder accepted the current format, once checked.
  public private(set) var hardwareDecode: HardwareDecodeReport?

  private var format: CMVideoFormatDescription?
  private var parameterSets: H264ParameterSets?
  private var waitingForKeyframe = true
  private var keyframeRequested = false
  private var observers: [any NSObjectProtocol] = []
  private static let log = Logger(subsystem: "ai.omnigent.remote-browser", category: "video")

  /// Creates a renderer.
  public init() {
    layer.videoGravity = .resize
    let center = NotificationCenter.default
    let renderer = layer.sampleBufferRenderer
    for name in [
      AVSampleBufferVideoRenderer.didFailToDecodeNotification,
      AVSampleBufferVideoRenderer.requiresFlushToResumeDecodingDidChangeNotification,
    ] {
      observers.append(
        center.addObserver(forName: name, object: renderer, queue: .main) { [weak self] _ in
          MainActor.assumeIsolated { self?.recoverIfNeeded() }
        })
    }
  }

  isolated deinit {
    for observer in observers {
      NotificationCenter.default.removeObserver(observer)
    }
  }

  /// Decodes and shows `frame`, or drops it while waiting for a keyframe.
  /// - Parameter frame: The access unit.
  public func enqueue(_ frame: VideoFrame) {
    recoverIfNeeded()
    let renderer = layer.sampleBufferRenderer
    if frame.keyframe {
      guard let sets = frame.params else {
        fail(.noFormat, reason: .decoderError)
        return
      }
      if frame.formatChanged || sets != parameterSets || format == nil {
        do {
          let description = try H264SampleBuffers.formatDescription(sets)
          if format != nil { renderer.flush() }
          format = description
          parameterSets = sets
          let dimensions = description.dimensions
          let size = CGSize(width: Int(dimensions.width), height: Int(dimensions.height))
          if size != videoSize {
            videoSize = size
            videoSizeChanged(size)
          }
          checkHardwareDecode(description)
        } catch {
          fail(error, reason: .decoderError)
          return
        }
      }
      waitingForKeyframe = false
      keyframeRequested = false
    }
    guard !waitingForKeyframe, let format else { return }
    do {
      let sample = try H264SampleBuffers.sampleBuffer(
        avcc: frame.avcc, format: format, presentationMicroseconds: frame.ptsUs)
      renderer.enqueue(sample)
      framesEnqueued += 1
      lastError = nil
    } catch {
      fail(error, reason: .decoderError)
    }
  }

  /// Drops the shown picture and waits for the next keyframe (for example after the tab was
  /// hidden), asking for one.
  public func reset() {
    layer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
    awaitKeyframe(.flush)
  }

  private func recoverIfNeeded() {
    let renderer = layer.sampleBufferRenderer
    if renderer.status == .failed {
      let message = renderer.error.map { String(describing: $0) } ?? "unknown decoder error"
      Self.log.error("Decoder failed: \(message, privacy: .public)")
      lastError = message
      renderer.flush()
      awaitKeyframe(.decoderError)
    } else if renderer.requiresFlushToResumeDecoding {
      renderer.flush()
      awaitKeyframe(.flush)
    }
  }

  private func fail(_ error: RemoteVideoError, reason: KeyframeReason) {
    Self.log.error("\(error.description, privacy: .public)")
    lastError = error.description
    awaitKeyframe(reason)
  }

  private func awaitKeyframe(_ reason: KeyframeReason) {
    waitingForKeyframe = true
    guard !keyframeRequested else { return }
    keyframeRequested = true
    requestKeyframe(reason)
  }

  private func checkHardwareDecode(_ description: CMVideoFormatDescription) {
    let report = HardwareDecodeReport.probe(description)
    hardwareDecode = report
    // Once per format, persisted so the decode path can be checked after the fact.
    if report.usingHardware {
      Self.log.notice("H.264 \(report.description, privacy: .public)")
    } else {
      Self.log.error("H.264 \(report.description, privacy: .public)")
    }
  }
}
