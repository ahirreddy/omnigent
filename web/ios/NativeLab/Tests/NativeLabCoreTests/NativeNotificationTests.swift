import Foundation
import XCTest

@testable import NativeLabCore

final class NativeNotificationTests: XCTestCase {
  private func payload(
    server: String = "https://example.invalid", user: String = "alice",
    workspace: String = "0", session: String = "conv_a", event: String = "event_a"
  ) -> [AnyHashable: Any] {
    [
      "omnigent": [
        "version": 1, "server_url": server, "user_id": user,
        "workspace_id": workspace, "session_id": session, "event_id": event, "kind": "approval",
      ]
    ]
  }

  func testScopedRouteCanonicalizesOriginAndRejectsUntrustedNavigation() throws {
    let route = try XCTUnwrap(
      NotificationRoute(userInfo: payload(server: "https://EXAMPLE.invalid:443/")))
    XCTAssertEqual(route.scope.serverURL, "https://example.invalid")
    XCTAssertEqual(route.sessionID, "conv_a")
    XCTAssertNil(NotificationRoute(userInfo: ["navigatePath": "/sessions/conv_a"]))
    for invalid in ["../other", "conv_a?redirect=evil", "conv_a/other", "", "conv_a%2Fother"] {
      XCTAssertNil(NotificationRoute(userInfo: payload(session: invalid)))
    }
    for invalid in [
      "file:///tmp", "https://user:pass@example.invalid", "https://example.invalid/%2e%2e/other",
      "https://example.invalid?q=1",
    ] {
      XCTAssertNil(NotificationRoute(userInfo: payload(server: invalid)))
    }
    XCTAssertNotEqual(route.scope, NotificationRoute(userInfo: payload(user: "bob"))?.scope)
    XCTAssertNotEqual(route.scope, NotificationRoute(userInfo: payload(workspace: "1"))?.scope)
  }

  func testDedupPersistsAndScopesEveryIdentityComponent() throws {
    var ledger = NotificationLedger()
    let route = try XCTUnwrap(NotificationRoute(userInfo: payload()))
    XCTAssertTrue(ledger.insert(route))
    XCTAssertFalse(ledger.insert(route))
    ledger = try JSONDecoder().decode(NotificationLedger.self, from: JSONEncoder().encode(ledger))
    XCTAssertFalse(ledger.insert(route))
    for value in [
      payload(server: "https://other.invalid"), payload(user: "bob"),
      payload(workspace: "1"), payload(session: "conv_b"), payload(event: "event_b"),
    ] {
      XCTAssertTrue(ledger.insert(try XCTUnwrap(NotificationRoute(userInfo: value))))
    }
    var activation = NotificationLedger()
    XCTAssertTrue(activation.insert(route), "Presentation must not consume the tap")
  }

  func testLedgerIsBoundedAndRetainsRecentEvents() throws {
    var ledger = NotificationLedger()
    for index in 0...512 {
      XCTAssertTrue(
        ledger.insert(try XCTUnwrap(NotificationRoute(userInfo: payload(event: "e_\(index)")))))
    }
    XCTAssertFalse(
      ledger.insert(try XCTUnwrap(NotificationRoute(userInfo: payload(event: "e_512")))))
    XCTAssertTrue(ledger.insert(try XCTUnwrap(NotificationRoute(userInfo: payload(event: "e_0")))))
  }

  func testLoopbackDevelopmentScopeIsExact() {
    for address in ["http://127.0.0.1:6767", "http://[::1]:6767"] {
      XCTAssertEqual(
        NotificationScope(serverURL: address, userID: "local")?.isLoopbackDevelopment, true)
    }
    for address in [
      "http://localhost:6767", "http://192.168.0.1:6767", "http://127.0.0.1.evil.invalid",
    ] {
      XCTAssertNil(NotificationScope(serverURL: address, userID: "local"))
    }
    XCTAssertFalse(
      NotificationScope(serverURL: "http://127.0.0.1", userID: "alice")!.isLoopbackDevelopment)
    XCTAssertFalse(
      NotificationScope(serverURL: "http://127.0.0.1", userID: "local", workspaceID: "1")!
        .isLoopbackDevelopment)
  }

  func testHTTPRegistrationContractAndRedirectRejection() async throws {
    let client = try HTTPNativePushRegistrationClient(
      baseURL: URL(string: "https://example.invalid")!
    ) { request in
      XCTAssertEqual(request.url?.path, "/v1/notifications/devices")
      XCTAssertEqual(request.httpMethod, "PUT")
      let body = try XCTUnwrap(
        JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
      XCTAssertEqual(body["session_ids"] as? [String], ["conv_a", "conv_b"])
      XCTAssertNil(body["user_id"], "Identity comes from authentication")
      return (
        Data(),
        HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!
      )
    }
    try await client.register(
      NativePushRegistration(
        installationID: "install_a", deviceToken: "ab",
        environment: "sandbox", topic: "ai.test", sessionIDs: ["conv_b", "conv_a", "conv_a"]))
    let redirected = try HTTPNativePushRegistrationClient(
      baseURL: URL(string: "https://example.invalid")!
    ) { _ in
      (
        Data(),
        HTTPURLResponse(
          url: URL(string: "https://other.invalid")!, statusCode: 200, httpVersion: nil,
          headerFields: nil)!
      )
    }
    do {
      _ = try await redirected.capabilities()
      XCTFail("Redirect must fail")
    } catch { XCTAssertEqual(error as? LocalServerClientError, .redirectNotAllowed) }
  }
}
