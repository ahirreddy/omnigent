import Darwin
import Foundation
import OWLProtocol
import Testing

@testable import OmnigentWebLayer

/// Messages seen by a handler that leaves their ports alone. Touched only on the main queue.
nonisolated(unsafe) private var untakenPortMessages = 0

private nonisolated func countMessage(
  _: UnsafeMutableRawPointer?, _: UnsafeMutablePointer<owl_message>
) {
  unsafe untakenPortMessages += 1
}

private nonisolated func ignoreEvent(_: UnsafeMutableRawPointer?, _: owl_channel_event, _: Int64) {}

/// A channel listening on a unique service, with a send right to it as another process would get.
@MainActor
private final class ListeningChannel {
  let channel: HostChannel
  var events: [HostChannel.Event] = []
  private let service: String

  init() throws {
    service = "ai.omnigent.tests.channel.\(UUID().uuidString)"
    channel = try HostChannel.listen(serviceName: service)
    channel.onEvent = { [weak self] event in self?.events.append(event) }
    channel.start()
  }

  /// Sends bytes in a valid envelope, as the host's end of the channel does.
  func sendFromPeer(
    kind: UInt16, payload: [UInt8], port: mach_port_t = mach_port_t(MACH_PORT_NULL),
    disposition: Int32 = MACH_MSG_TYPE_COPY_SEND
  ) throws {
    var raw: OpaquePointer?
    try #require(unsafe owl_channel_connect(service, &raw) == KERN_SUCCESS)
    let peer = unsafe try #require(raw)
    defer { unsafe owl_channel_destroy(peer) }
    let sent = payload.withUnsafeBytes { buffer in
      unsafe owl_channel_send(
        peer, kind, 0, 0, buffer.baseAddress, buffer.count, port,
        mach_msg_type_name_t(disposition), 1000)
    }
    try #require(sent == KERN_SUCCESS)
  }

