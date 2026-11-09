public import Foundation
public import Observation
public import OmnigentCoreFFI

/// Runs one agent browser action. Matches `AgentBrowserActing.perform(_:)` in OmnigentBrowser,
/// so this package does not depend on it: an adapter builds `AgentBrowserActionRequest` with
/// `init(eventJSON: request.eventJSON(), conversationID: request.sessionId)` and returns
/// `result.jsonData()`.
public protocol BrowserActionPerforming: AnyObject {
  /// Runs a claimed action and returns its `result` object (`{ok, error?, data?, data_url?}`)
  /// as JSON. Called only after this client won the claim.
  /// - Parameter request: The action.
  /// - Returns: The result object's JSON.
  /// - Throws: When no result could be produced; the store then posts `{ok: false, error}`.
  func perform(_ request: BrowserActionRequest) async throws -> Data
}

extension BrowserActionRequest {
  /// The raw event object `{"type": "browser.action_request", "action_id", "action", "args"}`,
  /// for `AgentBrowserActionRequest(eventJSON:conversationID:)`.
  /// - Returns: The JSON bytes.
  /// - Throws: When `argsJson` is not JSON.
  public func eventJSON() throws -> Data {
    let args = try JSONSerialization.jsonObject(with: Data(argsJson.utf8))
    let event: [String: Any] = [
      "type": "browser.action_request", "action_id": actionId, "action": action, "args": args,
    ]
    return try JSONSerialization.data(withJSONObject: event, options: [.sortedKeys])
  }
}

/// The `result` object posted when the performer produced none.
private struct FailureResult: Encodable {
  var ok = false
  let error: String
}

/// Where one agent browser action stands.
public enum BrowserActionPhase: Equatable, Sendable {
  /// No performer is installed, so it was left for another client and not claimed.
  case unhandled
  /// Claiming (the server waits 2 s).
  case claiming
  /// Another client won the claim (or the action expired); it was not run.
  case notClaimed
  /// Claimed; the performer is running it.
  case performing
  /// Posting the result (the server waits 30 s).
  case posting
  /// The result was delivered, or the server had already given up (`expired`).
  case delivered(BrowserActionDelivery)
  /// The claim or the post failed. The action never ran when the claim failed.
  case failed(CoreError)
}

/// One agent browser action and its progress.
public struct BrowserActionRecord: Identifiable, Equatable, Sendable {
  /// The action.
  public let request: BrowserActionRequest
  /// Where it stands.
  public internal(set) var phase: BrowserActionPhase
  /// The performer's failure, when it produced no result and `{ok: false}` was posted instead.
  public internal(set) var performerError: String?

  /// The server's action id.
  public var id: String { request.actionId }
}

/// Executes the server's `browser.action_request` events: claims each one for the session
/// whose stream delivered it, runs it with the injected ``performer`` only when the claim was
/// granted, and posts the result with the claim token. Nothing is retried; failures are state.
@Observable
public final class BrowserActionStore {
  /// Recent actions, oldest first (at most 50).
  public private(set) var actions: [BrowserActionRecord] = []
  /// The last failure, until ``dismissError()``.
  public private(set) var lastError: CoreError?
  /// Runs claimed actions. Without one, requests are recorded as ``BrowserActionPhase/unhandled``
  /// and never claimed, so another client can take them.
  @ObservationIgnored public var performer: (any BrowserActionPerforming)?

  private let core: ClientCore

  init(core: ClientCore) {
    self.core = core
  }

  /// Clears ``lastError`` after the user has seen it.
  public func dismissError() {
    lastError = nil
  }

  /// Handles one request: claim, perform, post. Returns when it is finished.
  /// - Parameter request: The action, from `CoreEvent.browserActionRequested`.
  public func handle(_ request: BrowserActionRequest) async {
    guard let performer else {
      record(request, .unhandled)
      return
    }
    record(request, .claiming)
    let token: String
    do {
      switch try await core.claimBrowserAction(
        sessionId: request.sessionId, actionId: request.actionId)
      {
      case .claimed(let claimToken): token = claimToken
      case .notClaimed:
        update(request.actionId) { $0.phase = .notClaimed }
        return
      }
    } catch {
      fail(request.actionId, coreError(error))
      return
    }
    update(request.actionId) { $0.phase = .performing }
    let resultJSON: String
    switch await performedJSON(of: request, performer: performer) {
    case .success(let json):
      resultJSON = json
    case .failure(let error):
      fail(request.actionId, error)
      return
    }
    update(request.actionId) { $0.phase = .posting }
    do {
      let delivery = try await core.postBrowserActionResult(
        sessionId: request.sessionId, actionId: request.actionId, claimToken: token,
        resultJson: resultJSON)
      update(request.actionId) { $0.phase = .delivered(delivery) }
    } catch {
      fail(request.actionId, coreError(error))
    }
  }

  /// Runs `request`: the performer's answer, or `{ok: false}` when it produced none.
  private func performedJSON(
    of request: BrowserActionRequest, performer: any BrowserActionPerforming
  ) async -> Result<String, CoreError> {
    let result: Data
    do {
      result = try await performer.perform(request)
    } catch {
      let message = "The browser could not run \(request.action): \(error)"
      update(request.actionId) { $0.performerError = message }
      return Self.failureJSON(FailureResult(error: message))
    }
    guard let resultJSON = String(bytes: result, encoding: .utf8) else {
      return .failure(.Decode(message: "The browser action result is not UTF-8 JSON."))
    }
    return .success(resultJSON)
  }

  /// The JSON of a failure to post in place of a result.
  /// - Parameter failure: The failure.
  /// - Returns: The JSON, or the error when it can't be encoded.
  static func failureJSON(_ failure: some Encodable) -> Result<String, CoreError> {
    do {
      // JSONEncoder always writes UTF-8.
      // swiftlint:disable:next optional_data_string_conversion
      return .success(String(decoding: try JSONEncoder().encode(failure), as: UTF8.self))
    } catch {
      return .failure(
        .InvalidState(message: "Could not encode the browser action failure: \(error)"))
    }
  }

  private func record(_ request: BrowserActionRequest, _ phase: BrowserActionPhase) {
    actions.append(BrowserActionRecord(request: request, phase: phase))
    if actions.count > 50 { actions.removeFirst(actions.count - 50) }
  }

  private func update(_ actionID: String, _ change: (inout BrowserActionRecord) -> Void) {
    guard let index = actions.lastIndex(where: { $0.id == actionID }) else { return }
    change(&actions[index])
  }

  private func fail(_ actionID: String, _ error: CoreError) {
    update(actionID) { $0.phase = .failed(error) }
    lastError = error
  }
}
