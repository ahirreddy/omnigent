import Foundation
import OmnigentViewTesting
import Testing

@testable import OmnigentBrowser

@MainActor
func makeEnvironment(
  directory: URL? = nil, provider: FakeProvider = FakeProvider(),
  engine: BrowserEngineKind = .chromium
) throws -> (BrowserEnvironment, FakeProvider) {
  SystemSideEffects.install()
  let defaults = try isolatedDefaults()
  let presenter = BrowserPromptPresenter(
    permissionStore: BrowserPermissionStore(defaults: defaults),
    credentialStore: InMemoryBrowserCredentialStore(),
    downloadSettings: BrowserDownloadSettings(defaults: defaults),
    downloadCenter: BrowserDownloadCenter())
  let environment = BrowserEnvironment(
    directory: try directory ?? temporaryDirectory(), provider: provider,
    preferences: BrowserPreferences(defaults: defaults, defaultEngine: engine),
    presenter: presenter, defaults: defaults)
  return (environment, provider)
}

@Suite("Restore state")
struct RestoreStateTests {
  static func history() throws -> BrowserNavigationHistory {
    BrowserNavigationHistory(
      entries: [
        BrowserNavigationEntry(url: try testURL("https://a.example/one"), title: "One"),
        BrowserNavigationEntry(
          url: try testURL("https://b.example/two?x=1&y=a+b#frag"), title: "Two & more"),
        BrowserNavigationEntry(url: try testURL("https://c.example/three"), title: "Three"),
      ], currentIndex: 1)
  }

  @Test func codableRoundTripKeepsHistory() throws {
    let state = BrowserTabRestoreState(
      profileID: UUID(), url: try testURL("https://b.example/two"), title: "Two",
      faviconPNG: Data([1, 2, 3]), history: try Self.history(),
      webKitInteractionState: Data([9, 9]), isPinned: true, isMuted: true)
    let data = try JSONEncoder().encode(state)
    let decoded = try JSONDecoder().decode(BrowserTabRestoreState.self, from: data)
    #expect(decoded == state)
    #expect(decoded.history.currentIndex == 1)
    #expect(decoded.history.entries.count == 3)
  }

  @Test func newerVersionsAreRejected() throws {
    var json =
      try JSONSerialization.jsonObject(
        with: JSONEncoder().encode(BrowserTabRestoreState(profileID: UUID(), url: nil)))
      as? [String: Any] ?? [:]
    json["version"] = BrowserTabRestoreState.currentVersion + 1
    let data = try JSONSerialization.data(withJSONObject: json)
    #expect(
      throws: BrowserError.restoreStateUnsupported(
        version: BrowserTabRestoreState.currentVersion + 1)
    ) {
      _ = try JSONDecoder().decode(BrowserTabRestoreState.self, from: data)
    }
  }

  @Test func placeholdersRoundTripSpecialCharacters() throws {
    for entry in try Self.history().entries {
      let fragment = BrowserRestorePlaceholder.fragment(for: entry)
      let url = try testURL("about:blank\(fragment)")
      #expect(BrowserRestorePlaceholder.isPlaceholder(url))
      #expect(BrowserRestorePlaceholder.entry(from: url) == entry)
    }
    #expect(BrowserRestorePlaceholder.isPlaceholder(BrowserRestorePlaceholder.startURL))
    #expect(
      !BrowserRestorePlaceholder.isPlaceholder(try testURL("https://example.com/#omnigent-restore"))
    )
  }

  @Test func savingMapsPlaceholdersAndLimitsLength() throws {
    let real = try Self.history().entries
    let placeholder = try testURL("about:blank\(BrowserRestorePlaceholder.fragment(for: real[0]))")
    let raw = BrowserNavigationHistory(
      entries: [
        BrowserNavigationEntry(url: try testURL("about:blank"), title: ""),
        BrowserNavigationEntry(url: placeholder, title: "about:blank"),
        real[1],
      ], currentIndex: 2)
    let saved = raw.normalizedForSaving()
    #expect(saved.entries == [real[0], real[1]])
    #expect(saved.currentIndex == 1)

    let long = BrowserNavigationHistory(
      entries: try (0..<120).map {
        BrowserNavigationEntry(url: try testURL("https://x.example/\($0)"), title: "")
      },
      currentIndex: 100)
    let trimmed = long.normalizedForSaving()
    #expect(trimmed.entries.count == BrowserNavigationHistory.maximumSavedEntries)
    #expect(trimmed.current?.url == (try testURL("https://x.example/100")))
  }

  @Test func rebuildScriptCarriesEveryEntry() throws {
    let script = BrowserRestorePlaceholder.rebuildScript(for: try Self.history())
    #expect(script.contains("const target = 1;"))
    #expect(script.contains("u=https%3A%2F%2Fb.example%2Ftwo%3Fx%3D1%26y%3Da%2Bb%23frag"))
    #expect(script.contains("history.pushState"))
  }
}

