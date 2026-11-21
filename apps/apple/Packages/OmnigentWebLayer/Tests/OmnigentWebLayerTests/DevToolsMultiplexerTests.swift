import Foundation
import Synchronization
import Testing

@testable import OmnigentWebLayer

/// Sharing Chromium's DevTools pipe: ids, sessions and targets stay with the connection and
/// scope they belong to.
@Suite("DevTools multiplexer")
struct DevToolsMultiplexerTests {
  /// Records what goes up the pipe and what each connection receives.
  nonisolated final class Wire: Sendable {
    let upstream = Mutex<[Data]>([])
    let received = Mutex<[UInt64: [Data]]>([:])
    let closed = Mutex<Set<String>>([])

    var upstreamIsEmpty: Bool { upstream.withLock { $0.isEmpty } }
    func lastUpstream() -> [String: Any] {
      DevToolsMultiplexerTests.object(upstream.withLock { $0.last ?? Data() })
    }
    func messages(_ client: UInt64) -> [[String: Any]] {
      received.withLock { $0[client] ?? [] }.map(DevToolsMultiplexerTests.object)
    }
  }

  private func make() -> (DevToolsMultiplexer, Wire) {
    let wire = Wire()
    let multiplexer = DevToolsMultiplexer { data in
      wire.upstream.withLock { $0.append(data) }
    }
    return (multiplexer, wire)
  }

  private func client(_ multiplexer: DevToolsMultiplexer, _ wire: Wire, scope: String) -> UInt64 {
    let box = Mutex<UInt64>(0)
    let id = multiplexer.addClient(
      scope: scope,
      send: { data in
        let client = box.withLock { $0 }
        wire.received.withLock { $0[client, default: []].append(data) }
      },
      close: { wire.closed.withLock { _ = $0.insert(scope) } })
    box.withLock { $0 = id }
    return id
  }

