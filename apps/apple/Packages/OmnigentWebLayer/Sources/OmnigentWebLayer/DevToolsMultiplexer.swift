internal import Foundation
internal import Synchronization
internal import os

/// Shares Chromium's one DevTools pipe among several agent connections, and keeps each inside
/// its scope (an Omnigent session's tabs).
///
/// Message ids are renumbered upstream and restored on the way back. A CDP session belongs to the
/// connection that attached it (its child sessions too), and only that connection sees its
/// traffic. The multiplexer runs target discovery itself and shows each connection only the
/// targets in its scope, plus popups they opened. A connection may attach only to those, and
/// methods that reach the whole profile (the cookie jar, cache, downloads, passkeys, the browser
/// itself) are refused; the runner's proxy enforces the same rules (`policy.py`), so this is
/// the second line.
nonisolated final class DevToolsMultiplexer: Sendable {
  typealias ClientID = UInt64

  /// One agent connection.
  struct Client: Sendable {
    let scope: String
    let send: @Sendable (Data) -> Void
    let close: @Sendable () -> Void
    var discovering = false
    var announced: Set<String> = []
    var rootSessions: Set<String> = []
  }

  struct Pending: Sendable {
    /// `nil` for the multiplexer's own requests.
    let client: ClientID?
    let originalID: Int
    let attachTarget: String?
  }

  struct TargetInfo: Sendable {
    let openerID: String?
    let json: Data
  }

  struct State: Sendable {
    var nextClientID: ClientID = 1
    var nextUpstreamID = 1
    var clients: [ClientID: Client] = [:]
    var pending: [Int: Pending] = [:]
    var sessionOwners: [String: ClientID] = [:]
    var pendingAttaches: [String: [ClientID]] = [:]
    var targets: [String: TargetInfo] = [:]
    var scopes: [String: Set<String>] = [:]
  }

  /// One request from a connection.
  struct Request {
    let client: ClientID
    let id: Int
    let method: String
    let params: [String: Any]
    let session: String?
    let message: [String: Any]
  }

  static let outOfScope =
    "That target is not one of this session's tabs, or a popup one of them opened."
  static let openerDepth = 8

  let sendUpstream: @Sendable (Data) -> Void
  private let state = Mutex(State())

  /// Creates a multiplexer.
  /// - Parameter sendUpstream: Writes one message to Chromium's pipe.
  init(sendUpstream: @escaping @Sendable (Data) -> Void) {
    self.sendUpstream = sendUpstream
  }

  /// Turns on target discovery upstream. Call once, when the first agent arrives.
  func start() {
    state.withLock { state in
      internalCommand(&state, "Target.setDiscoverTargets", ["discover": true])
    }
  }

  /// How many agent connections are open.
  var clientCount: Int { state.withLock { $0.clients.count } }

  /// Adds a connection limited to `scope`.
  /// - Parameters:
  ///   - scope: Whose targets it may use, e.g. an Omnigent session id.
  ///   - send: Delivers one message to the connection.
  ///   - close: Closes the connection, when the browser goes away.
  /// - Returns: The connection's id.
  func addClient(
    scope: String, send: @escaping @Sendable (Data) -> Void,
    close: @escaping @Sendable () -> Void
  ) -> ClientID {
    state.withLock { state in
      let id = state.nextClientID
      state.nextClientID += 1
      state.clients[id] = Client(scope: scope, send: send, close: close)
      return id
    }
  }

  /// Forgets a closed connection and detaches its sessions upstream.
  func removeClient(_ id: ClientID) {
    state.withLock { state in
      guard let client = state.clients.removeValue(forKey: id) else { return }
      for session in client.rootSessions.sorted() {
        internalCommand(&state, "Target.detachFromTarget", ["sessionId": session])
      }
      state.sessionOwners = state.sessionOwners.filter { $0.value != id }
      for (target, waiting) in state.pendingAttaches {
        state.pendingAttaches[target] = waiting.filter { $0 != id }
      }
    }
  }

  /// Sets the targets `scope` may use, and shows connections in it the ones they now may.
  func setScope(_ scope: String, targets: Set<String>) {
    state.withLock { state in
      state.scopes[scope] = targets
      announceAllowed(&state, scope: scope)
    }
  }

  /// Adds one target to `scope`, e.g. a tab just opened for its agent.
  func addToScope(_ scope: String, target: String) {
    state.withLock { state in
      state.scopes[scope, default: []].insert(target)
      announceAllowed(&state, scope: scope)
    }
  }

  /// Handles one message from connection `id`.
  func clientMessage(_ id: ClientID, _ data: Data) {
    state.withLock { state in
      guard let client = state.clients[id] else { return }
      let message = Self.object(data)
      guard let requestID = message["id"] as? Int else {
        DevToolsGate.log.error("An agent sent the DevTools gate a message without a numeric id.")
        return
      }
      let session = message["sessionId"] as? String
      guard let method = message["method"] as? String else {
        Self.reply(client, requestID, session, error: "The message names no method.")
        return
      }
      let request = Request(
        client: id, id: requestID, method: method,
        params: message["params"] as? [String: Any] ?? [:], session: session, message: message)
      let refusal =
        session == nil ? browserRequest(&state, request) : sessionRequest(&state, request)
      if let refusal { Self.reply(client, requestID, session, error: refusal) }
    }
  }

  /// Handles one message from Chromium.
  func upstreamMessage(_ data: Data) {
    state.withLock { state in
      var message = Self.object(data)
      guard !message.isEmpty else {
        DevToolsGate.log.error("Chromium's DevTools pipe sent a message that is not a JSON object.")
        return
      }
      if let id = message["id"] as? Int {
        response(&state, id, &message)
      } else if let method = message["method"] as? String {
        let params = message["params"] as? [String: Any] ?? [:]
        if let session = message["sessionId"] as? String {
          sessionEvent(&state, method, params, session: session, data: data)
        } else {
          browserEvent(&state, method, params, data: data)
        }
      }
    }
  }

  /// Closes every connection: the browser is gone.
  func upstreamClosed() {
    let clients = state.withLock { state in
      defer { state = State() }
      return Array(state.clients.values)
    }
    for client in clients { client.close() }
  }
}

