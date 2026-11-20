public import Foundation
public import Observation
import OmnigentCoreFFI

/// One Browser design tool request (Annotate, Draw) the outbox holds until it is sent.
nonisolated public struct DesignOutboxRequest: Identifiable, Hashable, Sendable {
  /// The tool that made it.
  public enum Tool: String, Hashable, Sendable, Codable {
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
  /// When it was made.
  public let madeAt: Date
  /// Where it stands.
  public internal(set) var status: Status
  /// Sending, and the server hasn't answered for a while.
  public internal(set) var isSlow = false
  /// The account signed in when it was made; `nil` until one is known.
  public internal(set) var owner: DesignOutboxOwner?
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
/// sent stays, saying why, until it is retried or removed. Unsent requests are kept on disk per
/// account (``DesignOutboxStorage``) and come back after a relaunch, each needing a Retry.
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
    /// A request kept from before the app last closed.
    public static let restored =
      "The app closed before this was confirmed sent, so it may have reached the agent. \(look)"
    /// A request another account would send.
    public static let accountChanged =
      "Another account is signed in now, so this wasn't sent. Sign back in as the account that made it to Retry, or Remove it."
    /// A send the server never answered.
    public static let stalled =
      "The server didn't answer, so this may have reached the agent. \(look)"
  }

  /// How long the outbox waits for the session.
  public struct Timing: Sendable {
    /// Between looks at whether the session is free.
    public var poll: Duration
    /// The longest a sent request waits for its turn to start before the next one goes.
    public var turnStart: Duration
    /// How long a send runs before the outbox says the server is slow.
    public var slow: Duration = .seconds(60)
    /// How long a send runs before the outbox stops waiting on it: it may still have arrived.
    public var stalled: Duration = .seconds(180)

    /// The web's timings.
    public static let standard = Self(poll: .milliseconds(250), turnStart: .seconds(15))
  }

  /// Every request not yet sent, oldest first.
  public private(set) var requests: [DesignOutboxRequest] = []

  @ObservationIgnored let deliver: (DesignOutboxRequest) async throws -> Void
  @ObservationIgnored private let isRunning: (String) -> Bool
  @ObservationIgnored let timing: Timing
  /// The account signed in now; `nil` while none is known.
  @ObservationIgnored let owner: () -> DesignOutboxOwner?
  @ObservationIgnored let storage: DesignOutboxStorage?
  @ObservationIgnored private let now: () -> Date
  @ObservationIgnored private var outcomes: [UUID: (DesignOutboxOutcome) -> Void] = [:]
  @ObservationIgnored private var draining: Set<String> = []

  /// An outbox over a connection's core, reading each session's turn from its open conversation.
  /// - Parameters:
  ///   - connection: The connection.
  ///   - storage: Where unsent requests are kept across launches; `nil` keeps none.
  public convenience init(connection: ConnectionStore, storage: DesignOutboxStorage? = nil) {
    self.init(
      timing: .standard,
      isRunning: { [weak connection] in connection?.openConversation($0)?.isRunning ?? false },
      owner: { [weak connection] in
        connection?.connectedServer.map {
          DesignOutboxOwner(server: $0.baseUrl, account: $0.accountId)
        }
      },
      storage: storage,
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

  /// An outbox with its own sending, turn and account reading, for tests.
  init(
    timing: Timing, isRunning: @escaping (String) -> Bool,
    owner: @escaping () -> DesignOutboxOwner?, storage: DesignOutboxStorage? = nil,
    now: @escaping () -> Date = Date.init,
    deliver: @escaping (DesignOutboxRequest) async throws -> Void
  ) {
    self.timing = timing
    self.isRunning = isRunning
    self.owner = owner
    self.storage = storage
    self.now = now
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
      text: message.text, files: message.files, madeAt: now(), status: .waiting,
      owner: owner())
    requests.append(request)
    outcomes[request.id] = outcome
    persisted(request.id)
    drain(sessionID)
    return request.id
  }

  /// Sends a failed request again: the user's call, as one may have arrived.
  public func retry(_ id: UUID) {
    guard let index = requests.firstIndex(where: { $0.id == id }),
      case .failed(_, true) = requests[index].status
    else { return }
    requests[index].status = .waiting
    persisted(id)
    drain(requests[index].sessionID)
  }

  /// Drops a request that isn't on its way.
  public func remove(_ id: UUID) {
    guard let request = requests.first(where: { $0.id == id }), request.status != .sending
    else { return }
    requests.removeAll { $0.id == id }
    outcomes[id] = nil
    persisted(id)
  }

  private func drain(_ sessionID: String) {
    guard !draining.contains(sessionID) else { return }
    draining.insert(sessionID)
    Task {
      await sendWaiting(in: sessionID)
      draining.remove(sessionID)
    }
  }

  /// Sends the session's waiting requests in turn, each once the session is free and its
  /// account still the one signed in.
  private func sendWaiting(in sessionID: String) async {
    while let next = requests.first(where: { $0.sessionID == sessionID && $0.status == .waiting }) {
      guard await wait(until: { !self.isRunning(sessionID) && self.owner() != nil }) else {
        return
      }
      guard let index = requests.firstIndex(where: { $0.id == next.id && $0.status == .waiting }),
        let signedIn = owner()
      else { continue }
      if let made = requests[index].owner, made != signedIn {
        fail(next.id, Copy.accountChanged, canRetry: true)
        continue
      }
      requests[index].owner = signedIn
      requests[index].status = .sending
      persisted(next.id)
      switch await attempt(requests[index]) {
      case .sent:
        requests.removeAll { $0.id == next.id }
        persisted(next.id)
        outcomes.removeValue(forKey: next.id)?(.sent)
      case .failed(let error):
        let failure = Self.failure(error)
        fail(next.id, failure.message, canRetry: failure.canRetry)
        continue
      case .stalled:
        // Its post may still land: the next one waits as if this one was sent.
        fail(next.id, Copy.stalled, canRetry: true)
      }
      // Its turn starts and ends before the next one goes, so that one doesn't steer it.
      _ = await wait(until: { self.isRunning(sessionID) }, atMost: timing.turnStart)
    }
  }

  /// Marks a request not sent, with why, and tells its page.
  private func fail(_ id: UUID, _ message: String, canRetry: Bool) {
    set(id, .failed(message, canRetry: canRetry))
    outcomes[id]?(.failed(message))
  }

  func set(_ id: UUID, _ status: DesignOutboxRequest.Status) {
    guard let index = requests.firstIndex(where: { $0.id == id }) else { return }
    requests[index].status = status
    requests[index].isSlow = false
    persisted(id)
  }

  /// A send that runs long says so, while it keeps waiting.
  func markSlow(_ id: UUID) {
    guard let index = requests.firstIndex(where: { $0.id == id }),
      requests[index].status == .sending
    else { return }
    requests[index].isSlow = true
  }

  /// Puts restored requests ahead of the ones made since.
  func insertRestored(_ restored: [DesignOutboxRequest]) {
    requests.insert(contentsOf: restored, at: 0)
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