  nonisolated static func object(_ data: Data) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
  }

  private static func json(_ object: [String: Any]) -> Data {
    (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
  }

  private func send(_ multiplexer: DevToolsMultiplexer, _ client: UInt64, _ object: [String: Any]) {
    multiplexer.clientMessage(client, Self.json(object))
  }

  private func target(_ id: String, opener: String? = nil) -> [String: Any] {
    var info: [String: Any] = ["targetId": id, "type": "page", "url": "https://example.com/"]
    if let opener { info["openerId"] = opener }
    return ["method": "Target.targetCreated", "params": ["targetInfo": info]]
  }

  @Test("two connections may reuse ids; replies come back to the sender with its own id")
  func idsAreRenumbered() {
    let (multiplexer, wire) = make()
    let first = client(multiplexer, wire, scope: "conv_a")
    let second = client(multiplexer, wire, scope: "conv_b")
    send(multiplexer, first, ["id": 1, "method": "Browser.getVersion"])
    let firstUpstream = wire.lastUpstream()["id"] as? Int
    send(multiplexer, second, ["id": 1, "method": "Browser.getVersion"])
    let secondUpstream = wire.lastUpstream()["id"] as? Int
    #expect(firstUpstream != secondUpstream)
    multiplexer.upstreamMessage(Self.json(["id": secondUpstream ?? 0, "result": ["n": 2]]))
    multiplexer.upstreamMessage(Self.json(["id": firstUpstream ?? 0, "result": ["n": 1]]))
    #expect(wire.messages(first).map { $0["id"] as? Int } == [1])
    #expect((wire.messages(first)[0]["result"] as? [String: Any])?["n"] as? Int == 1)
    #expect((wire.messages(second)[0]["result"] as? [String: Any])?["n"] as? Int == 2)
  }

  @Test("a connection attaches only to its scope's tabs and owns the sessions it attached")
  func attachIsScopedAndSessionsAreOwned() {
    let (multiplexer, wire) = make()
    let owner = client(multiplexer, wire, scope: "conv_a")
    let stranger = client(multiplexer, wire, scope: "conv_b")
    multiplexer.upstreamMessage(Self.json(target("T1")))
    multiplexer.setScope("conv_a", targets: ["T1"])

    send(
      multiplexer, stranger,
      [
        "id": 3, "method": "Target.attachToTarget",
        "params": ["targetId": "T1", "flatten": true],
      ])
    #expect(wire.messages(stranger).last?["error"] != nil)
    #expect(wire.upstreamIsEmpty)

    send(
      multiplexer, owner,
      [
        "id": 4, "method": "Target.attachToTarget",
        "params": ["targetId": "T1", "flatten": true],
      ])
    let attachID = wire.lastUpstream()["id"] as? Int ?? 0
    multiplexer.upstreamMessage(
      Self.json([
        "method": "Target.attachedToTarget",
        "params": ["sessionId": "S1", "targetInfo": ["targetId": "T1", "type": "page"]],
      ]))
    multiplexer.upstreamMessage(Self.json(["id": attachID, "result": ["sessionId": "S1"]]))
    #expect(wire.messages(owner).contains { $0["method"] as? String == "Target.attachedToTarget" })
    #expect(wire.messages(owner).last?["id"] as? Int == 4)

    // Events of the session reach only its owner; the stranger cannot use it.
    multiplexer.upstreamMessage(Self.json(["method": "Page.loadEventFired", "sessionId": "S1"]))
    #expect(wire.messages(owner).last?["method"] as? String == "Page.loadEventFired")
    send(multiplexer, stranger, ["id": 5, "method": "Runtime.evaluate", "sessionId": "S1"])
    #expect(wire.messages(stranger).last?["error"] != nil)
    #expect(!wire.messages(stranger).contains { $0["method"] as? String == "Page.loadEventFired" })
  }

  @Test("profile-wide and unknown browser methods are refused")
  func refusedMethods() {
    let (multiplexer, wire) = make()
    let agent = client(multiplexer, wire, scope: "conv_a")
    for method in [
      "Browser.close", "Storage.getCookies", "Target.createTarget", "Target.setAutoAttach",
    ] {
      send(multiplexer, agent, ["id": 1, "method": method])
      #expect(wire.messages(agent).last?["error"] != nil, "\(method)")
    }
    #expect(DevToolsMultiplexer.isRefused("Network.getAllCookies"))
    #expect(DevToolsMultiplexer.isRefused("WebAuthn.enable"))
    #expect(!DevToolsMultiplexer.isRefused("Runtime.evaluate"))
    #expect(wire.upstreamIsEmpty)
  }

  @Test("discovery shows a connection its scope's tabs and their popups, and new ones as added")
  func discoveryIsScoped() {
    let (multiplexer, wire) = make()
    multiplexer.start()
    let agent = client(multiplexer, wire, scope: "conv_a")
    multiplexer.upstreamMessage(Self.json(target("MINE")))
    multiplexer.upstreamMessage(Self.json(target("OTHER")))
    multiplexer.setScope("conv_a", targets: ["MINE"])
    send(
      multiplexer, agent,
      [
        "id": 1, "method": "Target.setDiscoverTargets",
        "params": ["discover": true],
      ])
    multiplexer.upstreamMessage(Self.json(target("POPUP", opener: "MINE")))
    multiplexer.upstreamMessage(Self.json(target("NEW")))
    multiplexer.addToScope("conv_a", target: "NEW")

    let announced = wire.messages(agent).compactMap { message -> String? in
      guard message["method"] as? String == "Target.targetCreated" else { return nil }
      return ((message["params"] as? [String: Any])?["targetInfo"] as? [String: Any])?["targetId"]
        as? String
    }
    #expect(announced == ["MINE", "POPUP", "NEW"])
    send(multiplexer, agent, ["id": 2, "method": "Target.getTargets"])
    let infos = (wire.messages(agent).last?["result"] as? [String: Any])?["targetInfos"] as? [Any]
    #expect(infos?.count == 3)
  }

  @Test("a closed connection's sessions are detached, and a gone browser closes everyone")
  func cleanUp() {
    let (multiplexer, wire) = make()
    let agent = client(multiplexer, wire, scope: "conv_a")
    multiplexer.upstreamMessage(Self.json(target("T1")))
    multiplexer.setScope("conv_a", targets: ["T1"])
    send(
      multiplexer, agent,
      [
        "id": 1, "method": "Target.attachToTarget",
        "params": ["targetId": "T1", "flatten": true],
      ])
    multiplexer.upstreamMessage(
      Self.json([
        "method": "Target.attachedToTarget",
        "params": ["sessionId": "S1", "targetInfo": ["targetId": "T1", "type": "page"]],
      ]))
    multiplexer.removeClient(agent)
    #expect(wire.lastUpstream()["method"] as? String == "Target.detachFromTarget")
    #expect((wire.lastUpstream()["params"] as? [String: Any])?["sessionId"] as? String == "S1")

    _ = client(multiplexer, wire, scope: "conv_b")
    multiplexer.upstreamClosed()
    #expect(wire.closed.withLock { $0 } == ["conv_b"])
    #expect(multiplexer.clientCount == 0)
  }
}
