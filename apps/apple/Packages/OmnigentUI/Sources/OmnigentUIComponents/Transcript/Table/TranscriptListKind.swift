import Foundation

/// Which list lays out the chat transcript: a list of reused cells with cached heights
/// (``TableTranscriptView``, the default), a table on the Mac and a collection view on iPhone and
/// iPad, or SwiftUI's lazy stack, the fallback. Read from `omnigent:transcript-list` (a launch
/// argument `-omnigent:transcript-list stack` or a stored default).
nonisolated enum TranscriptListKind: String, Sendable, CaseIterable {
  case stack
  case table

  /// The defaults key.
  static let key = "omnigent:transcript-list"

  /// The list `defaults` asks for; the table for a missing or unknown value.
  static func read(from defaults: UserDefaults) -> Self {
    defaults.string(forKey: key).flatMap(Self.init(rawValue:)) ?? .table
  }

  /// The list this process uses, read once: switching lists takes a relaunch. A test sets it
  /// for its duration to host a screen over the other list.
  @MainActor static var current: Self = read(from: .standard)
}
