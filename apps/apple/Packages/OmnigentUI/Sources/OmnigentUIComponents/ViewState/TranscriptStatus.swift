/// What the session status line needs from the transcript. Streamed text never changes it, so a
/// host can keep it apart from the rows and only the transcript re-renders per delta.
nonisolated public struct TranscriptStatus: Hashable, Sendable {
  /// No transcript rows yet.
  public var isEmpty: Bool
  /// The last transcript row was interrupted (the turn was stopped).
  public var lastInterrupted: Bool
  /// The latest in-progress tool's title.
  public var activityTitle: String?

  /// Creates a status.
  /// - Parameters:
  ///   - isEmpty: No transcript rows yet.
  ///   - lastInterrupted: The last transcript row was interrupted.
  ///   - activityTitle: The latest in-progress tool's title.
  public init(isEmpty: Bool, lastInterrupted: Bool, activityTitle: String?) {
    self.isEmpty = isEmpty
    self.lastInterrupted = lastInterrupted
    self.activityTitle = activityTitle
  }

  /// The status of `rows`.
  /// - Parameter rows: Rows in order; activity-only rows are skipped.
  public init(rows: [Row]) {
    let transcript = rows.filter { !$0.isActivityOnly }
    self.init(
      isEmpty: transcript.isEmpty, lastInterrupted: transcript.last?.interrupted == true,
      activityTitle: transcript.last { $0.activity?.status == "in_progress" }?.activity?.title)
  }
}

/// The transcript's rows, read when the transcript renders. Reading them in the transcript's
/// own body means observable state behind them invalidates only the transcript, not the screen.
public struct LiveTranscriptRows {
  /// Returns the current rows and the revision that counts their changes.
  public let read: @MainActor () -> (rows: [Row], revision: UInt64)

  /// Creates a reader.
  /// - Parameter read: Returns the current rows and revision.
  public init(read: @escaping @MainActor () -> (rows: [Row], revision: UInt64)) {
    self.read = read
  }
}
