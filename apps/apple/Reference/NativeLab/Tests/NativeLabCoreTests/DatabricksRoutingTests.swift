import Foundation
import XCTest

@testable import NativeLabCore

final class DatabricksRoutingTests: XCTestCase {
  private let mount = "/api/2.0/omnigent"
  private let token = "fixture-routing-token"

  private func url(_ harness: TransportHarness, org: String = "123") -> URL {
    URL(string: "https://fixture.cloud.databricks.com:\(harness.port)\(mount)?o=\(org)")!
  }

  private func configure(_ harness: TransportHarness) {
    harness.respond(
      path: mount + "/v1/info",
      body: #"{"single_user":false,"accounts_enabled":false}"#)
    harness.respond(path: mount + "/v1/me", body: #"{"user_id":"alice"}"#)
    harness.respond(path: mount + "/v1/sessions", body: #"{"data":[],"has_more":false}"#)
  }

  func testSelectorCanonicalizationAndDocumentedHostBoundaries() throws {
    for host in [
      "acme.databricks.com", "dbc-test.cloud.databricks.com",
      "test.gcp.databricks.com", "adb-123.4.azuredatabricks.net",
    ] {
      let endpoint = try ServerEndpoint(
        baseURL: URL(string: "https://\(host.uppercased()):443\(mount)/?o=123")!)
      XCTAssertEqual(endpoint.baseURL.absoluteString, "https://\(host)\(mount)?o=123")
      XCTAssertEqual(endpoint.databricksOrgID, "123")
      XCTAssertFalse(endpoint.isLocalSingleUser)
    }
    let unscoped = try ServerEndpoint(baseURL: URL(string: "https://acme.databricks.com\(mount)")!)
    XCTAssertNil(unscoped.databricksOrgID, "Never infer an org from a hostname")
    XCTAssertNil(
      try unscoped.request(path: "/v1/me").value(forHTTPHeaderField: "X-Databricks-Org-Id"))
  }

  func testRejectsMalformedSelectorsAndOtherHostsWithoutMakingRequests() throws {
    for query in [
      "", "o", "o=", "o=-1", "o=+1", "o=1.2", "o=1e3", "o= 1", "o=١",
      "O=123", "o=123&o=123", "o=123&other=1", "o=123&", "o=123=4",
      "other=123", "%6F=123", "o=%31", "o=123%0D%0AX-Test:1",
    ] {
      XCTAssertThrowsError(
        try ServerEndpoint(
          baseURL:
            URL(string: "https://acme.databricks.com\(mount)?\(query)")!), query)
    }
    for root in [
      "http://acme.databricks.com", "http://127.0.0.1", "https://127.0.0.1",
      "https://example.invalid", "https://databricks.com",
      "https://evildatabricks.com", "https://acme.databricks.com.evil.invalid",
      "https://evilazuredatabricks.net", "https://acme.azuredatabricks.net.evil.invalid",
      "https://app.aws.databricksapps.com", "https://a..databricks.com",
    ] {
      XCTAssertThrowsError(try ServerEndpoint(baseURL: URL(string: root + "?o=123")!), root)
    }
  }

  func testEveryTransportCarriesOrgHeaderWithoutPollutingEndpointQuery() async throws {
    let harness = TransportHarness()
    let client = try harness.makeClient(baseURL: url(harness), bearerToken: token)
    let query = [
      URLQueryItem(name: "after", value: "cursor/+?&"),
      URLQueryItem(name: "limit", value: "20"),
    ]
    for (path, socket) in [
      ("/v1/info", false), ("/v1/me", false),
      ("/v1/sessions", false), ("/v1/sessions/a/stream", false),
      ("/v1/sessions/updates", true), ("/v1/sessions/a/resources/files", false),
      ("/v1/sessions/a/resources/files/f/content", false),
      ("/v1/sessions/a/configuration", false), ("/v1/notifications/devices", false),
    ] {
      let request = try await client.request(path: path, query: query, webSocket: socket)
      XCTAssertEqual(request.url?.path, mount + path)
      XCTAssertEqual(request.url?.scheme, socket ? "wss" : "https")
      XCTAssertEqual(request.url?.host, "fixture.cloud.databricks.com")
      XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer " + token)
      XCTAssertEqual(request.value(forHTTPHeaderField: "X-Databricks-Org-Id"), "123")
      let components = try XCTUnwrap(
        URLComponents(url: request.url!, resolvingAgainstBaseURL: false))
      XCTAssertEqual(components.queryItems, query)
      XCTAssertFalse(components.queryItems!.contains { $0.name == "o" })
      XCTAssertNil(request.value(forHTTPHeaderField: "X-Forwarded-Email"))
    }
    do {
      _ = try await client.request(
        path: "/v1/sessions", query: [URLQueryItem(name: "o", value: "456")])
      XCTFail("Endpoint query must not override the saved workspace")
    } catch { XCTAssertEqual(error as? LocalServerClientError, .invalidBaseURL) }
  }

  func testIdentityNotificationAndDraftScopesSeparateOrgsOnSameHost() async throws {
    let harness = TransportHarness()
    configure(harness)
    let first = try harness.makeClient(baseURL: url(harness), bearerToken: token)
    let second = try harness.makeClient(baseURL: url(harness, org: "456"), bearerToken: token)
    let firstInfo = try await first.connect()
    let secondInfo = try await second.connect()
    XCTAssertEqual(firstInfo.userID, secondInfo.userID)
    XCTAssertEqual(firstInfo.baseURL, url(harness))
    XCTAssertNotEqual(firstInfo.scope, secondInfo.scope)
    XCTAssertNotEqual(
      NotificationScope(serverURL: firstInfo.baseURL.absoluteString, userID: "alice"),
      NotificationScope(serverURL: secondInfo.baseURL.absoluteString, userID: "alice"))
    XCTAssertNotEqual(
      AttachmentDraftKey(scope: firstInfo.baseURL.absoluteString + "|alice", sessionID: "a"),
      AttachmentDraftKey(scope: secondInfo.baseURL.absoluteString + "|alice", sessionID: "a"))
    _ = try await first.sessionPage(after: "cursor", limit: 20)
    XCTAssertEqual(harness.requests.last?.value(forHTTPHeaderField: "X-Databricks-Org-Id"), "123")
    for request in harness.requests {
      XCTAssertFalse(
        URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?
          .contains(where: { $0.name == "o" }) ?? false)
    }
  }

  func testUploadsAndPreviewRequestsPreserveScopeAndRejectCrossOrgAttachments() async throws {
    let harness = TransportHarness()
    configure(harness)
    harness.respond(
      path: mount + "/v1/sessions/a",
      body: #"{"id":"a","status":"idle","created_at":1,"permission_level":4}"#)
    harness.respond(
      path: mount + "/v1/sessions/a/resources/files",
      body: #"{"id":"file_a","session_id":"a","name":"example.txt"}"#, status: 201)
    harness.respond(path: mount + "/v1/sessions/a/resources/files/file_a/content", body: "{}")
    let client = try harness.makeClient(baseURL: url(harness), bearerToken: token)
    _ = try await client.connect()
    let file = try AttachmentUploadFile(filename: "example.txt", data: Data("fixture".utf8))
    let uploaded = try await client.uploadAttachment(file, sessionID: "a")
    XCTAssertEqual(uploaded.serverURL, url(harness))
    XCTAssertEqual(uploaded.userID, "alice")
    _ = try await client.attachmentContent(sessionID: "a", fileID: "file_a")
    for request in harness.requests {
      XCTAssertEqual(request.value(forHTTPHeaderField: "X-Databricks-Org-Id"), "123")
      XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer " + token)
      let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
      if request.url?.path == mount + "/v1/sessions/a" {
        XCTAssertEqual(query, [URLQueryItem(name: "include_items", value: "false")])
      } else {
        XCTAssertNil(query)
      }
    }
    let second = try harness.makeClient(baseURL: url(harness, org: "456"), bearerToken: token)
    _ = try await second.connect()
    let count = harness.requests.count
    do {
      _ = try await second.submitMessage("", attachments: [uploaded], to: "a")
      XCTFail("Cross-workspace upload accepted")
    } catch { XCTAssertEqual(error as? AttachmentUploadError, .wrongSession) }
    XCTAssertEqual(harness.requests.count, count)
  }

  func testAttachmentReferencesResolveWithScopeQueryAndRejectDifferentOrg() throws {
    let harness = TransportHarness()
    let client = try harness.makeClient(baseURL: url(harness), bearerToken: token)
    let path = "/v1/sessions/a/resources/files/f/content"
    let root = "https://fixture.cloud.databricks.com:\(harness.port)\(mount)"
    for reference in [
      path, String(path.dropFirst()), root + path, root + path + "?o=123", path + "?o=123",
    ] {
      XCTAssertEqual(client.attachmentFileID(reference: reference, sessionID: "a"), "f")
    }
    for reference in [
      root + path + "?o=456", path + "?o=456", path + "?o=123&o=123",
      path + "?o=%31%32%33", path + "?o=123&download=1",
      "https://other.databricks.com\(mount)" + path + "?o=123",
    ] {
      XCTAssertNil(client.attachmentFileID(reference: reference, sessionID: "a"), reference)
    }
  }

  func testOrgScopedAuthDiscoveryUsesHeaderAndRejectsStandaloneLoginBeforeSendingSecrets()
    async throws
  {
    let harness = TransportHarness()
    configure(harness)
    harness.respond(
      path: mount + "/v1/info",
      body: #"{"single_user":false,"accounts_enabled":false,"login_url":"/auth/login"}"#)
    let session = harness.makeSession()
    defer { session.invalidateAndCancel() }
    let auth = try ServerAuthenticationClient(baseURL: url(harness), session: session)
    let discovery = try await auth.discover()
    XCTAssertEqual(discovery.mode, .proxy)
    XCTAssertEqual(discovery.baseURL, url(harness))
    XCTAssertEqual(harness.requests.last?.value(forHTTPHeaderField: "X-Databricks-Org-Id"), "123")
    XCTAssertNil(harness.requests.last?.url?.query)
    do {
      _ = try await auth.beginBrowserLogin()
      XCTFail("Workspace browser auth cannot reuse the standalone callback contract")
    } catch { XCTAssertEqual(error as? LocalServerClientError, .unsupportedAuthentication) }
    do {
      _ = try await auth.login(username: "alice", password: "synthetic-password")
      XCTFail("Workspace proxy should use bearer authentication")
    } catch { XCTAssertEqual(error as? LocalServerClientError, .unsupportedAuthentication) }
    XCTAssertEqual(harness.requests.count, 1)
  }

  func testBothNotificationClientsUseHeaderAndStripScopeQuery() async throws {
    let harness = TransportHarness()
    configure(harness)
    harness.respond(path: mount + "/v1/notifications/devices/install_a", body: "", status: 204)
    let client = try harness.makeClient(baseURL: url(harness), bearerToken: token)
    _ = try await client.connect()
    try await client.unregister(installationID: "install_a")
    XCTAssertEqual(harness.requests.last?.value(forHTTPHeaderField: "X-Databricks-Org-Id"), "123")
    XCTAssertNil(harness.requests.last?.url?.query)
    let generic = try HTTPNativePushRegistrationClient(baseURL: url(harness)) { request in
      XCTAssertEqual(request.url?.path, "/api/2.0/omnigent/v1/notifications/devices/install_a")
      XCTAssertEqual(request.value(forHTTPHeaderField: "X-Databricks-Org-Id"), "123")
      XCTAssertNil(request.url?.query)
      return (
        Data(),
        HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!
      )
    }
    try await generic.unregister(installationID: "install_a")
  }
}
