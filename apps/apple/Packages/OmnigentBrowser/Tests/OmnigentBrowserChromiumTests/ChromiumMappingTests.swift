import Foundation
import OmnigentBrowser
import Testing

#if os(macOS)
  @testable import OmnigentBrowserChromium
  @testable import OmnigentWebLayer

  @MainActor
  @Suite("Chromium error and value mapping")
  struct ChromiumMappingTests {
    @Test func hostFailuresMapToEngineErrorsWithTheirDescription() {
      let failedToStart: [WebLayerError] = [
        .launchFailed("a"), .channelFailed("a"), .handshakeFailed("a"),
        .protocolMismatch(host: "1", client: "2"), .hostInitializationFailed("a"),
        .hostTimedOut(phase: "p", seconds: 1), .renderingUnavailable("a"),
      ]
      for error in failedToStart {
        #expect(
          ChromiumBrowserTab.convert(error)
            == .engineFailedToStart(.chromium, reason: error.localizedDescription), "\(error)")
      }
      let missing = WebLayerError.hostNotBundled(path: "/x")
      #expect(
        ChromiumBrowserTab.convert(missing)
          == .engineNotBundled(.chromium, reason: missing.localizedDescription))
      let stopped = WebLayerError.hostUnresponsive(seconds: 1)
      #expect(
        ChromiumBrowserTab.convert(stopped)
          == .engineStopped(.chromium, reason: stopped.localizedDescription))
      for error in [WebLayerError.hostError(code: .max, message: "m"), .invalidArgument("a")] {
        #expect(
          ChromiumBrowserTab.convert(error)
            == .engineError(.chromium, message: error.localizedDescription), "\(error)")
      }
      #expect(ChromiumBrowserTab.convert(.viewClosed) == .tabClosed)
    }

    @Test func pageAndPolicyFailuresKeepTheirDetails() {
      let url = URL(string: "https://example.test/")
      let cases: [(WebLayerError, BrowserError)] = [
        (.navigationBlocked(url: url, reason: "r"), .navigationBlocked(url: url, reason: "r")),
        (.popupBlocked(url: nil, reason: ""), .popupBlocked(url: nil, reason: "")),
        (.promptFinished("p"), .notAllowed("p")),
        (
          .navigationFailed(url: nil, code: .min, message: "m"),
          .navigationFailed(url: nil, code: .min, message: "m")
        ),
        (.navigationCancelled(url: url), .navigationCancelled(url: url)),
        (.rendererTerminated("r"), .contentProcessTerminated(reason: "r")),
        (.unsupportedScriptResult("t"), .unsupportedScriptResult("t")),
        (.devToolsFailed(method: "m", message: ""), .devToolsFailed(method: "m", message: "")),
        (.snapshotFailed("s"), .snapshotFailed("s")),
        (.downloadBlocked(url: nil), .downloadsUnsupported(url: nil)),
        (
          .featureBlocked(feature: "f", detail: "d"),
          .featureUnsupported(feature: "f (d)", engine: .chromium)
        ),
      ]
      for (error, expected) in cases {
        #expect(ChromiumBrowserTab.convert(error) == expected, "\(error)")
      }
    }

    @Test func scriptValuesConvertAtDepthAndWithOddNumbers() {
      var nested = WebScriptValue.string("\u{0}")
      var expected = BrowserScriptValue.string("\u{0}")
      for _ in 0..<500 {
        nested = .array([nested])
        expected = .array([expected])
      }
      #expect(ChromiumBrowserTab.convert(nested) == expected)
      #expect(ChromiumBrowserTab.convert(.undefined) == .undefined)
      #expect(ChromiumBrowserTab.convert(.number(.infinity)) == .number(.infinity))
      guard case .number(let notANumber) = ChromiumBrowserTab.convert(.number(.nan)) else {
        Issue.record("expected a number")
        return
      }
      #expect(notANumber.isNaN)
      #expect(ChromiumBrowserTab.convert(.object([:])) == .object([:]))
    }

    @Test func policiesConvert() {
      #expect(ChromiumBrowserTab.webPolicy(.allow) == .allow)
      #expect(ChromiumBrowserTab.webPolicy(.block) == .block)
      #expect(ChromiumBrowserTab.webPolicy(.requireUserGesture) == .requireUserGesture)
      var rules = BrowserURLRules()
      rules.schemes = ["\u{0}"]
      rules.allow = [""]
      rules.deny = ["*"]
      rules.blockPrivateAddresses = true
      rules.allowLoopback = true
      let converted = ChromiumBrowserTab.webRules(rules)
      #expect(converted.schemes == rules.schemes)
      #expect(converted.allow == rules.allow)
      #expect(converted.deny == rules.deny)
      #expect(converted.blockPrivateAddresses)
      #expect(converted.allowLoopback)
    }
  }

  @MainActor
  @Suite("Chromium engine availability", .serialized)
  struct ChromiumAvailabilityTests {
    private func configuration(_ host: URL) -> ChromiumConfiguration {
      ChromiumConfiguration(
        session: SessionConfiguration(
          hostAppURL: host, rootCacheURL: FileManager.default.temporaryDirectory))
    }

    /// A folder laid out like the host app, whose executable never runs.
    private func fakeHost() throws -> URL {
      let app = FileManager.default.temporaryDirectory
        .appending(path: "owl-chromium-tests-\(UUID().uuidString)")
        .appending(path: "\(SessionConfiguration.hostAppName).app")
      let directory = app.appending(path: "Contents/MacOS")
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let executable = directory.appending(path: SessionConfiguration.hostAppName)
      try "#!/bin/sh\nexit 1\n".write(to: executable, atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: executable.path)
      return app
    }

    @Test func aMissingOrNonExecutableHostIsNotBundled() throws {
      let app = try fakeHost()
      defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
      let executable = app.appending(path: "Contents/MacOS/\(SessionConfiguration.hostAppName)")
      #expect(ChromiumBrowserEngine.availability(configuration: configuration(app)) == .available)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o644], ofItemAtPath: executable.path)
      guard
        case .unavailable(.engineNotBundled(.chromium, _)) =
          ChromiumBrowserEngine.availability(configuration: configuration(app))
      else {
        Issue.record("expected engineNotBundled")
        return
      }
    }

    @Test func oddHostPathsAreNotBundledAndStartRefuses() throws {
      let urls = [
        URL(fileURLWithPath: ""), URL(fileURLWithPath: "/"), URL(fileURLWithPath: "/\u{0}"),
        URL(fileURLWithPath: "/" + String(repeating: "x", count: 10_000)),
        try #require(URL(string: "https://example.test/Host.app")),
      ]
      for url in urls {
        let factory = ChromiumEngineFactory(configuration: configuration(url))
        #expect(factory.kind == .chromium)
        if case .available = factory.availability() { Issue.record("\(url) is not a host") }
        #expect(throws: BrowserError.self) { try factory.start() }
      }
    }

    @Test("a bundled host starts, and the engine owns its session")
    func startsABundledHost() throws {
      let app = try fakeHost()
      defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
      let started = try ChromiumEngineFactory(configuration: configuration(app)).start()
      let engine = try #require(started as? ChromiumBrowserEngine)
      defer { engine.session.shutdown() }
      #expect(engine.kind == .chromium)
      #expect(engine.session.configuration.hostAppURL == app)
      #expect(engine.session.process != nil || engine.session.state != .idle)
    }

    @Test func insideAppSandboxTheHostNeedsItsOwnSandboxOff() throws {
      let app = try fakeHost()
      defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
      setenv("APP_SANDBOX_CONTAINER_ID", "test", 1)
      defer { unsetenv("APP_SANDBOX_CONTAINER_ID") }
      var settings = configuration(app)
      guard
        case .unavailable(.engineFailedToStart(.chromium, _)) =
          ChromiumBrowserEngine.availability(configuration: settings)
      else {
        Issue.record("expected engineFailedToStart")
        return
      }
      settings.session.disableSandbox = true
      #expect(ChromiumBrowserEngine.availability(configuration: settings) == .available)
    }

    @Test func theEngineReportsItsHostVersionOnceReady() throws {
      let fixture = try ChromiumTabFixture()
      #expect(fixture.engine.hostVersion == "cef-test")
      #expect(fixture.engine.kind == .chromium)
      fixture.session.state = .idle
      #expect(fixture.engine.hostVersion == nil)
    }
  }
#endif
