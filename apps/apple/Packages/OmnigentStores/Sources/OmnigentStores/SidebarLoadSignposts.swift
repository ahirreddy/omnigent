import Darwin
public import OmnigentCoreFFI
public import os

/// Signposts that time the sidebar's loading, from launch to every list event and sidebar build,
/// for Instruments or `Tools/perf/sidebar-load.sh` (`log stream --signpost`, subsystem
/// `ai.omnigent.performance`, category `sidebar`). They cost next to nothing while unrecorded.
/// Each carries the CPU time its thread has used, which on the main thread is the app's.
nonisolated public enum SidebarLoadSignposts {
  /// The sidebar's signposter.
  public static let signposter = OSSignposter(
    subsystem: "ai.omnigent.performance", category: "sidebar")

  /// Whether something records them.
  public static var isEnabled: Bool { signposter.isEnabled }

  /// Marks a moment of the load: `name` with `detail`, and the thread's CPU time so far.
  /// - Parameters:
  ///   - name: The moment, a literal.
  ///   - detail: Counts and kinds, never what a session says.
  public static func mark(_ name: StaticString, _ detail: @autoclosure () -> String = "") {
    guard signposter.isEnabled else { return }
    let cpu = threadCPUMilliseconds()
    let text = detail()
    signposter.emitEvent(name, "\(text, privacy: .public) cpu=\(cpu)")
  }

  /// Runs `body` inside an interval named `name`, its end carrying `detail` and the CPU time.
  /// - Parameters:
  ///   - name: The interval, a literal.
  ///   - detail: Counts and kinds, read after `body`.
  ///   - body: The work.
  /// - Returns: What `body` returns.
  public static func measure<Result>(
    _ name: StaticString, detail: (Result) -> String = { _ in "" }, _ body: () throws -> Result
  ) rethrows -> Result {
    guard signposter.isEnabled else { return try body() }
    let state = signposter.beginInterval(name, id: signposter.makeSignpostID())
    let result = try body()
    let cpu = threadCPUMilliseconds()
    let text = detail(result)
    signposter.endInterval(name, state, "\(text, privacy: .public) cpu=\(cpu)")
    return result
  }

  /// What a sidebar event is, with its rows; `nil` for other events.
  /// - Parameter event: The core's event.
  /// - Returns: Its kind and counts.
  public static func kind(of event: CoreEvent) -> String? {
    switch event {
    case .connectionChanged(let phase): "phase \(phase.signpostName)"
    case .sessionListChanged(let change): kind(of: change)
    case .sessionListLoaded: "loaded"
    case .offlineChanged(let url): "offline \(url != nil)"
    case .savedListShown(let url): "saved list \(url != nil)"
    case .projectsLoaded(let projects, _): "projects \(projects.count)"
    case .projectFoldersChanged(let folders): "folders \(folders.count)"
    case .sessionListPagingChanged(let hasMore, let isLoading): "paging \(hasMore) \(isLoading)"
    case .unreadChanged(let ids): "unread \(ids.count)"
    default: nil
    }
  }

  private static func kind(of change: SessionListChange) -> String {
    switch change {
    case .reset(let sessions): "reset \(sessions.count)"
    case .upsert(let sessions): "upsert \(sessions.count)"
    case .remove(let ids): "remove \(ids.count)"
    }
  }

  /// The calling thread's CPU time in milliseconds.
  static func threadCPUMilliseconds() -> UInt64 {
    clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) / 1_000_000
  }
}

extension ConnectionPhase {
  /// The phase's name for a signpost, without what it carries.
  nonisolated var signpostName: String {
    switch self {
    case .disconnected: "disconnected"
    case .discovering: "discovering"
    case .signInRequired: "signInRequired"
    case .signingIn: "signingIn"
    case .awaitingBrowserLogin: "awaitingBrowserLogin"
    case .connecting: "connecting"
    case .connected: "connected"
    case .failed: "failed"
    }
  }
}
