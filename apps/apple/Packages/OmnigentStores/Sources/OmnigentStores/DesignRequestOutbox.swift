public import Foundation
public import Observation
import OmnigentCoreFFI

/// One Browser design tool request (Annotate, Draw) the outbox holds until it is sent.
nonisolated public struct DesignOutboxRequest: Identifiable, Hashable, Sendable {
  /// The tool that made it.
  public enum Tool: String, Hashable, Sendable {
    /// A picked element and what should change.
    case annotate
    /// A marked-up screenshot.
    case draw
  }

  /// Where it stands.
  public enum Status: Hashable, Sendable {
    /// Waiting for the session to be free.
    case waiting
    /// On its way.
    case sending
    /// Not sent, with why; `canRetry` is false for one a policy blocked.
    case failed(String, canRetry: Bool)
  }

  /// A file it carries.
  public struct File: Hashable, Sendable {
    /// The file name.
    public var name: String
    /// The media type.
    public var mediaType: String
    /// The bytes.
    public var data: Data

    /// Creates a file.
    public init(name: String, mediaType: String, data: Data) {
      self.name = name
      self.mediaType = mediaType
      self.data = data
    }
  }

  /// What a request sends, and its name for the list.
  public struct Message: Hashable, Sendable {
    /// The tool that made it.
    public var tool: Tool
    /// A one-line name for the list (`Annotate p "Hello"`).
    public var label: String
    /// The message.
    public var text: String
    /// Its files (its screenshot).
    public var files: [File]

    /// Creates a message.
    public init(tool: Tool, label: String, text: String, files: [File]) {
      self.tool = tool
      self.label = label
      self.text = text
      self.files = files
    }
  }

  /// Identity.
  public let id: UUID
  /// The session it goes to.
  public let sessionID: String
  /// The tool that made it.
  public let tool: Tool
  /// A one-line name for the list (`Annotate p "Hello"`).
  public let label: String
  /// The message.
  public let text: String
  /// The files it carries (its screenshot).
  public let files: [File]
  /// Where it stands.
  public internal(set) var status: Status
}

/// How a request ended, for the page that made it.
nonisolated public enum DesignOutboxOutcome: Hashable, Sendable {
  /// The server took it.
  case sent
  /// It wasn't sent, with why.
  case failed(String)
}

/// The Browser design tools' outbox (web `designOutbox.ts`): requests go to their session one
/// at a time, each once the session's turn has ended, outside the composer. One that isn't
/// sent stays, saying why, until it is retried or removed. Requests live as long as the window.
@Observable
public final class DesignRequestOutbox {
  /// Wording the web's outbox uses.
  public enum Copy {
    /// The page's notice once a request is sent.
    public static let sent = "Sent to agent."
    /// A request a policy blocked.
    public static let denied = "A policy blocked this request, so it wasn't sent."
    /// A request refused because the session's host is offline.
    public static let hostOffline =
      "The session's host is offline, so this wasn't sent. Retry once it's back."
    /// What to do about a request that may have arrived.
    public static let look = "Look in the chat: if it isn't there, Retry sends it."
  }

  /// How long the outbox waits for the session.
  public struct Timing: Sendable {
    /// Between looks at whether the session is free.
    public var poll: Duration
    /// The longest a sent request waits for its turn to start before the next one goes.
    public var turnStart: Duration

    /// The web's timings.
    public static let standard = Self(poll: .milliseconds(250), turnStart: .seconds(15))
  }

  /// Every request not yet sent, oldest first.
  public private(set) var requests: [DesignOutboxRequest] = []

  @ObservationIgnored private let deliver: (DesignOutboxRequest) async throws -> Void
  @ObservationIgnored private let isRunning: (String) -> Bool
  @ObservationIgnored private let timing: Timing
  @ObservationIgnored private var outcomes: [UUID: (DesignOutboxOutcome) -> Void] = [:]
  @ObservationIgnored private var draining: Set<String> = []

  /// An outbox over a connection's core, reading each session's turn from its open conversation.
  /// - Parameter connection: The connection.
  public convenience init(connection: ConnectionStore) {
    self.init(
      timing: .standard,
      isRunning: { [weak connection] in connection?.openConversation($0)?.isRunning ?? false },
      deliver: { [weak connection] request in
        guard let core = connection?.core else {
          throw CoreError.InvalidState(message: "The server connection isn't ready.")
        }
        try await core.sendExternalMessage(
          sessionId: request.sessionID, text: request.text,
          files: request.files.map {
            ExternalAttachment(filename: $0.name, mediaType: $0.mediaType, data: $0.data)
          })
      })
  }

