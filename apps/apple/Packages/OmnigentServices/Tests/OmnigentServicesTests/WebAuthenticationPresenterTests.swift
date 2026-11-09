import AuthenticationServices
import Foundation
import Testing

@testable import OmnigentServices

/// Stands in for the system session, so a whole sign-in runs without a sheet on screen.
@MainActor
private final class FakeSignInSession: WebAuthenticationSessionRunning {
  var presentationContextProvider: (any ASWebAuthenticationPresentationContextProviding)?
  var prefersEphemeralWebBrowserSession = false
  let complete: @Sendable (URL?, (any Error)?) -> Void
  /// What `start()` returns.
  var startsSuccessfully = true
  /// Runs inside `start()`, as a session that finishes at once would.
  var onStart: (@MainActor (FakeSignInSession) -> Void)?
  private(set) var startCount = 0

  init(complete: @escaping @Sendable (URL?, (any Error)?) -> Void) {
    self.complete = complete
  }

  func start() -> Bool {
    startCount += 1
    onStart?(self)
    return startsSuccessfully
  }
}

/// Makes fake sessions and records what each was made from.
@MainActor
private final class FakeSessionFactory {
  private(set) var sessions: [FakeSignInSession] = []
  private(set) var requests: [(url: URL, callback: WebAuthenticationCallback)] = []
  /// Sets up each new session before it starts.
  var configure: (@MainActor (FakeSignInSession) -> Void)?

  func make(
    url: URL, callback: WebAuthenticationCallback,
    completion: @escaping @Sendable (URL?, (any Error)?) -> Void
  ) -> any WebAuthenticationSessionRunning {
    let session = FakeSignInSession(complete: completion)
    configure?(session)
    sessions.append(session)
    requests.append((url, callback))
    return session
  }
}

@MainActor
private final class FixedAnchorProvider: WebAuthenticationAnchorProviding {
  let anchor = ASPresentationAnchor()

  func presentationAnchor() -> ASPresentationAnchor? { anchor }
}

@MainActor
@Suite("Web sign-in, driven through a fake session") struct WebAuthenticationPresenterTests {
  private let page = URL(filePath: "/authorize")
  private let scheme = WebAuthenticationCallback.customScheme("ai.omnigent")

  private func callbackURL() throws -> URL {
    try #require(URL(string: "ai.omnigent:/cb?code=1"))
  }

  /// A sign-in that finishes inside `start()` with `callbackURL` and `error`.
  private func factory(finishingWith callbackURL: URL?, error: (any Error)?) -> FakeSessionFactory {
    let factory = FakeSessionFactory()
    factory.configure = { session in
      session.onStart = { $0.complete(callbackURL, error) }
    }
    return factory
  }

  @Test("A finished sign-in returns the callback the session got")
  func succeeds() async throws {
    let expected = try callbackURL()
    let factory = factory(finishingWith: expected, error: nil)
    let presenter = WebAuthenticationPresenter(makeSession: factory.make)

    let result = try await presenter.authenticate(
      url: page, callback: scheme, anchorProvider: FixedAnchorProvider())

    #expect(result == expected)
    #expect(factory.requests.map(\.url) == [page])
    #expect(factory.requests.map(\.callback) == [scheme])
    #expect(factory.sessions.first?.startCount == 1)
  }

  @Test("Ephemeral is what the caller asked for, either way", arguments: [true, false])
  func ephemeral(prefersEphemeral: Bool) async throws {
    let factory = factory(finishingWith: try callbackURL(), error: nil)
    _ = try await WebAuthenticationPresenter(makeSession: factory.make).authenticate(
      url: page, callback: scheme, prefersEphemeralSession: prefersEphemeral,
      anchorProvider: FixedAnchorProvider())
    #expect(factory.sessions.first?.prefersEphemeralWebBrowserSession == prefersEphemeral)
  }