  /// The channel's receive right.
  var port: mach_port_t {
    get throws { unsafe owl_channel_receive_port(try #require(channel.handle)) }
  }

  /// Delivers a message with no envelope, as a stranger with the service's name could.
  func sendGarbage(size: Int = MemoryLayout<mach_msg_header_t>.size, complex: Bool = false) throws {
    let port = try port
    let made = mach_port_insert_right(
      unsafe mach_task_self_, port, port, mach_msg_type_name_t(MACH_MSG_TYPE_MAKE_SEND))
    try #require(made == KERN_SUCCESS)
    var header = mach_msg_header_t()
    header.msgh_bits =
      mach_msg_bits_t(MACH_MSG_TYPE_COPY_SEND) | (complex ? MACH_MSGH_BITS_COMPLEX : 0)
    header.msgh_size = mach_msg_size_t(size)
    header.msgh_remote_port = port
    header.msgh_id = 1234
    var bytes = [UInt8](repeating: 0, count: size)
    let sent = bytes.withUnsafeMutableBytes { raw in
      unsafe raw.storeBytes(of: header, as: mach_msg_header_t.self)
      return unsafe mach_msg(
        raw.baseAddress?.assumingMemoryBound(to: mach_msg_header_t.self), MACH_SEND_MSG,
        header.msgh_size, 0, mach_port_t(MACH_PORT_NULL), 0, mach_port_t(MACH_PORT_NULL))
    }
    try #require(sent == KERN_SUCCESS)
  }

  var messages: Int {
    events.count { if case .message = $0 { true } else { false } }
  }

  func eventually(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<400 {
      if condition() { return true }
      do {
        try await Task.sleep(for: .milliseconds(5))
      } catch {
        return false
      }
    }
    return condition()
  }

  var failures: [String] {
    events.compactMap {
      if case .failure(let error) = $0 { error.localizedDescription } else { nil }
    }
  }
}

@MainActor
@Suite("The host channel, with real Mach messages", .serialized)
struct HostChannelMachTests {
  @Test("a service name that's taken is reported, not fatal")
  func serviceTaken() throws {
    let service = "ai.omnigent.tests.taken.\(UUID().uuidString)"
    let first = try HostChannel.listen(serviceName: service)
    defer { withExtendedLifetime(first) {} }
    #expect(throws: WebLayerError.self) { try HostChannel.listen(serviceName: service) }
  }

  @Test("a stranger's message without an envelope is dropped and reported")
  func malformed() async throws {
    let listening = try ListeningChannel()
    try listening.sendGarbage()
    #expect(await listening.eventually { !listening.failures.isEmpty })
    #expect(listening.failures.first?.contains("malformed") == true)
    #expect(!listening.events.contains { if case .message = $0 { true } else { false } })
  }

  @Test("a real message is delivered; fields that can't be decoded are reported")
  func messages() async throws {
    let listening = try ListeningChannel()
    try listening.sendFromPeer(kind: OWLMessageKind.pong.rawValue, payload: [])
    #expect(
      await listening.eventually {
        listening.events.contains { if case .message = $0 { true } else { false } }
      })
    try listening.sendFromPeer(kind: OWLMessageKind.pong.rawValue, payload: [0xFF, 0xFF, 0xFF])
    #expect(await listening.eventually { !listening.failures.isEmpty })
  }

  @Test("a message from a process other than the host is rejected")
  func wrongSender() async throws {
    let listening = try ListeningChannel()
    listening.channel.expect(pid: 1)
    try listening.sendFromPeer(kind: OWLMessageKind.pong.rawValue, payload: [])
    #expect(await listening.eventually { !listening.failures.isEmpty })
    #expect(listening.failures.first?.contains("Rejected") == true)
    #expect(!listening.events.contains { if case .message = $0 { true } else { false } })
  }

  @Test("the host's port going away is reported once, and later sends fail")
  func peerDeath() async throws {
    let listening = try ListeningChannel()
    let (right, receive) = try FakeHost.sendRightWithReceive()
    try listening.channel.adoptPeer(right)
    try listening.channel.send(.ping)
    let destroyed = mach_port_mod_refs(
      unsafe mach_task_self_, receive, mach_port_right_t(MACH_PORT_RIGHT_RECEIVE), -1)
    #expect(destroyed == KERN_SUCCESS)
    #expect(
      await listening.eventually {
        listening.events.contains { if case .peerDied = $0 { true } else { false } }
      })
    #expect(throws: WebLayerError.self) { try listening.channel.send(.ping) }
  }

  @Test("a host that stopped reading makes a send fail instead of hanging the app")
  func fullQueue() throws {
    let listening = try ListeningChannel()
    try listening.channel.adoptPeer(try FakeHost.fullPort())
    #expect(throws: WebLayerError.self) { try listening.channel.send(.ping) }
  }

