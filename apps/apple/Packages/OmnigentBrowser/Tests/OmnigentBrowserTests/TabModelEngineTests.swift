import AppKit
import Foundation
import OmnigentViewTesting
import Testing

@testable import OmnigentBrowser

@MainActor
@Suite("A tab model and its engine tab", .serialized)
struct TabModelEngineTests {
  private struct Restored {
    let model: BrowserTabModel
    let tab: FakeTab
    let history: BrowserNavigationHistory
  }

  /// A model restored from three-page history, activated on a fake engine.
  private func restoredModel() throws -> Restored {
    let (environment, provider) = try makeEnvironment()
    let history = try RestoreStateTests.history()
    let model = environment.restoreTab(
      BrowserTabRestoreState(
        profileID: environment.profiles.defaultProfileID, url: history.current?.url,
        title: "Two", history: history))
    model.activate()
    let tab = try #require(provider.engines[.chromium]?.tabs.first)
    return Restored(model: model, tab: tab, history: history)
  }

  @Test("a restore that takes too long gives up and loads the current page")
  func restoreTimesOut() throws {
    let restored = try restoredModel()
    let (model, tab, history) = (restored.model, restored.tab, restored.history)
    model.restoreTimedOut(ObjectIdentifier(model))
    #expect(model.isLoading)
    #expect(tab.loads == [BrowserRestorePlaceholder.startURL])

    model.restoreTimedOut(ObjectIdentifier(tab))
    guard case .navigationFailed(_, _, let message)? = model.lastError else {
      Issue.record("expected the timeout to be reported")
      return
    }
    #expect(message.contains("timed out"))
    #expect(tab.loads.last == history.current?.url)

    let loads = tab.loads.count
    model.restoreTimedOut(ObjectIdentifier(tab))
    #expect(tab.loads.count == loads)
  }

  @Test("a restore waits for its start page, then for a real page, ignoring anything else")
  func restoreSteps() async throws {
    let restored = try restoredModel()
    let (model, tab) = (restored.model, restored.tab)
    tab.state.url = try testURL("https://elsewhere.example/")
    model.advanceRestore(tab)
    #expect(tab.scripts.isEmpty)
    tab.state.url = BrowserRestorePlaceholder.startURL
    #expect(try await waitUntil { tab.scripts.contains { $0.contains("history.pushState") } })
    model.advanceRestore(tab)
    let scripts = tab.scripts.count
    tab.state.url = try testURL("about:blank")
    model.advanceRestore(tab)
    #expect(model.isLoading)
    #expect(tab.scripts.count == scripts)
  }

  @Test("only a settled tab on a new placeholder has its page swapped in")
  func placeholderGuards() throws {
    let restored = try restoredModel()
    let (model, tab) = (restored.model, restored.tab)
    model.replacePlaceholder(try testURL("https://a.example/"), in: tab)
    #expect(tab.scripts.isEmpty)
    let placeholder = try testURL(
      "about:blank\(BrowserRestorePlaceholder.fragment(for: restored.history.entries[0]))")
    tab.state.isLoading = true
    model.replacePlaceholder(placeholder, in: tab)
    #expect(tab.scripts.isEmpty)
  }

  @Test("a restore whose script fails reports it and loads the current page")
  func rebuildFails() async throws {
    let restored = try restoredModel()
    let (model, tab, history) = (restored.model, restored.tab, restored.history)
    let failure = BrowserError.scriptFailed(message: "rebuild failed")
    tab.scriptFailure = failure
    tab.state.url = BrowserRestorePlaceholder.startURL
    tab.state.title = "start"
    #expect(try await waitUntil { model.lastError == failure })
    #expect(tab.loads.last == history.current?.url)
  }

  @Test("a placeholder that can't be swapped loads its page directly")
  func placeholderFails() async throws {
    let restored = try restoredModel()
    let (model, tab, history) = (restored.model, restored.tab, restored.history)
    tab.state.url = BrowserRestorePlaceholder.startURL
    #expect(try await waitUntil { tab.scripts.contains { $0.contains("history.pushState") } })
    tab.state.url = history.entries[1].url
    #expect(try await waitUntil { !model.isLoading })

    let failure = BrowserError.scriptFailed(message: "no replace")
    tab.scriptFailure = failure
    let placeholder = try testURL(
      "about:blank\(BrowserRestorePlaceholder.fragment(for: history.entries[0]))")
    tab.state.url = placeholder
    #expect(model.title == history.entries[0].title)
    #expect(try await waitUntil { model.lastError == failure })
    #expect(tab.loads.last == history.entries[0].url)
  }

  @Test("a page closing itself closes the tab, or asks the app when it handles closing")
  func pageCloses() async throws {
    let (environment, provider) = try makeEnvironment()
    let plain = environment.makeTab(url: try testURL("https://a.example/"))
    plain.activate()
    let plainTab = try #require(provider.engines[.chromium]?.tabs.last)
    plainTab.close()
    #expect(try await waitUntil { plain.isClosed })

    var asked: [UUID] = []
    environment.onCloseTab = { asked.append($0.id) }
    let handled = environment.makeTab(url: try testURL("https://a.example/"))
    handled.activate()
    let handledTab = try #require(provider.engines[.chromium]?.tabs.last)
    handledTab.close()
    #expect(try await waitUntil { asked == [handled.id] })
    #expect(!handled.isClosed)
  }

