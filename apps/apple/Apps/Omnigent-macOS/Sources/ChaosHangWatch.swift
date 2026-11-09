#if DEBUG
  import Foundation
  import OSLog
  import OmnigentUIComponents

  /// Writes what layout is doing when the main thread stops returning to its run loop, which
  /// no code on that thread can report. Its own thread beats the main queue once a second.
  nonisolated final class ChaosHangWatch: @unchecked Sendable {
    private static let logger = Logger(subsystem: "ai.omnigent.mac.lab", category: "chaos")
    /// Hangs reported per run, so one that never ends is not logged again and again.
    private static let reports = 3

    private let path: String
    private let threshold: TimeInterval
    private let span: TimeInterval
    private let lock = NSLock()
    private var lastBeat = Date()
    private var isStopped = false

    /// - Parameters:
    ///   - path: The log to append to.
    ///   - threshold: How long the main queue stays silent before it counts as a hang.
    ///   - span: How long pass counts are compared over.
    init(path: String, threshold: TimeInterval = 20, span: TimeInterval = 5) {
      self.path = path
      self.threshold = threshold
      self.span = span
    }

    func start() {
      HangTrace.isEnabled = true
      Thread.detachNewThread { [self] in watch() }
    }

    func stop() {
      lock.withLock { isStopped = true }
    }

    private func watch() {
      var reported = 0
      var isHung = false
      while !lock.withLock({ isStopped }) {
        DispatchQueue.main.async { [self] in lock.withLock { lastBeat = Date() } }
        Thread.sleep(forTimeInterval: min(1, threshold / 4))
        let silent = Date().timeIntervalSince(lock.withLock { lastBeat })
        guard silent >= threshold else {
          isHung = false
          continue
        }
        guard !isHung, reported < Self.reports else { continue }
        isHung = true
        reported += 1
        report(silentFor: silent)
      }
    }

    private func report(silentFor silent: TimeInterval) {
      let before = HangTrace.passCounts()
      Thread.sleep(forTimeInterval: span)
      let trace = HangTrace.report(since: before)
      append("HANG main thread silent for \(Int(silent)) s; over the next \(span) s, \(trace)\n")
    }

    private func append(_ text: String) {
      do {
        guard let log = FileHandle(forWritingAtPath: path) else {
          Self.logger.error("Cannot open the chaos log at \(self.path, privacy: .public)")
          return
        }
        defer { try? log.close() }
        try log.seekToEnd()
        try log.write(contentsOf: Data(text.utf8))
      } catch {
        Self.logger.error("Chaos log write failed: \(error.localizedDescription, privacy: .public)")
      }
    }
  }
#endif
