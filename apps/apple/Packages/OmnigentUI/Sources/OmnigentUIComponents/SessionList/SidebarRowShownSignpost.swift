#if os(macOS)
  import Darwin
  import os

  /// Marks the frames that show the sidebar's rows: "sidebar rows shown" among the sidebar's
  /// load signposts (subsystem `ai.omnigent.performance`, category `sidebar`), with the list's
  /// row count and the main thread's CPU time, each time the count has doubled. The list adds
  /// its row views a pass after the sidebar builds its rows, so this is when rows are on screen.
  @MainActor
  enum SidebarRowShownSignpost {
    private nonisolated static let signposter = OSSignposter(
      subsystem: "ai.omnigent.performance", category: "sidebar")
    private static var markedRows = 0

    /// A row's view is in a list of `rows` rows; marks the frame it draws in when that is twice
    /// the rows last marked.
    static func rowsShown(_ rows: Int) {
      guard rows >= max(1, markedRows * 2) else { return }
      markedRows = rows
      guard signposter.isEnabled else { return }
      MainRunLoop.performAfterDisplay {
        let cpu = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) / 1_000_000
        signposter.emitEvent("sidebar rows shown", "rows=\(rows) cpu=\(cpu)")
      }
    }
  }
#endif
