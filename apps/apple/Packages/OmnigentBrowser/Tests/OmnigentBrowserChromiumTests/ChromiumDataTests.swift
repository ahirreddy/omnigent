import Foundation
import OWLProtocol
import OmnigentBrowser
import Testing

#if os(macOS)
  @testable import OmnigentBrowserChromium
  @testable import OmnigentWebLayer

  /// A value whose encoding fails, as a broken encoder would.
  private struct RefusesToEncode: Encodable {
    func encode(to encoder: any Encoder) throws {
      throw CocoaError(.coderInvalidValue)
    }
  }

  @MainActor
  @Suite("Chromium profile data", .serialized)
  struct ChromiumDataTests {
    private let profile = BrowserProfile(identifier: "tests", persistence: .ephemeral)

    @Test("DevTools parameters that can't be encoded fail instead of being sent")
    func parametersRefused() throws {
      #expect(throws: WebLayerError.self) {
        _ = try ChromiumBrowserEngine.json(RefusesToEncode())
      }
      #expect(throws: WebLayerError.self) {
        _ = try ChromiumBrowserEngine.utf8Text(Data([0xFF]))
      }
      #expect(try ChromiumBrowserEngine.json(["a": "b"]) == #"{"a":"b"}"#)
    }

    /// Runs one removal, answering each DevTools call, and returns how many it made.
    private func answeredCalls(
      _ fixture: ChromiumTabFixture, types: BrowserDataTypes, origins: [URL]
    ) async throws -> Int {
      let engine = fixture.engine
      let profile = self.profile
      var finished = false
      let removal = Task {
        defer { finished = true }
        try await engine.removeData(types, for: profile, since: nil, origins: origins)
      }
      var answered = 0
      let deadline = ContinuousClock.now + .seconds(30)
      while !finished, ContinuousClock.now < deadline {
        if fixture.session.replies.isEmpty {
          await Task.yield()
        } else {
          try await fixture.answer(WireEncoder().bool(.success, true).string(.JSON, "{}"))
          answered += 1
        }
      }
      try await removal.value
      return answered
    }

    @Test func typesTheEngineDoesNotHoldDoNothing() async throws {
      let fixture = try ChromiumTabFixture()
      let view = fixture.webView
      try await fixture.engine.removeData([], for: profile, since: nil, origins: [])
      #expect(fixture.sent.isEmpty)
      #expect(view.status == .live)
    }

    @Test func cookiesCacheAndSiteDataEachCallDevTools() async throws {
      let fixture = try ChromiumTabFixture()
      try fixture.connect()
      defer { fixture.session.tearDownConnection() }
      let origins = try [
        "https://a.test/path", "https://a.test/other", "http://b.test:8080/", "ftp://c.test/",
        "file:///etc/passwd", "about:blank", "https:///no-host", "data:text/plain,x",
      ].map { try #require(URL(string: $0)) }
      #expect(
        try await answeredCalls(fixture, types: [.cookies, .cache, .siteData], origins: origins)
          == 4)
      #expect(try await answeredCalls(fixture, types: [.siteData], origins: []) == 0)
      #expect(try await answeredCalls(fixture, types: [.cookies], origins: origins) == 1)
    }

    @Test func aFailingCallBecomesABrowserError() async throws {
      let fixture = try ChromiumTabFixture()
      try fixture.connect()
      defer { fixture.session.tearDownConnection() }
      let engine = fixture.engine
      let profile = self.profile
      let removal = Task {
        try await engine.removeData(.cookies, for: profile, since: nil, origins: [])
      }
      try await fixture.answer(WireEncoder().string(.JSON, #"{"message":"nope"}"#))
      await #expect(
        throws: BrowserError.devToolsFailed(method: "Network.clearBrowserCookies", message: "nope")
      ) {
        try await removal.value
      }
    }

    @Test func removingDataWhenTheHostFailedIsAnEngineError() async throws {
      let fixture = try ChromiumTabFixture()
      fixture.session.state = .failed(.hostExited(status: 1, reason: "gone"))
      await #expect(throws: BrowserError.self) {
        try await fixture.engine.removeData(.cookies, for: profile, since: nil, origins: [])
      }
    }

    @Test func removingDataMakesAHiddenViewWhenNoneIsLive() async throws {
      let fixture = try ChromiumTabFixture()
      fixture.webView.status = .waitingForHost
      let other = BrowserProfile(identifier: "other", persistence: .persistent)
      let removal = Task {
        try await fixture.engine.removeData(.cookies, for: other, since: nil, origins: [])
      }
      let webProfile = fixture.session.existingProfile(
        identifier: "other", persistence: .persistent)
      #expect(await fixture.eventually { webProfile != nil || !fixture.sent.isEmpty })
      removal.cancel()
      #expect(
        await fixture.eventually {
          fixture.session.profile(identifier: "other", persistence: .persistent).views.count <= 1
        })
      if let view = fixture.session.profile(identifier: "other", persistence: .persistent).views
        .first
      {
        view.status = .unavailable(.notReady)
      }
      await #expect(throws: BrowserError.self) { try await removal.value }
    }

    @Test func deletingAnEphemeralProfileClosesItAndIgnoresUnknownOnes() async throws {
      let fixture = try ChromiumTabFixture()
      try await fixture.engine.deleteProfileData(profile)
      #expect(fixture.webView.status == .closed)
      for identifier in ["", "\u{0}", "../..", String(repeating: "W", count: 100_000)] {
        try await fixture.engine.deleteProfileData(
          BrowserProfile(identifier: identifier, persistence: .ephemeral))
      }
    }

    @Test func deletingAPersistentProfileRemovesOnlyItsDirectory() async throws {
      let fixture = try ChromiumTabFixture()
      let sibling = fixture.root.appending(path: "keep-me")
      try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
      for identifier in ["persistent", "", "\u{0}", "../..", "../keep-me", "/", "👩‍👩‍👧‍👦"] {
        try await fixture.engine.deleteProfileData(
          BrowserProfile(identifier: identifier, persistence: .persistent))
      }
      #expect(FileManager.default.fileExists(atPath: sibling.path))
    }
  }
#endif
