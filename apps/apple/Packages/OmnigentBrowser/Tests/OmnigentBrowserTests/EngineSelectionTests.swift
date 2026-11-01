import Foundation
import Testing

@testable import OmnigentBrowser

#if os(macOS)
  import AppKit
#else
  import UIKit
#endif

@MainActor
final class FakeTab: BrowserTab {
  let engineKind: BrowserEngineKind
  let profile: BrowserProfile
  let state = BrowserTabState()
  let platformView = BrowserPlatformView(frame: .zero)
  private(set) var loads: [URL] = []
  weak var delegate: (any BrowserTabDelegate)?
  var popupPolicy = BrowserPopupPolicy.requireUserGesture
  var urlPolicy: (any BrowserURLPolicy)?
  let agentInput: any BrowserAgentInput = RecordingAgentInput()

  init(kind: BrowserEngineKind, profile: BrowserProfile, initialURL: URL?) {
    engineKind = kind
    self.profile = profile
    if let initialURL {
      load(initialURL)
    }
  }

  func load(_ url: URL) {
    loads.append(url)
    state.url = url
  }
  func goBack() {}
  func goForward() {}
  func reload() {}
  func stopLoading() {}
  func evaluateJavaScript(_ script: String) throws(BrowserError) -> BrowserScriptValue {
    .undefined
  }
  func takeSnapshotPNG() throws(BrowserError) -> Data { Data() }
  func find(_ text: String, forward: Bool, caseSensitive: Bool) throws(BrowserError)
    -> BrowserFindResult
  {
    BrowserFindResult(matchFound: false, matchCount: nil, activeMatch: nil)
  }
  func showDevTools() throws(BrowserError) {}
  func close() { state.isClosed = true }
}

@MainActor
final class FakeEngine: BrowserEngine {
  let kind: BrowserEngineKind
  private(set) var tabs: [FakeTab] = []

  init(kind: BrowserEngineKind) { self.kind = kind }

  func makeTab(profile: BrowserProfile, initialURL: URL?) throws(BrowserError) -> any BrowserTab {
    let tab = FakeTab(kind: kind, profile: profile, initialURL: initialURL)
    tabs.append(tab)
    return tab
  }
}

@MainActor
final class FakeProvider: BrowserEngineProvider {
  var failures: [BrowserEngineKind: BrowserError] = [:]
  var engines: [BrowserEngineKind: FakeEngine] = [:]
  private(set) var requests: [BrowserEngineKind] = []

  func availability(of kind: BrowserEngineKind) -> BrowserEngineAvailability {
    failures[kind].map { .unavailable($0) } ?? .available
  }

  func engine(for kind: BrowserEngineKind) throws(BrowserError) -> any BrowserEngine {
    requests.append(kind)
    if let failure = failures[kind] {
      throw failure
    }
    if let engine = engines[kind] {
      return engine
    }
    let engine = FakeEngine(kind: kind)
    engines[kind] = engine
    return engine
  }
}

func isolatedDefaults() throws -> UserDefaults {
  let suite = "OmnigentBrowserTests.\(UUID().uuidString)"
  return try #require(UserDefaults(suiteName: suite))
}

func testURL(_ string: String) throws -> URL {
  try #require(URL(string: string))
}

@Suite("Engine kinds")
struct EngineKindTests {
  @Test func displayNames() {
    #expect(BrowserEngineKind.system.displayName == "System (WebKit)")
    #expect(BrowserEngineKind.chromium.displayName == "Chromium")
  }

  @Test func platformSupport() {
    #if os(macOS)
      #expect(BrowserEngineKind.supportedOnThisPlatform == [.chromium, .system])
    #else
      #expect(BrowserEngineKind.supportedOnThisPlatform == [.system])
    #endif
  }

  @Test func rawValuesAreStable() {
    #expect(BrowserEngineKind.chromium.rawValue == "chromium")
    #expect(BrowserEngineKind.system.rawValue == "system")
  }
}