  @Test("The sheet attaches to the window the sign-in started from")
  func anchorIsTheProvidersWindow() async throws {
    let provider = FixedAnchorProvider()
    let factory = factory(finishingWith: try callbackURL(), error: nil)
    let system = ASWebAuthenticationSession(
      url: page, callback: scheme.sessionCallback, completionHandler: { _, _ in })
    let shownOn = ShownOnRecorder()
    let configure = factory.configure
    factory.configure = { session in
      configure?(session)
      let finish = session.onStart
      session.onStart = { started in
        shownOn.window = started.presentationContextProvider?.presentationAnchor(for: system)
        finish?(started)
      }
    }

    _ = try await WebAuthenticationPresenter(makeSession: factory.make).authenticate(
      url: page, callback: scheme, anchorProvider: provider)

    #expect(shownOn.window === provider.anchor)
  }

  @Test("Dismissing the sheet reads as a cancellation")
  func dismissed() async {
    let factory = factory(
      finishingWith: nil, error: ASWebAuthenticationSessionError(.canceledLogin))
    await #expect(throws: WebAuthenticationError.cancelled) {
      _ = try await WebAuthenticationPresenter(makeSession: factory.make).authenticate(
        url: page, callback: scheme, anchorProvider: FixedAnchorProvider())
    }
  }

  @Test("A session that can't start fails the sign-in, and the next sign-in still runs")
  func cannotStart() async throws {
    let factory = FakeSessionFactory()
    factory.configure = { $0.startsSuccessfully = false }
    let presenter = WebAuthenticationPresenter(makeSession: factory.make)

    await #expect(
      throws: WebAuthenticationError.failed(message: "The sign-in session could not start.")
    ) {
      _ = try await presenter.authenticate(
        url: page, callback: scheme, anchorProvider: FixedAnchorProvider())
    }

    let expected = try callbackURL()
    factory.configure = { session in session.onStart = { $0.complete(expected, nil) } }
    let second = try await presenter.authenticate(
      url: page, callback: scheme, anchorProvider: FixedAnchorProvider())
    #expect(second == expected)
  }

  @Test("A session that reports its failure twice doesn't crash the app")
  func failureReportedTwice() async {
    let factory = factory(finishingWith: nil, error: URLError(.cannotConnectToHost))
    let configure = factory.configure
    factory.configure = { session in
      configure?(session)
      session.startsSuccessfully = false
    }
    await #expect(throws: WebAuthenticationError.self) {
      _ = try await WebAuthenticationPresenter(makeSession: factory.make).authenticate(
        url: page, callback: scheme, anchorProvider: FixedAnchorProvider())
    }
    #expect(factory.sessions.count == 1)
  }

  @Test("A second sign-in is refused while the first is open, and the first still finishes")
  func secondWhileOpen() async throws {
    let factory = FakeSessionFactory()
    let presenter = WebAuthenticationPresenter(makeSession: factory.make)
    let page = page
    let scheme = scheme
    let provider = FixedAnchorProvider()
    let first = Task {
      try await presenter.authenticate(url: page, callback: scheme, anchorProvider: provider)
    }
    while factory.sessions.isEmpty { await Task.yield() }

    await #expect(
      throws: WebAuthenticationError.failed(message: "A sign-in is already in progress.")
    ) {
      _ = try await presenter.authenticate(url: page, callback: scheme, anchorProvider: provider)
    }
    #expect(factory.sessions.count == 1)

    let expected = try callbackURL()
    factory.sessions.first?.complete(expected, nil)
    #expect(try await first.value == expected)
  }

  @Test("The real factory builds a system session without starting it")
  func systemSession() {
    let session = WebAuthenticationPresenter.makeSystemSession(
      url: page, callback: scheme, completion: { _, _ in })
    #expect(session is ASWebAuthenticationSession)
  }

  @Test("Each callback form reaches the system as the same redirect")
  func callbackForms() throws {
    let custom = WebAuthenticationCallback.customScheme("ai.omnigent").sessionCallback
    #expect(custom.matchesURL(try callbackURL()))
    #expect(!custom.matchesURL(try #require(URL(string: "https://example.com/cb"))))

    let https = WebAuthenticationCallback.https(host: "example.com", path: "/cb").sessionCallback
    #expect(https.matchesURL(try #require(URL(string: "https://example.com/cb?code=1"))))
    #expect(!https.matchesURL(try #require(URL(string: "https://example.com/other"))))
    #expect(!https.matchesURL(try #require(URL(string: "https://example.org/cb"))))
  }
}

/// Holds the window a session was given.
@MainActor
private final class ShownOnRecorder {
  var window: ASPresentationAnchor?
}
