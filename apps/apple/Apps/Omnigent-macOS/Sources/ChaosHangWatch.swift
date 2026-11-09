#if DEBUG
  import Foundation
  import OSLog
  import OmnigentUIComponents

  /// Writes what layout is doing, and a sample of the stacks, when the main thread stops
  /// returning to its run loop, which no code on that thread can report. Its own thread beats
  /// the main run loop once a second.
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
        // A block on the run loop, not the main queue: a modal loop inside a main-queue job
        // keeps the app alive but never drains that queue.
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) { [self] in
          lock.withLock { lastBeat = Date() }
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
        Thread.sleep(forTimeInterval: min(1, threshold / 4))
        let silent = Date().timeIntervalSince(lock.withLock { lastBeat })
        guard silent >= threshold else {
          isHung = false
          continue
        }
        guard !isHung, reported < Self.reports else { continue }
        isHung = true
        reported += 1
        report(silentFor: silent, number: reported)
      }
    }

    private func report(silentFor silent: TimeInterval, number: Int) {
      let before = HangTrace.passCounts()
      let sampleFile = "\(path).hang-\(number).txt"
      let sampler = sampling(into: sampleFile)
      Thread.sleep(forTimeInterval: span)
      let trace = HangTrace.report(since: before)
      append("HANG main thread silent for \(Int(silent)) s; over the next \(span) s, \(trace)\n")
      switch sampler {
      case .success(let process):
        process.waitUntilExit()
        append("sample: \(sampleFile), exit \(process.terminationStatus)\n")
      case .failure(let error):
        append("sample failed: \(error.localizedDescription)\n")
      }
    }

    /// Starts `sample` on this process, which a sandboxed edition is not allowed to do.
    private func sampling(into file: String) -> Result<Process, any Error> {
      let process = Process()
      process.executableURL = URL(filePath: "/usr/bin/sample")
      process.arguments = [
        "\(ProcessInfo.processInfo.processIdentifier)", "\(max(1, Int(span.rounded(.up))))",
        "-file", file,
      ]
      process.standardOutput = FileHandle.nullDevice
      process.standardError = FileHandle.nullDevice
      return Result {
        try process.run()
        return process
      }
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
