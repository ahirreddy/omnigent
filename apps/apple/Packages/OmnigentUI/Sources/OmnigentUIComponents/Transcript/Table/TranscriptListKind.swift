import Foundation

/// Which list lays out the chat transcript: SwiftUI's lazy stack (the default), or, on the Mac,
/// a table whose rows are reused cells with cached heights (``TableTranscriptView``), a
/// prototype read from `omnigent:transcript-list` (a launch argument
/// `-omnigent:transcript-list table` or a stored default).
nonisolated enum TranscriptListKind: String, Sendable, CaseIterable {
  case stack
  case table

  /// The defaults key.
  static let key = "omnigent:transcript-list"

  /// The list `defaults` asks for; the stack for a missing or unknown value.
  static func read(from defaults: UserDefaults) -> Self {
    defaults.string(forKey: key).flatMap(Self.init(rawValue:)) ?? .stack
  }

  /// The list this process uses, read once: switching lists takes a relaunch. A test sets it
  /// for its duration to host a screen over the other list.
  @MainActor static var current: Self = {
    #if os(macOS)
      read(from: .standard)
    #else
      .stack
    #endif
  }()
}
