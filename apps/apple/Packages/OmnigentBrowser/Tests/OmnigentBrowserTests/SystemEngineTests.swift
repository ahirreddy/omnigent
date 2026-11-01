import Foundation
import Testing

@testable import OmnigentBrowser

@MainActor
func waitUntil(
  timeout: Duration = .seconds(10), _ condition: () -> Bool
) async throws -> Bool {
  let clock = ContinuousClock()
  let deadline = clock.now + timeout
  while !condition() {
    if clock.now >= deadline {
      return false
    }
    try await Task.sleep(for: .milliseconds(20))
  }
  return true
}

@MainActor
@Suite("System engine (WebKit)", .serialized)
struct SystemEngineTests {
  private func writePage(_ name: String, title: String, body: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "OmnigentBrowserTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appending(path: name)
    try "<!doctype html><title>\(title)</title><body>\(body)</body>".write(
      to: url, atomically: true, encoding: .utf8)
    return url
  }

  @Test func loadsFileURLAndUpdatesState() async throws {
    let engine = SystemBrowserEngine()
    let page = try writePage("one.html", title: "First Page", body: "<p id=t>hello</p>")
    let tab = try engine.makeTab(profile: .ephemeral("test-state"), initialURL: page)
    defer { tab.close() }

    #expect(
      try await waitUntil { !tab.state.isLoading && tab.state.title == "First Page" })
    #expect(tab.state.url == page)
    #expect(tab.state.estimatedProgress == 1)
    #expect(!tab.state.canGoBack)
    #expect(tab.state.lastError == nil)

    let second = try writePage("two.html", title: "Second Page", body: "")
    tab.load(second)
    #expect(
      try await waitUntil { !tab.state.isLoading && tab.state.title == "Second Page" })
    #expect(tab.state.canGoBack)

    tab.goBack()
    #expect(try await waitUntil { tab.state.title == "First Page" })
    #expect(tab.state.canGoForward)
  }

  @Test func evaluatesJavaScript() async throws {
    let engine = SystemBrowserEngine()
    let page = try writePage("js.html", title: "JS", body: "<p id=t>hello</p>")
    let tab = try engine.makeTab(profile: .ephemeral("test-js"), initialURL: page)
    defer { tab.close() }
    #expect(try await waitUntil { !tab.state.isLoading && tab.state.title == "JS" })

    #expect(
      try await tab.evaluateJavaScript("document.getElementById('t').textContent")
        == .string("hello"))
    #expect(try await tab.evaluateJavaScript("1 + 1") == .number(2))
    #expect(
      try await tab.evaluateJavaScript("({a: [true, null]})")
        == .object(["a": .array([.bool(true), .null])]))
    await #expect(throws: BrowserError.self) {
      try await tab.evaluateJavaScript("throw new Error('boom')")
    }
  }

  @Test func navigationFailureIsSurfaced() async throws {
    let engine = SystemBrowserEngine()
    let missing = FileManager.default.temporaryDirectory.appending(
      path: "does-not-exist-\(UUID().uuidString).html")
    let tab = try engine.makeTab(profile: .ephemeral("test-fail"), initialURL: missing)
    defer { tab.close() }
    #expect(try await waitUntil { tab.state.lastError != nil })
    guard case .navigationFailed = tab.state.lastError else {
      Issue.record("expected navigationFailed, got \(String(describing: tab.state.lastError))")
      return
    }
  }

  @Test func closedTabRejectsWork() async throws {
    let tab = try SystemBrowserEngine().makeTab(profile: .ephemeral("closed"), initialURL: nil)
    tab.close()
    #expect(tab.state.isClosed)
    await #expect(throws: BrowserError.tabClosed) { try await tab.evaluateJavaScript("1") }
  }

  @Test func historyAndInteractionStateRestoreIntoANewTab() async throws {
    let engine = SystemBrowserEngine()
    let first = try writePage("h1.html", title: "History One", body: "")
    let second = try writePage("h2.html", title: "History Two", body: "")
    let tab = try engine.makeTab(profile: .ephemeral("test-restore"), initialURL: first)
    defer { tab.close() }
    #expect(try await waitUntil { !tab.state.isLoading && tab.state.title == "History One" })
    tab.load(second)
    #expect(try await waitUntil { !tab.state.isLoading && tab.state.title == "History Two" })
    let history = tab.navigationHistory
    #expect(history.entries.map(\.title) == ["History One", "History Two"])
    #expect(history.currentIndex == 1)
    let data = try #require(tab.engineRestoreData)

    let restored = try engine.makeTab(profile: .ephemeral("test-restore"), initialURL: nil)
    defer { restored.close() }
    #expect(restored.restoreEngineState(data))
    #expect(
      try await waitUntil { !restored.state.isLoading && restored.state.title == "History Two" })
    #expect(restored.state.canGoBack)
    restored.goBack()
    #expect(try await waitUntil { restored.state.title == "History One" })
  }

  @Test func zoomHardReloadAndMuteUpdateState() async throws {
    let engine = SystemBrowserEngine()
    let page = try writePage("z.html", title: "Zoom", body: "<audio></audio>")
    let tab = try engine.makeTab(profile: .ephemeral("test-zoom"), initialURL: page)
    defer { tab.close() }
    #expect(try await waitUntil { !tab.state.isLoading && tab.state.title == "Zoom" })
    tab.setZoomFactor(1.25)
    #expect(tab.state.zoomFactor == 1.25)
    tab.setAudioMuted(true)
    #expect(tab.state.isMuted)
    tab.reload(ignoringCache: true)
    #expect(try await waitUntil { !tab.state.isLoading && tab.state.title == "Zoom" })
    let source = try await tab.viewSourceURL()
    #expect(source.scheme == "data")
  }
}