  @Test("a second peer is refused")
  func secondPeer() throws {
    let listening = try ListeningChannel()
    try listening.channel.adoptPeer(try FakeHost.sendRight())
    #expect(throws: WebLayerError.self) {
      try listening.channel.adoptPeer(try FakeHost.sendRight())
    }
  }

  @Test("an empty complex message is dropped and reported")
  func emptyComplexMessage() async throws {
    let listening = try ListeningChannel()
    let size = MemoryLayout<mach_msg_header_t>.size + MemoryLayout<mach_msg_body_t>.size
    try listening.sendGarbage(size: size, complex: true)
    #expect(await listening.eventually { !listening.failures.isEmpty })
    #expect(listening.failures.first?.contains("malformed") == true)
  }

  @Test("a message too big for the channel is reported, and the channel keeps working")
  func tooBig() async throws {
    let listening = try ListeningChannel()
    try listening.sendGarbage(size: 32 * 1024)
    #expect(await listening.eventually { !listening.failures.isEmpty })
    #expect(listening.failures.first?.contains("Receiving failed") == true)
    try listening.sendFromPeer(kind: OWLMessageKind.pong.rawValue, payload: [])
    #expect(await listening.eventually { listening.messages == 1 })
  }

  @Test("a one-time right in a message is dropped and reported; only send rights are accepted")
  func sendOnceRight() async throws {
    let listening = try ListeningChannel()
    let (right, receive) = try FakeHost.sendRightWithReceive()
    defer { withExtendedLifetime(right) {} }
    try listening.sendFromPeer(
      kind: OWLMessageKind.pong.rawValue, payload: [], port: receive,
      disposition: MACH_MSG_TYPE_MAKE_SEND_ONCE)
    #expect(await listening.eventually { !listening.failures.isEmpty })
    #expect(listening.messages == 0)
  }

  @Test("another port's death isn't taken for the peer's")
  func otherPortDies() async throws {
    let listening = try ListeningChannel()
    let (right, receive) = try FakeHost.sendRightWithReceive()
    defer { withExtendedLifetime(right) {} }
    var previous = mach_port_t(MACH_PORT_NULL)
    let task = unsafe mach_task_self_
    let requested = unsafe mach_port_request_notification(
      task, receive, MACH_NOTIFY_DEAD_NAME, 0, try listening.port,
      mach_msg_type_name_t(MACH_MSG_TYPE_MAKE_SEND_ONCE), &previous)
    try #require(requested == KERN_SUCCESS)
    let destroyed = mach_port_mod_refs(
      task, receive, mach_port_right_t(MACH_PORT_RIGHT_RECEIVE), -1)
    try #require(destroyed == KERN_SUCCESS)
    try listening.sendFromPeer(kind: OWLMessageKind.pong.rawValue, payload: [])
    #expect(await listening.eventually { listening.messages == 1 })
    #expect(!listening.events.contains { if case .peerDied = $0 { true } else { false } })
  }

  @Test("connecting to a service nobody registered is reported")
  func noSuchService() {
    var raw: OpaquePointer?
    let service = "ai.omnigent.tests.absent.\(UUID().uuidString)"
    #expect(unsafe owl_channel_connect(service, &raw) != KERN_SUCCESS)
    #expect(unsafe raw == nil)
  }

  @Test("a listener fails cleanly when the kernel or the allocator refuses")
  func listenerFaults() {
    for fault in [OWL_CHANNEL_FAULT_QUEUE_LIMIT, OWL_CHANNEL_FAULT_ALLOC] {
      var raw: OpaquePointer?
      owl_channel_inject_fault(fault)
      let service = "ai.omnigent.tests.fault.\(UUID().uuidString)"
      #expect(unsafe owl_channel_create_listener(service, &raw) == KERN_RESOURCE_SHORTAGE)
      #expect(unsafe raw == nil)
    }
  }

  @Test("a connection fails cleanly at each step the kernel or the allocator can refuse")
  func connectFaults() throws {
    let service = "ai.omnigent.tests.fault.\(UUID().uuidString)"
    let listener = try HostChannel.listen(serviceName: service)
    defer { withExtendedLifetime(listener) {} }
    for fault in [
      OWL_CHANNEL_FAULT_QUEUE_LIMIT, OWL_CHANNEL_FAULT_ALLOC, OWL_CHANNEL_FAULT_ALLOCATE_PORT,
      OWL_CHANNEL_FAULT_ARM_DEAD_NAME,
    ] {
      var raw: OpaquePointer?
      owl_channel_inject_fault(fault)
      #expect(unsafe owl_channel_connect(service, &raw) == KERN_RESOURCE_SHORTAGE)
      #expect(unsafe raw == nil)
    }
    var working: OpaquePointer?
    #expect(unsafe owl_channel_connect(service, &working) == KERN_SUCCESS)
    let channel = unsafe try #require(working)
    unsafe owl_channel_destroy(channel)
  }

  @Test("a payload length without a payload is refused before anything is sent")
  func lengthWithoutPayload() throws {
    let service = "ai.omnigent.tests.payload.\(UUID().uuidString)"
    let listener = try HostChannel.listen(serviceName: service)
    defer { withExtendedLifetime(listener) {} }
    var raw: OpaquePointer?
    #expect(unsafe owl_channel_connect(service, &raw) == KERN_SUCCESS)
    let peer = unsafe try #require(raw)
    defer { unsafe owl_channel_destroy(peer) }
    let sent = unsafe owl_channel_send(
      peer, OWLMessageKind.pong.rawValue, 0, 0, nil, 5, mach_port_t(MACH_PORT_NULL),
      mach_msg_type_name_t(MACH_MSG_TYPE_COPY_SEND), 100)
    #expect(sent == KERN_INVALID_ARGUMENT)
  }

  @Test("the audit trailer names the sender only when it's all there")
  func auditTrailer() {
    let headerSize = MemoryLayout<mach_msg_header_t>.size
    let trailerSize = MemoryLayout<mach_msg_audit_trailer_t>.size
    var header = mach_msg_header_t()
    header.msgh_size = mach_msg_size_t(headerSize)
    var trailer = mach_msg_audit_trailer_t()
    trailer.msgh_trailer_size = mach_msg_trailer_size_t(trailerSize)
    trailer.msgh_audit.val.5 = 4242
    var bytes = [UInt8](repeating: 0, count: headerSize + trailerSize)
    func sender(capacity: Int) -> pid_t {
      bytes.withUnsafeMutableBytes { raw in
        unsafe raw.storeBytes(of: header, as: mach_msg_header_t.self)
        unsafe raw.storeBytes(
          of: trailer, toByteOffset: headerSize, as: mach_msg_audit_trailer_t.self)
        guard let start = raw.baseAddress else { return 0 }
        return unsafe owl_audit_sender(start, capacity)
      }
    }
    #expect(sender(capacity: bytes.count) == 4242)
    #expect(sender(capacity: bytes.count - 1) == -1)
    trailer.msgh_trailer_size = 4
    #expect(sender(capacity: bytes.count) == -1)
  }

  @Test("a port the handler doesn't take is released by the channel")
  func untakenPortIsReleased() async throws {
    let service = "ai.omnigent.tests.port.\(UUID().uuidString)"
    var raw: OpaquePointer?
    #expect(unsafe owl_channel_create_listener(service, &raw) == KERN_SUCCESS)
    let channel = unsafe try #require(raw)
    defer { unsafe owl_channel_destroy(channel) }
    unsafe untakenPortMessages = 0
    unsafe owl_channel_start(channel, .main, nil, countMessage, ignoreEvent)

    var connected: OpaquePointer?
    #expect(unsafe owl_channel_connect(service, &connected) == KERN_SUCCESS)
    let peer = unsafe try #require(connected)
    defer { unsafe owl_channel_destroy(peer) }
    let (right, port) = try FakeHost.sendRightWithReceive()
    defer { withExtendedLifetime(right) {} }
    let task = unsafe mach_task_self_
    var before: mach_port_urefs_t = 0
    unsafe mach_port_get_refs(task, port, mach_port_right_t(MACH_PORT_RIGHT_SEND), &before)
    let sent = unsafe owl_channel_send(
      peer, OWLMessageKind.pong.rawValue, 0, 0, nil, 0, port,
      mach_msg_type_name_t(MACH_MSG_TYPE_COPY_SEND), 1000)
    #expect(sent == KERN_SUCCESS)
    var seen = 0
    for _ in 0..<400 where seen == 0 {
      try await Task.sleep(for: .milliseconds(5))
      seen = unsafe untakenPortMessages
    }
    #expect(seen == 1)
    var after: mach_port_urefs_t = 0
    unsafe mach_port_get_refs(task, port, mach_port_right_t(MACH_PORT_RIGHT_SEND), &after)
    #expect(after == before)
  }
}
