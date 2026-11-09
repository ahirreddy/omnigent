import Foundation
import Testing

@testable import OmnigentDeepLinks
@testable import OmnigentDesktop

/// The probe and the CLI handshake against a real socket on loopback.
@Suite("Loopback requests", .serialized)
struct LoopbackNetworkTests {
  private typealias Reply = LoopbackStub.Reply
  private static let health = Reply(status: 200, body: #"{"status":"ok"}"#)
  private static let manifest = Reply(
    status: 200,
    body:
      #"{"manifest_version":2,"server_version":"1.2","server_name":"Lab","auth":{"mode":"none"}}"#)

  private func probe(_ replies: [String: Reply]) async throws -> LocalServerProbeResult {
    let stub = try await LoopbackStub(replies)
    defer { stub.stop() }
    return await URLSessionLocalServerProbe().probe(try stub.url)
  }

  @Test("health and a manifest read as ready with the server's details")
  func ready() async throws {
    let result = try await probe([
      "/health": Self.health, "/.well-known/omnigent.json": Self.manifest,
    ])
    #expect(
      result
        == .ready(
          LocalServerManifest(
            manifestVersion: 2, serverVersion: "1.2", serverName: "Lab", authMode: "none")))
  }

  @Test("a server older than the manifest route is still ready")
  func noManifest() async throws {
    #expect(try await probe(["/health": Self.health]) == .ready(nil))
  }

  @Test("server errors mean keep waiting")
  func keepWaiting() async throws {
    #expect(
      try await probe(["/health": Reply(status: 503)])
        == .notReady("/health returned HTTP 503"))
    #expect(
      try await probe([
        "/health": Self.health, "/.well-known/omnigent.json": Reply(status: 500),
      ]) == .notReady("the manifest returned HTTP 500"))
  }

  @Test("anything that isn't Omnigent is rejected, not used")
  func rejected() async throws {
    #expect(
      try await probe(["/health": Reply(status: 403)])
        == .rejected("/health returned HTTP 403"))
    guard
      case .rejected(let notJSON) = try await probe(["/health": Reply(status: 200, body: "<html>")])
    else {
      Issue.record("HTML health must be rejected")
      return
    }
    #expect(notJSON.contains("did not return JSON"))
    #expect(
      try await probe(["/health": Reply(status: 200, body: #"{"status":"bad"}"#)])
        == .rejected(#"/health did not answer {"status": "ok"}"#))
    #expect(
      try await probe([
        "/health": Self.health, "/.well-known/omnigent.json": Reply(status: 403),
      ]) == .rejected("the manifest returned HTTP 403"))
    #expect(
      try await probe([
        "/health": Self.health,
        "/.well-known/omnigent.json": Reply(status: 200, body: "[]"),
      ]) == .rejected("the manifest is not a JSON object"))
  }

  @Test("a redirect is never followed, so it can't answer for the local server")
  func redirect() async throws {
    let moved = Reply(status: 302, headers: ["Location": "http://127.0.0.1:1/health"])
    #expect(
      try await probe(["/health": moved]) == .rejected("/health returned HTTP 302"))
  }

  @Test("nothing listening keeps waiting and names the path")
  func nothingListening() async throws {
    let stub = try await LoopbackStub([:])
    let closed = try stub.url
    stub.stop()
    try await Task.sleep(for: .milliseconds(20))
    guard case .notReady(let reason) = await URLSessionLocalServerProbe().probe(closed) else {
      Issue.record("a closed port must read as not ready")
      return
    }
    #expect(reason.contains("/health"))
  }

  @Test("the manifest's own problems read as sentences")
  func manifestProblems() {
    #expect(throws: ProbeProblem.self) { try LocalServerManifest.decode(Data("nope".utf8)) }
    #expect(throws: ProbeProblem("the manifest has no positive integer manifest_version")) {
      try LocalServerManifest.decode(Data(#"{"manifest_version":0}"#.utf8))
    }
  }

  @Test("the sign-in check reads 200 as signed in, sends the token, and a redirect as needed")
  func signIn() async throws {
    let stub = try await LoopbackStub([
      "/v1/me": Reply(status: 200),
      "/moved/v1/me": Reply(status: 302, headers: ["Location": "http://127.0.0.1:1/login"]),
    ])
    let probe = URLSessionLocalServerProbe()
    let server = try stub.url
    #expect(await probe.signInProbe(server, bearer: "token") == .signedIn)
    #expect(await probe.signInProbe(server.appending(path: "moved"), bearer: nil) == .signInNeeded)
    stub.stop()
    try await Task.sleep(for: .milliseconds(20))
    #expect(await probe.signInProbe(server, bearer: nil) == .unreachable)
  }

  private func acknowledge(
    status: Int, headers: [String: String] = [:]
  ) async throws -> Bool {
    let stub = try await LoopbackStub([
      "/desktop-open/abc": Reply(status: status, headers: headers)
    ])
    defer { stub.stop() }
    let acknowledgment = DeepLinkAcknowledgment(port: stub.port, nonce: "abc")
    return try await LoopbackDeepLinkAcknowledger().acknowledge(acknowledgment)
  }

  @Test("only 204 claims a CLI navigation, and a redirect doesn't count")
  func acknowledgment() async throws {
    #expect(try await acknowledge(status: 204))
    #expect(try await !acknowledge(status: 200))
    #expect(
      try await !acknowledge(status: 302, headers: ["Location": "http://127.0.0.1:1/ok"]))
  }

  @Test("a closed CLI listener reports a transport failure")
  func acknowledgmentFailure() async throws {
    let stub = try await LoopbackStub([:])
    let port = stub.port
    stub.stop()
    try await Task.sleep(for: .milliseconds(20))
    await #expect(throws: DeepLinkAcknowledgmentError.self) {
      try await LoopbackDeepLinkAcknowledger(timeout: 1).acknowledge(
        DeepLinkAcknowledgment(port: port, nonce: "abc"))
    }
  }
}
