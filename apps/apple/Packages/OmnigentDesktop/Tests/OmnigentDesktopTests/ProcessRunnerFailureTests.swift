import Darwin
import Foundation
import Synchronization
import Testing

@testable import OmnigentDesktop

/// How the real runner fails. A signal number no system has fails before anything is delivered.
@Suite("Process runner failures")
struct ProcessRunnerFailureTests {
  private static let noSuchSignal: Int32 = 9_999

  private func isOpen(_ descriptor: Int32) -> Bool { fcntl(descriptor, F_GETFD) != -1 }

  private func launch(_ path: String, _ arguments: [String] = []) -> LocalProcessLaunch {
    LocalProcessLaunch(
      executable: URL(filePath: path), arguments: arguments, environment: [:])
  }

  @Test("running out of descriptors for the second pipe closes the first, and fails the launch")
  func secondPipeFails() throws {
    let made = Mutex([OutputPipe]())
    var runner = PosixSpawnProcessRunner()
    let problem = LocalServerError.spawnSetupFailed("pipe: too many open files")
    runner.makePipe = { () throws(LocalServerError) in
      if made.withLock({ !$0.isEmpty }) { throw problem }
      let pipe = try OutputPipe()
      made.withLock { $0.append(pipe) }
      return pipe
    }
    #expect(throws: problem) { _ = try runner.launch(launch("/bin/echo")) }
    let first = try #require(made.withLock { $0.first })
    #expect(!isOpen(first.readEnd))
    #expect(!isOpen(first.writeEnd))
  }

  @Test("a pipe that can't be marked close-on-exec closes both ends and names the errno")
  func pipeMarkFails() {
    var seen: [Int32] = []
    do {
      _ = try OutputPipe(markCloseOnExec: { descriptor in
        seen.append(descriptor)
        return EBADF
      })
      Issue.record("expected the pipe to fail")
    } catch {
      #expect(error.message.contains("fcntl FD_CLOEXEC"))
      #expect(error.message.contains("errno \(EBADF)"))
    }
    #expect(seen.count == 1)
    #expect(seen.allSatisfy { !isOpen($0) })
  }

  @Test("a setup step reports the code it returned, whatever errno holds")
  func setupStepCode() throws {
    try PosixSpawnProcessRunner.check("step", 0)
    errno = ENOENT
    #expect(
      throws: LocalServerError.spawnSetupFailed("step: \(Errno.describe(ENOMEM))")
    ) {
      try PosixSpawnProcessRunner.check("step", ENOMEM)
    }
    #expect(Errno.describe(ENOMEM).contains("errno \(ENOMEM)"))
  }

  @Test("a working directory too long for the system fails before anything runs")
  func tooLongDirectory() {
    var tooLong = launch("/bin/echo")
    tooLong.workingDirectory = URL(filePath: "/" + String(repeating: "x", count: 5_000))
    do {
      let process = try PosixSpawnProcessRunner().launch(tooLong)
      Issue.record("expected a setup failure, got PID \(process.pid)")
    } catch {
      #expect(error.message.contains("chdir"))
    }
  }

  @Test("a socket option on a closed descriptor is a setup failure")
  func socketOptionFails() {
    do {
      try PosixSpawnProcessRunner.allowAddressReuse(on: -1)
      Issue.record("expected a setup failure")
    } catch {
      #expect(error.message.contains("setsockopt"))
    }
  }

  @Test("a signal the kernel refuses is an error that names the command")
  func refusedGroupSignal() {
    do {
      try PosixSpawnProcessRunner.send(signalNumber: Self.noSuchSignal, toGroupOf: getpid())
      Issue.record("expected the signal to be refused")
    } catch {
      #expect(error.message.contains("kill -\(Self.noSuchSignal)"))
    }
  }

  @Test("a child that refuses a signal reports it, and can still be stopped")
  func refusedChildSignal() async throws {
    let handle = try PosixSpawnProcessRunner().launch(launch("/bin/sleep", ["30"]))
    let process = try #require(handle as? SpawnedProcess)
    do {
      try process.send(signalNumber: Self.noSuchSignal)
      Issue.record("expected the signal to be refused")
    } catch {
      #expect(error.message.contains("-\(process.pid)"))
    }
    try process.send(.kill)
    #expect(await process.waitForExit() == .signaled(SIGKILL))
  }

  @Test("output that can't be read says so in the output, and ends")
  func unreadableOutput() async throws {
    let (stream, continuation) = AsyncStream.makeStream(of: LocalProcessOutput.self)
    SpawnedProcess.drain(-1, .standardError, into: continuation)
    continuation.finish()
    var chunks: [LocalProcessOutput] = []
    for await chunk in stream { chunks.append(chunk) }
    #expect(chunks.count == 1)
    #expect(chunks.first?.stream == .standardError)
    let text = try #require(chunks.first.flatMap { String(bytes: $0.data, encoding: .utf8) })
    #expect(text.contains("Reading the process output failed"))
    #expect(text.contains("errno \(EBADF)"))
  }

  @Test("a process something else already reaped ends as unknown")
  func alreadyReaped() {
    // Not a child of this process, so waitpid refuses without touching it.
    #expect(SpawnedProcess.reap(getppid()) == .unknown)
  }
}
