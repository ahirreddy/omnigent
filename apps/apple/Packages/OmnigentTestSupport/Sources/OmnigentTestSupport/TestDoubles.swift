public import Foundation
public import OmnigentCoreFFI
import Synchronization

/// A clock the test moves by hand.
public final class TestClock: Clock, Sendable {
  private struct State {
    var monotonic: UInt64 = 0
    var unix: UInt64 = 1_700_000_000_000
  }

  private let state = Mutex(State())

  /// Creates a clock at monotonic 0 and a fixed Unix time.
  public init() {}

  /// The monotonic time, as set by the test.
  public func monotonicMs() -> UInt64 {
    state.withLock { $0.monotonic }
  }

  /// The wall-clock time, as set by the test.
  public func unixTimeMs() -> UInt64 {
    state.withLock { $0.unix }
  }

  /// Moves both clocks forward by `ms`.
  public func advance(byMs milliseconds: UInt64) {
    state.withLock { state in
      state.monotonic += milliseconds
      state.unix += milliseconds
    }
  }

  /// Sets the wall clock, leaving the monotonic clock alone.
  public func setUnixTimeMs(_ milliseconds: UInt64) {
    state.withLock { $0.unix = milliseconds }
  }
}

/// A scheduler for tests. Sleeps are scaled by `sleepScale` (0 makes every sleep an immediate
/// yield), and spawned work is kept so a test can wait for it with ``drainSpawned()``.
public final class TestScheduler: Scheduler, Sendable {
  private let sleepScale: Double
  private let spawned = Mutex<[Task<Void, Never>]>([])

  /// Creates a scheduler.
  /// - Parameter sleepScale: The fraction of each requested delay that is really slept.
  public init(sleepScale: Double = 0) {
    self.sleepScale = sleepScale
  }

  /// Sleeps for the scaled delay, or yields when the scale is zero.
  /// - Parameter delayMs: The requested delay in milliseconds.
  public func sleep(delayMs: UInt64) async {
    let scaled = UInt64(Double(delayMs) * sleepScale)
    guard scaled > 0 else {
      await Task.yield()
      return
    }
    do {
      try await Task.sleep(for: .milliseconds(scaled))
    } catch is CancellationError {
      // Cancellation ends the sleep early, as with the production scheduler.
      return
    } catch {
      // Task.sleep documents CancellationError as its only failure; anything else is a bug.
      preconditionFailure("Task.sleep threw an unexpected error: \(error)")
    }
  }

  /// Runs `task` in a task this scheduler keeps, so `drainSpawned()` can await it.
  /// - Parameter task: The work to run.
  public func spawn(task: CoreTask) {
    let spawnedTask = Task {
      await task.run()
    }
    spawned.withLock { $0.append(spawnedTask) }
  }

  /// Waits for every task spawned so far to finish.
  public func drainSpawned() async {
    let tasks = spawned.withLock { $0 }
    for task in tasks {
      await task.value
    }
  }
}

/// A secure store kept in memory, keyed by namespace and account.
public final class InMemorySecureStore: SecureStore, Sendable {
  private let items = Mutex<[String: Data]>([:])

  /// Creates an empty store.
  public init() {}

  /// The stored value under `key`.
  /// - Parameter key: The item to read.
  /// - Returns: The bytes, or nil when absent.
  /// - Throws: Never, because the in-memory store cannot fail.
  public func get(key: SecureStoreKey) throws(SecureStoreError) -> Data? {
    items.withLock { $0[Self.name(key)] }
  }

  /// Stores `value` under `key`.
  /// - Parameters:
  ///   - key: The item to write.
  ///   - value: The bytes to store.
  /// - Throws: Never, because the in-memory store cannot fail.
  public func set(key: SecureStoreKey, value: Data) throws(SecureStoreError) {
    items.withLock { $0[Self.name(key)] = value }
  }

  /// Removes `key`.
  /// - Parameter key: The item to remove.
  /// - Throws: Never, because the in-memory store cannot fail.
  public func delete(key: SecureStoreKey) throws(SecureStoreError) {
    _ = items.withLock { $0.removeValue(forKey: Self.name(key)) }
  }

  /// Every stored key, as `namespace/account`, for test assertions.
  public var storedKeys: [String] {
    items.withLock { Array($0.keys).sorted() }
  }

  private static func name(_ key: SecureStoreKey) -> String {
    "\(key.namespace)/\(key.account)"
  }
}

/// An entropy source that returns a repeating pattern, so tests get the same bytes each run.
public final class FixedEntropySource: EntropySource, Sendable {
  private let pattern: [UInt8]

  /// Creates a source.
  /// - Parameter pattern: The bytes repeated to fill each request. Must not be empty.
  public init(pattern: [UInt8] = [0xA5]) {
    self.pattern = pattern
  }

  /// Returns `len` bytes cycled from the pattern.
  /// - Parameter len: The number of bytes.
  /// - Returns: The bytes.
  /// - Throws: `EntropyError.Unavailable` when the pattern is empty.
  public func randomBytes(len: UInt32) throws(EntropyError) -> Data {
    guard !pattern.isEmpty else {
      throw .Unavailable(message: "FixedEntropySource has an empty pattern")
    }
    return Data((0..<Int(len)).map { pattern[$0 % pattern.count] })
  }
}

/// Settings kept in memory as JSON text, matching the contract of the production storage.
public final class InMemorySettingsStorage: SettingsStorage, Sendable {
  private let values = Mutex<[String: String]>([:])

  /// Creates empty settings.
  public init() {}

  /// The JSON text stored under `key`.
  /// - Parameter key: The settings key.
  /// - Returns: The JSON text, or nil when absent.
  /// - Throws: Never, because the in-memory store cannot fail.
  public func get(key: String) throws(SettingsStorageError) -> String? {
    values.withLock { $0[key] }
  }

  /// Stores or removes the JSON text under `key`.
  /// - Parameters:
  ///   - key: The settings key.
  ///   - value: The JSON text, or nil to remove the key.
  /// - Throws: Never, because the in-memory store cannot fail.
  public func set(key: String, value: String?) throws(SettingsStorageError) {
    values.withLock { $0[key] = value }
  }
}