@MainActor
@Suite("Preferences")
struct PreferencesTests {
  @Test func defaultPrefersChromiumOnlyWhenAvailable() {
    let unavailable = BrowserEngineAvailability.unavailable(
      .engineNotBundled(.chromium, reason: "missing"))
    #expect(BrowserPreferences.defaultEngine(chromiumAvailability: unavailable) == .system)
    #if os(macOS)
      #expect(BrowserPreferences.defaultEngine(chromiumAvailability: .available) == .chromium)
    #else
      #expect(BrowserPreferences.defaultEngine(chromiumAvailability: .available) == .system)
    #endif
  }

  @Test func defaultFollowsProvider() throws {
    let provider = FakeProvider()
    provider.failures[.chromium] = .engineNotBundled(.chromium, reason: "missing")
    let preferences = BrowserPreferences(defaults: try isolatedDefaults(), provider: provider)
    #expect(preferences.engine == .system)
    #expect(preferences.storedEngine == nil)
  }

  @Test func choiceIsPersisted() throws {
    let defaults = try isolatedDefaults()
    let preferences = BrowserPreferences(defaults: defaults, defaultEngine: .chromium)
    preferences.engine = .system
    #expect(defaults.string(forKey: BrowserPreferences.engineDefaultsKey) == "system")
    let reloaded = BrowserPreferences(defaults: defaults, defaultEngine: .chromium)
    #expect(reloaded.engine == .system)
    #expect(reloaded.storedEngine == .system)
    reloaded.resetToDefault()
    #expect(reloaded.engine == .chromium)
    #expect(defaults.string(forKey: BrowserPreferences.engineDefaultsKey) == nil)
  }

  @Test func unknownStoredValueFallsBackToDefault() throws {
    let defaults = try isolatedDefaults()
    defaults.set("gecko", forKey: BrowserPreferences.engineDefaultsKey)
    let preferences = BrowserPreferences(defaults: defaults, defaultEngine: .system)
    #expect(preferences.storedEngine == nil)
    #expect(preferences.engine == .system)
  }
}

@MainActor
@Suite("Controller fallback")
struct ControllerTests {
  @Test func failedEngineIsSurfacedNotSwapped() throws {
    let provider = FakeProvider()
    let failure = BrowserError.engineFailedToStart(.chromium, reason: "boom")
    provider.failures[.chromium] = failure
    let preferences = BrowserPreferences(defaults: try isolatedDefaults(), defaultEngine: .chromium)
    let controller = BrowserController(
      profile: .server("a"), preferences: preferences, provider: provider,
      initialURL: try testURL("https://example.com"))

    controller.activate()

    guard case .engineUnavailable(let requested, let error) = controller.content else {
      Issue.record("expected engineUnavailable, got \(controller.content)")
      return
    }
    #expect(requested == .chromium)
    #expect(error == failure)
    #expect(provider.requests == [.chromium])
    #expect(preferences.engine == .chromium)
    #expect(controller.tab == nil)
  }

  @Test func explicitSwitchUsesSystemAndPersists() throws {
    let provider = FakeProvider()
    provider.failures[.chromium] = .engineFailedToStart(.chromium, reason: "boom")
    let preferences = BrowserPreferences(defaults: try isolatedDefaults(), defaultEngine: .chromium)
    let url = try testURL("https://example.com")
    let controller = BrowserController(
      profile: .server("a"), preferences: preferences, provider: provider, initialURL: url)
    controller.activate()

    controller.switchEngine(to: .system)

    let tab = try #require(controller.tab as? FakeTab)
    #expect(tab.engineKind == .system)
    #expect(tab.loads == [url])
    #expect(tab.profile == .server("a"))
    #expect(preferences.storedEngine == .system)
  }

  @Test func switchingPreservesCurrentURLAndClosesOldTab() throws {
    let provider = FakeProvider()
    let preferences = BrowserPreferences(defaults: try isolatedDefaults(), defaultEngine: .system)
    let controller = BrowserController(
      profile: .server("a"), preferences: preferences, provider: provider,
      initialURL: try testURL("https://example.com"))
    controller.activate()
    let first = try #require(controller.tab as? FakeTab)
    let navigated = try testURL("https://example.org/page")
    first.load(navigated)

    controller.switchEngine(to: .chromium)

    let second = try #require(controller.tab as? FakeTab)
    #expect(first.state.isClosed)
    #expect(second.engineKind == .chromium)
    #expect(second.loads == [navigated])
  }

