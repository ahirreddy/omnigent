internal import Foundation
internal import os

// MARK: Upstream

nonisolated extension DevToolsMultiplexer {
  func response(_ state: inout State, _ id: Int, _ message: inout [String: Any]) {
    guard let pending = state.pending.removeValue(forKey: id) else { return }
    guard let clientID = pending.client else {
      if let error = message["error"] as? [String: Any] {
        let reason = String(describing: error["message"] ?? "unknown")
        DevToolsGate.log.info("A DevTools gate request failed: \(reason, privacy: .public)")
      }
      return
    }
    if let target = pending.attachTarget {
      settleAttach(&state, clientID, target, message)
    }
    guard let client = state.clients[clientID] else { return }
    message["id"] = pending.originalID
    if let data = Self.data(message) { client.send(data) }
  }

  /// Records the session an attach made, or drops the waiting entry of one that failed.
  private func settleAttach(
    _ state: inout State, _ clientID: ClientID, _ target: String, _ message: [String: Any]
  ) {
    let session = (message["result"] as? [String: Any])?["sessionId"] as? String
    if let session, state.clients[clientID] != nil {
      state.sessionOwners[session] = clientID
      state.clients[clientID]?.rootSessions.insert(session)
    } else if let index = state.pendingAttaches[target]?.firstIndex(of: clientID) {
      state.pendingAttaches[target]?.remove(at: index)
    }
  }

  func sessionEvent(
    _ state: inout State, _ method: String, _ params: [String: Any], session: String, data: Data
  ) {
    guard let owner = state.sessionOwners[session], let client = state.clients[owner] else {
      return
    }
    let child = params["sessionId"] as? String
    if method == "Target.attachedToTarget", let child { state.sessionOwners[child] = owner }
    client.send(data)
    if method == "Target.detachedFromTarget", let child { state.sessionOwners[child] = nil }
  }

  func browserEvent(_ state: inout State, _ method: String, _ params: [String: Any], data: Data) {
    switch method {
    case "Target.targetCreated", "Target.targetInfoChanged":
      targetInfoEvent(&state, params, data: data)
    case "Target.targetDestroyed", "Target.targetCrashed":
      targetGoneEvent(&state, params, destroyed: method == "Target.targetDestroyed", data: data)
    case "Target.attachedToTarget":
      attachedEvent(&state, params, data: data)
    case "Target.detachedFromTarget":
      guard let session = params["sessionId"] as? String,
        let owner = state.sessionOwners.removeValue(forKey: session)
      else { return }
      state.clients[owner]?.rootSessions.remove(session)
      state.clients[owner]?.send(data)
    default:
      break
    }
  }

  private func targetInfoEvent(_ state: inout State, _ params: [String: Any], data: Data) {
    guard let info = params["targetInfo"] as? [String: Any],
      let target = info["targetId"] as? String, let json = Self.data(info)
    else { return }
    state.targets[target] = TargetInfo(openerID: info["openerId"] as? String, json: json)
    for (id, client) in state.clients
    where client.discovering && allowed(state, target, client.scope) {
      state.clients[id]?.announced.insert(target)
      client.send(data)
    }
  }

  private func targetGoneEvent(
    _ state: inout State, _ params: [String: Any], destroyed: Bool, data: Data
  ) {
    guard let target = params["targetId"] as? String else { return }
    for (id, client) in state.clients where client.announced.contains(target) {
      if destroyed { state.clients[id]?.announced.remove(target) }
      client.send(data)
    }
    if destroyed { state.targets[target] = nil }
  }

  private func attachedEvent(_ state: inout State, _ params: [String: Any], data: Data) {
    guard let session = params["sessionId"] as? String,
      let target = (params["targetInfo"] as? [String: Any])?["targetId"] as? String
    else { return }
    guard let owner = state.pendingAttaches[target]?.first, let client = state.clients[owner]
    else {
      // Nobody asked for this attach; do not leave it open.
      internalCommand(&state, "Target.detachFromTarget", ["sessionId": session])
      return
    }
    state.pendingAttaches[target]?.removeFirst()
    state.sessionOwners[session] = owner
    state.clients[owner]?.rootSessions.insert(session)
    client.send(data)
  }
}
