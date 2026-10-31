import Foundation
import XCTest

@testable import NativeLabCore

final class HostedServerAuthenticationTests: XCTestCase {
  private let mount = "/api/2.0/omnigent"
  private let fixtureToken = "fixture-token-not-a-real-credential"

  func testPublicConnectionStateBecomesFalseAfter401() async throws {
    let harness = TransportHarness()
    configure(harness)
    let client = try harness.makeClient(baseURL: url(harness), bearerToken: fixtureToken)
    let initial = await client.isConnected
    XCTAssertFalse(initial)
    _ = try await client.connect()
    let authenticated = await client.isConnected
    XCTAssertTrue(authenticated)
    harness.respond(path: mount + "/v1/sessions", body: "{}", status: 401)
    await expect(.unauthorized) { _ = try await client.sessions() }
    let invalidated = await client.isConnected
    XCTAssertFalse(invalidated)
    let requestCount = harness.requests.count
    await expect(.notConnected) { _ = try await client.sessions() }
    XCTAssertEqual(harness.requests.count, requestCount)
  }

  private func url(_ harness: TransportHarness) -> URL {
    URL(string: "https://127.0.0.1:\(harness.port)\(mount)")!
  }

  private func configure(_ harness: TransportHarness, identity: String = "alice") {
    harness.respond(
      path: mount + "/v1/info",
      body: #"{"single_user":false,"accounts_enabled":false}"#)
    harness.respond(path: mount + "/v1/me", body: "{\"user_id\":\"\(identity)\"}")
    harness.respond(path: mount + "/v1/sessions", body: #"{"data":[],"has_more":false}"#)
  }

  private func auth(_ harness: TransportHarness) throws -> ServerAuthenticationClient {
    let session = harness.makeSession()
    defer { session.invalidateAndCancel() }
    return try ServerAuthenticationClient(baseURL: url(harness), session: session)
  }

  private func expect(_ expected: LocalServerClientError, _ action: () async throws -> Void) async {
    do {
      try await action()
      XCTFail("Expected \(expected)")
    } catch { XCTAssertEqual(error as? LocalServerClientError, expected) }
  }

  func testHostedProxyConfirmsIdentityAndScopesEveryRequestToMountedAPI() async throws {
    let harness = TransportHarness()
    configure(harness)
    let client = try harness.makeClient(
      baseURL: url(harness), bearerToken: fixtureToken,
      expectedUserID: "alice")
    let info = try await client.connect()
    XCTAssertEqual(info.userID, "alice")
    XCTAssertEqual(info.scope, ServerIdentityScope(serverURL: url(harness), userID: "alice"))
    _ = try await client.sessions()
    XCTAssertEqual(
      harness.requests.map { $0.url!.path },
      ["/v1/info", "/v1/me", "/v1/sessions"].map { mount + $0 })
    for request in harness.requests {
      XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer " + fixtureToken)
      XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
      XCTAssertNil(request.value(forHTTPHeaderField: "X-Forwarded-Email"))
      XCTAssertFalse(request.httpShouldHandleCookies)
    }
  }

  func testBearerHeaderAndMountApplyToSSEWebSocketUploadConfigurationAndNotifications() async throws
  {
    let harness = TransportHarness()
    let client = try harness.makeClient(baseURL: url(harness), bearerToken: fixtureToken)
    for path in [
      "/v1/sessions/a/stream", "/v1/sessions/a/resources/files",
      "/v1/sessions/a/configuration", "/v1/notifications/devices",
    ] {
      let request = try await client.request(path: path)
      XCTAssertEqual(request.url?.path, mount + path)
      XCTAssertEqual(request.url?.scheme, "https")
      XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer " + fixtureToken)
    }
    let socket = try await client.request(path: "/v1/sessions/updates", webSocket: true)
    XCTAssertEqual(socket.url?.scheme, "wss")
    XCTAssertEqual(socket.url?.path, mount + "/v1/sessions/updates")
    XCTAssertEqual(socket.value(forHTTPHeaderField: "Authorization"), "Bearer " + fixtureToken)
  }

  func testHostedConnectionsRequireBearerAndNonemptyConfirmedIdentity() async throws {
    let harness = TransportHarness()
    configure(harness)
    let missing = try harness.makeClient(baseURL: url(harness))
    await expect(.unauthorized) { _ = try await missing.connect() }
    XCTAssertFalse(harness.requests.contains { $0.url?.path.hasSuffix("/me") == true })
    for body in [#"{"user_id":null}"#, #"{"user_id":" "}"#] {
      harness.respond(path: mount + "/v1/me", body: body)
      let client = try harness.makeClient(baseURL: url(harness), bearerToken: fixtureToken)
      await expect(.identityUnavailable) { _ = try await client.connect() }
      await expect(.notConnected) { _ = try await client.sessions() }
    }
  }

  func testHostedSingleUserFallbackIsNotMistakenForBearerAuthentication() async throws {
    let harness = TransportHarness()
    configure(harness)
    harness.respond(
      path: mount + "/v1/info",
      body: #"{"single_user":true,"accounts_enabled":false}"#)
    let client = try harness.makeClient(baseURL: url(harness), bearerToken: fixtureToken)
    await expect(.unsupportedAuthentication) { _ = try await client.connect() }
    XCTAssertEqual(harness.requests.count, 1)
  }

  func testSSEUnauthorizedStopsAndPublishesSignInAgainWithoutRetry() async throws {
    let harness = TransportHarness()
    configure(harness)
    harness.respond(path: mount + "/v1/sessions/a/stream", body: "{}", status: 401)
    let client = try harness.makeClient(baseURL: url(harness), bearerToken: fixtureToken)
    _ = try await client.connect()
    let updates = await client.activityUpdates()
    let failure = expectation(description: "Actionable sign-in failure")
    let observer = Task {
      for await update in updates {
        if case .streamState("a", .failed(let message)) = update {
          XCTAssertEqual(message, LocalServerClientError.unauthorized.localizedDescription)
          failure.fulfill()
          break
        }
      }
    }
    try await client.startWatching(sessionID: "a")
    await fulfillment(of: [failure], timeout: 3)
    observer.cancel()
    await expect(.notConnected) { _ = try await client.sessions() }
    let watching = await client.watchedSessionID
    let task = await client.streamTask
    let list = await client.listTask
    XCTAssertNil(watching)
    XCTAssertNil(task)
    XCTAssertNil(list)
    XCTAssertEqual(harness.requests.filter { $0.url?.path.hasSuffix("/stream") == true }.count, 1)
  }

  func testSocketHandshakeAuthAndTLSFailuresDoNotReconnect() async throws {
    let harness = TransportHarness()
    let client = try harness.makeClient(baseURL: url(harness), bearerToken: fixtureToken)
    for status in [302, 401, 403] {
      let response = HTTPURLResponse(
        url: url(harness), statusCode: status, httpVersion: nil,
        headerFields: nil)!
      let error = await client.streamFailure(URLError(.badServerResponse), response: response)
      let reconnect = await client.shouldReconnect(error)
      XCTAssertFalse(reconnect)
      if status == 401 { XCTAssertEqual(error as? LocalServerClientError, .unauthorized) }
    }
    for code in [
      URLError.Code.userAuthenticationRequired, .userCancelledAuthentication,
      .serverCertificateUntrusted, .serverCertificateHasUnknownRoot,
    ] {
      let error = await client.streamFailure(URLError(code))
      let reconnect = await client.shouldReconnect(error)
      XCTAssertFalse(reconnect)
    }
  }

  func testMountedUploadCarriesBearerAndReturnedAttachmentIdentity() async throws {
    let harness = TransportHarness()
    configure(harness)
    harness.respond(
      path: mount + "/v1/sessions/a",
      body: #"{"id":"a","status":"idle","created_at":1,"permission_level":4}"#)
    harness.respond(
      path: mount + "/v1/sessions/a/resources/files",
      body: #"{"id":"file_a","session_id":"a","name":"example.txt"}"#, status: 201)
    let client = try harness.makeClient(baseURL: url(harness), bearerToken: fixtureToken)
    _ = try await client.connect()
    let file = try AttachmentUploadFile(filename: "example.txt", data: Data("fixture".utf8))
    let attachment = try await client.uploadAttachment(file, sessionID: "a")
    XCTAssertEqual(attachment.serverURL, url(harness))
    XCTAssertEqual(attachment.userID, "alice")
    let request = try XCTUnwrap(harness.requests.last)
    XCTAssertEqual(request.httpMethod, "POST")
    XCTAssertEqual(request.url?.path, mount + "/v1/sessions/a/resources/files")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer " + fixtureToken)
  }

  func testExpectedIdentityAndReconnectPinningRejectDifferentAccounts() async throws {
    let harness = TransportHarness()
    configure(harness)
    let wrong = try harness.makeClient(
      baseURL: url(harness), bearerToken: fixtureToken,
      expectedUserID: "bob")
    await expect(.identityMismatch) { _ = try await wrong.connect() }
    let client = try harness.makeClient(baseURL: url(harness), bearerToken: fixtureToken)
    _ = try await client.connect()
    configure(harness, identity: "bob")
    await expect(.identityMismatch) { _ = try await client.connect() }
    await expect(.notConnected) { _ = try await client.sessions() }
  }

  func testDisconnectDiscardsInFlightInventory() async throws {
    let harness = TransportHarness()
    configure(harness)
    let client = try harness.makeClient(baseURL: url(harness), bearerToken: fixtureToken)
    _ = try await client.connect()
    harness.enqueue(
      path: mount + "/v1/sessions", method: "GET",
      stubs: [
        .init(body: #"{"data":[],"has_more":false}"#, delay: 0.2)
      ])
    let requested = expectation(description: "Inventory started")
    harness.observeRequests { request in
      if request.url?.path.hasSuffix("/v1/sessions") == true { requested.fulfill() }
    }
    let operation = Task { try await client.sessions() }
    await fulfillment(of: [requested], timeout: 2)
    await client.disconnect()
    await expect(.notConnected) { _ = try await operation.value }
    let count = await client.summaries.count
    XCTAssertEqual(count, 0)
  }

  func testUnauthorizedClearsConnectionAndMountedNotificationMutationUsesBearer() async throws {
    let harness = TransportHarness()
    configure(harness)
    let client = try harness.makeClient(baseURL: url(harness), bearerToken: fixtureToken)
    _ = try await client.connect()
    harness.respond(path: mount + "/v1/notifications/devices/install_a", body: "", status: 204)
    try await client.unregister(installationID: "install_a")
    XCTAssertEqual(harness.requests.last?.httpMethod, "DELETE")
    XCTAssertEqual(
      harness.requests.last?.value(forHTTPHeaderField: "Authorization"),
      "Bearer " + fixtureToken)
    harness.respond(path: mount + "/v1/notifications/devices/install_a", body: "", status: 401)
    await expect(.unauthorized) { try await client.unregister(installationID: "install_a") }
    await expect(.notConnected) { _ = try await client.sessions() }
  }

  func testEndpointRejectsUnsafeURLsAndCanonicalizesMount() throws {
    let endpoint = try ServerEndpoint(baseURL: URL(string: "https://EXAMPLE.invalid:443/api/2.0/")!)
    XCTAssertEqual(endpoint.baseURL.absoluteString, "https://example.invalid/api/2.0")
    for address in [
      "http://example.invalid/api", "https://user:pass@example.invalid/api",
      "https://example.invalid/api?token=example", "https://example.invalid/#fragment",
      "https://example.invalid/api/../other", "https://example.invalid/api/%2Fother",
      "https://example.invalid/api//other",
    ] {
      XCTAssertThrowsError(try ServerEndpoint(baseURL: URL(string: address)!))
    }
    for token in ["", "a\r\nX-Forwarded-Email: bob", " bearer value "] {
      XCTAssertThrowsError(
        try LocalServerSessionClient(baseURL: endpoint.baseURL, bearerToken: token))
    }
    XCTAssertThrowsError(
      try LocalServerSessionClient(
        baseURL: URL(string: "http://127.0.0.1:6767")!, bearerToken: fixtureToken))
  }

  func testAttachmentReferencesStayWithinMountAndIdentity() async throws {
    let harness = TransportHarness()
    configure(harness)
    let client = try harness.makeClient(baseURL: url(harness), bearerToken: fixtureToken)
    _ = try await client.connect()
    let path = "/v1/sessions/a/resources/files/f/content"
    for reference in [path, String(path.dropFirst()), url(harness).absoluteString + path] {
      XCTAssertEqual(client.attachmentFileID(reference: reference, sessionID: "a"), "f")
    }
    for reference in [
      "https://other.invalid" + mount + path,
      "https://127.0.0.1:\(harness.port)/other" + path,
      url(harness).absoluteString + path + "?token=example",
    ] {
      XCTAssertNil(client.attachmentFileID(reference: reference, sessionID: "a"))
    }
    for identity in [nil, "bob"] as [String?] {
      let attachment = UploadedAttachment(
        serverURL: url(harness), sessionID: "a", id: "f",
        filename: "example.txt", isImage: false, userID: identity)
      do {
        _ = try await client.submitMessage("", attachments: [attachment], to: "a")
        XCTFail("Cross-account attachment accepted")
      } catch { XCTAssertEqual(error as? AttachmentUploadError, .wrongSession) }
    }
    XCTAssertEqual(harness.requests.count, 2)
  }

  func testNotificationScopeIncludesMountAndAccount() throws {
    let first = try XCTUnwrap(
      NotificationScope(
        serverURL: "https://EXAMPLE.invalid:443/api/one/",
        userID: "alice"))
    XCTAssertEqual(first.serverURL, "https://example.invalid/api/one")
    XCTAssertNotEqual(
      first,
      NotificationScope(
        serverURL: "https://example.invalid/api/two",
        userID: "alice"))
    XCTAssertNotEqual(first, NotificationScope(serverURL: first.serverURL, userID: "bob"))
  }

  func testAccountLoginUsesActualContractAndDoesNotCarryAmbientCredentials() async throws {
    let harness = TransportHarness()
    harness.respond(
      path: mount + "/v1/info",
      body: #"{"single_user":false,"accounts_enabled":true,"login_url":"/login"}"#)
    harness.respond(
      path: mount + "/auth/login",
      body: "{\"token\":\"\(fixtureToken)\",\"expires_in\":3600,\"user\":{\"id\":\"alice\"}}")
    let client = try auth(harness)
    let started = Date()
    let credential = try await client.login(username: "alice", password: "synthetic-password")
    XCTAssertEqual(credential.userID, "alice")
    XCTAssertEqual(credential.token, fixtureToken)
    XCTAssertGreaterThanOrEqual(credential.expiresAt.timeIntervalSince(started), 3599)
    let request = try XCTUnwrap(harness.requests.last)
    XCTAssertEqual(request.httpMethod, "POST")
    XCTAssertEqual(
      try JSONDecoder().decode([String: String].self, from: request.httpBody!),
      ["username": "alice", "password": "synthetic-password"])
    for request in harness.requests {
      XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
      XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
    }
    XCTAssertFalse(String(reflecting: credential).contains(fixtureToken))
    XCTAssertTrue(Mirror(reflecting: credential).children.isEmpty)
  }

  func testProxyDiscoveryNeverTurnsIntoPasswordOrOIDCLogin() async throws {
    let harness = TransportHarness()
    configure(harness)
    let client = try auth(harness)
    let discovery = try await client.discover()
    XCTAssertEqual(discovery.mode, .proxy)
    await expect(.unsupportedAuthentication) {
      _ = try await client.login(username: "alice", password: "synthetic-password")
    }
    await expect(.unsupportedAuthentication) { _ = try await client.beginBrowserLogin() }
    XCTAssertTrue(harness.requests.allSatisfy { $0.httpMethod == "GET" })
    harness.respond(path: mount + "/v1/info", body: "{}", status: 401)
    await expect(.unauthorized) { _ = try await client.discover() }
  }

  private func configureOIDC(_ harness: TransportHarness) {
    harness.respond(
      path: mount + "/v1/info",
      body: #"{"single_user":false,"accounts_enabled":false,"login_url":"/auth/login"}"#)
    harness.respond(
      path: mount + "/auth/cli-login",
      body: #"{"ticket":"synthetic-ticket","login_url":"/auth/login?ticket=synthetic-ticket"}"#)
  }

  func testOIDCBrowserTicketPendingSuccessExpiryAndServerScope() async throws {
    let harness = TransportHarness()
    configureOIDC(harness)
    let client = try auth(harness)
    let ticket = try await client.beginBrowserLogin()
    XCTAssertEqual(
      ticket.loginURL.absoluteString,
      url(harness).absoluteString + "/auth/login?ticket=synthetic-ticket")
    XCTAssertFalse(String(reflecting: ticket).contains("synthetic-ticket"))
    harness.respond(path: mount + "/auth/cli-poll", body: #"{"status":"pending"}"#, status: 202)
    let pending = try await client.pollBrowserLogin(ticket)
    XCTAssertNil(pending)
    harness.respond(
      path: mount + "/auth/cli-poll",
      body: "{\"token\":\"\(fixtureToken)\",\"user_id\":\"alice\",\"expires_in\":3600}")
    let credential = try await client.pollBrowserLogin(ticket)
    XCTAssertEqual(credential?.userID, "alice")
    XCTAssertEqual(credential?.token, fixtureToken)
    let other = try ServerAuthenticationClient(baseURL: URL(string: "https://other.invalid")!)
    await expect(.redirectNotAllowed) { _ = try await other.pollBrowserLogin(ticket) }
    harness.respond(path: mount + "/auth/cli-poll", body: "{}", status: 410)
    await expect(.browserLoginExpired) { _ = try await client.pollBrowserLogin(ticket) }
  }

  func testOIDCRejectsUntrustedBrowserURLsAndAPIRedirects() async throws {
    let harness = TransportHarness()
    configureOIDC(harness)
    let client = try auth(harness)
    for target in [
      "https://other.invalid/auth/login?ticket=synthetic-ticket",
      "//other.invalid/auth/login?ticket=synthetic-ticket",
      "/auth/login?ticket=synthetic-ticket&return_to=https://other.invalid",
      "/auth/login?ticket=different-ticket",
    ] {
      let body = try JSONEncoder().encode(["ticket": "synthetic-ticket", "login_url": target])
      harness.respond(path: mount + "/auth/cli-login", body: String(decoding: body, as: UTF8.self))
      await expect(.redirectNotAllowed) { _ = try await client.beginBrowserLogin() }
    }
    harness.respond(path: mount + "/v1/info", body: "{}", status: 302)
    await expect(.redirectNotAllowed) { _ = try await client.discover() }
    harness.respond(
      path: mount + "/v1/info", body: "{}",
      responseURL: URL(string: "https://other.invalid/v1/info"))
    await expect(.redirectNotAllowed) { _ = try await client.discover() }
  }

  func testDelegateRejectsRedirectAndUsesPlatformTLSValidation() throws {
    let delegate = ServerTransportDelegate()
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    let target = URL(string: "https://example.invalid/api")!
    let task = session.dataTask(with: target)
    let response = HTTPURLResponse(
      url: target, statusCode: 302, httpVersion: nil, headerFields: nil)!
    var redirected = true
    delegate.urlSession(
      session, task: task, willPerformHTTPRedirection: response,
      newRequest: URLRequest(url: target)
    ) { redirected = $0 != nil }
    XCTAssertFalse(redirected)
    for method in [NSURLAuthenticationMethodServerTrust, NSURLAuthenticationMethodHTTPBasic] {
      let protection = URLProtectionSpace(
        host: "example.invalid", port: 443,
        protocol: "https", realm: nil, authenticationMethod: method)
      let challenge = URLAuthenticationChallenge(
        protectionSpace: protection, proposedCredential: nil,
        previousFailureCount: 0, failureResponse: nil, error: nil, sender: ChallengeSender())
      var disposition: URLSession.AuthChallengeDisposition?
      handleServerChallenge(challenge) { value, credential in
        disposition = value
        XCTAssertNil(credential)
      }
      XCTAssertEqual(
        disposition,
        method == NSURLAuthenticationMethodServerTrust
          ? .performDefaultHandling : .cancelAuthenticationChallenge)
    }
  }
}

private final class ChallengeSender: NSObject, URLAuthenticationChallengeSender {
  func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
  func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
  func cancel(_ challenge: URLAuthenticationChallenge) {}
}