  @Test("a tab's name falls back from the title to the host, the address and New Tab")
  func displayTitles() throws {
    let (environment, provider) = try makeEnvironment()
    let model = environment.makeTab(url: try testURL("about:blank"))
    #expect(model.displayTitle == "New Tab")
    model.activate()
    let tab = try #require(provider.engines[.chromium]?.tabs.last)
    tab.state.url = try testURL("mailto:a@example.com")
    #expect(model.displayTitle == "mailto:a@example.com")
    tab.state.url = try testURL("https://a.example/")
    #expect(model.displayTitle == "a.example")
    tab.state.title = "Page"
    #expect(model.displayTitle == "Page")
    #expect(model.pageError == nil)
    tab.state.lastError = .tabNotReady
    #expect(model.pageError == .tabNotReady)
  }

  @Test("a new tab that never activated still restores to its address")
  func snapshotBeforeActivation() throws {
    let (environment, _) = try makeEnvironment()
    let url = try testURL("https://a.example/")
    let snapshot = environment.makeTab(url: url).snapshotForRestore()
    #expect(snapshot.url == url)
    #expect(snapshot.history.entries.map(\.url) == [url])
    let empty = environment.makeTab().snapshotForRestore()
    #expect(empty.url == nil)
    #expect(empty.history == .empty)
  }

  @Test("restoring into an open tab replaces what it shows; into a sleeping one, it waits")
  func restoreInPlace() throws {
    let (environment, provider) = try makeEnvironment()
    let target = try testURL("https://b.example/")
    let state = BrowserTabRestoreState(
      profileID: environment.profiles.defaultProfileID, url: target, title: "B",
      faviconPNG: try squarePNG(size: 8),
      history: BrowserNavigationHistory(
        entries: [BrowserNavigationEntry(url: target, title: "B")], currentIndex: 0),
      isPinned: true, isMuted: true)

    let sleeping = environment.makeTab(url: try testURL("https://a.example/"))
    sleeping.restore(from: state)
    #expect(sleeping.url == target)
    #expect(sleeping.isPinned)
    #expect(sleeping.favicon != nil)
    #expect(provider.engines[.chromium]?.tabs.isEmpty != false)

    let open = environment.makeTab(url: try testURL("https://a.example/"))
    open.activate()
    let before = provider.engines[.chromium]?.tabs.count ?? 0
    open.restore(from: state)
    let tabs = try #require(provider.engines[.chromium]?.tabs)
    #expect(tabs.count == before + 1)
    #expect(tabs.last?.loads.last == target)
    #expect(tabs.last?.state.isMuted == true)
  }

  @Test("the page's icon shows on the tab; a missing one leaves a reason")
  func icons() async throws {
    let (environment, provider) = try makeEnvironment()
    let model = environment.makeTab(url: try testURL("https://a.example/"))
    model.activate()
    let tab = try #require(provider.engines[.chromium]?.tabs.last)
    let file = FileManager.default.temporaryDirectory
      .appending(path: "tab-icon-\(UUID().uuidString).png")
    defer { try? FileManager.default.removeItem(at: file) }
    try squarePNG(size: 32).write(to: file)
    tab.state.faviconURL = file
    #expect(try await waitUntil { model.favicon != nil })

    tab.state.faviconURL = FileManager.default.temporaryDirectory.appending(
      path: "gone-\(UUID()).png")
    #expect(try await waitUntil { model.faviconError != nil })
    tab.state.faviconURL = nil
    tab.state.title = "After"
    let history = environment.history(for: model.profileID)
    #expect(try await waitUntil { history.visits.first?.title == "After" })
  }

  @Test("commands that fail leave their reason on the tab")
  func failingCommands() async throws {
    let (environment, provider) = try makeEnvironment()
    let model = environment.makeTab(url: try testURL("https://a.example/"))
    model.activate()
    let tab = try #require(provider.engines[.chromium]?.tabs.last)
    let failure = BrowserError.featureUnsupported(feature: "x", engine: .chromium)
    tab.failure = failure
    model.showDevTools()
    #expect(model.lastError == failure)
    model.dismissError()
    model.printPage()
    #expect(try await waitUntil { model.lastError == failure })
    model.dismissError()
    model.viewSource()
    #expect(try await waitUntil { model.lastError == failure })
  }
}

@MainActor
@Suite("The browser environment", .serialized)
struct BrowserEnvironmentTests {
  private func popup(
    _ provider: FakeProvider, opener: any BrowserTab, profile: BrowserProfile
  ) throws -> BrowserPopup {
    let engine = try provider.engine(for: .chromium)
    let tab = try engine.makeTab(profile: profile, initialURL: nil)
    return BrowserPopup(
      tab: tab, opener: opener, targetURL: try testURL("https://a.example/popup"),
      disposition: .popup, requestedSize: CGSize(width: 300, height: 200))
  }

