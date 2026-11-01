internal import Darwin
internal import Foundation
internal import OWLProtocol

/// Owns one user reference to a Mach send right and releases it unless taken.
final class MachSendRight {
  private(set) var name: mach_port_t

  init(name: mach_port_t) {
    self.name = name
  }

  /// Transfers ownership to the caller.
  func take() -> mach_port_t {
    let taken = name
    name = mach_port_t(MACH_PORT_NULL)
    return taken
  }

  isolated deinit {
    if name != mach_port_t(MACH_PORT_NULL) {
      _ = owl_port_release(name)  // A failed release only means the right is already gone.
    }
  }
}

/// A message from the host, copied out of the Mach buffer.
struct IncomingMessage {
  /// Raw kind; may be a kind this client does not know.
  let kindValue: UInt16
  let request: UInt64
  let target: UInt64
  let protocolMajor: UInt16
  let fields: WireDecoder
  let port: MachSendRight?

  var kind: OWLMessageKind? { OWLMessageKind(rawValue: kindValue) }
}

/// The client end of the OWL channel. Delivers on the main queue.
@safe final class HostChannel {
  enum Event {
    case message(IncomingMessage)
    case peerDied
    case failure(WebLayerError)
  }

  private var handle: OpaquePointer?
  private var started = false
  let serviceName: String
  var onEvent: ((Event) -> Void)?

  private init(handle: OpaquePointer, serviceName: String) {
    unsafe self.handle = handle
    self.serviceName = serviceName
  }

  /// Registers `serviceName` with launchd so the host can look it up.
  static func listen(serviceName: String) throws(WebLayerError) -> HostChannel {
    var raw: OpaquePointer?
    let result = unsafe owl_channel_create_listener(serviceName, &raw)
    guard result == KERN_SUCCESS, let raw = unsafe raw else {
      throw .channelFailed(
        "bootstrap_check_in(\(serviceName)) failed: \(Self.describe(result)) (\(result)).")
    }
    return unsafe HostChannel(handle: raw, serviceName: serviceName)
  }

  static func describe(_ code: kern_return_t) -> String {
    unsafe String(cString: owl_error_string(code))
  }

  func start() {
    guard let handle = unsafe handle, !started else { return }
    started = true
    let sink = ChannelSink(channel: self)
    let context = unsafe Unmanaged.passRetained(sink).toOpaque()
    unsafe owl_channel_start(
      handle, DispatchQueue.main, context, channelMessageThunk,
      channelEventThunk)
  }

  /// Accepts only messages from `pid`.
  func expect(pid: pid_t) {
    guard let handle = unsafe handle else { return }
    unsafe owl_channel_set_expected_pid(handle, pid)
  }

  /// Adopts the host's send right from Hello.
  func adoptPeer(_ right: MachSendRight) throws(WebLayerError) {
    guard let handle = unsafe handle else { throw .channelFailed("The channel is closed.") }
    let result = unsafe owl_channel_set_peer(handle, right.take())
    guard result == KERN_SUCCESS else {
      throw .channelFailed("Cannot adopt the host port: \(Self.describe(result)).")
    }
  }

  func send(
    _ kind: OWLMessageKind, request: UInt64 = 0, target: UInt64 = 0,
    _ fields: WireEncoder = WireEncoder()
  ) throws(WebLayerError) {
    guard let handle = unsafe handle else { throw .channelFailed("The channel is closed.") }
    let result = fields.bytes.withUnsafeBytes { buffer in
      unsafe owl_channel_send(
        handle, kind.rawValue, request, target, buffer.baseAddress, buffer.count,
        mach_port_t(MACH_PORT_NULL), mach_msg_type_name_t(MACH_MSG_TYPE_COPY_SEND), 100)
    }
    guard result == KERN_SUCCESS else {
      throw .channelFailed(
        "Sending message \(kind.rawValue) failed: \(Self.describe(result)) (\(result)).")
    }
  }

  /// Stops delivery and releases the channel. Idempotent.
  func invalidate() {
    guard let handle = unsafe handle else { return }
    unsafe self.handle = nil
    onEvent = nil
    unsafe owl_channel_destroy(handle)
  }

  fileprivate func deliver(_ event: Event) {
    onEvent?(event)
  }
}

/// Retained by the C channel until it reports cancellation.
private final class ChannelSink {
  weak var channel: HostChannel?

  init(channel: HostChannel) {
    self.channel = channel
  }
}

private nonisolated func channelMessageThunk(
  _ context: UnsafeMutableRawPointer?, _ message: UnsafeMutablePointer<owl_message>
) {
  guard let context = unsafe context else { return }
  let payload: [UInt8] =
    unsafe message.pointee.payload.map { pointer in
      unsafe Array(UnsafeBufferPointer(start: pointer, count: message.pointee.payload_length))
    } ?? []
  let port = unsafe owl_message_take_port(message)
  let kind = unsafe message.pointee.kind
  let request = unsafe message.pointee.request
  let target = unsafe message.pointee.target
  let major = unsafe message.pointee.protocol_major
  // The address crosses into the main-actor closure as a plain integer.
  let address = UInt(bitPattern: context)
  MainActor.assumeIsolated {
    guard let context = unsafe UnsafeMutableRawPointer(bitPattern: address) else { return }
    let sink = unsafe Unmanaged<ChannelSink>.fromOpaque(context).takeUnretainedValue()
    let right = port == mach_port_t(MACH_PORT_NULL) ? nil : MachSendRight(name: port)
    guard let channel = sink.channel else { return }
    do throws(WebLayerError) {
      let fields = try WireDecoder(payload)
      channel.deliver(
        .message(
          IncomingMessage(
            kindValue: kind, request: request, target: target, protocolMajor: major,
            fields: fields, port: right)))
    } catch {
      channel.deliver(.failure(error))
    }
  }
}

private nonisolated func channelEventThunk(
  _ context: UnsafeMutableRawPointer?, _ event: owl_channel_event, _ detail: Int64
) {
  guard let context = unsafe context else { return }
  let address = UInt(bitPattern: context)
  MainActor.assumeIsolated {
    guard let context = unsafe UnsafeMutableRawPointer(bitPattern: address) else { return }
    let unmanaged = unsafe Unmanaged<ChannelSink>.fromOpaque(context)
    if event == OWL_CHANNEL_EVENT_CANCELLED {
      unsafe unmanaged.release()
      return
    }
    guard let channel = unsafe unmanaged.takeUnretainedValue().channel else { return }
    switch event {
    case OWL_CHANNEL_EVENT_PEER_DIED:
      channel.deliver(.peerDied)
    case OWL_CHANNEL_EVENT_RECEIVE_FAILED:
      channel.deliver(
        .failure(
          .channelFailed("Receiving failed: \(HostChannel.describe(kern_return_t(detail))).")))
    case OWL_CHANNEL_EVENT_SENDER_REJECTED:
      channel.deliver(.failure(.channelFailed("Rejected a message from process \(detail).")))
    case OWL_CHANNEL_EVENT_MALFORMED:
      channel.deliver(.failure(.channelFailed("Dropped a malformed message of \(detail) bytes.")))
    default:
      channel.deliver(.failure(.channelFailed("Unknown channel event \(event.rawValue).")))
    }
  }
}