@MainActor
@Suite("Tab model", .serialized)
struct TabModelTests {
  @Test func restoreIsLazyAndRoundTripsBeforeActivation() throws {
    let (environment, provider) = try makeEnvironment()
    let state = BrowserTabRestoreState(
      profileID: environment.profiles.defaultProfileID, url: try testURL("https://b.example/two"),
      title: "Two", faviconPNG: Data([1]), history: try RestoreStateTests.history(), isPinned: true)
    let model = environment.restoreTab(state)
    #expect(model.id == state.id)
    #expect(model.title == "Two")
    #expect(model.isPinned)
    #expect(model.canGoBack && model.canGoForward)
    #expect(!model.isActivated)
    #expect(provider.requests.isEmpty)
    #expect(model.snapshotForRestore() == state)
  }

  @Test func activationRebuildsHistoryOnChromium() async throws {
    let (environment, provider) = try makeEnvironment()
    let history = try RestoreStateTests.history()
    let model = environment.restoreTab(
      BrowserTabRestoreState(
        profileID: environment.profiles.defaultProfileID, url: history.current?.url,
        title: "Two", history: history))
    model.activate()
    let tab = try #require(provider.engines[.chromium]?.tabs.first)
    #expect(tab.loads == [BrowserRestorePlaceholder.startURL])
    #expect(model.isLoading)
    #expect(try await waitUntil { tab.scripts.contains { $0.contains("history.pushState") } })
    // The page replaced the current placeholder with the real entry.
    tab.history = BrowserNavigationHistory(
      entries: [
        BrowserNavigationEntry(
          url: try testURL(
            "about:blank\(BrowserRestorePlaceholder.fragment(for: history.entries[0]))"),
          title: ""),
        history.entries[1],
        BrowserNavigationEntry(
          url: try testURL(
            "about:blank\(BrowserRestorePlaceholder.fragment(for: history.entries[2]))"),
          title: ""),
      ], currentIndex: 1)
    tab.state.url = history.entries[1].url
    tab.state.title = history.entries[1].title
    #expect(try await waitUntil { !model.isLoading })
    let snapshot = model.snapshotForRestore()
    #expect(snapshot.history == history)
    #expect(
      try await waitUntil {
        environment.history(for: model.profileID).visits.first?.url == history.entries[1].url
      })
    // Going back lands on a placeholder, which the model swaps for its page.
    tab.state.url = tab.history.entries[0].url
    #expect(model.url == history.entries[0].url)
    #expect(try await waitUntil { tab.scripts.contains(BrowserRestorePlaceholder.replaceScript) })
  }

  @Test func webKitUsesInteractionState() throws {
    let (environment, provider) = try makeEnvironment(engine: .system)
    let state = BrowserTabRestoreState(
      profileID: environment.profiles.defaultProfileID, url: try testURL("https://b.example/two"),
      history: try RestoreStateTests.history(), webKitInteractionState: Data([7, 7, 7]))
    let model = environment.restoreTab(state)
    model.activate()
    let tab = try #require(provider.engines[.system]?.tabs.first)
    #expect(tab.restoredData == Data([7, 7, 7]))
    #expect(tab.loads.isEmpty)
  }

  @Test func closeRecordsAndReopenRestores() throws {
    let (environment, _) = try makeEnvironment()
    let model = environment.makeTab(url: try testURL("https://example.com/"))
    model.activate()
    let state = model.close()
    #expect(model.isClosed)
    #expect(environment.recentlyClosed.states.last == state)
    let reopened = try #require(environment.reopenClosedTab())
    #expect(reopened.id == state.id)
    #expect(reopened.url == (try testURL("https://example.com/")))
    #expect(environment.recentlyClosed.states.isEmpty)
  }

  @Test func zoomIsRememberedPerSite() async throws {
    let (environment, provider) = try makeEnvironment()
    let model = environment.makeTab(url: try testURL("https://zoom.example/a"))
    model.activate()
    let tab = try #require(provider.engines[.chromium]?.tabs.first)
    model.zoomIn()
    #expect(tab.state.zoomFactor == 1.1)
    #expect(
      environment.zoom(for: model.profileID).factor(for: try testURL("https://zoom.example/b"))
        == 1.1)
    let second = environment.makeTab(url: try testURL("https://zoom.example/c"))
    second.activate()
    let secondTab = try #require(provider.engines[.chromium]?.tabs.last)
    #expect(try await waitUntil { secondTab.state.zoomFactor == 1.1 })
    model.resetZoom()
    #expect(environment.zoom(for: model.profileID).factors.isEmpty)
  }

  @Test func muteCarriesIntoTheEngineAndRestoreState() throws {
    let (environment, provider) = try makeEnvironment()
    let model = environment.makeTab(url: try testURL("https://audio.example/"))
    model.toggleMute()
    model.activate()
    let tab = try #require(provider.engines[.chromium]?.tabs.first)
    #expect(tab.state.isMuted)
    #expect(model.snapshotForRestore().isMuted)
  }

  @Test func omniboxSubmitsSearchesAndURLs() throws {
    let (environment, provider) = try makeEnvironment()
    let model = environment.makeTab()
    model.activate()
    let tab = try #require(provider.engines[.chromium]?.tabs.first)
    try model.submitOmnibox("example.org")
    try model.submitOmnibox("swift testing")
    #expect(
      tab.loads.map(\.absoluteString) == [
        "https://example.org", "https://www.google.com/search?q=swift%20testing",
      ])
    #expect(throws: BrowserError.self) { try model.submitOmnibox("  ") }
  }

  @Test func deletingAProfileClosesItsTabsAndDeletesItsData() async throws {
    let (environment, provider) = try makeEnvironment()
    let work = try environment.profiles.create(name: "Work", color: .orange)
    let model = environment.makeTab(profileID: work.id, url: try testURL("https://work.example/"))
    model.activate()
    environment.history(for: work.id).recordVisit(
      url: try testURL("https://work.example/"), title: "W")
    try environment.history(for: work.id).flush()
    try await environment.profiles.delete(id: work.id)
    #expect(model.isClosed)
    #expect(provider.engines[.chromium]?.deleted.contains(work.browserProfile) == true)
    #expect(environment.history(for: work.id).visits.isEmpty)
  }

  @Test func clearingDataReachesEnginesAndStores() async throws {
    let (environment, provider) = try makeEnvironment()
    let id = environment.profiles.defaultProfileID
    environment.history(for: id).recordVisit(url: try testURL("https://a.example/"), title: "A")
    _ = try provider.engine(for: .chromium)
    try await environment.clearBrowsingData(profileID: id, types: [.history, .cookies], since: nil)
    #expect(environment.history(for: id).visits.isEmpty)
    #expect(provider.engines[.chromium]?.removed.first?.0 == .cookies)
  }
}
