import Foundation
import GhosttyKit

/// Runs libghostty's parser for remote output on a thread of its own.
///
/// Parsing a sequence can post many messages to the app's mailbox, which holds 64. When it is
/// full the parser waits for a drain, and drains happen on the main thread, so parsing on the main
/// thread would hang for good on a program that changes its title or palette many times at once.
@safe final class GhosttyParserThread: @unchecked Sendable {
  @unsafe private struct Output {
    let surface: ghostty_surface_t
    let bytes: UnsafePointer<CChar>?
    let count: UInt
  }

  private let started = DispatchSemaphore(value: 0)
  private let finished = DispatchSemaphore(value: 0)
  /// Written before `started` signals and read after, so never at the same time.
  private var output: Output?

  init() {
    let thread = Thread { [self] in
      while true {
        started.wait()
        if let output = unsafe output {
          unsafe ghostty_surface_process_output(output.surface, output.bytes, output.count)
        }
        finished.signal()
      }
    }
    thread.name = "ai.omnigent.terminal.parser"
    thread.stackSize = 8 << 20
    // The main thread waits on this one, so it must not run at a lower priority.
    thread.qualityOfService = .userInteractive
    thread.start()
  }

  /// Parses `bytes`, which stay valid as this returns only once parsing is done, calling `drain`
  /// meanwhile.
  func process(
    _ surface: ghostty_surface_t, _ bytes: UnsafeBufferPointer<CChar>, drain: () -> Void
  ) {
    unsafe output = Output(surface: surface, bytes: bytes.baseAddress, count: UInt(bytes.count))
    started.signal()
    while finished.wait(timeout: .now() + .milliseconds(1)) == .timedOut {
      drain()
    }
    unsafe output = nil
  }
}
