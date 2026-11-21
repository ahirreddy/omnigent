import Darwin
import Foundation
import Synchronization
import Testing

@testable import OmnigentWebLayer

/// The host gets the DevTools pipe as fds 3 and 4 and nothing else of the app's; a session with
/// agent DevTools launches it that way and opens no listener by itself.
@Suite("DevTools pipe")
struct DevToolsPipeTests {
  @Test("the child reads fd 3 and answers on fd 4, one NUL-ended message at a time")
  func pipeRoundTrip() async throws {
    let pipe = try DevToolsPipe()
    // Echoes each NUL-ended message back with a prefix, as Chromium answers a command.
    let echo = #"while IFS= read -r -d '' message <&3; do printf 'echo:%s\0' "$message" >&4; done"#
    let process = try HostProcess(
      executable: URL(fileURLWithPath: "/bin/bash"), arguments: ["-c", echo],
      descriptors: pipe.childDescriptors)
    defer { process.kill() }
    pipe.closeChildEnds()
    let received = Mutex<[String]>([])
    let closed = Mutex(false)
    pipe.start(
      onMessage: { data in
        received.withLock { $0.append(String(bytes: data, encoding: .utf8) ?? "") }
      },
      onClose: { closed.withLock { $0 = true } })
    pipe.send(Data(#"{"id":1}"#.utf8))
    pipe.send(Data(#"{"id":2}"#.utf8))
    #expect(await eventually { received.withLock { $0.count } == 2 })
    #expect(received.withLock { $0 } == [#"echo:{"id":1}"#, #"echo:{"id":2}"#])
    process.kill()
    #expect(await eventually { closed.withLock { $0 } }, "the reader sees the host's end close")
  }

  @Test("descriptors the app did not name never reach the child")
  func otherDescriptorsStayClosed() async throws {
    var spare: [Int32] = [-1, -1]
    #expect(unsafe pipe(&spare) == 0)
    defer {
      close(spare[0])
      close(spare[1])
    }
    // Not close-on-exec, so only the spawn's own rule keeps it from the child.
    let script = "[ -e /dev/fd/\(spare[1]) ] && exit 3; exit 0"
    let process = try HostProcess(
      executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script])
    let status = Mutex<Int32?>(nil)
    process.onExit = { code, _ in status.withLock { $0 = code } }
    #expect(await eventually { status.withLock { $0 } != nil })
    #expect(status.withLock { $0 } == 0)
  }

  @Test("a session with agent DevTools hands the host the pipe and listens for nobody")
  func sessionLaunchesWithThePipe() async throws {
    let report =
      #"echo "$*" > "$(dirname "$0")/args"; [ -e /dev/fd/3 ] && [ -e /dev/fd/4 ] && "#
      + #"touch "$(dirname "$0")/pipes"; exec /bin/sleep 20"#
    let host = try FakeHost(script: report) { $0.agentDevTools = true }
    defer { host.cleanUp() }
    let plain = try FakeHost(script: report)
    defer { plain.cleanUp() }
    host.session.start()
    plain.session.start()
    let macOS = "\(SessionConfiguration.hostAppName).app/Contents/MacOS"
    let hostArgs = host.root.appending(path: "\(macOS)/args")
    let plainArgs = plain.root.appending(path: "\(macOS)/args")
    #expect(await host.eventually { FileManager.default.fileExists(atPath: hostArgs.path) })
    #expect(await plain.eventually { FileManager.default.fileExists(atPath: plainArgs.path) })
    #expect(try String(contentsOf: hostArgs, encoding: .utf8).contains("--owl-devtools-pipe"))
    #expect(!(try String(contentsOf: plainArgs, encoding: .utf8).contains("--owl-devtools-pipe")))
    #expect(
      FileManager.default.fileExists(atPath: host.root.appending(path: "\(macOS)/pipes").path))
    #expect(
      !FileManager.default.fileExists(atPath: plain.root.appending(path: "\(macOS)/pipes").path))
    #expect(host.session.devTools != nil)
    #expect(!host.session.isAgentDevToolsListening)
    await #expect(throws: WebLayerError.notReady) {
      try await host.session.agentDevToolsEndpoint(scope: "conv_a")
    }
    #expect(!host.session.isAgentDevToolsListening)
  }

  private func eventually(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<500 {
      if condition() { return true }
      try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
  }
}
