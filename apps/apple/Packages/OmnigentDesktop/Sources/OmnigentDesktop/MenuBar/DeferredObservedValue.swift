import Observation

/// A value read from observable sources and republished one main-actor turn after they change,
/// never in the middle of the change. The menu bar icon reads it: a window's views mutate its
/// sources from their update callbacks during layout, and AppKit throws when the status item's
/// image changes then.
@Observable
final class DeferredObservedValue<Value: Equatable> {
  /// The latest value read.
  private(set) var value: Value
  @ObservationIgnored private let read: () -> Value

  /// Reads the value now and starts following its sources.
  /// - Parameter read: Computes the value from observable state.
  init(_ read: @escaping () -> Value) {
    self.read = read
    value = read()
    observe()
  }

  private func observe() {
    let current = withObservationTracking(read) { [weak self] in
      Task { @MainActor in self?.observe() }
    }
    if current != value {
      value = current
    }
  }
}