  @Test func activateIsIdempotent() throws {
    let provider = FakeProvider()
    let preferences = BrowserPreferences(defaults: try isolatedDefaults(), defaultEngine: .system)
    let controller = BrowserController(
      profile: .server("a"), preferences: preferences, provider: provider, initialURL: nil)
    controller.activate()
    controller.activate()
    #expect(provider.engines[.system]?.tabs.count == 1)
  }

  @Test func addressParsing() throws {
    #expect(
      try BrowserController.url(fromAddressText: " example.com ").absoluteString
        == "https://example.com")
    #expect(
      try BrowserController.url(fromAddressText: "http://localhost:8080").absoluteString
        == "http://localhost:8080")
    #expect(throws: BrowserError.invalidURL("two words")) {
      try BrowserController.url(fromAddressText: "two words")
    }
    #expect(throws: BrowserError.invalidURL("")) {
      try BrowserController.url(fromAddressText: "")
    }
  }
}

@MainActor
final class FakeFactory: BrowserEngineFactory {
  let kind: BrowserEngineKind
  var startError: BrowserError?
  private(set) var starts = 0

  init(kind: BrowserEngineKind) { self.kind = kind }

  func availability() -> BrowserEngineAvailability { .available }

  func start() throws(BrowserError) -> any BrowserEngine {
    starts += 1
    if let startError { throw startError }
    return FakeEngine(kind: kind)
  }
}

@MainActor
@Suite("Default provider")
struct DefaultProviderTests {
  @Test func withoutRegisteredEnginesOffersOnlySystem() throws {
    let provider = DefaultBrowserEngineProvider()
    #expect(provider.offeredEngines == [.system])
    #expect(provider.availability(of: .system) == .available)
    #if os(macOS)
      guard
        case .unavailable(.engineNotBundled(.chromium, _)) = provider.availability(of: .chromium)
      else {
        Issue.record("expected engineNotBundled for an unregistered engine")
        return
      }
    #endif
    #expect(throws: BrowserError.self) { try provider.engine(for: .chromium) }

    let preferences = BrowserPreferences(defaults: try isolatedDefaults(), provider: provider)
    #expect(preferences.defaultEngine == .system)
    #expect(preferences.allowedEngines == [.system])
  }

  @Test func storedChoiceOutsideTheBuildIsIgnored() throws {
    let defaults = try isolatedDefaults()
    defaults.set("chromium", forKey: BrowserPreferences.engineDefaultsKey)
    let preferences = BrowserPreferences(
      defaults: defaults, provider: DefaultBrowserEngineProvider())
    #expect(preferences.storedEngine == nil)
    #expect(preferences.engine == .system)
  }

  #if os(macOS)
    @Test func registeredEngineIsOfferedAndPreferred() throws {
      let factory = FakeFactory(kind: .chromium)
      let provider = DefaultBrowserEngineProvider(additionalEngines: [factory])
      #expect(provider.offeredEngines == [.chromium, .system])
      #expect(provider.availability(of: .chromium) == .available)
      let preferences = BrowserPreferences(defaults: try isolatedDefaults(), provider: provider)
      #expect(preferences.defaultEngine == .chromium)

      let first = try provider.engine(for: .chromium)
      let second = try provider.engine(for: .chromium)
      #expect(first === second)
      #expect(factory.starts == 1)
    }

    @Test func startFailureIsSticky() {
      let factory = FakeFactory(kind: .chromium)
      let failure = BrowserError.engineFailedToStart(.chromium, reason: "boom")
      factory.startError = failure
      let provider = DefaultBrowserEngineProvider(additionalEngines: [factory])
      #expect(throws: failure) { try provider.engine(for: .chromium) }
      #expect(throws: failure) { try provider.engine(for: .chromium) }
      #expect(factory.starts == 1)
      #expect(provider.availability(of: .chromium) == .unavailable(failure))
    }
  #endif
}
