import Foundation
import Network

/// A TCP relay in front of the local server, so a flow can take the server away from the app and
/// bring it back while the server and its hosts keep running. Stopping it refuses new
/// connections and cuts the open ones, as a server restart or a lost network does; starting it
/// again listens on the same port.
final class MacFlowProxy: @unchecked Sendable {
  enum ProxyError: Error, CustomStringConvertible {
    case badServer(String)
    case notListening(String)

    var description: String {
      switch self {
      case .badServer(let server): "\(server) has no host and port to relay to"
      case .notListening(let why): "the relay could not listen: \(why)"
      }
    }
  }

  /// Everything below changes on this queue only.
  private let queue = DispatchQueue(label: "ai.omnigent.uitest.proxy")
  private let target: NWEndpoint
  private var listener: NWListener?
  private var relays: [Relay] = []
  private var port: NWEndpoint.Port = .any

  /// A relay to `server`, not listening yet.
  init(to server: String) throws {
    guard let url = URL(string: server), let host = url.host(), let port = url.port,
      let targetPort = NWEndpoint.Port(rawValue: UInt16(port))
    else { throw ProxyError.badServer(server) }
    target = .hostPort(host: NWEndpoint.Host(host), port: targetPort)
  }

  /// The address to give the app, once it has listened.
  var server: String { "http://127.0.0.1:\(queue.sync { port.rawValue })" }

  /// Listens, on the port it had before after a ``stop()``.
  func start() throws {
    let parameters = NWParameters.tcp
    parameters.allowLocalEndpointReuse = true
    // Loopback only: no local-network permission, and nothing outside the Mac can reach it.
    parameters.requiredInterfaceType = .loopback
    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: queue.sync { port })
    let listener = try NWListener(using: parameters)
    let started = StartOutcome()
    listener.stateUpdateHandler = { state in
      switch state {
      case .ready: started.finish(nil)
      case .failed(let error): started.finish("\(error)")
      default: break
      }
    }
    listener.newConnectionHandler = { [weak self] inbound in self?.relay(inbound) }
    listener.start(queue: queue)
    if let failure = started.wait() {
      listener.cancel()
      throw ProxyError.notListening(failure)
    }
    queue.sync {
      self.listener = listener
      if let bound = listener.port { port = bound }
    }
  }

  /// Stops listening and cuts every relayed connection.
  func stop() {
    queue.sync {
      listener?.cancel()
      listener = nil
      for relay in relays { relay.cancel() }
      relays.removeAll()
    }
  }

  private func relay(_ inbound: NWConnection) {
    let relay = Relay(inbound: inbound, outbound: NWConnection(to: target, using: .tcp))
    relays.append(relay)
    relay.start(on: queue)
  }
}

/// Whether the listener came up, handed from its queue to the test's thread.
private final class StartOutcome: @unchecked Sendable {
  private let done = DispatchSemaphore(value: 0)
  private var failure: String?
  private var finished = false

  /// Records the outcome once; the listener's queue calls it.
  func finish(_ failure: String?) {
    guard !finished else { return }
    finished = true
    self.failure = failure
    done.signal()
  }

  /// The failure, or `nil` once listening; a listener silent for 10 seconds failed.
  func wait() -> String? {
    guard done.wait(timeout: .now() + 10) == .success else { return "no answer in 10 seconds" }
    return failure
  }
}

/// One relayed connection: bytes each way until either side ends, which ends both. Its callbacks
/// name a direction rather than capture a connection, which is not `Sendable`.
private final class Relay: @unchecked Sendable {
  /// Which way bytes go.
  private enum Direction: Sendable {
    case toServer, toApp
  }

  private let inbound: NWConnection
  private let outbound: NWConnection

  init(inbound: NWConnection, outbound: NWConnection) {
    self.inbound = inbound
    self.outbound = outbound
  }

  func start(on queue: DispatchQueue) {
    inbound.start(queue: queue)
    outbound.start(queue: queue)
    pipe(.toServer)
    pipe(.toApp)
  }

  func cancel() {
    inbound.cancel()
    outbound.cancel()
  }

  private func ends(_ direction: Direction) -> (source: NWConnection, sink: NWConnection) {
    direction == .toServer ? (inbound, outbound) : (outbound, inbound)
  }

  private func pipe(_ direction: Direction) {
    let source = ends(direction).source
    source.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, ended, error in
      self.forward(data, ending: ended || error != nil, direction)
    }
  }

  /// Sends what arrived on, then reads more; the side ending (or failing) ends both.
  private func forward(_ data: Data?, ending: Bool, _ direction: Direction) {
    guard let data, !data.isEmpty else {
      if ending { cancel() }
      return
    }
    ends(direction).sink.send(
      content: data,
      completion: .contentProcessed { sendError in
        if sendError != nil || ending {
          self.cancel()
        } else {
          self.pipe(direction)
        }
      })
  }
}
