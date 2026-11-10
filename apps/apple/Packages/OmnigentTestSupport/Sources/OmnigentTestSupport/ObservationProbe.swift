import Observation
import Synchronization

/// Whether `change` changes an observable value that `read` read: what redraws a view that reads
/// the same values in its body.
/// - Parameters:
///   - read: Reads the values, as the view's body would.
///   - change: The change.
/// - Returns: Whether the reader was told.
public func observationNotifies(_ read: () -> Void, when change: () -> Void) -> Bool {
  let notified = Mutex(false)
  withObservationTracking(read) { notified.withLock { $0 = true } }
  change()
  return notified.withLock { $0 }
}
