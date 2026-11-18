import AVFoundation
import Foundation
import Observation

/// One video's playback, as the web's `VideoPlayer` runs it: nothing is read until Play, the
/// player then streams the file (``WorkspaceVideoLoader``) and starts once it can, and closing
/// releases it.
@Observable
final class WorkspaceVideoPlayback {
  /// Where playback stands.
  enum Phase: Equatable {
    /// Not asked to play.
    case idle
    /// Reading the file until it can play.
    case loading
    /// Playing or paused.
    case ready
    /// It could not play.
    case failed
  }

  /// Where playback stands.
  private(set) var phase = Phase.idle
  /// The player once asked to play.
  private(set) var player: AVPlayer?
  /// The playhead, in seconds.
  private(set) var time = 0.0
  /// The length, once known.
  private(set) var duration: Double?

  @ObservationIgnored private var loader: WorkspaceVideoLoader?
  @ObservationIgnored private var status: NSKeyValueObservation?
  @ObservationIgnored private var clock: Any?
  @ObservationIgnored private var pendingSeek: Double?

  /// Starts reading and playing `path`.
  /// - Parameter read: Reads a byte range of the video.
  func play(_ read: @escaping WorkspaceVideoLoader.Read) {
    guard phase == .idle else { return }
    phase = .loading
    let loader = WorkspaceVideoLoader(read: read)
    let asset = AVURLAsset(url: WorkspaceVideoLoader.assetURL())
    asset.resourceLoader.setDelegate(loader, queue: loader.queue)
    let item = AVPlayerItem(asset: asset)
    let player = AVPlayer(playerItem: item)
    // AVFoundation reports the status from its own threads.
    status = item.observe(\.status, options: [.new]) { @Sendable [weak self] item, _ in
      let ready = item.status == .readyToPlay
      let failed = item.status == .failed
      let length = item.duration.seconds
      Task { @MainActor [weak self] in
        self?.statusChanged(ready: ready, failed: failed, length: length)
      }
    }
    clock = player.addPeriodicTimeObserver(
      forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main
    ) { [weak self] time in
      let seconds = time.seconds
      MainActor.assumeIsolated { self?.time = seconds }
    }
    self.loader = loader
    self.player = player
  }

  /// Moves the playhead to `seconds`, starting playback first when it has not started.
  /// - Parameters:
  ///   - seconds: Where to go.
  ///   - read: Reads a byte range of the video, should playback start.
  func seek(to seconds: Double, read: @escaping WorkspaceVideoLoader.Read) {
    time = seconds
    guard phase == .ready, let player else {
      pendingSeek = seconds
      play(read)
      return
    }
    player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
  }

  /// Releases the player, back to before Play (the web's Retry, and closing the file).
  func stop() {
    player?.pause()
    if let clock { player?.removeTimeObserver(clock) }
    status?.invalidate()
    loader?.cancelAll()
    clock = nil
    status = nil
    loader = nil
    player = nil
    pendingSeek = nil
    phase = .idle
    time = 0
    duration = nil
  }

  private func statusChanged(ready: Bool, failed: Bool, length: Double) {
    if failed {
      // As the web's `onError`: a failure at any point, also mid-playback.
      guard phase != .idle else { return }
      phase = .failed
      player?.pause()
      return
    }
    guard phase == .loading, ready, let player else { return }
    phase = .ready
    if length.isFinite { duration = length }
    if let pendingSeek {
      let target = duration.map { min(pendingSeek, $0) } ?? pendingSeek
      player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
      self.pendingSeek = nil
    }
    player.play()
  }
}
