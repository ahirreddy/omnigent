public import os

/// Signposts around the apps' hot paths, shared by macOS and iOS, for Instruments' os_signpost
/// track or, without Instruments:
/// `log show --last 5m --signpost --style ndjson --predicate 'subsystem == "ai.omnigent.performance"'`.
/// Intervals cost next to nothing while nothing records them.
public enum PerformanceSignposts {
  /// The signposts' subsystem.
  public static let subsystem = "ai.omnigent.performance"
  /// The transcript: folding rows into turns, paced row updates, markdown parsing.
  public static let transcript = OSSignposter(subsystem: subsystem, category: "transcript")

  /// Runs `body` inside a signposted interval.
  /// - Parameters:
  ///   - signposter: Where to record it.
  ///   - name: The interval's name.
  ///   - body: The work.
  /// - Returns: What `body` returns.
  public static func measure<Result>(
    _ signposter: OSSignposter, _ name: StaticString, _ body: () throws -> Result
  ) rethrows -> Result {
    let state = signposter.beginInterval(name)
    defer { signposter.endInterval(name, state) }
    return try body()
  }
}
