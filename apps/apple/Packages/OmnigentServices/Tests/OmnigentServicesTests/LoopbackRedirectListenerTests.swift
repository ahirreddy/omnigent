#if os(macOS)
  import Foundation
  import Network
  import Testing

  @testable import OmnigentServices

  @Suite struct LoopbackRedirectListenerTests {
    /// A URL from a string this test built, failing the test when it is malformed.
    private func url(_ string: String) throws -> URL {
      try #require(URL(string: string))
    }

    /// Sends one `GET` with an ephemeral session and returns the status and body.
    private func get(_ url: URL) async throws -> (Int, String) {
      let session = URLSession(configuration: .ephemeral)
      defer { session.finishTasksAndInvalidate() }
      let (data, response) = try await session.data(from: url)
      let status = try #require(response as? HTTPURLResponse).statusCode
      return (status, String(bytes: data, encoding: .utf8) ?? "")
    }

    @Test func receivesTheCallbackWithItsQuery() async throws {
      let listener = LoopbackRedirectListener()
      let redirect = try await listener.start(path: "/oauth/callback")
      #expect(redirect.absoluteString.hasPrefix("http://127.0.0.1:"))
      #expect(redirect.path == "/oauth/callback")

      let waiter = Task { try await listener.waitForCallback() }
      let (status, body) = try await get(url("\(redirect.absoluteString)?code=abc123&state=xyz"))

      #expect(status == 200)
      #expect(body.contains("You can close this window"))
      let callback = try await waiter.value
      #expect(callback.absoluteString == "\(redirect.absoluteString)?code=abc123&state=xyz")
    }

    @Test func otherPathsAreNotFoundAndDoNotCompleteTheWait() async throws {
      let listener = LoopbackRedirectListener()
      let redirect = try await listener.start(path: "/oauth/callback")
      let waiter = Task { try await listener.waitForCallback() }

      let port = try #require(redirect.port)
      let (status, _) = try await get(url("http://127.0.0.1:\(port)/favicon.ico"))
      #expect(status == 404)

      let (ok, _) = try await get(url("\(redirect.absoluteString)?code=late"))
      #expect(ok == 200)
      let callback = try await waiter.value
      #expect(callback.query == "code=late")
    }

    @Test func requestSplitAcrossReadsIsAssembled() async throws {
      let listener = LoopbackRedirectListener()
      let redirect = try await listener.start(path: "/cb")
      let waiter = Task { try await listener.waitForCallback() }
      let port = try #require(redirect.port)
      let endpointPort = try #require(NWEndpoint.Port(rawValue: UInt16(port)))

      let connection = NWConnection(host: "127.0.0.1", port: endpointPort, using: .tcp)
      connection.start(queue: .global())
      try await send(connection, "GET /cb?code=spl")
      try await Task.sleep(for: .milliseconds(100))
      try await send(connection, "it HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")

      let callback = try await waiter.value
      #expect(callback.query == "code=split")
      connection.cancel()
    }

    @Test func nonGetMethodsAreRejected() async throws {
      let listener = LoopbackRedirectListener()
      let redirect = try await listener.start(path: "/cb")
      let waiter = Task { try await listener.waitForCallback() }
      let port = try #require(redirect.port)

      var request = URLRequest(url: try url("http://127.0.0.1:\(port)/cb?code=x"))
      request.httpMethod = "POST"
      let session = URLSession(configuration: .ephemeral)
      defer { session.finishTasksAndInvalidate() }
      let (_, response) = try await session.data(for: request)
      #expect((response as? HTTPURLResponse)?.statusCode == 405)

      listener.cancel()
      await #expect(throws: LoopbackRedirectError.cancelled) {
        _ = try await waiter.value
      }
    }

    @Test func cancellingTheWaiterStopsTheListener() async throws {
      let listener = LoopbackRedirectListener()
      let redirect = try await listener.start(path: "/cb")
      let waiter = Task { try await listener.waitForCallback() }
      waiter.cancel()

      await #expect(throws: LoopbackRedirectError.cancelled) {
        _ = try await waiter.value
      }
      let port = try #require(redirect.port)
      let late = try url("http://127.0.0.1:\(port)/cb?code=after")
      await #expect(throws: (any Error).self) {
        _ = try await get(late)
      }
    }

    @Test func waitingBeforeStartIsAnError() async {
      let listener = LoopbackRedirectListener()
      await #expect(throws: LoopbackRedirectError.notStarted) {
        _ = try await listener.waitForCallback()
      }
    }

    @Test func pathMustStartWithASlash() async {
      let listener = LoopbackRedirectListener()
      await #expect(throws: LoopbackRedirectError.self) {
        _ = try await listener.start(path: "cb")
      }
    }

    @Test func requestLineParsingWaitsForTheWholeHead() {
      #expect(LoopbackRedirectListener.requestLine(in: Data("GET /cb HTTP/1.1\r\n".utf8)) == nil)
      let complete = Data("GET /cb?x=1 HTTP/1.1\r\nHost: a\r\n\r\n".utf8)
      #expect(
        LoopbackRedirectListener.requestLine(in: complete)
          == LoopbackRedirectListener.RequestLine(method: "GET", target: "/cb?x=1"))
      #expect(
        LoopbackRedirectListener.requestLine(in: Data("nonsense\r\n\r\n".utf8))
          == LoopbackRedirectListener.RequestLine(method: "", target: ""))
    }

    /// Sends `text` on `connection`, waiting until the network has accepted it.
    private func send(_ connection: NWConnection, _ text: String) async throws {
      try await withCheckedThrowingContinuation { continuation in
        connection.send(
          content: Data(text.utf8),
          completion: .contentProcessed(continuation.resumeOnSend))
      }
    }
  }

  extension CheckedContinuation where T == Void, E == any Error {
    /// Resumes with success, or with the send error.
    func resumeOnSend(_ error: NWError?) {
      if let error {
        resume(throwing: error)
      } else {
        resume()
      }
    }
  }
#endif
