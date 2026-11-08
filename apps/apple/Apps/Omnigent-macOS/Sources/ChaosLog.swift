#if DEBUG
  import AppKit
  import ObjectiveC

  /// What ``ChaosDriver`` writes besides its steps: window names and every Objective-C exception.
  enum ChaosLog {
    /// A window's title, or its class and level when it has none (sheets, panels, popovers).
    @MainActor
    static func describe(_ window: NSWindow) -> String {
      let kind =
        "\(Swift.type(of: window)) level=\(window.level.rawValue) screen=\(window.screen != nil)"
      return window.title.isEmpty ? "<\(kind)>" : "\"\(window.title)\""
    }

    /// Throws logged so far; a loop that throws on every pass stops being logged after this.
    nonisolated(unsafe) private static var thrownCount = 0

    /// Logs uncaught exceptions with their reasons, which the system log keeps private, and every
    /// throw before anything catches it: one AppKit catches still leaves Swift's exclusivity and
    /// executor records of the frames it unwound, and a later access crashes far away.
    static func recordExceptions() {
      NSSetUncaughtExceptionHandler { exception in Self.recordUncaught(exception) }
      objc_setExceptionPreprocessor { exception in
        if let exception = exception as? NSException { Self.recordThrown(exception) }
        return exception
      }
    }

    nonisolated private static func recordUncaught(_ exception: NSException) {
      let stack = exception.callStackSymbols.prefix(40).joined(separator: "\n")
      append("EXCEPTION \(exception.name.rawValue): \(exception.reason ?? "no reason")\n\(stack)\n")
    }

    nonisolated private static func recordThrown(_ exception: NSException) {
      unsafe thrownCount += 1
      guard unsafe thrownCount <= 200 else { return }
      let stack = Thread.callStackSymbols.dropFirst(2).prefix(30).joined(separator: "\n")
      append("THROWN \(exception.name.rawValue): \(exception.reason ?? "no reason")\n\(stack)\n")
    }

    /// Appends `text` to the chaos log, or says on standard error why it could not.
    nonisolated private static func append(_ text: String) {
      guard let path = UserDefaults.standard.string(forKey: "OmnigentChaosLog") else { return }
      do {
        let log = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try log.seekToEnd()
        try log.write(contentsOf: Data(text.utf8))
      } catch {
        FileHandle.standardError.write(Data("chaos log write failed: \(error)\n\(text)".utf8))
      }
    }
  }
#endif
