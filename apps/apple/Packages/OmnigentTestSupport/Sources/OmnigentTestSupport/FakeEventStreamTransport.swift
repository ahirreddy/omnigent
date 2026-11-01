import Foundation
public import OmnigentCoreFFI
import Synchronization

/// A stream opened on a ``FakeEventStreamTransport``.
public struct OpenedEventStream: Sendable {
  /// The request the core asked to open.
  public let request: HttpRequest
  /// The sink the test drives: call `response`, `chunk` and `finish` on it.
  public let sink: ByteSink
  /// The handle the core cancels.
  public let handle: FakeStreamHandle
}

/// `EventStreamTransport` that records opens and hands each sink to the test.
public final class FakeEventStreamTransport: EventStreamTransport, Sendable {
  private let opens = Rendezvous<OpenedEventStream>()
  private let recorded = Mutex<[OpenedEventStream]>([])
  private let openFailure = Mutex<TransportError?>(nil)

  /// Creates a fake with no failures configured.
  public init() {}

  /// Every stream opened so far, in order.
  public var openedStreams: [OpenedEventStream] {
    recorded.withLock { $0 }
  }

  /// Makes every later `open` fail with `error`, the way a request that cannot start does.
  public func failOpens(with error: TransportError?) {
    openFailure.withLock { $0 = error }
  }

  /// Waits for the next stream the core opens, and returns its request and sink.
  public func waitForOpen() async -> (HttpRequest, ByteSink) {
    let opened = await opens.next()
    return (opened.request, opened.sink)
  }

  /// Waits for the next stream the core opens, with its handle.
  public func waitForOpenedStream() async -> OpenedEventStream {
    await opens.next()
  }

  /// Records the stream and hands its sink to the test.
  /// - Parameters:
  ///   - request: The request the core asked to open.
  ///   - sink: The stream's event sink.
  /// - Returns: The fake handle for the stream.
  /// - Throws: The configured open failure, if any.
  public func openStream(request: HttpRequest, sink: ByteSink) throws(TransportError)
    -> any StreamHandle
  {
    if let failure = openFailure.withLock({ $0 }) {
      throw failure
    }
    let handle = FakeStreamHandle()
    let opened = OpenedEventStream(request: request, sink: sink, handle: handle)
    recorded.withLock { $0.append(opened) }
    opens.push(opened)
    return handle
  }
}

/// Records cancellation of one fake stream.
public final class FakeStreamHandle: StreamHandle, Sendable {
  private let cancels = Mutex(0)

  /// Creates a handle that has not been cancelled.
  public init() {}

  /// How many times the core cancelled this stream.
  public var cancelCount: Int {
    cancels.withLock { $0 }
  }

  /// Counts one cancellation.
  public func cancel() {
    cancels.withLock { $0 += 1 }
  }
}
