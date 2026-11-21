import Darwin
import Foundation
import OWLProtocol
import Testing

/// Payloads and events a raw channel delivered, in order. Touched only on the main queue.
nonisolated(unsafe) private var deliveredPayloads: [[UInt8]] = []
nonisolated(unsafe) private var deliveredEvents: [owl_channel_event] = []

private nonisolated func recordPayload(
  _: UnsafeMutableRawPointer?, _ message: UnsafeMutablePointer<owl_message>
) {
  let length = unsafe message.pointee.payload_length
  let payload =
    unsafe message.pointee.payload.map {
      unsafe Array(UnsafeBufferPointer(start: $0, count: length))
    }
    ?? []
  unsafe deliveredPayloads.append(payload)
}

private nonisolated func recordEvent(
  _: UnsafeMutableRawPointer?, _ event: owl_channel_event, _: Int64
) {
  if event != OWL_CHANNEL_EVENT_CANCELLED { unsafe deliveredEvents.append(event) }
}

/// Messages of every size the channel sends, through real Mach ports.
@MainActor
@Suite("The host channel's message sizes", .serialized)
struct HostChannelSizeTests {
  @Test("payloads just under, at and over the old 4,044-byte limit arrive whole")
  func payloadsAroundTheOldLimit() async throws {
    // The receive size once left no room for the audit trailer, so the kernel destroyed every
    // inline payload over 4,044 bytes. Above OWL_INLINE_PAYLOAD_MAX payloads go out of line.
    let inlineMax = Int(OWL_INLINE_PAYLOAD_MAX)
    let sizes = [4043, 4044, 4045, 4048, inlineMax - 1, inlineMax, inlineMax + 1, 1 << 20]
    let payloads = sizes.map { size in
      (0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ size) }
    }
    let service = "ai.omnigent.tests.sizes.\(UUID().uuidString)"
    var raw: OpaquePointer?
    try #require(unsafe owl_channel_create_listener(service, &raw) == KERN_SUCCESS)
    let channel = unsafe try #require(raw)
    defer { unsafe owl_channel_destroy(channel) }
    unsafe deliveredPayloads = []
    unsafe deliveredEvents = []
    unsafe owl_channel_start(channel, .main, nil, recordPayload, recordEvent)

    var connected: OpaquePointer?
    try #require(unsafe owl_channel_connect(service, &connected) == KERN_SUCCESS)
    let peer = unsafe try #require(connected)
    defer { unsafe owl_channel_destroy(peer) }
    for payload in payloads {
      let sent = payload.withUnsafeBytes { buffer in
        unsafe owl_channel_send(
          peer, OWLMessageKind.evaluate.rawValue, 0, 0, buffer.baseAddress, buffer.count,
          mach_port_t(MACH_PORT_NULL), mach_msg_type_name_t(MACH_MSG_TYPE_COPY_SEND), 1000)
      }
      #expect(sent == KERN_SUCCESS, "sending \(payload.count) bytes")
    }
    func settled() -> Bool { unsafe deliveredPayloads.count + deliveredEvents.count >= sizes.count }
    for _ in 0..<400 where !settled() {
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(unsafe deliveredEvents.isEmpty, "nothing was dropped")
    #expect(unsafe deliveredPayloads.map(\.count) == sizes)
    #expect(unsafe deliveredPayloads == payloads)
  }
}
