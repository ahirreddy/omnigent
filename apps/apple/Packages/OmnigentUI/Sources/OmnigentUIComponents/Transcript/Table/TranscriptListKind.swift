import Foundation

/// Which list lays out the chat transcript: SwiftUI's lazy stack (the default), or a list of
/// reused cells with cached heights (``TableTranscriptView``), a table on the Mac and a
/// collection view on iPhone and iPad. A prototype read from `omnigent:transcript-list` (a
/// launch argument `-omnigent:transcript-list table` or a stored default).
nonisolated enum TranscriptListKind: String, Sendable {
  case stack
  case table

  /// The defaults key.
  static let key = "omnigent:transcript-list"

  /// The list `defaults` asks for; the stack for a missing or unknown value.
  static func read(from defaults: UserDefaults) -> Self {
    defaults.string(forKey: key).flatMap(Self.init(rawValue:)) ?? .stack
  }

  /// The list this process uses, read once: switching lists takes a relaunch.
  @MainActor static let current: Self = read(from: .standard)
}
