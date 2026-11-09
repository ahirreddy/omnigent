#if os(macOS)
  import Foundation
  import Network
  import Testing

  @testable import OmnigentServices

  /// What happens when the socket underneath the sign-in redirect fails.
  extension LoopbackRedirectListenerTests {
    private func failedMessage(of error: LoopbackRedirectError?) -> String? {
      guard case .failed(let message) = error else { return nil }
      return message
    }

    /// The error `body` threw, typed.
    private func redirectError(
      _ body: () async throws(LoopbackRedirectError) -> URL
    ) async -> LoopbackRedirectError? {
      do {
        _ = try await body()
        return nil
      } catch {
        return error
      }
    }

    @Test func aListenerThatCannotBeCreatedFailsTheStart() async {
      let listener = LoopbackRedirectListener(makeListener: { _ in throw NWError.posix(.EMFILE) })
      let error = await redirectError { () throws(LoopbackRedirectError) in
        try await listener.start(path: "/cb")
      }
      #expect(failedMessage(of: error)?.contains("could not be created") == true)
      // It never bound anything, so there is nothing to wait for.
      let wait = await redirectError { () throws(LoopbackRedirectError) in
        try await listener.waitForCallback()
      }
      #expect(wait == .notStarted)
    }

    /// Another process holding the port is the failure a real listener can hit.
    @Test func aPortAlreadyInUseFailsTheStartAndAnyLaterWait() async throws {
      let holder = LoopbackRedirectListener()
      defer { holder.cancel() }
      let held = try await holder.start(path: "/cb")
      let heldPort = try #require(held.port)
      let port = try #require(NWEndpoint.Port(rawValue: UInt16(heldPort)))

      let listener = LoopbackRedirectListener(makeListener: {
        try NWListener(using: $0, on: port)
      })
      let error = await redirectError { () throws(LoopbackRedirectError) in
        try await listener.start(path: "/cb")
      }
      #expect(failedMessage(of: error)?.contains("The listener failed") == true)
      let wait = await redirectError { () throws(LoopbackRedirectError) in
        try await listener.waitForCallback()
      }
      #expect(wait == error)
    }

    @Test func readyWithoutAPortEndsTheWaitInsteadOfHanging() async {
      let listener = LoopbackRedirectListener()
      listener.listenerStateChanged(.ready)
      let wait = await redirectError { () throws(LoopbackRedirectError) in
        try await listener.waitForCallback()
      }
      #expect(wait == .failed(message: "The listener is ready without a port."))
    }

    @Test func aConnectionThatArrivesAfterTheEndIsClosed() async throws {
      let listener = LoopbackRedirectListener()
      let redirect = try await listener.start(path: "/cb")
      let connection = try connect(to: redirect)
      listener.cancel()

      listener.accept(connection)

      #expect(await eventually { connection.state == .cancelled })
    }

    @Test func aFailedReadClosesThatConnectionAndTheWaitGoesOn() async throws {
      let listener = LoopbackRedirectListener()
      let redirect = try await listener.start(path: "/cb")
      let waiter = Task { try await listener.waitForCallback() }
      let connection = try connect(to: redirect)

      let completion = listener.receiveCompletion(LoopbackConnection(connection), buffer: Data())
      completion(Data("GET /cb?code=lost HTTP/1.1\r\n\r\n".utf8), nil, false, .posix(.ECONNRESET))

      #expect(await eventually { connection.state == .cancelled })
      let (status, _) = try await get(try url("\(redirect.absoluteString)?code=later"))
      #expect(status == 200)
      #expect(try await waiter.value.query == "code=later")
    }

    @Test(arguments: [NWError?.none, .posix(.EPIPE)])
    func aConnectionClosesOnceItsAnswerIsWrittenOrLost(failure: NWError?) async throws {
      let listener = LoopbackRedirectListener()
      defer { listener.cancel() }
      let connection = try connect(to: try await listener.start(path: "/cb"))

      listener.sendCompletion(LoopbackConnection(connection))(failure)

      #expect(await eventually { connection.state == .cancelled })
    }

    /// Port and path are the listener's own; everything else comes off the wire.
    @Test func eachRequestGetsTheRightAnswer() throws {
      typealias Line = LoopbackRedirectListener.RequestLine
      func decide(_ line: Line, port: UInt16? = 8_080) -> LoopbackRedirectListener.RequestDecision {
        LoopbackRedirectListener.decision(
          for: line, expectedPath: "/cb", port: port, host: "localhost")
      }
      let malformed = LoopbackRedirectListener.RequestDecision.refuse(
        status: 400, reason: "Bad Request", body: "Malformed request.")
      let notFound = LoopbackRedirectListener.RequestDecision.refuse(
        status: 404, reason: "Not Found", body: "Not found.")

      #expect(decide(Line(method: "", target: "")) == malformed)
      #expect(
        decide(Line(method: "POST", target: "/cb"))
          == .refuse(status: 405, reason: "Method Not Allowed", body: "Method not allowed."))
      #expect(decide(Line(method: "GET", target: "/other")) == notFound)
      #expect(decide(Line(method: "GET", target: "/cb/more?code=1")) == notFound)
      #expect(decide(Line(method: "GET", target: "?code=1")) == notFound)
      #expect(decide(Line(method: "GET", target: "/cb?code=1"), port: nil) == malformed)
      #expect(
        decide(Line(method: "GET", target: "/cb?code=1"))
          == .complete(try url("http://localhost:8080/cb?code=1")))
      #expect(
        decide(Line(method: "GET", target: "/cb"))
          == .complete(try url("http://localhost:8080/cb")))
    }

    @Test func noRedirectURLWithoutAPort() {
      #expect(
        LoopbackRedirectListener.callbackURL(host: "localhost", port: nil, target: "/cb")
          == .failure(.failed(message: "The redirect URL could not be formed for /cb.")))
    }
  }
#endif