  /// An outbox with its own sending and turn reading, for tests.
  init(
    timing: Timing, isRunning: @escaping (String) -> Bool,
    deliver: @escaping (DesignOutboxRequest) async throws -> Void
  ) {
    self.timing = timing
    self.isRunning = isRunning
    self.deliver = deliver
  }

  /// The session's requests not yet sent.
  public func requests(in sessionID: String) -> [DesignOutboxRequest] {
    requests.filter { $0.sessionID == sessionID }
  }

  /// Hands a request to the outbox; it goes once its session is free.
  /// - Parameters:
  ///   - message: What it sends.
  ///   - sessionID: The session.
  ///   - outcome: Told when it is sent, or why it wasn't, each time it is tried.
  /// - Returns: Its identity.
  @discardableResult
  public func queue(
    _ message: DesignOutboxRequest.Message, to sessionID: String,
    outcome: @escaping (DesignOutboxOutcome) -> Void
  ) -> UUID {
    let request = DesignOutboxRequest(
      id: UUID(), sessionID: sessionID, tool: message.tool, label: message.label,
      text: message.text, files: message.files, status: .waiting)
    requests.append(request)
    outcomes[request.id] = outcome
    drain(sessionID)
    return request.id
  }

  /// Sends a failed request again: the user's call, as one may have arrived.
  public func retry(_ id: UUID) {
    guard let index = requests.firstIndex(where: { $0.id == id }),
      case .failed(_, true) = requests[index].status
    else { return }
    requests[index].status = .waiting
    drain(requests[index].sessionID)
  }

  /// Drops a request that isn't on its way.
  public func remove(_ id: UUID) {
    guard let request = requests.first(where: { $0.id == id }), request.status != .sending
    else { return }
    requests.removeAll { $0.id == id }
    outcomes[id] = nil
  }

  private func drain(_ sessionID: String) {
    guard !draining.contains(sessionID) else { return }
    draining.insert(sessionID)
    Task {
      await sendWaiting(in: sessionID)
      draining.remove(sessionID)
    }
  }

  /// Sends the session's waiting requests in turn, each once the session is free.
  private func sendWaiting(in sessionID: String) async {
    while let next = requests.first(where: { $0.sessionID == sessionID && $0.status == .waiting }) {
      guard await wait(until: { !self.isRunning(sessionID) }) else { return }
      guard let index = requests.firstIndex(where: { $0.id == next.id && $0.status == .waiting })
      else { continue }
      requests[index].status = .sending
      do {
        try await deliver(next)
      } catch {
        let failure = Self.failure(error)
        set(next.id, .failed(failure.message, canRetry: failure.canRetry))
        outcomes[next.id]?(.failed(failure.message))
        continue
      }
      requests.removeAll { $0.id == next.id }
      outcomes.removeValue(forKey: next.id)?(.sent)
      // Its turn starts and ends before the next one goes, so that one doesn't steer it.
      _ = await wait(until: { self.isRunning(sessionID) }, atMost: timing.turnStart)
    }
  }

  private func set(_ id: UUID, _ status: DesignOutboxRequest.Status) {
    guard let index = requests.firstIndex(where: { $0.id == id }) else { return }
    requests[index].status = status
  }

  /// Waits until `condition` holds, or `atMost` has passed; `false` when the wait was
  /// cancelled or ran out.
  private func wait(until condition: () -> Bool, atMost: Duration? = nil) async -> Bool {
    let clock = ContinuousClock()
    let deadline = atMost.map { clock.now + $0 }
    while !condition() {
      if let deadline, clock.now >= deadline { return false }
      do {
        try await Task.sleep(for: timing.poll)
      } catch {
        return false
      }
    }
    return true
  }

  /// Why a send failed, for the user, and whether Retry may send it again.
  static func failure(_ error: any Error) -> (message: String, canRetry: Bool) {
    let error = coreError(error)
    if case .Session(.messageDenied, _, _, _, _) = error { return (Copy.denied, false) }
    if error.isHostOffline { return (Copy.hostOffline, true) }
    if error.isDeliveryUncertain {
      return ("Couldn't tell whether this reached the agent (\(error.message)). \(Copy.look)", true)
    }
    return ("Couldn't send: \(error.message)", true)
  }
}
