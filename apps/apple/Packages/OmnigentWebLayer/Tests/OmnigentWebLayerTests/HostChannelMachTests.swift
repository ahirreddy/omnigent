import Darwin
import Foundation
import OWLProtocol
import Testing

@testable import OmnigentWebLayer

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
  func sendFromPeer(kind: UInt16, payload: [UInt8]) throws {
    var raw: OpaquePointer?
    try #require(unsafe owl_channel_connect(service, &raw) == KERN_SUCCESS)
    let peer = unsafe try #require(raw)
    defer { unsafe owl_channel_destroy(peer) }
    let sent = payload.withUnsafeBytes { buffer in
      unsafe owl_channel_send(
        peer, kind, 0, 0, buffer.baseAddress, buffer.count, mach_port_t(MACH_PORT_NULL),
        mach_msg_type_name_t(MACH_MSG_TYPE_COPY_SEND), 1000)
    }
    try #require(sent == KERN_SUCCESS)
  }

  /// Delivers a message with no envelope, as a stranger with the service's name could.
  func sendGarbage() throws {
    let handle = unsafe try #require(channel.handle)
    let port = unsafe owl_channel_receive_port(handle)
    let made = mach_port_insert_right(
      unsafe mach_task_self_, port, port, mach_msg_type_name_t(MACH_MSG_TYPE_MAKE_SEND))
    try #require(made == KERN_SUCCESS)
    var header = mach_msg_header_t()
    header.msgh_bits = mach_msg_bits_t(MACH_MSG_TYPE_COPY_SEND)
    header.msgh_size = mach_msg_size_t(MemoryLayout<mach_msg_header_t>.size)
    header.msgh_remote_port = port
    header.msgh_id = 1234
    let sent = unsafe mach_msg(
      &header, MACH_SEND_MSG, header.msgh_size, 0, mach_port_t(MACH_PORT_NULL), 0,
      mach_port_t(MACH_PORT_NULL))
    try #require(sent == KERN_SUCCESS)
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
}