// MARK: Requests

nonisolated extension DevToolsMultiplexer {
  /// Mirrors `REFUSED_DOMAINS` in `omnigent/runner/browser_devtools/policy.py`.
  static let refusedDomains: Set<String> = [
    "Autofill", "Extensions", "PWA", "Tethering", "WebAuthn",
  ]
  /// Mirrors `REFUSED_METHODS` in `omnigent/runner/browser_devtools/policy.py`.
  static let refusedMethods: Set<String> = [
    "Browser.close", "Browser.crash", "Browser.crashGpuProcess", "Browser.grantPermissions",
    "Browser.resetPermissions", "Browser.setDownloadBehavior", "Browser.setPermission",
    "Network.clearBrowserCache", "Network.clearBrowserCookies", "Network.deleteCookies",
    "Network.getAllCookies", "Network.setCookie", "Network.setCookies",
    "Page.setDownloadBehavior", "Storage.clearCookies", "Storage.clearDataForOrigin",
    "Storage.clearDataForStorageKey", "Storage.getCookies", "Storage.setCookies",
    "Target.attachToBrowserTarget", "Target.createBrowserContext",
    "Target.disposeBrowserContext", "Target.exposeDevToolsProtocol", "Target.openDevTools",
    "Target.sendMessageToTarget", "Target.setRemoteLocations",
  ]

  /// Whether `method` is refused on every session because it reaches beyond the tab.
  static func isRefused(_ method: String) -> Bool {
    refusedMethods.contains(method)
      || refusedDomains.contains(String(method.prefix { $0 != "." }))
  }

  /// Handles a browser-level request; returns why it is refused, if it is.
  func browserRequest(_ state: inout State, _ request: Request) -> String? {
    guard let client = state.clients[request.client] else { return nil }
    switch request.method {
    case "Target.setDiscoverTargets":
      setDiscoverTargets(&state, request)
    case "Target.getTargets":
      let infos = state.targets.keys.sorted().filter { allowed(state, $0, client.scope) }
        .compactMap { state.targets[$0].map { Self.object($0.json) } }
      Self.reply(client, request.id, nil, result: ["targetInfos": infos])
    case "Target.attachToTarget":
      if let refusal = checkAttach(state, request.params, client.scope) { return refusal }
      if let target = request.params["targetId"] as? String {
        state.pendingAttaches[target, default: []].append(request.client)
        forward(&state, request, attachTarget: target)
      }
    case "Target.detachFromTarget", "Target.getTargetInfo":
      if let refusal = checkTargetParams(state, request, client.scope) { return refusal }
      forward(&state, request)
    case "Browser.getVersion", "Target.getBrowserContexts":
      forward(&state, request)
    default:
      return "\(request.method) is not available through this Mac's browser gate."
    }
    return nil
  }

  /// Discovery is emulated: the multiplexer discovers for everyone and shows each connection its
  /// scope's targets.
  private func setDiscoverTargets(_ state: inout State, _ request: Request) {
    guard var client = state.clients[request.client] else { return }
    client.discovering = request.params["discover"] as? Bool == true
    if !client.discovering { client.announced = [] }
    state.clients[request.client] = client
    Self.reply(client, request.id, nil, result: [:])
    if client.discovering { announceAllowed(&state, scope: client.scope) }
  }

  /// Handles a request on a page session; returns why it is refused, if it is.
  func sessionRequest(_ state: inout State, _ request: Request) -> String? {
    guard let client = state.clients[request.client], let session = request.session else {
      return nil
    }
    guard state.sessionOwners[session] == request.client else {
      return "No session with given id: \(session)"
    }
    if Self.isRefused(request.method) {
      return "\(request.method) is not available to agents: it reaches beyond this session's tabs."
    }
    if let refusal = checkPageTargetMethod(state, request, client.scope) { return refusal }
    forward(&state, request)
    return nil
  }

  /// Allows the page-session `Target` and `Browser` calls that stay inside the scope.
  private func checkPageTargetMethod(_ state: State, _ request: Request, _ scope: String)
    -> String?
  {
    let domain = request.method.prefix { $0 != "." }
    guard domain == "Target" || domain == "Browser" else { return nil }
    switch request.method {
    case "Target.setAutoAttach", "Browser.getVersion":
      return nil
    case "Target.attachToTarget":
      return checkAttach(state, request.params, scope)
    case "Target.detachFromTarget", "Target.getTargetInfo":
      return checkTargetParams(state, request, scope)
    default:
      return "\(request.method) is not available on a page through this Mac's browser gate."
    }
  }

  private func checkAttach(_ state: State, _ params: [String: Any], _ scope: String) -> String? {
    guard let target = params["targetId"] as? String, allowed(state, target, scope) else {
      return Self.outOfScope
    }
    return params["flatten"] as? Bool == true ? nil : "Only flatten mode attach is supported."
  }

  /// Checks the `targetId` and `sessionId` a Target method names, when it names them.
  private func checkTargetParams(_ state: State, _ request: Request, _ scope: String) -> String? {
    if let target = request.params["targetId"] as? String, !allowed(state, target, scope) {
      return Self.outOfScope
    }
    if let session = request.params["sessionId"] as? String,
      state.sessionOwners[session] != request.client
    {
      return "No session with given id: \(session)"
    }
    return nil
  }

  private func forward(_ state: inout State, _ request: Request, attachTarget: String? = nil) {
    let upstreamID = state.nextUpstreamID
    state.nextUpstreamID += 1
    var renumbered = request.message
    renumbered["id"] = upstreamID
    guard let data = Self.data(renumbered) else { return }
    state.pending[upstreamID] = Pending(
      client: request.client, originalID: request.id, attachTarget: attachTarget)
    sendUpstream(data)
  }

  func internalCommand(_ state: inout State, _ method: String, _ params: [String: Any]) {
    let upstreamID = state.nextUpstreamID
    state.nextUpstreamID += 1
    guard let data = Self.data(["id": upstreamID, "method": method, "params": params]) else {
      return
    }
    state.pending[upstreamID] = Pending(client: nil, originalID: 0, attachTarget: nil)
    sendUpstream(data)
  }
}

