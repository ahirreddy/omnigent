internal import Darwin
internal import Foundation
internal import Synchronization
internal import os

/// Chromium's `--remote-debugging-pipe`: the host reads DevTools commands on its fd 3 and writes
/// replies and events on its fd 4, each message a JSON text ended by a NUL byte. Only the app
/// holds the other ends, so no other process can reach the browser through it.
nonisolated final class DevToolsPipe: Sendable {
  /// The descriptors to hand the host, keyed by their number there. Close them after the spawn.
  let childDescriptors: [Int32: Int32]

  private let commandsWrite: Int32
  private let repliesRead: Int32
  private let writes = DispatchQueue(label: "ai.omnigent.weblayer.devtools-pipe.write")
  private let state = Mutex(PipeState())

  private struct PipeState {
    var childEndsOpen = true
    var closed = false
    var started = false
  }

  /// Opens both pipes.
  /// - Throws: `.launchFailed` when the process is out of descriptors.
  init() throws(WebLayerError) {
    let commands = try Self.makePipe()
    let replies: (read: Int32, write: Int32)
    do {
      replies = try Self.makePipe()
    } catch {
      Darwin.close(commands.read)
      Darwin.close(commands.write)
      throw error
    }
    commandsWrite = commands.write
    repliesRead = replies.read
    childDescriptors = [3: commands.read, 4: replies.write]
    // A host that exited turns a write into EPIPE instead of a SIGPIPE that ends the app.
    _ = fcntl(commandsWrite, F_SETNOSIGPIPE, 1)
  }

  deinit {
    closeChildEnds()
    shutDown()
  }

  /// Closes the app's copies of the host's ends, once the host holds them.
  func closeChildEnds() {
    let open = state.withLock { state in
      defer { state.childEndsOpen = false }
      return state.childEndsOpen
    }
    guard open else { return }
    for descriptor in childDescriptors.values { Darwin.close(descriptor) }
  }

  /// Starts reading. `onMessage` gets each message, in order, on a private thread; `onClose`
  /// runs once when the host's end closes or reading fails.
  func start(
    onMessage: @escaping @Sendable (Data) -> Void, onClose: @escaping @Sendable () -> Void
  ) {
    let first = state.withLock { state in
      defer { state.started = true }
      return !state.started && !state.closed
    }
    guard first else { return }
    let descriptor = repliesRead
    // The reader owns its descriptor: closing it under a blocked read could hand the number to
    // another file. It returns once the host's end closes.
    Thread.detachNewThread {
      Self.read(descriptor, onMessage: onMessage)
      Darwin.close(descriptor)
      onClose()
    }
  }

  /// Queues one message for the host.
  /// - Parameter message: A JSON text without the NUL terminator.
  func send(_ message: Data) {
    let descriptor = commandsWrite
    writes.async { [weak self] in
      guard let self, !state.withLock({ $0.closed }) else { return }
      var framed = message
      framed.append(0)
      if !Self.writeAll(framed, to: descriptor) {
        DevToolsGate.log.error("Writing to the DevTools pipe failed: errno \(errno)")
      }
    }
  }

  /// Closes the app's ends. The host sees its pipe close and Chromium shuts down, so this is
  /// only for a host that is gone.
  func shutDown() {
    let (wasOpen, reading) = state.withLock { state in
      defer { state.closed = true }
      return (!state.closed, state.started)
    }
    guard wasOpen else { return }
    writes.async { [commandsWrite] in Darwin.close(commandsWrite) }
    if !reading { Darwin.close(repliesRead) }
  }

  private static func makePipe() throws(WebLayerError) -> (read: Int32, write: Int32) {
    var descriptors: [Int32] = [-1, -1]
    guard unsafe pipe(&descriptors) == 0 else {
      throw .launchFailed("DevTools pipe: errno \(errno)")
    }
    // Close-on-exec in the app, so nothing else it spawns inherits them.
    for descriptor in descriptors { _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC) }
    return (descriptors[0], descriptors[1])
  }

  private static func writeAll(_ data: Data, to descriptor: Int32) -> Bool {
    var offset = 0
    while offset < data.count {
      let written = unsafe data.withUnsafeBytes { bytes in
        unsafe Darwin.write(
          descriptor, bytes.baseAddress?.advanced(by: offset), bytes.count - offset)
      }
      if written < 0 {
        if errno == EINTR { continue }
        return false
      }
      offset += written
    }
    return true
  }

  private static func read(_ descriptor: Int32, onMessage: @Sendable (Data) -> Void) {
    var pending = Data()
    var buffer = [UInt8](repeating: 0, count: 65_536)
    while true {
      let count = buffer.withUnsafeMutableBytes { bytes in
        unsafe Darwin.read(descriptor, bytes.baseAddress, bytes.count)
      }
      if count < 0, errno == EINTR { continue }
      guard count > 0 else { return }
      var start = 0
      for index in 0..<count where buffer[index] == 0 {
        pending.append(contentsOf: buffer[start..<index])
        onMessage(pending)
        pending = Data()
        start = index + 1
      }
      pending.append(contentsOf: buffer[start..<count])
    }
  }
}
