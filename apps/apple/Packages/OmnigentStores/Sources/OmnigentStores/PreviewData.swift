import OmnigentCoreFFI
import OmnigentServices

/// Stores for SwiftUI previews and the offline sample, backed by the core's demo server: the real
/// core, sample sessions, and replies that stream on a timer. No network is used.
public enum PreviewData {
  /// The address the offline sample server answers on; the demo connects to it on launch.
  public static let demoServerURL = "http://127.0.0.1:6767"

  /// A store over the offline sample server, not yet connected.
  /// - Returns: The store.
  /// - Throws: `CoreError` when the bundled sample does not load.
  public static func demoStore() throws -> ConnectionStore {
    ConnectionStore(core: try ClientCore.newDemo(clock: SystemClock(), scheduler: TaskScheduler()))
  }

  /// A store connected to the offline sample server, with its session list loaded.
  /// - Returns: The store.
  /// - Throws: `CoreError` when the bundled sample does not load or connect.
  public static func connectedDemoStore() async throws -> ConnectionStore {
    let store = try demoStore()
    await store.connect(serverURL: demoServerURL)
    if let issue = store.issues.last { throw issue.error }
    return store
  }
}