  @Test("a page's popup goes to the app as a tab, with its opener and size")
  func popupToTheApp() throws {
    let (environment, provider) = try makeEnvironment()
    var opened: [(BrowserTabModel, BrowserTabOpenContext)] = []
    environment.onOpenTab = { opened.append(($0, $1)) }
    let model = environment.makeTab(url: try testURL("https://a.example/"))
    model.activate()
    let openerTab = try #require(provider.engines[.chromium]?.tabs.last)
    let fromTab = try popup(provider, opener: openerTab, profile: openerTab.profile)
    environment.presenter.tab(openerTab, didOpen: fromTab)
    let context = try #require(opened.last?.1)
    #expect(context.opener === model)
    #expect(context.disposition == .popup)
    #expect(context.requestedSize == CGSize(width: 300, height: 200))
    #expect(opened.last?.0.profileID == model.profileID)
    #expect(opened.last?.0.tab === fromTab.tab)

    // An opener that's no longer a tab: the popup keeps its profile, or falls back to the default.
    let second = try environment.profiles.create(name: "Second", color: .green, avatar: .initials)
    let strangerTab = FakeTab(kind: .chromium, profile: .ephemeral("stranger"), initialURL: nil)
    let fromStranger = try popup(provider, opener: strangerTab, profile: second.browserProfile)
    environment.presenter.tab(strangerTab, didOpen: fromStranger)
    #expect(opened.last?.0.profileID == second.id)
    #expect(opened.last?.1.opener == nil)
    let unknownProfile = try popup(provider, opener: strangerTab, profile: .ephemeral("unknown"))
    environment.presenter.tab(strangerTab, didOpen: unknownProfile)
    #expect(opened.last?.0.profileID == environment.profiles.defaultProfileID)
  }

  @Test("a save at quit keeps what's waiting; one that fails doesn't stop the quit")
  func flushAtQuit() throws {
    let directory = try temporaryDirectory()
    let (environment, _) = try makeEnvironment(directory: directory)
    let profileID = environment.profiles.defaultProfileID
    let url = try testURL("https://a.example/")
    environment.history(for: profileID).recordVisit(url: url, title: "A")
    NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)
    let reloaded = try makeEnvironment(directory: directory).0.history(for: profileID)
    #expect(reloaded.visits.first?.url == url)

    environment.zoom(for: profileID).setFactor(1.5, for: url)
    try environment.flush()

    try FileManager.default.removeItem(at: directory)
    try Data("not a folder".utf8).write(to: directory)
    defer { try? FileManager.default.removeItem(at: directory) }
    environment.history(for: profileID).recordVisit(
      url: try testURL("https://b.example/"), title: "B")
    #expect(throws: BrowserError.self) { try environment.flush() }
    environment.history(for: profileID).recordVisit(
      url: try testURL("https://c.example/"), title: "C")
    NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)
  }

  @Test("with no tab strip, a page's popup gets its own window")
  func popupWithoutATabStrip() throws {
    let (environment, provider) = try makeEnvironment()
    SystemSideEffects.reset()
    let model = environment.makeTab(url: try testURL("https://a.example/"))
    model.activate()
    let opener = try #require(provider.engines[.chromium]?.tabs.last)
    let popup = try popup(provider, opener: opener, profile: opener.profile)
    environment.presenter.tab(opener, didOpen: popup)
    #expect(SystemSideEffects.record.shownWindowTitles.last == "a.example")
    popup.tab.close()
  }

  @Test("a bookmark that can't be saved leaves its reason on the tab")
  func bookmarkFailure() throws {
    let blocker = try temporaryDirectory().appending(path: "blocker")
    try Data("a file".utf8).write(to: blocker)
    let (environment, _) = try makeEnvironment(directory: blocker.appending(path: "sub"))
    let model = environment.makeTab(url: try testURL("https://a.example/"))
    model.toggleBookmark()
    #expect(model.lastError != nil)
  }

  @Test("the browser's data lives under Application Support")
  func standardDirectory() {
    #expect(BrowserEnvironment.standardDirectory.path.contains("Application Support"))
    #expect(BrowserEnvironment.standardDirectory.lastPathComponent == "Browser")
  }

  @Test("a profile folder that can't be deleted says so")
  func deleteFolderFailure() async throws {
    let directory = try temporaryDirectory()
    let (environment, _) = try makeEnvironment(directory: directory)
    let second = try environment.profiles.create(name: "Second", color: .green, avatar: .initials)
    let history = environment.history(for: second.id)
    history.recordVisit(url: try testURL("https://a.example/"), title: "A")
    try history.flush()
    let attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o555]
    let contents = try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: nil)
    let parents = contents.filter { $0.hasDirectoryPath }
    for parent in parents {
      try FileManager.default.setAttributes(attributes, ofItemAtPath: parent.path)
    }
    defer {
      for parent in parents {
        try? FileManager.default.setAttributes(
          [.posixPermissions: 0o755], ofItemAtPath: parent.path)
      }
    }
    await #expect(throws: BrowserError.self) {
      try await environment.profiles.delete(id: second.id)
    }
  }
}
