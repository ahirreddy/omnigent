import Foundation

/// How one send ended.
enum DesignOutboxAttempt {
  /// The server took it.
  case sent
  /// It failed.
  case failed(any Error)
  /// The server didn't answer in time; it may still have arrived.
  case stalled
}

/// The first of a send and its stall limit to finish.
private final class DesignOutboxAttemptRace {
  var continuation: CheckedContinuation<DesignOutboxAttempt, Never>?
  var timers: [Task<Void, Never>] = []
  var delivery: Task<Void, Never>?

  func finish(_ result: DesignOutboxAttempt) {
    guard let continuation else { return }
    self.continuation = nil
    for timer in timers { timer.cancel() }
    if case .stalled = result { delivery?.cancel() }
    continuation.resume(returning: result)
  }
}

/// Sending with the web's slow note and stall limit, and keeping unsent requests on disk.
extension DesignRequestOutbox {
  /// One send: past ``Timing/slow`` it says the server is slow, past ``Timing/stalled`` the
  /// outbox stops waiting on it.
  func attempt(_ request: DesignOutboxRequest) async -> DesignOutboxAttempt {
    let race = DesignOutboxAttemptRace()
    let deliver = deliver
    let timing = timing
    return await withCheckedContinuation { continuation in
      race.continuation = continuation
      race.timers = [
        Task { [weak self] in
          guard await Self.sleep(timing.slow) else { return }
          self?.markSlow(request.id)
        },
        Task {
          guard await Self.sleep(timing.stalled) else { return }
          race.finish(.stalled)
        },
      ]
      race.delivery = Task {
        do {
          try await deliver(request)
          race.finish(.sent)
        } catch {
          race.finish(.failed(error))
        }
      }
    }
  }

  /// Sleeps for `duration`; `false` when cancelled first.
  private static func sleep(_ duration: Duration) async -> Bool {
    do {
      try await Task.sleep(for: duration)
      return true
    } catch {
      return false
    }
  }

  /// Keeps a request's latest state on disk, or forgets one that left the list. One made before
  /// its account was known is saved once it is.
  func persisted(_ id: UUID) {
    guard let storage else { return }
    guard let request = requests.first(where: { $0.id == id }) else {
      storage.delete(id)
      return
    }
    guard let owner = request.owner else { return }
    storage.save(request, owner: owner, holder: self)
  }

  /// Brings back the signed-in account's requests kept from before the app last closed, as the
  /// web's restore: none sends on its own, and one that was waiting or on its way may have
  /// reached the agent, so it needs a Retry. Expired and other accounts' requests are deleted.
  public func restoreSaved() {
    guard let storage, let owner = owner() else { return }
    let known = Set(requests.map(\.id))
    let restored = storage.adopt(owner: owner, holder: self).compactMap { saved in
      known.contains(saved.record.id) ? nil : Self.request(saved.record, files: saved.files)
    }
    guard !restored.isEmpty else { return }
    insertRestored(restored)
    for request in restored { persisted(request.id) }
  }

  /// A saved request, failed for the user to retry unless it had already failed.
  private static func request(
    _ record: DesignOutboxRecord, files: [DesignOutboxRequest.File]
  ) -> DesignOutboxRequest {
    let status: DesignOutboxRequest.Status =
      switch record.status {
      case .waiting, .sending: .failed(Copy.restored, canRetry: true)
      case .failed: .failed(record.error ?? Copy.restored, canRetry: record.canRetry)
      }
    return DesignOutboxRequest(
      id: record.id, sessionID: record.sessionID, tool: record.tool, label: record.label,
      text: record.text, files: files, madeAt: record.savedAt, status: status,
      owner: record.owner)
  }
}
