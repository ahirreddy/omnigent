import Foundation
public import Observation
public import OmnigentCoreFFI

/// The review of what a newly connected host carries over (the web's import review): waits for
/// the host to come online, then reads its harnesses once.
@MainActor
@Observable
public final class ImportReviewStore {
  /// Where the review stands.
  public enum Phase: Equatable {
    /// The host isn't online yet.
    case connecting
    /// Its harnesses are being read.
    case checking
    /// The review.
    case loaded(ImportReview)
    /// The read failed, with the reason.
    case failed(String)
  }

  /// Where the review stands.
  public private(set) var phase = Phase.connecting
  /// The host.
  public let hostID: String

  private let core: ClientCore
  /// How long to wait between reads while the host connects, as the web's 2 s retry.
  private let retryDelay: Duration

  init(core: ClientCore, hostID: String, retryDelay: Duration = .seconds(2)) {
    self.core = core
    self.hostID = hostID
    self.retryDelay = retryDelay
  }

  /// Reads the review, again every couple of seconds while the host isn't online or its tunnel
  /// isn't up (409), until the task is cancelled.
  public func load() async {
    while !Task.isCancelled {
      if case .loaded = phase { return }
      do {
        let review = try await core.importReview(hostId: hostID)
        if review.online {
          phase = .loaded(review)
          return
        }
        phase = .connecting
      } catch {
        let failure = coreError(error)
        guard case .HttpStatus(409, _) = failure else {
          phase = .failed(failure.message)
          return
        }
        phase = .checking
      }
      do {
        try await Task.sleep(for: retryDelay)
      } catch {
        return  // Cancelled: the review closed.
      }
    }
  }
}

extension ConnectionStore {
  /// The import review of `hostID`, a new store each time it shows.
  /// - Parameter hostID: The host.
  /// - Returns: The store, or `nil` without a core.
  public func importReview(hostID: String) -> ImportReviewStore? {
    core.map { ImportReviewStore(core: $0, hostID: hostID) }
  }
}