// MARK: Helpers

nonisolated extension DevToolsMultiplexer {
  /// Whether `target` is in `scope`, or a popup opened (directly or not) by one that is.
  func allowed(_ state: State, _ target: String, _ scope: String) -> Bool {
    let inScope = state.scopes[scope] ?? []
    var current: String? = target
    for _ in 0..<Self.openerDepth {
      guard let id = current else { return false }
      if inScope.contains(id) { return true }
      current = state.targets[id]?.openerID
    }
    return false
  }

  /// Shows `scope`'s discovering connections every allowed target they have not seen.
  func announceAllowed(_ state: inout State, scope: String) {
    for (id, client) in state.clients where client.scope == scope && client.discovering {
      for target in state.targets.keys.sorted()
      where !client.announced.contains(target) && allowed(state, target, scope) {
        guard let info = state.targets[target],
          let event = Self.data([
            "method": "Target.targetCreated", "params": ["targetInfo": Self.object(info.json)],
          ])
        else { continue }
        state.clients[id]?.announced.insert(target)
        client.send(event)
      }
    }
  }

  static func reply(_ client: Client, _ requestID: Int, _ session: String?, result: [String: Any]) {
    var message: [String: Any] = ["id": requestID, "result": result]
    if let session { message["sessionId"] = session }
    if let encoded = Self.data(message) { client.send(encoded) }
  }

  static func reply(_ client: Client, _ requestID: Int, _ session: String?, error: String) {
    var message: [String: Any] = ["id": requestID, "error": ["code": -32_000, "message": error]]
    if let session { message["sessionId"] = session }
    if let encoded = Self.data(message) { client.send(encoded) }
  }

  /// The JSON object in `data`; empty when it holds none.
  static func object(_ data: Data) -> [String: Any] {
    let parsed = try? JSONSerialization.jsonObject(with: data)
    return parsed as? [String: Any] ?? [:]
  }

  static func data(_ object: [String: Any]) -> Data? {
    try? JSONSerialization.data(withJSONObject: object)
  }
}
